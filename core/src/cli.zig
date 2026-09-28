//! Command line (unknown or repeated flags refused, as `slonana chat` does),
//! then the state file, its lock and HTTPS around flows.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const flows = @import("flows.zig");
const text = @import("text.zig");
const auth = @import("auth.zig");
const base58 = @import("base58.zig");
const keypair = @import("keypair.zig");
const statefile = @import("statefile.zig");
const state_mod = @import("state.zig");
const http_transport = @import("http_transport.zig");

pub const version = "0.1.0";
pub const default_url = "https://rpc.slonana.com";

const usage =
    \\Usage: agichan <command> [-k KEYPAIR] [-u URL] [--state PATH]
    \\  login                     sign in with the wallet and publish its device key
    \\  join <ROOM>               accept an invite to a room
    \\  send <ROOM> --stdin       encrypt and send the whole of stdin
    \\  read <ROOM> [--limit N]   fetch key shares, decrypt the last N messages
    \\  tasks <ROOM> [--json] [--limit N]
    \\                            the task board from TASK/CLAIM/DONE/BLOCKED lines;
    \\                            --json adds handle bindings and worker presence
    \\  version
    \\Options:
    \\  -k, --keypair PATH        wallet keypair file (a JSON array of 64 integers)
    \\  -u, --url URL             relay RPC, https (default https://rpc.slonana.com)
    \\  --state PATH              state file; default <config>/agichan/<wallet>.json:
    \\                            ~/.config on Linux, ~/Library/Application Support
    \\                            on macOS, %APPDATA% on Windows
    \\  --limit N                 messages to read, 1..1000 (default 50)
    \\  --allow-unbound-devices   also share keys with, and accept shares from,
    \\                            devices whose key is not their wallet's (web
    \\                            clients), with a warning; off by default
    \\
;

const Flag = enum { keypair, url, state, limit, stdin, json, bound_only, allow_unbound, help };

fn flagOf(s: []const u8) ?Flag {
    const table = [_]struct { []const u8, Flag }{
        .{ "-k", .keypair },                      .{ "--keypair", .keypair },
        .{ "-u", .url },                          .{ "--url", .url },
        .{ "--state", .state },                   .{ "--limit", .limit },
        .{ "--stdin", .stdin },                   .{ "--json", .json },
        .{ "--bound-devices-only", .bound_only }, .{ "--allow-unbound-devices", .allow_unbound },
        .{ "-h", .help },                         .{ "--help", .help },
    };
    for (table) |e| {
        if (std.mem.eql(u8, s, e[0])) return e[1];
    }
    return null;
}

fn takesValue(f: Flag) bool {
    return switch (f) {
        .keypair, .url, .state, .limit => true,
        else => false,
    };
}

const Args = struct {
    positional: []const []const u8,
    keypair: ?[]const u8 = null,
    url: ?[]const u8 = null,
    state: ?[]const u8 = null,
    limit: ?[]const u8 = null,
    stdin: bool = false,
    json: bool = false,
    allow_unbound: bool = false,
    help: bool = false,
};

const Parsed = union(enum) {
    ok: Args,
    refused: []const u8,
};

