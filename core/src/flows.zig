//! ChatCommand's flows (chat.cpp) over an injected transport, randomness and
//! state store, so they need no OS. Each returns the exit code (0, or 1 after
//! a message); allocations go to `Context.a`, an arena for one command.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const text = @import("text.zig");
const crypto = @import("crypto.zig");
const base58 = @import("base58.zig");
const e2ee = @import("e2ee.zig");
const board = @import("board.zig");
const auth = @import("auth.zig");
const rpc = @import("rpc.zig");
const device = @import("device.zig");
const keypair = @import("keypair.zig");
const state_mod = @import("state.zig");
const State = state_mod.State;

pub const Error = Allocator.Error || std.Io.Writer.Error;

/// Persists the state; null on success, else why it was not written.
pub const Saver = struct {
    ctx: *anyopaque,
    saveFn: *const fn (ctx: *anyopaque, gpa: Allocator, st: *const State) Allocator.Error!?[]const u8,

    pub fn save(s: Saver, gpa: Allocator, st: *const State) Allocator.Error!?[]const u8 {
        return s.saveFn(s.ctx, gpa, st);
    }
};

pub const Context = struct {
    a: Allocator,
    transport: rpc.Transport,
    rng: std.Random,
    st: *State,
    saver: Saver,
    /// Named in messages about the saved sessions.
    state_label: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    keypair: keypair.Keypair,
    /// base58 of the wallet's public key
    wallet: []const u8,
    /// Lowercased host of the RPC URL (auth.urlHost), for the login check.
    host: []const u8,
    /// Share keys with, and accept shares from, only devices whose key is
    /// their wallet's. agichan's default; `slonana chat` needs a flag for it.
    bound_only: bool = true,
    prog: []const u8 = "agichan",
    warned: std.StringArrayHashMapUnmanaged(void) = .empty,
};

fn fail(ctx: *Context, what: []const u8) Error!u8 {
    try ctx.err.print("{s}: ", .{ctx.prog});
    try ctx.err.writeAll(try text.oneLine(ctx.a, what));
    try ctx.err.writeByte('\n');
    return 1;
}

fn failf(ctx: *Context, comptime fmt: []const u8, args: anytype) Error!u8 {
    return fail(ctx, try std.fmt.allocPrint(ctx.a, fmt, args));
}

fn aex(ctx: *Context, path: []const u8, method: []const u8, body: []const u8, token: []const u8) Allocator.Error!rpc.Reply {
    return rpc.call(ctx.a, ctx.transport, path, method, body, token);
}

/// A relay body as JSON; null when it is not JSON (running out of memory
/// is still an error, not a bad reply).
fn parseBody(ctx: *Context, body: []const u8) Allocator.Error!?json.Value {
    return json.parse(ctx.a, body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return null,
    };
}

fn printReply(ctx: *Context, r: rpc.Reply) Error!u8 {
    if (!r.ok) return fail(ctx, r.err);
    try ctx.out.writeAll(try text.oneLine(ctx.a, r.body));
    try ctx.out.writeByte('\n');
    return 0;
}

fn save(ctx: *Context) Allocator.Error!?[]const u8 {
    return ctx.saver.save(ctx.a, ctx.st);
}

/// adopt_wallet_device: moves the state to its wallet-derived device key,
/// keeping an older one to open shares sealed to it; false when already there.
fn adoptWalletDevice(ctx: *Context, want: crypto.X25519Keypair) Allocator.Error!bool {
    if (ctx.st.device) |d| {
        if (std.mem.eql(u8, &d.public_key, &want.public_key)) return false;
        try ctx.st.retired.append(ctx.a, d);
    }
    ctx.st.device = want;
    return true;
}

/// upload_device: publishes this state's device key for its wallet.
fn uploadDevice(ctx: *Context) Allocator.Error!?[]const u8 {
    var up = try json.Object.init(ctx.a);
    try up.string("device_id", ctx.st.device_id);
    try up.string("ed25519_key", &crypto.toHex32(ctx.keypair.public_key));
    try up.string("x25519_key", &crypto.toHex32(ctx.st.device.?.public_key));
    const r = try aex(ctx, "/aexchat/keys/upload", "POST", try up.finish(), ctx.st.token);
    if (r.ok) return null;
    return try std.fmt.allocPrint(ctx.a, "keys/upload: {s}", .{r.err});
}

fn newDeviceId(ctx: *Context) Allocator.Error![]const u8 {
    var r: [8]u8 = undefined;
    ctx.rng.bytes(&r);
    return std.fmt.allocPrint(ctx.a, "agichan_{s}", .{std.fmt.bytesToHex(r, .lower)});
}

