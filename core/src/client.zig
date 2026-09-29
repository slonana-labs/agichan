//! One path for every wallet operation, used by both the CLI dispatcher and the
//! swarm. keygen/address are local; the chat subcommands run over an injectable
//! transport Backend (HTTPS in production, the in-process relay in tests) so a
//! swarm of many wallets is exercised without a network. Mirrors what the bash
//! did by shelling out to `slonana chat ...`, but in-process.
const std = @import("std");
const Allocator = std.mem.Allocator;
const flows = @import("flows.zig");
const auth = @import("auth.zig");
const base58 = @import("base58.zig");
const keypair = @import("keypair.zig");
const statefile = @import("statefile.zig");
const state_mod = @import("state.zig");
const text = @import("text.zig");
const rpc = @import("rpc.zig");
const http_transport = @import("http_transport.zig");
const data = @import("data.zig");
const solana = @import("solana.zig");
const board = @import("board.zig");

pub const Error = flows.Error; // Allocator.Error || std.Io.Writer.Error

/// `pay`'s confirmation: poll getSignatureStatuses this many times, this apart,
/// before giving up and NOT claiming payment (chat_pay confirms err:null first).
pub const pay_confirm_tries = 40;
pub const pay_confirm_interval_ns = 1500 * std.time.ns_per_ms;

pub const PayArgs = struct {
    room: []const u8,
    payee: []const u8, // "@handle" or a base58 wallet
    lamports: u64,
    as: []const u8, // the paying handle; must be the task's creator
    task: []const u8,
    limit: u64 = 200,
};

/// One wallet subcommand, the same set `slonana chat` exposes.
pub const Cmd = union(enum) {
    login,
    join: []const u8,
    send: struct { room: []const u8, text: []const u8 },
    read: struct { room: []const u8, limit: u64, mention: []const u8 = "" },
    tasks: struct { room: []const u8, limit: u64, json: bool },
    create: []const u8,
    invite: struct { room: []const u8, wallet: []const u8 },
    leave: []const u8,
    ban: struct { room: []const u8, wallet: []const u8 },
    members: []const u8,
    forward: struct { room: []const u8, wallet: []const u8, limit: u64 },
    pay: PayArgs,
};

// ---- transport backend ----------------------------------------------------

pub const Conn = struct {
    ctx: *anyopaque,
    t: rpc.Transport,
    closeFn: *const fn (ctx: *anyopaque) void,
    pub fn close(c: Conn) void {
        c.closeFn(c.ctx);
    }
};

pub const Backend = struct {
    ctx: *anyopaque,
    openFn: *const fn (ctx: *anyopaque, url: []const u8) Conn,
    pub fn open(b: Backend, url: []const u8) Conn {
        return b.openFn(b.ctx, url);
    }
};

fn httpsOpen(_: *anyopaque, url: []const u8) Conn {
    const hc = std.heap.page_allocator.create(http_transport.Https) catch @panic("agichan: out of memory opening HTTPS");
    hc.* = http_transport.Https.init(std.heap.page_allocator, url);
    return .{ .ctx = hc, .t = hc.transport(), .closeFn = httpsClose };
}
fn httpsClose(ctx: *anyopaque) void {
    const hc: *http_transport.Https = @ptrCast(@alignCast(ctx));
    hc.deinit();
    std.heap.page_allocator.destroy(hc);
}

/// The production backend: one std.http.Client per call, over system roots.
pub const https_backend = Backend{ .ctx = @ptrFromInt(@alignOf(usize)), .openFn = httpsOpen };

pub const Env = struct {
    a: Allocator,
    backend: Backend,
    url: []const u8,
    /// Lowercased host of `url`, for login's challenge check (auth.urlHost).
    host: []const u8,
    bound_only: bool,
    rng: std.Random,
    prog: []const u8 = "agichan",
    /// When set, chat state is <state_dir>/<wallet>.json instead of the default
    /// config-home path. Used to isolate tests and keep a swarm's state together.
    state_dir: ?[]const u8 = null,
};