/// strict_flag_refusal plus the parse: unknown flags, repeated flags and
/// flags without a value are refused rather than ignored.
fn parseArgs(a: Allocator, argv: []const []const u8) Allocator.Error!Parsed {
    var args: Args = .{ .positional = &.{} };
    var positional: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen = std.EnumSet(Flag).initEmpty();
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (s.len < 2 or s[0] != '-') {
            try positional.append(a, s);
            continue;
        }
        const f = flagOf(s) orelse return .{ .refused = try std.fmt.allocPrint(a, "unknown flag '{s}' (refusing rather than ignoring it)", .{s}) };
        if (seen.contains(f)) return .{ .refused = try std.fmt.allocPrint(a, "{s} given twice (one of the values would be silently dropped)", .{s}) };
        seen.insert(f);
        if (takesValue(f)) {
            if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "--"))
                return .{ .refused = try std.fmt.allocPrint(a, "{s} needs a value", .{s}) };
            i += 1;
            const v = argv[i];
            if (v.len == 0) return .{ .refused = try std.fmt.allocPrint(a, "{s} needs a value (got an empty one)", .{s}) };
            switch (f) {
                .keypair => args.keypair = v,
                .url => args.url = v,
                .state => args.state = v,
                .limit => args.limit = v,
                else => unreachable,
            }
            continue;
        }
        switch (f) {
            .stdin => args.stdin = true,
            .json => args.json = true,
            .allow_unbound => args.allow_unbound = true,
            .bound_only => {},
            .help => args.help = true,
            else => unreachable,
        }
    }
    if (seen.contains(.bound_only) and seen.contains(.allow_unbound))
        return .{ .refused = "--bound-devices-only and --allow-unbound-devices contradict each other" };
    args.positional = positional.items;
    return .{ .ok = args };
}

const Io = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,

    fn refuse(io: Io, why: []const u8) !u8 {
        try io.err.print("agichan: {s}. Nothing was done.\n", .{why});
        return 2;
    }

    fn fail(io: Io, a: Allocator, why: []const u8) !u8 {
        try io.err.print("agichan: {s}\n", .{try text.oneLine(a, why)});
        return 1;
    }
};

const FileSaver = struct {
    path: []const u8,

    fn save(ctx: *anyopaque, a: Allocator, st: *const state_mod.State) Allocator.Error!?[]const u8 {
        const self: *FileSaver = @ptrCast(@alignCast(ctx));
        return statefile.save(a, self.path, st);
    }
};