/// `login`: sign the relay's challenge, publish the wallet-derived device key.
pub fn login(ctx: *Context) Error!u8 {
    var c = try json.Object.init(ctx.a);
    try c.string("wallet", ctx.wallet);
    const ch = try aex(ctx, "/aexchat/auth/challenge", "POST", try c.finish(), "");
    if (!ch.ok) return failf(ctx, "challenge: {s}", .{ch.err});
    const doc = (try parseBody(ctx, ch.body)) orelse return failf(ctx, "challenge: unexpected reply {s}", .{ch.body});
    const nonce = json.getString(doc, "nonce") orelse return failf(ctx, "challenge: unexpected reply {s}", .{ch.body});
    const message = json.getString(doc, "message") orelse return failf(ctx, "challenge: unexpected reply {s}", .{ch.body});
    if (!auth.challengeMessageOk(message, nonce)) {
        const shown = try json.escapeAlloc(ctx.a, message[0..@min(message.len, 160)]);
        return failf(ctx, "challenge: refusing to sign, the node's message is not the aexchat login template for its nonce: \"{s}\"", .{shown});
    }
    const named = auth.challengeHost(message);
    if (!try auth.challengeHostOk(ctx.a, named, ctx.host))
        return failf(ctx, "challenge: refusing to sign, the node at {s} asked to sign in to {s}, which is neither it nor its parent domain (a node that passes on another server's challenge would get a token there); nothing was signed", .{ ctx.host, named });
    const sig = ctx.keypair.sign(message);
    // "cli_" + the wallet's first 8 characters was the C++'s old fixed id.
    const legacy = try std.fmt.allocPrint(ctx.a, "cli_{s}", .{ctx.wallet[0..@min(ctx.wallet.len, 8)]});
    if (ctx.st.device_id.len == 0 or std.mem.eql(u8, ctx.st.device_id, legacy))
        ctx.st.device_id = try newDeviceId(ctx);
    var v = try json.Object.init(ctx.a);
    try v.string("wallet", ctx.wallet);
    try v.string("signature", try base58.encode(ctx.a, &sig));
    try v.string("nonce", nonce);
    try v.string("device_id", ctx.st.device_id);
    const ver = try aex(ctx, "/aexchat/auth/verify", "POST", try v.finish(), "");
    if (!ver.ok) return failf(ctx, "verify: {s}", .{ver.err});
    const vdoc = (try parseBody(ctx, ver.body)) orelse return failf(ctx, "verify: unexpected reply {s}", .{ver.body});
    const token = json.getString(vdoc, "access_token") orelse return failf(ctx, "verify: unexpected reply {s}", .{ver.body});
    const user_id = json.getString(vdoc, "user_id") orelse return failf(ctx, "verify: unexpected reply {s}", .{ver.body});
    ctx.st.token = token;
    ctx.st.user_id = user_id;
    const want = device.walletDeviceKeypair(ctx.keypair.seed, ctx.keypair.public_key) orelse
        return fail(ctx, "cannot derive this wallet's device key");
    _ = try adoptWalletDevice(ctx, want);
    if (try uploadDevice(ctx)) |why| return fail(ctx, why);
    if (try save(ctx)) |why| return fail(ctx, why);
    try ctx.out.print("{s} (device {s})\n", .{ ctx.st.user_id, ctx.st.device_id });
    return 0;
}

/// Run before every command but login: refuses without a token, and moves a
/// device from before wallet-bound keys once. Null to go on.
pub fn prelude(ctx: *Context, keypair_label: []const u8) Error!?u8 {
    if (ctx.st.token.len == 0)
        return try failf(ctx, "not logged in: run `{s} login -k {s}` first", .{ ctx.prog, keypair_label });
    if (device.walletDeviceKeypair(ctx.keypair.seed, ctx.keypair.public_key)) |want| {
        if (try adoptWalletDevice(ctx, want)) {
            if (try uploadDevice(ctx)) |why|
                return try failf(ctx, "{s} (moving this device to its wallet-derived key)", .{why});
            if (try save(ctx)) |why| return try fail(ctx, why);
        }
    }
    return null;
}

/// `join <room>`: accept an invite.
pub fn join(ctx: *Context, room: []const u8) Error!u8 {
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/join", .{room});
    return printReply(ctx, try aex(ctx, path, "POST", "", ctx.st.token));
}

const Device = struct {
    user: []const u8,
    id: []const u8,
    /// lowercase hex, the key `shared` and shares go by
    x25519: []const u8,
};

const Devices = union(enum) {
    ok: []const Device,
    err: []const u8,
};

fn warnUnbound(ctx: *Context, user: []const u8, dev: []const u8) Error!void {
    const k = try std.fmt.allocPrint(ctx.a, "{s}|{s}", .{ user, dev });
    const gop = try ctx.warned.getOrPut(ctx.a, k);
    if (gop.found_existing) return;
    try ctx.err.print("{s}: {s} device {s} is not bound to its wallet (a web client, or a device the node added); used because of --allow-unbound-devices\n", .{ ctx.prog, try text.oneLine(ctx.a, user), try text.oneLine(ctx.a, dev) });
}