fn statedirPath(a: Allocator, dir: []const u8, wallet: []const u8) Allocator.Error![]const u8 {
    const file = try std.fmt.allocPrint(a, "{s}.json", .{wallet});
    defer a.free(file);
    return std.fs.path.join(a, &.{ dir, file });
}

const FileSaver = struct {
    path: []const u8,
    fn save(ctx: *anyopaque, a: Allocator, st: *const state_mod.State) Allocator.Error!?[]const u8 {
        const self: *FileSaver = @ptrCast(@alignCast(ctx));
        return statefile.save(a, self.path, st);
    }
};

fn failOut(err: *std.Io.Writer, prog: []const u8, a: Allocator, why: []const u8) Error!u8 {
    try err.print("{s}: {s}\n", .{ prog, try text.oneLine(a, why) });
    return 1;
}

/// Runs `cmd` as the wallet at `keypair_path`, its chat state at `state_override`
/// or the default for that wallet, one command at a time under the state lock.
/// Writes to `out`/`err`; returns the exit code (0, 1 failed, 2 refused).
pub fn execAs(env: Env, keypair_path: []const u8, state_override: ?[]const u8, cmd: Cmd, out: *std.Io.Writer, err: *std.Io.Writer) Error!u8 {
    const a = env.a;
    const kp_text = std.fs.cwd().readFileAlloc(a, keypair_path, 1 << 20) catch |e|
        return failOut(err, env.prog, a, try std.fmt.allocPrint(a, "could not load keypair {s}: {s}", .{ keypair_path, @errorName(e) }));
    var kp = keypair.parse(a, kp_text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidKeypair => return failOut(err, env.prog, a, try std.fmt.allocPrint(a, "could not load keypair {s}: not a JSON array of 64 integers 0..255", .{keypair_path})),
        error.KeypairMismatch => return failOut(err, env.prog, a, try std.fmt.allocPrint(a, "could not load keypair {s}: its public key is not its seed's", .{keypair_path})),
    };
    defer kp.wipe();
    std.crypto.secureZero(u8, kp_text);
    const wallet = try base58.encode(a, &kp.public_key);

    const state_path = state_override orelse if (env.state_dir) |dir|
        try statedirPath(a, dir, wallet)
    else switch (try statefile.defaultPath(a, wallet)) {
        .ok => |p| p,
        .err => |why| return failOut(err, env.prog, a, why),
    };
    if (try statefile.ensureDir(a, state_path)) |why| return failOut(err, env.prog, a, why);
    const lock_path = try std.mem.concat(a, u8, &.{ state_path, ".lock" });
    var lock = statefile.Lock.acquire(lock_path, 60_000) orelse
        return failOut(err, env.prog, a, try std.fmt.allocPrint(a, "could not lock {s} within 60 s (another agichan command holds it); nothing was done", .{lock_path}));
    defer lock.release();
    var st = switch (try statefile.load(a, state_path)) {
        .ok => |s| s,
        .err => |why| return failOut(err, env.prog, a, why),
    };
    defer st.wipe();

    // Any room id going into a URL path is checked first, as chat.cpp does.
    const room_opt: ?[]const u8 = switch (cmd) {
        .join => |r| r,
        .send => |x| x.room,
        .read => |x| x.room,
        .tasks => |x| x.room,
        .invite => |x| x.room,
        .leave => |r| r,
        .ban => |x| x.room,
        .members => |r| r,
        .forward => |x| x.room,
        .pay => |x| x.room,
        .login, .create => null,
    };
    if (room_opt) |r| {
        if (!text.isRoomId(r)) return failOut(err, env.prog, a, try std.fmt.allocPrint(a, "{s} is not a room id (!<id>:<server>); nothing was done", .{r}));
    }

    const conn = env.backend.open(env.url);
    defer conn.close();
    var saver: FileSaver = .{ .path = state_path };
    var ctx: flows.Context = .{
        .a = a,
        .transport = conn.t,
        .rng = env.rng,
        .st = &st,
        .saver = .{ .ctx = &saver, .saveFn = FileSaver.save },
        .state_label = state_path,
        .out = out,
        .err = err,
        .keypair = kp,
        .wallet = wallet,
        .host = env.host,
        .bound_only = env.bound_only,
        .prog = env.prog,
    };
    defer ctx.keypair.wipe();
    if (cmd == .login) return flows.login(&ctx);
    if (try flows.prelude(&ctx, keypair_path)) |code| return code;
    return switch (cmd) {
        .login => unreachable,
        .join => |r| flows.join(&ctx, r),
        .send => |x| flows.send(&ctx, x.room, x.text),
        .read => |x| flows.read(&ctx, x.room, x.limit, .lines, x.mention),
        .tasks => |x| flows.read(&ctx, x.room, x.limit, if (x.json) .board_json else .board_text, ""),
        .create => |name| flows.create(&ctx, name),
        .invite => |x| flows.invite(&ctx, x.room, x.wallet),
        .leave => |r| flows.leave(&ctx, r),
        .ban => |x| flows.ban(&ctx, x.room, x.wallet),
        .members => |r| flows.membersReply(&ctx, r),
        .forward => |x| flows.forward(&ctx, x.room, x.wallet, x.limit),
        .pay => |x| payWithContext(&ctx, x),
    };
}