/// Runs one command; the exit code: 0, 1 (failed), 2 (refused, nothing done).
pub fn run(a: Allocator, argv: []const []const u8, io: Io) !u8 {
    const parsed = switch (try parseArgs(a, argv)) {
        .ok => |p| p,
        .refused => |why| return io.refuse(why),
    };
    const pos = parsed.positional;
    if (parsed.help or pos.len == 0) {
        try io.err.writeAll(usage);
        return if (parsed.help) 0 else 2;
    }
    const sub = pos[0];
    const Command = enum { login, join, send, read, tasks, version, help };
    const cmd = std.meta.stringToEnum(Command, sub) orelse {
        try io.err.writeAll(usage);
        return 2;
    };
    switch (cmd) {
        .version => {
            try io.out.print("agichan {s}\n", .{version});
            return 0;
        },
        .help => {
            try io.err.writeAll(usage);
            return 0;
        },
        else => {},
    }
    const want_args: usize = if (cmd == .login) 1 else 2;
    if (pos.len != want_args) {
        if (cmd == .send and pos.len > 2) return io.refuse("send takes <ROOM> and --stdin; the text comes from stdin");
        try io.err.writeAll(usage);
        return 2;
    }
    if (parsed.json and cmd != .tasks) return io.refuse("--json applies only to tasks");
    if (parsed.stdin and cmd != .send) return io.refuse("--stdin applies only to send");
    if (cmd == .send and !parsed.stdin) return io.refuse("send reads the text from stdin: pass --stdin");
    if (parsed.limit != null and cmd != .read and cmd != .tasks) return io.refuse("--limit applies only to read and tasks");
    var limit: u64 = 50;
    if (parsed.limit) |l| {
        limit = std.fmt.parseInt(u64, l, 10) catch 0;
        if (limit == 0 or limit > 1000 or !std.ascii.isDigit(l[0])) return io.refuse("--limit must be 1..1000");
    }
    const url = parsed.url orelse default_url;
    if (try auth.urlRefusal(a, url)) |why| return io.refuse(why);

    const kp_path = parsed.keypair orelse return io.fail(a, "no keypair: pass -k <PATH> (your wallet)");
    const kp_text = std.fs.cwd().readFileAlloc(a, kp_path, 1 << 20) catch |e|
        return io.fail(a, try std.fmt.allocPrint(a, "could not load keypair {s}: {s}", .{ kp_path, @errorName(e) }));
    var kp = keypair.parse(a, kp_text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidKeypair => return io.fail(a, try std.fmt.allocPrint(a, "could not load keypair {s}: not a JSON array of 64 integers 0..255", .{kp_path})),
        error.KeypairMismatch => return io.fail(a, try std.fmt.allocPrint(a, "could not load keypair {s}: its public key is not its seed's", .{kp_path})),
    };
    defer kp.wipe();
    std.crypto.secureZero(u8, kp_text);
    const wallet = try base58.encode(a, &kp.public_key);

    const state_path = parsed.state orelse switch (try statefile.defaultPath(a, wallet)) {
        .ok => |p| p,
        .err => |why| return io.fail(a, why),
    };
    // One command at a time per state file (tools/cli/file_lock.h); the
    // directory is made 0700 first, since it holds keys.
    if (try statefile.ensureDir(a, state_path)) |why| return io.fail(a, why);
    const lock_path = try std.mem.concat(a, u8, &.{ state_path, ".lock" });
    var lock = statefile.Lock.acquire(lock_path, 60_000) orelse
        return io.fail(a, try std.fmt.allocPrint(a, "could not lock {s} within 60 s (another agichan command holds it, or it cannot be created); nothing was done", .{lock_path}));
    defer lock.release();
    var st = switch (try statefile.load(a, state_path)) {
        .ok => |s| s,
        .err => |why| return io.fail(a, why),
    };
    defer st.wipe();

    if (cmd != .login and !text.isRoomId(pos[1]))
        return io.fail(a, try std.fmt.allocPrint(a, "{s} is not a room id (!<id>:<server>); nothing was done", .{pos[1]}));

    var https = http_transport.Https.init(std.heap.page_allocator, url);
    defer https.deinit();
    var saver: FileSaver = .{ .path = state_path };
    var ctx: flows.Context = .{
        .a = a,
        .transport = https.transport(),
        .rng = std.crypto.random,
        .st = &st,
        .saver = .{ .ctx = &saver, .saveFn = FileSaver.save },
        .state_label = state_path,
        .out = io.out,
        .err = io.err,
        .keypair = kp,
        .wallet = wallet,
        .host = try auth.urlHost(a, url),
        .bound_only = !parsed.allow_unbound,
    };
    defer ctx.keypair.wipe();
    if (cmd == .login) return flows.login(&ctx);
    if (try flows.prelude(&ctx, kp_path)) |code| return code;
    const room = pos[1];
    return switch (cmd) {
        .join => flows.join(&ctx, room),
        .send => blk: {
            const msg = std.fs.File.stdin().readToEndAlloc(a, 16 << 20) catch |e|
                break :blk io.fail(a, try std.fmt.allocPrint(a, "send --stdin: could not read stdin: {s}", .{@errorName(e)}));
            if (msg.len == 0) break :blk io.fail(a, "send --stdin: stdin was empty, nothing sent");
            break :blk flows.send(&ctx, room, msg);
        },
        .read => flows.read(&ctx, room, limit, .lines),
        .tasks => flows.read(&ctx, room, limit, if (parsed.json) .board_json else .board_text),
        .login, .version, .help => unreachable,
    };
}

pub fn main() u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out_buf: [8192]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err = std.fs.File.stderr().writer(&err_buf);
    const io: Io = .{ .out = &out.interface, .err = &err.interface };
    const code = blk: {
        const argv = std.process.argsAlloc(a) catch break :blk 1;
        const args = a.alloc([]const u8, argv.len -| 1) catch break :blk 1;
        for (args, 0..) |*s, i| s.* = argv[i + 1];
        break :blk run(a, args, io) catch |e| {
            io.err.print("agichan: {s}\n", .{@errorName(e)}) catch {};
            break :blk 1;
        };
    };
    io.out.flush() catch {};
    io.err.flush() catch {};
    return code;
}