/// load_device_keys: the devices of `users` only, into `store`; with bound_only
/// an unbound device is left out, so it gets no share and its shares are refused.
fn loadDeviceKeys(ctx: *Context, users: []const []const u8, store: *e2ee.KeyStore) Error!Devices {
    var q = try json.Object.init(ctx.a);
    try q.strings("user_ids", users);
    const r = try aex(ctx, "/aexchat/keys/query", "POST", try q.finish(), ctx.st.token);
    if (!r.ok) return .{ .err = r.err };
    const unexpected: Devices = .{ .err = try std.fmt.allocPrint(ctx.a, "keys/query: unexpected reply {s}", .{r.body}) };
    const doc = (try parseBody(ctx, r.body)) orelse return unexpected;
    const by_user = (doc.get("device_keys") orelse return unexpected).asObject() orelse return unexpected;
    var out: std.ArrayListUnmanaged(Device) = .empty;
    for (by_user) |field| {
        var wanted = false;
        for (users) |u| {
            if (std.mem.eql(u8, u, field.key)) wanted = true;
        }
        if (!wanted) continue;
        const devices = field.value.asArray() orelse continue;
        for (devices) |d| {
            const dev = json.getString(d, "device_id") orelse continue;
            const ed = json.getString(d, "ed25519_key") orelse continue;
            const x = json.getString(d, "x25519_key") orelse continue;
            const edb = (try crypto.fromHex(ctx.a, ed)) orelse continue;
            const xb = (try crypto.fromHex(ctx.a, x)) orelse continue;
            if (edb.len != 32 or xb.len != 32) continue;
            const xk = xb[0..32].*;
            if (!try device.deviceBound(ctx.a, field.key, xk)) {
                if (ctx.bound_only) continue;
                try warnUnbound(ctx, field.key, dev);
            }
            try store.upload(.{ .user_id = field.key, .device_id = dev, .ed25519 = edb[0..32].*, .x25519 = xk });
            try out.append(ctx.a, .{ .user = field.key, .id = dev, .x25519 = try crypto.toHex(ctx.a, &xk) });
        }
    }
    return .{ .ok = out.items };
}

/// joined_members: the room's members whose membership is "join".
fn joinedMembers(ctx: *Context, room: []const u8) Error!union(enum) { ok: []const []const u8, err: []const u8 } {
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/members", .{room});
    const r = try aex(ctx, path, "GET", "", ctx.st.token);
    if (!r.ok) return .{ .err = r.err };
    const unexpected = try std.fmt.allocPrint(ctx.a, "members: unexpected reply {s}", .{r.body});
    const doc = (try parseBody(ctx, r.body)) orelse return .{ .err = unexpected };
    const members = (doc.get("members") orelse return .{ .err = unexpected }).asArray() orelse return .{ .err = unexpected };
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (members) |m| {
        const uid = json.getString(m, "user_id") orelse continue;
        const membership = json.getString(m, "membership") orelse continue;
        if (std.mem.eql(u8, membership, "join")) try out.append(ctx.a, uid);
    }
    return .{ .ok = out.items };
}

/// A manager holding this state's device keys and saved sessions; null
/// (after the message) when the saved sessions do not import.
fn manager(ctx: *Context, store: *const e2ee.KeyStore) Error!?e2ee.Manager {
    var mgr = e2ee.Manager.init(ctx.a, store);
    const dev = ctx.st.device orelse crypto.X25519Keypair{ .public_key = [_]u8{0} ** 32, .secret_key = [_]u8{0} ** 32 };
    try mgr.setDevice(ctx.st.user_id, ctx.st.device_id, dev);
    for (ctx.st.retired.items) |k| try mgr.addRetired(k);
    if (ctx.st.sessions.len != 0 and !try mgr.importSessions(ctx.st.sessions)) {
        _ = try failf(ctx, "saved sessions are corrupt in {s}", .{ctx.state_label});
        return null;
    }
    return mgr;
}