fn cfail(ctx: *flows.Context, why: []const u8) Error!u8 {
    try ctx.err.print("{s}: {s}\n", .{ ctx.prog, try text.oneLine(ctx.a, why) });
    return 1;
}
fn cfailf(ctx: *flows.Context, comptime fmt: []const u8, a: anytype) Error!u8 {
    return cfail(ctx, try std.fmt.allocPrint(ctx.a, fmt, a));
}

/// `pay`'s plain-transfer settlement (escrow AcceptWork is not ported here; it
/// stays on the MCP/slonana client). Validates against the board, transfers,
/// confirms err:null, then posts the PAID line. Runs inside execAs's state lock.
fn payWithContext(ctx: *flows.Context, args: PayArgs) Error!u8 {
    const a = ctx.a;
    if (args.task.len == 0) return cfail(ctx, "--task <id> is required: a payment is for a task");
    if (args.lamports == 0) return cfail(ctx, "a payment must be more than zero lamports");
    if (args.lamports > board.max_pay_lamports)
        return cfailf(ctx, "at most {d} lamports per payment; use a plain transfer for more", .{board.max_pay_lamports});
    if (!board.isBoardAuthor(args.as)) return cfail(ctx, "--as must be a handle");

    const b = try flows.readBoard(ctx, args.room, args.limit);
    var payee_handle = args.payee;
    var payee_wallet: []const u8 = "";
    if (args.payee.len > 1 and args.payee[0] == '@') {
        payee_handle = args.payee[1..];
        payee_wallet = (try board.walletOfHandle(a, b.bindings, payee_handle)) orelse
            return cfailf(ctx, "@{s} is not bound to a wallet in this room", .{payee_handle});
    } else {
        if ((try base58.aexchatDecodedLen(a, args.payee)) != 32) return cfailf(ctx, "{s} is not a wallet or an @handle", .{args.payee});
        payee_wallet = args.payee;
    }
    // The board says money is owed: DONE, unpaid, --as created it, payee finished it.
    const why = try board.taskPayRefusal(a, b.tasks, b.bindings, args.task, args.as, ctx.st.user_id, payee_wallet, false);
    if (why.len != 0) return cfail(ctx, why);

    const to = base58.decode32(payee_wallet) orelse return cfailf(ctx, "payee wallet {s} is not 32 bytes", .{payee_wallet});
    const bh = switch (try solana.getLatestBlockhash(a, ctx.transport)) {
        .ok => |h| h,
        .err => |e| return cfailf(ctx, "getLatestBlockhash: {s}", .{e}),
    };
    const tx = try solana.signedTransferB58(a, ctx.keypair, to, bh, args.lamports);
    const sig = switch (try solana.sendTransaction(a, ctx.transport, tx)) {
        .ok => |s| s,
        .err => |e| return cfailf(ctx, "sendTransaction: {s} (nothing was paid)", .{e}),
    };
    try ctx.err.print("{s}: sending {s}\n", .{ ctx.prog, sig });
    var confirmed = false;
    var i: usize = 0;
    while (i < pay_confirm_tries) : (i += 1) {
        switch (try solana.signatureStatus(a, ctx.transport, sig)) {
            .status => |s| switch (s) {
                .confirmed => {
                    confirmed = true;
                    break;
                },
                .failed => return cfailf(ctx, "the transfer {s} failed on chain; nothing was claimed", .{sig}),
                .unknown => {},
            },
            .err => {},
        }
        std.Thread.sleep(pay_confirm_interval_ns);
    }
    if (!confirmed) {
        try ctx.out.print("paid {d} lamports for {s}: {s} (not confirmed in time; the PAID line was NOT posted -- verify it landed, then post it)\n", .{ args.lamports, args.task, sig });
        return 1;
    }
    const line = try board.paidLine(a, args.as, payee_handle, args.task, args.lamports, sig);
    const code = try flows.send(ctx, args.room, line);
    if (code == 0) try ctx.out.print("paid {d} lamports for {s}, confirmed: {s}\n", .{ args.lamports, args.task, sig });
    return code;
}