/// `send <room>`: rotate if a holder left, share with devices lacking the key,
/// then encrypt and send.
pub fn send(ctx: *Context, room: []const u8, plaintext: []const u8) Error!u8 {
    var store = e2ee.KeyStore.init(ctx.a);
    var mgr = (try manager(ctx, &store)) orelse return 1;
    defer mgr.deinit();

    const members = switch (try joinedMembers(ctx, room)) {
        .ok => |m| m,
        .err => |e| return failf(ctx, "members: {s}", .{e}),
    };
    const devices = switch (try loadDeviceKeys(ctx, members, &store)) {
        .ok => |d| d,
        .err => |e| return failf(ctx, "keys/query: {s}", .{e}),
    };
    var current: std.StringArrayHashMapUnmanaged(void) = .empty;
    var key_of: std.StringArrayHashMapUnmanaged([]const u8) = .empty; // "user|device" -> x25519
    for (devices) |d| {
        try current.put(ctx.a, d.x25519, {});
        try key_of.put(ctx.a, try std.fmt.allocPrint(ctx.a, "{s}|{s}", .{ d.user, d.id }), d.x25519);
    }

    var sid = mgr.outboundSessionId(room);
    if (sid.len != 0) {
        if (ctx.st.shared.get(sid)) |held| {
            var stale = false;
            for (held.keys()) |k| {
                if (!current.contains(k)) stale = true;
            }
            if (stale) {
                mgr.rotateSession(room);
                _ = ctx.st.shared.orderedRemove(sid);
                sid = "";
            }
        }
    }

    // Share BEFORE encrypting: a share carries the current index.
    var pending: std.ArrayListUnmanaged(e2ee.Target) = .empty;
    const have = if (sid.len != 0) ctx.st.shared.get(sid) else null;
    for (devices) |d| {
        if (sid.len == 0 or have == null or !have.?.contains(d.x25519))
            try pending.append(ctx.a, .{ .user = d.user, .device = d.id });
    }
    if (pending.items.len != 0) {
        const all = try mgr.shareRoomKey(ctx.a, room, pending.items, ctx.rng);
        sid = try ctx.a.dupe(u8, mgr.outboundSessionId(room));
        // A key ECDH refuses (low order) gives an empty share the relay rejects.
        var shares: std.ArrayListUnmanaged(e2ee.KeyShareEvent) = .empty;
        for (all) |s| {
            if (s.encrypted_key.len != 0) try shares.append(ctx.a, s);
        }
        var arr = try json.Array.init(ctx.a);
        for (shares.items) |s| {
            var e = try json.Object.init(ctx.a);
            try e.string("target_user", s.target_user);
            try e.string("room_id", s.room_id);
            try e.string("session_id", s.session_id);
            try e.string("encrypted_key", try crypto.toHex(ctx.a, s.encrypted_key));
            try e.string("sender_x25519_public", &crypto.toHex32(s.sender_x25519_public));
            try arr.raw(try e.finish());
        }
        var body = try json.Object.init(ctx.a);
        try body.raw("shares", try arr.finish());
        if (shares.items.len != 0) {
            const r = try aex(ctx, "/aexchat/keys/share", "POST", try body.finish(), ctx.st.token);
            if (!r.ok) return failf(ctx, "keys/share: {s} (nothing sent)", .{r.err});
        }
        for (shares.items) |s| {
            const k = try std.fmt.allocPrint(ctx.a, "{s}|{s}", .{ s.target_user, s.target_device });
            if (key_of.get(k)) |x| try ctx.st.addShared(ctx.a, sid, x);
        }
    }

    const enc = try mgr.encryptForRoom(ctx.a, room, plaintext, ctx.rng);
    var content = try json.Object.init(ctx.a);
    try content.string("msgtype", "m.encrypted");
    try content.string("algorithm", "megolm.v1");
    try content.string("session_id", enc.session_id);
    try content.int("message_index", enc.message_index);
    try content.string("ciphertext", try crypto.toHex(ctx.a, enc.ciphertext));
    try content.string("sender_device", ctx.st.device_id);
    var msg = try json.Object.init(ctx.a);
    try msg.string("type", "m.room.encrypted");
    try msg.string("content", try content.finish());
    // Persist the advanced ratchet before sending: a reused index would reuse
    // an AES-GCM key.
    ctx.st.sessions = try mgr.exportSessions(ctx.a);
    if (try save(ctx)) |why| return failf(ctx, "{s} (nothing sent)", .{why});
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/send", .{room});
    return printReply(ctx, try aex(ctx, path, "POST", try msg.finish(), ctx.st.token));
}

/// `<wallet>` as a room user id `@<wallet>:<server>`, the server taken from our
/// own user id; a value that already has ':' is used as is (chat.cpp's rule for
/// ban and forward targets).
fn targetUserId(ctx: *Context, wallet: []const u8) Error!?[]const u8 {
    if (std.mem.indexOfScalar(u8, wallet, ':') != null) return wallet;
    const colon = std.mem.indexOfScalar(u8, ctx.st.user_id, ':') orelse return null;
    const bare = if (wallet.len != 0 and wallet[0] == '@') wallet[1..] else wallet;
    return try std.fmt.allocPrint(ctx.a, "@{s}{s}", .{ bare, ctx.st.user_id[colon..] });
}

pub const CreatedRoom = union(enum) { ok: []const u8, err: []const u8 };

/// `create <name>`: a private, invite-only, encrypted room; returns its id.
pub fn createRoom(ctx: *Context, name: []const u8) Error!CreatedRoom {
    var b = try json.Object.init(ctx.a);
    try b.string("name", name);
    try b.string("visibility", "private");
    const r = try aex(ctx, "/aexchat/rooms/create", "POST", try b.finish(), ctx.st.token);
    if (!r.ok) return .{ .err = r.err };
    const doc = (try parseBody(ctx, r.body)) orelse return .{ .err = try std.fmt.allocPrint(ctx.a, "create: unexpected reply {s}", .{r.body}) };
    const id = json.getString(doc, "room_id") orelse return .{ .err = try std.fmt.allocPrint(ctx.a, "create: no room_id in reply {s}", .{r.body}) };
    return .{ .ok = id };
}

/// `create <name>`: prints the reply, as the C++ CLI does.
pub fn create(ctx: *Context, name: []const u8) Error!u8 {
    var b = try json.Object.init(ctx.a);
    try b.string("name", name);
    try b.string("visibility", "private");
    return printReply(ctx, try aex(ctx, "/aexchat/rooms/create", "POST", try b.finish(), ctx.st.token));
}

/// `invite <room> <wallet>`.
pub fn invite(ctx: *Context, room: []const u8, wallet: []const u8) Error!u8 {
    var b = try json.Object.init(ctx.a);
    try b.string("wallet", wallet);
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/invite", .{room});
    return printReply(ctx, try aex(ctx, path, "POST", try b.finish(), ctx.st.token));
}

/// `leave <room>`.
pub fn leave(ctx: *Context, room: []const u8) Error!u8 {
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/leave", .{room});
    return printReply(ctx, try aex(ctx, path, "POST", "", ctx.st.token));
}

/// `members <room>` (GET): prints the reply.
pub fn membersReply(ctx: *Context, room: []const u8) Error!u8 {
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/members", .{room});
    return printReply(ctx, try aex(ctx, path, "GET", "", ctx.st.token));
}

/// `ban <room> <wallet>`: a bare wallet gets this server's suffix.
pub fn ban(ctx: *Context, room: []const u8, wallet: []const u8) Error!u8 {
    const target = (try targetUserId(ctx, wallet)) orelse
        return fail(ctx, "own user id has no server part; log in first");
    var b = try json.Object.init(ctx.a);
    try b.string("user_id", target);
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/ban", .{room});
    return printReply(ctx, try aex(ctx, path, "POST", try b.finish(), ctx.st.token));
}

/// `forward <room> <wallet> --limit N`: re-seal this identity's keys for the
/// room's last N encrypted events to every device of `wallet`, so a member who
/// joined late can read them. The receiver keeps them forwarded (never
/// sender-verified). Prints "forwarded N key(s) for M event(s) to <t> (D device(s))".
pub fn forward(ctx: *Context, room: []const u8, wallet: []const u8, limit: u64) Error!u8 {
    var store = e2ee.KeyStore.init(ctx.a);
    var mgr = (try manager(ctx, &store)) orelse return 1;
    defer mgr.deinit();
    var outcomes = Outcomes.initFill(0);
    var wrong_room: usize = 0;
    if (try importPendingShares(ctx, room, &store, &mgr, &outcomes, &wrong_room)) |why| return fail(ctx, why);

    const target = (try targetUserId(ctx, wallet)) orelse
        return failf(ctx, "own user id has no server part: {s}", .{ctx.st.user_id});
    const devices = switch (try loadDeviceKeys(ctx, &.{target}, &store)) {
        .ok => |d| d,
        .err => |e| return failf(ctx, "keys/query: {s}", .{e}),
    };
    var targets: std.ArrayListUnmanaged(e2ee.Target) = .empty;
    for (devices) |d| {
        if (std.mem.eql(u8, d.user, target)) try targets.append(ctx.a, .{ .user = d.user, .device = d.id });
    }
    if (targets.items.len == 0)
        return failf(ctx, "{s} has no published device; it must log in first", .{target});

    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/messages?dir=b&limit={d}", .{ room, limit });
    const r = try aex(ctx, path, "GET", "", ctx.st.token);
    if (!r.ok) return failf(ctx, "messages: {s}", .{r.err});
    const doc = (try parseBody(ctx, r.body)) orelse return failf(ctx, "messages: unexpected reply {s}", .{r.body});
    const chunk = (doc.get("chunk") orelse return failf(ctx, "messages: unexpected reply {s}", .{r.body})).asArray() orelse
        return failf(ctx, "messages: unexpected reply {s}", .{r.body});
    var which: std.ArrayListUnmanaged(e2ee.SessionRef) = .empty;
    for (chunk) |ev| {
        const ty = json.getString(ev, "type") orelse continue;
        if (!std.mem.eql(u8, ty, "m.room.encrypted")) continue;
        const sender = json.getString(ev, "sender") orelse continue;
        const content = ev.get("content") orelse continue;
        const sid = json.getString(content, "session_id") orelse continue;
        try which.append(ctx.a, .{ .sender = sender, .session_id = sid });
    }

    const all = try mgr.forwardSessions(ctx.a, room, which.items, targets.items, ctx.rng);
    var shares: std.ArrayListUnmanaged(e2ee.KeyShareEvent) = .empty;
    for (all) |s| {
        if (s.encrypted_key.len != 0) try shares.append(ctx.a, s);
    }
    if (shares.items.len != 0) {
        var arr = try json.Array.init(ctx.a);
        for (shares.items) |s| {
            var e = try json.Object.init(ctx.a);
            try e.string("target_user", s.target_user);
            try e.string("room_id", s.room_id);
            try e.string("session_id", s.session_id);
            try e.string("encrypted_key", try crypto.toHex(ctx.a, s.encrypted_key));
            try e.string("sender_x25519_public", &crypto.toHex32(s.sender_x25519_public));
            try arr.raw(try e.finish());
        }
        var body = try json.Object.init(ctx.a);
        try body.raw("shares", try arr.finish());
        const up = try aex(ctx, "/aexchat/keys/share", "POST", try body.finish(), ctx.st.token);
        if (!up.ok) return failf(ctx, "keys/share: {s} (nothing forwarded)", .{up.err});
    }
    ctx.st.sessions = try mgr.exportSessions(ctx.a);
    if (try save(ctx)) |why| return fail(ctx, why);
    try ctx.out.print("forwarded {d} key(s) for {d} event(s) to {s} ({d} device(s))\n", .{ shares.items.len, which.items.len, try text.oneLine(ctx.a, target), targets.items.len });
    return 0;
}