// ---- local commands (no transport, no state) ------------------------------

/// `keygen new --outfile <path>`: a fresh wallet, written 0600 in a 0700 dir,
/// its address printed. Never overwrites an existing non-empty file.
pub fn keygenNew(a: Allocator, rng: std.Random, outfile: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) Error!u8 {
    if (std.fs.cwd().statFile(outfile)) |info| {
        if (info.size != 0) {
            try err.print("agichan: {s} already exists; refusing to overwrite a wallet\n", .{try text.oneLine(a, outfile)});
            return 1;
        }
    } else |_| {}
    if (try statefile.ensureDir(a, outfile)) |why| return failOut(err, "agichan", a, why);
    var kp = keypair.generate(rng);
    defer kp.wipe();
    const file_text = try keypair.format(a, kp);
    defer {
        std.crypto.secureZero(u8, file_text);
        a.free(file_text);
    }
    if (try data.writeFile600(a, outfile, file_text)) |why| return failOut(err, "agichan", a, why);
    const wallet = try base58.encode(a, &kp.public_key);
    try out.print("{s}\n", .{wallet});
    return 0;
}

/// Whether the wallet at `keypair_path` already holds a login token (so the
/// swarm can skip a redundant login). Cheap: a local read, no network.
pub fn hasToken(a: Allocator, keypair_path: []const u8, state_dir: ?[]const u8) bool {
    const kp_text = std.fs.cwd().readFileAlloc(a, keypair_path, 1 << 20) catch return false;
    var kp = keypair.parse(a, kp_text) catch return false;
    defer kp.wipe();
    const wallet = base58.encode(a, &kp.public_key) catch return false;
    const state_path = if (state_dir) |dir|
        statedirPath(a, dir, wallet) catch return false
    else switch (statefile.defaultPath(a, wallet) catch return false) {
        .ok => |p| p,
        .err => return false,
    };
    var st = switch (statefile.load(a, state_path) catch return false) {
        .ok => |s| s,
        .err => return false,
    };
    defer st.wipe();
    return st.token.len != 0;
}

/// `address --keypair <path>`: the wallet's base58 public key.
pub fn address(a: Allocator, keypair_path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) Error!u8 {
    const kp_text = std.fs.cwd().readFileAlloc(a, keypair_path, 1 << 20) catch |e|
        return failOut(err, "agichan", a, try std.fmt.allocPrint(a, "could not load keypair {s}: {s}", .{ keypair_path, @errorName(e) }));
    var kp = keypair.parse(a, kp_text) catch
        return failOut(err, "agichan", a, try std.fmt.allocPrint(a, "could not load keypair {s}: not a valid wallet", .{keypair_path}));
    defer kp.wipe();
    std.crypto.secureZero(u8, kp_text);
    const wallet = try base58.encode(a, &kp.public_key);
    try out.print("{s}\n", .{wallet});
    return 0;
}