const Outcomes = std.EnumArray(e2ee.ShareStatus, usize);

/// import_pending_shares: the room's pending key shares, each checked
/// against its uploader's published keys. Null, or which request failed.
fn importPendingShares(ctx: *Context, room: []const u8, store: *e2ee.KeyStore, mgr: *e2ee.Manager, outcomes: *Outcomes, wrong_room: *usize) Error!?[]const u8 {
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/keys/pending?room_id={s}", .{room});
    const r = try aex(ctx, path, "GET", "", ctx.st.token);
    if (!r.ok) return try std.fmt.allocPrint(ctx.a, "keys/pending: {s}", .{r.err});
    const unexpected = try std.fmt.allocPrint(ctx.a, "keys/pending: unexpected reply {s}", .{r.body});
    const doc = (try parseBody(ctx, r.body)) orelse return unexpected;
    const shares = (doc.get("key_shares") orelse return unexpected).asArray() orelse return unexpected;
    var events: std.ArrayListUnmanaged(e2ee.KeyShareEvent) = .empty;
    var senders: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (shares) |s| {
        const rid = json.getString(s, "room_id") orelse continue;
        const sid = json.getString(s, "session_id") orelse continue;
        const ekey = json.getString(s, "encrypted_key") orelse continue;
        const spub = json.getString(s, "sender_x25519_public") orelse continue;
        // Missing: left empty, and the manager refuses it as naming no sender.
        const sender = json.getString(s, "sender_user") orelse "";
        const ek = (try crypto.fromHex(ctx.a, ekey)) orelse continue;
        const sp = (try crypto.fromHex(ctx.a, spub)) orelse continue;
        if (sp.len != 32) continue;
        if (!std.mem.eql(u8, rid, room)) { // asked for `room`: another is a relay bug
            wrong_room.* += 1;
            continue;
        }
        try events.append(ctx.a, .{
            .room_id = rid,
            .session_id = sid,
            .target_user = ctx.st.user_id,
            .target_device = ctx.st.device_id,
            .encrypted_key = ek,
            .sender_x25519_public = sp[0..32].*,
            .sender_user = sender,
        });
        if (sender.len != 0) try senders.put(ctx.a, sender, {});
    }
    if (senders.count() != 0) {
        const users = try ctx.a.dupe([]const u8, senders.keys());
        std.mem.sort([]const u8, users, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        switch (try loadDeviceKeys(ctx, users, store)) {
            .ok => {},
            .err => |e| return try std.fmt.allocPrint(ctx.a, "keys/query: {s}", .{e}),
        }
    }
    for (events.items) |ev| outcomes.getPtr(try mgr.receiveKeyShare(ev)).* += 1;
    return null;
}

pub const BoardData = struct { tasks: []board.Task, bindings: []board.Binding };

/// The task board as structured data (for `pay`'s refusal check): imports
/// pending shares, decrypts the sender-verified and forwarded events, and folds
/// them with this room's kept handle chains. Advances and saves the sessions.
pub fn readBoard(ctx: *Context, room: []const u8, limit: u64) Error!BoardData {
    const empty: BoardData = .{ .tasks = &.{}, .bindings = &.{} };
    var store = e2ee.KeyStore.init(ctx.a);
    var mgr = (try manager(ctx, &store)) orelse return empty;
    defer mgr.deinit();
    var outcomes = Outcomes.initFill(0);
    var wrong_room: usize = 0;
    _ = try importPendingShares(ctx, room, &store, &mgr, &outcomes, &wrong_room);
    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/messages?dir=b&limit={d}", .{ room, limit });
    const r = try aex(ctx, path, "GET", "", ctx.st.token);
    if (!r.ok) return empty;
    const doc = (try parseBody(ctx, r.body)) orelse return empty;
    const chunk = (doc.get("chunk") orelse return empty).asArray() orelse return empty;
    var board_lines: std.ArrayListUnmanaged(board.Line) = .empty;
    for (chunk) |ev| {
        const ev_type = json.getString(ev, "type") orelse continue;
        if (!std.mem.eql(u8, ev_type, "m.room.encrypted")) continue;
        const sender = json.getString(ev, "sender") orelse continue;
        const ts_ms: i64 = if (ev.get("origin_server_ts")) |t| t.asInt() orelse 0 else 0;
        const content = ev.get("content") orelse continue;
        const algorithm = json.getString(content, "algorithm") orelse continue;
        if (!std.mem.eql(u8, algorithm, "megolm.v1")) continue;
        const sid = json.getString(content, "session_id") orelse continue;
        const ct = json.getString(content, "ciphertext") orelse continue;
        const index: ?i64 = if (content.get("message_index")) |v| v.asInt() else null;
        if (index == null or index.? < 0) continue;
        const bytes = (try crypto.fromHex(ctx.a, ct)) orelse continue;
        const msg: e2ee.EncryptedMessage = .{ .session_id = sid, .message_index = @truncate(@as(u64, @intCast(index.?))), .ciphertext = bytes };
        const pt = (try mgr.decrypt(ctx.a, msg, sender)) orelse continue;
        if (pt.verified or pt.forwarded_by.len != 0)
            try board_lines.append(ctx.a, .{ .sender = sender, .text = pt.plaintext, .ts_ms = ts_ms });
    }
    std.mem.reverse(board.Line, board_lines.items);
    var bindings: std.ArrayListUnmanaged(board.Binding) = .empty;
    const chains = try ctx.st.pinsOf(ctx.a, room);
    const tasks = try board.fold(ctx.a, board_lines.items, &bindings, chains, null);
    ctx.st.sessions = try mgr.exportSessions(ctx.a);
    _ = try save(ctx);
    return .{ .tasks = tasks, .bindings = bindings.items };
}

pub const ReadMode = enum { lines, board_text, board_json };

/// `read` and `tasks`: import pending shares, decrypt the last `limit` events,
/// print them oldest first or fold the verified ones into the board.
pub fn read(ctx: *Context, room: []const u8, limit: u64, mode: ReadMode, mention: []const u8) Error!u8 {
    var store = e2ee.KeyStore.init(ctx.a);
    var mgr = (try manager(ctx, &store)) orelse return 1;
    defer mgr.deinit();
    const unbound = mgr.unboundSessionCount();
    if (unbound != 0)
        try ctx.err.print("{s}: {d} saved session(s) predate sender binding and decrypt for any sender\n", .{ ctx.prog, unbound });
    var outcomes = Outcomes.initFill(0);
    var wrong_room: usize = 0;
    if (try importPendingShares(ctx, room, &store, &mgr, &outcomes, &wrong_room)) |why| return fail(ctx, why);
    if (wrong_room != 0)
        try ctx.err.print("{s}: the node returned {d} key share(s) for another room (ignored)\n", .{ ctx.prog, wrong_room });
    // Undecryptable stays silent: those are shares for other devices.
    if (outcomes.get(.no_sender) != 0)
        try ctx.err.print("{s}: {d} key share(s) named no sender\n", .{ ctx.prog, outcomes.get(.no_sender) });
    if (outcomes.get(.not_senders_key) != 0)
        try ctx.err.print("{s}: {d} key share(s) in {s} not sealed with a published device key of their sender\n", .{ ctx.prog, outcomes.get(.not_senders_key), room });
    if (outcomes.get(.refused) != 0)
        try ctx.err.print("{s}: {d} key share(s) refused: unproven or conflicting\n", .{ ctx.prog, outcomes.get(.refused) });

    const path = try std.fmt.allocPrint(ctx.a, "/aexchat/rooms/{s}/messages?dir=b&limit={d}", .{ room, limit });
    const r = try aex(ctx, path, "GET", "", ctx.st.token);
    if (!r.ok) return failf(ctx, "messages: {s}", .{r.err});
    const doc = (try parseBody(ctx, r.body)) orelse return failf(ctx, "messages: unexpected reply {s}", .{r.body});
    const chunk = (doc.get("chunk") orelse return failf(ctx, "messages: unexpected reply {s}", .{r.body})).asArray() orelse
        return failf(ctx, "messages: unexpected reply {s}", .{r.body});

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    // Decrypted lines only: a Megolm event decrypts only under its session's
    // sender, or under a key a named member forwarded.
    var board_lines: std.ArrayListUnmanaged(board.Line) = .empty;
    var unreadable: u64 = 0;
    var unproven: u64 = 0;
    for (chunk) |ev| {
        const ev_type = json.getString(ev, "type") orelse continue;
        const sender = json.getString(ev, "sender") orelse continue;
        const ts_ms: i64 = if (ev.get("origin_server_ts")) |t| t.asInt() orelse 0 else 0;
        const content = ev.get("content") orelse continue;
        var body: []const u8 = undefined;
        var verified = false;
        var via: []const u8 = "";
        var tag: []const u8 = "";
        if (std.mem.eql(u8, ev_type, "m.room.encrypted")) {
            const algorithm = json.getString(content, "algorithm");
            const sid = json.getString(content, "session_id");
            const index: ?i64 = if (content.get("message_index")) |v| v.asInt() else null;
            const ct = json.getString(content, "ciphertext");
            if (algorithm == null or !std.mem.eql(u8, algorithm.?, "megolm.v1") or sid == null or index == null or
                ct == null or index.? < 0)
            {
                body = "<encrypted: unsupported format>";
            } else {
                const bytes = try crypto.fromHex(ctx.a, ct.?);
                // The C++ keeps the low 32 bits of the index.
                const msg: e2ee.EncryptedMessage = .{ .session_id = sid.?, .message_index = @truncate(@as(u64, @intCast(index.?))), .ciphertext = bytes orelse "" };
                const pt = if (bytes != null) try mgr.decrypt(ctx.a, msg, sender) else null;
                if (pt) |p| {
                    verified = p.verified;
                    via = p.forwarded_by;
                    if (via.len != 0) {
                        tag = try std.fmt.allocPrint(ctx.a, "[via {s}] ", .{try text.oneLine(ctx.a, via)});
                    } else if (!verified) {
                        tag = "[unverified sender] ";
                    }
                    body = p.plaintext;
                } else {
                    body = "<encrypted: no key for this session>";
                }
            }
        } else if (std.mem.eql(u8, ev_type, "m.room.message") and json.getString(content, "body") != null) {
            // Every room is encrypted, so plaintext is the relay's word alone:
            // not shown (the C++ shows it tagged), never counted.
            body = "<refused: the relay served this in the clear, and this room is end-to-end encrypted>";
            tag = "[plaintext] ";
        } else {
            continue; // state and control events
        }
        // `read --mention H` keeps only messages naming @H or @ALL (the digest).
        if (mention.len == 0 or text.addressedTo(body, mention))
            try lines.append(ctx.a, try std.fmt.allocPrint(ctx.a, "{s}: {s}{s}", .{
                try text.oneLine(ctx.a, sender), tag, try text.oneLine(ctx.a, body),
            }));
        if (verified or via.len != 0) {
            try board_lines.append(ctx.a, .{ .sender = sender, .text = body, .ts_ms = ts_ms });
        } else if (tag.len == 0) {
            unreadable += 1; // encrypted, and this device holds no key for it
        } else {
            unproven += 1; // plaintext, or a sender no session vouches for
        }
    }
    std.mem.reverse([]const u8, lines.items); // dir=b is newest first
    std.mem.reverse(board.Line, board_lines.items);
    switch (mode) {
        .lines => for (lines.items) |l| {
            try ctx.out.writeAll(l);
            try ctx.out.writeByte('\n');
        },
        .board_text, .board_json => {
            var bindings: std.ArrayListUnmanaged(board.Binding) = .empty;
            var presence: board.PresenceMap = .empty;
            const chains = try ctx.st.pinsOf(ctx.a, room);
            const tasks = try board.fold(ctx.a, board_lines.items, &bindings, chains, if (mode == .board_json) &presence else null);
            if (mode == .board_json) {
                try ctx.out.writeAll(try board.renderJson(ctx.a, tasks, bindings.items, &presence, unreadable, unproven));
                try ctx.out.writeByte('\n');
            } else {
                try ctx.out.writeAll(try board.renderText(ctx.a, tasks));
                try ctx.out.writeAll(try board.renderBindings(ctx.a, bindings.items));
                if (unreadable != 0 or unproven != 0)
                    try ctx.out.print("not counted: {d} message(s) this device has no key for (sent before it joined, or never shared to it), {d} plaintext or unverified-sender\n", .{ unreadable, unproven });
            }
        },
    }
    ctx.st.sessions = try mgr.exportSessions(ctx.a);
    if (try save(ctx)) |why| return failf(ctx, "{s} (the keys imported above were not saved)", .{why});
    return 0;
}
