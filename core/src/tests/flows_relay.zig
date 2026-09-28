//! The flows against an in-process relay that speaks the aexchatRequest
//! envelope and enforces what src/aexchat/aexchat_server.cpp enforces for
//! these routes (signed challenges, tokens, membership, a share's sender key
//! being one of the uploader's devices). Each command starts from the state
//! JSON the previous one saved, as separate processes would. Knobs make the
//! relay hostile: a device it adds to a member, plaintext it injects, a
//! challenge it rewrites, a share it seals with a key it planted.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const crypto = @import("../crypto.zig");
const e2ee = @import("../e2ee.zig");
const base58 = @import("../base58.zig");
const rpc = @import("../rpc.zig");
const flows = @import("../flows.zig");
const keypair = @import("../keypair.zig");
const state_mod = @import("../state.zig");

const Device = struct { user: []const u8, id: []const u8, ed: []const u8, x: []const u8 };
const Share = struct { target: []const u8, room: []const u8, sid: []const u8, ek: []const u8, spub: []const u8, sender: []const u8 };
const Event = struct { id: []const u8, sender: []const u8, type: []const u8, content: []const u8, ts: i64 };
const Pending = struct { wallet: []const u8, message: []const u8 };

const Relay = struct {
    a: Allocator,
    counter: u64 = 0,
    challenges: std.StringArrayHashMapUnmanaged(Pending) = .empty,
    tokens: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    devices: std.ArrayListUnmanaged(Device) = .empty,
    members: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,
    invited: std.ArrayListUnmanaged([2][]const u8) = .empty,
    shares: std.ArrayListUnmanaged(Share) = .empty,
    events: std.ArrayListUnmanaged(Event) = .empty,
    verify_calls: usize = 0,
    // Hostile knobs.
    challenge_override: ?[]const u8 = null,
    challenge_host: []const u8 = "slonana.com",
    rogue_device_for: ?[]const u8 = null,
    rogue_x: []const u8 = "",

    fn next(r: *Relay) u64 {
        r.counter += 1;
        return r.counter;
    }

    fn err(r: *Relay, code: []const u8, msg: []const u8) ![]const u8 {
        var o = try json.Object.init(r.a);
        try o.string("errcode", code);
        try o.string("error", msg);
        return o.finish();
    }

    fn joined(r: *Relay, room: []const u8, user: []const u8) bool {
        const list = r.members.get(room) orelse return false;
        for (list.items) |u| {
            if (std.mem.eql(u8, u, user)) return true;
        }
        return false;
    }

    fn createRoom(r: *Relay, room: []const u8, creator: []const u8) !void {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        try list.append(r.a, creator);
        try r.members.put(r.a, room, list);
    }

    fn invite(r: *Relay, room: []const u8, user: []const u8) !void {
        try r.invited.append(r.a, .{ room, user });
    }

    fn post(ctx: *anyopaque, a: Allocator, request_json: []const u8) Allocator.Error!rpc.Posted {
        const r: *Relay = @ptrCast(@alignCast(ctx));
        const result = r.route(request_json) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try r.err("M_BAD_JSON", @errorName(e)),
        };
        return .{ .reply = try std.mem.concat(a, u8, &.{ "{\"jsonrpc\":\"2.0\",\"result\":", result, ",\"id\":1}" }) };
    }

    fn transport(r: *Relay) rpc.Transport {
        return .{ .ctx = r, .postFn = post, .url = "https://rpc.slonana.com" };
    }

    fn route(r: *Relay, request_json: []const u8) ![]const u8 {
        const a = r.a;
        const req = try json.parse(a, try a.dupe(u8, request_json));
        const params = json.get(req, "params").?;
        const path = json.getString(params, "path").?;
        const method = json.getString(params, "method").?;
        const body_text = json.getString(params, "body") orelse "{}";
        const body = try json.parse(a, try a.dupe(u8, body_text));
        const token = json.getString(params, "token") orelse "";

        if (std.mem.eql(u8, path, "/aexchat/auth/challenge")) {
            const wallet = json.getString(body, "wallet").?;
            const nonce = std.fmt.bytesToHex(crypto.sha256(std.mem.asBytes(&r.next())), .lower);
            const message = r.challenge_override orelse
                try std.fmt.allocPrint(a, "Sign in to {s}\nNonce: {s}\nTimestamp: 1790000000", .{ r.challenge_host, nonce });
            try r.challenges.put(a, try a.dupe(u8, &nonce), .{ .wallet = wallet, .message = message });
            var o = try json.Object.init(a);
            try o.string("nonce", &nonce);
            try o.string("message", message);
            try o.int("expires_at", 1790000300);
            return o.finish();
        }
        if (std.mem.eql(u8, path, "/aexchat/auth/verify")) {
            r.verify_calls += 1;
            const wallet = json.getString(body, "wallet").?;
            const nonce = json.getString(body, "nonce").?;
            const pending = r.challenges.get(nonce) orelse return r.err("M_FORBIDDEN", "Signature verification failed");
            if (!std.mem.eql(u8, pending.wallet, wallet)) return r.err("M_FORBIDDEN", "Signature verification failed");
            const sig = try base58.decode(a, json.getString(body, "signature").?);
            const pk = base58.decode32(wallet) orelse return r.err("M_FORBIDDEN", "bad wallet");
            if (sig.len != 64) return r.err("M_FORBIDDEN", "Signature verification failed");
            const signature = crypto.Ed25519.Signature.fromBytes(sig[0..64].*);
            const public = crypto.Ed25519.PublicKey.fromBytes(pk) catch return r.err("M_FORBIDDEN", "bad key");
            signature.verify(pending.message, public) catch return r.err("M_FORBIDDEN", "Signature verification failed");
            const tok = try std.fmt.allocPrint(a, "tok-{d}", .{r.next()});
            const user = try std.fmt.allocPrint(a, "@{s}:slonana.com", .{wallet});
            try r.tokens.put(a, tok, user);
            var o = try json.Object.init(a);
            try o.string("access_token", tok);
            try o.string("user_id", user);
            try o.string("device_id", json.getString(body, "device_id") orelse "");
            return o.finish();
        }
        const user = r.tokens.get(token) orelse return r.err("M_UNKNOWN_TOKEN", "no token");

        if (std.mem.eql(u8, path, "/aexchat/keys/upload")) {
            const id = json.getString(body, "device_id").?;
            const d: Device = .{ .user = user, .id = id, .ed = json.getString(body, "ed25519_key").?, .x = json.getString(body, "x25519_key").? };
            for (r.devices.items) |*e| {
                if (std.mem.eql(u8, e.user, user) and std.mem.eql(u8, e.id, id)) {
                    e.* = d;
                    return "{\"one_time_key_counts\":0}";
                }
            }
            try r.devices.append(a, d);
            return "{\"one_time_key_counts\":0}";
        }
        if (std.mem.eql(u8, path, "/aexchat/keys/query")) {
            var by_user = try json.Object.init(a);
            for (json.get(body, "user_ids").?.asArray().?) |u| {
                const uid = u.asString().?;
                var arr = try json.Array.init(a);
                for (r.devices.items) |d| {
                    if (!std.mem.eql(u8, d.user, uid)) continue;
                    var o = try json.Object.init(a);
                    try o.string("device_id", d.id);
                    try o.string("ed25519_key", d.ed);
                    try o.string("x25519_key", d.x);
                    try arr.raw(try o.finish());
                }
                if (r.rogue_device_for) |victim| {
                    if (std.mem.eql(u8, victim, uid)) {
                        var o = try json.Object.init(a);
                        try o.string("device_id", "relay_planted");
                        try o.string("ed25519_key", "07" ** 32);
                        try o.string("x25519_key", r.rogue_x);
                        try arr.raw(try o.finish());
                    }
                }
                try by_user.raw(uid, try arr.finish());
            }
            var o = try json.Object.init(a);
            try o.raw("device_keys", try by_user.finish());
            return o.finish();
        }
        if (std.mem.eql(u8, path, "/aexchat/keys/share")) {
            const items = json.get(body, "shares").?.asArray().?;
            for (items) |s| {
                const room = json.getString(s, "room_id").?;
                const target = json.getString(s, "target_user").?;
                if (!r.joined(room, user) or !r.joined(room, target)) return r.err("M_FORBIDDEN", "not joined");
                const spub = json.getString(s, "sender_x25519_public").?;
                var own = false;
                for (r.devices.items) |d| {
                    if (std.mem.eql(u8, d.user, user) and std.mem.eql(u8, d.x, spub)) own = true;
                }
                if (!own) return r.err("M_FORBIDDEN", "sender_x25519_public is not the x25519 key of any device you uploaded");
            }
            for (items) |s| try r.shares.append(a, .{
                .target = json.getString(s, "target_user").?,
                .room = json.getString(s, "room_id").?,
                .sid = json.getString(s, "session_id").?,
                .ek = json.getString(s, "encrypted_key").?,
                .spub = json.getString(s, "sender_x25519_public").?,
                .sender = user,
            });
            return std.fmt.allocPrint(a, "{{\"shared\":{d}}}", .{items.len});
        }
        if (std.mem.startsWith(u8, path, "/aexchat/keys/pending?room_id=")) {
            const room = path["/aexchat/keys/pending?room_id=".len..];
            if (!r.joined(room, user)) return r.err("M_FORBIDDEN", "join first");
            var arr = try json.Array.init(a);
            for (r.shares.items) |s| {
                if (!std.mem.eql(u8, s.target, user) or !std.mem.eql(u8, s.room, room)) continue;
                var o = try json.Object.init(a);
                try o.string("room_id", s.room);
                try o.string("session_id", s.sid);
                try o.string("encrypted_key", s.ek);
                try o.string("sender_x25519_public", s.spub);
                try o.string("sender_user", s.sender);
                try arr.raw(try o.finish());
            }
            var o = try json.Object.init(a);
            try o.raw("key_shares", try arr.finish());
            try o.boolean("truncated", false);
            return o.finish();
        }
        if (std.mem.startsWith(u8, path, "/aexchat/rooms/")) {
            const rest = path["/aexchat/rooms/".len..];
            const slash = std.mem.lastIndexOfScalar(u8, rest, '/').?;
            const room = rest[0..slash];
            var action = rest[slash + 1 ..];
            if (std.mem.indexOfScalar(u8, action, '?')) |q| action = action[0..q];
            if (std.mem.eql(u8, action, "join") and std.mem.eql(u8, method, "POST")) {
                var ok = r.joined(room, user);
                for (r.invited.items) |iv| {
                    if (std.mem.eql(u8, iv[0], room) and std.mem.eql(u8, iv[1], user)) ok = true;
                }
                if (!ok) return r.err("M_FORBIDDEN", "Cannot join room");
                if (!r.joined(room, user)) try r.members.getPtr(room).?.append(a, user);
                return std.fmt.allocPrint(a, "{{\"room_id\":\"{s}\"}}", .{room});
            }
            if (!r.joined(room, user)) return r.err("M_FORBIDDEN", "You must join this room");
            if (std.mem.eql(u8, action, "members")) {
                var arr = try json.Array.init(a);
                for (r.members.get(room).?.items) |m| {
                    var o = try json.Object.init(a);
                    try o.string("user_id", m);
                    try o.string("membership", "join");
                    try arr.raw(try o.finish());
                }
                var o = try json.Object.init(a);
                try o.raw("members", try arr.finish());
                return o.finish();
            }
            if (std.mem.eql(u8, action, "send")) {
                const id = try std.fmt.allocPrint(a, "$ev{d}", .{r.next()});
                try r.events.append(a, .{ .id = id, .sender = user, .type = json.getString(body, "type").?, .content = json.getString(body, "content").?, .ts = @intCast(1790000000000 + r.counter) });
                return std.fmt.allocPrint(a, "{{\"event_id\":\"{s}\"}}", .{id});
            }
            if (std.mem.eql(u8, action, "messages")) {
                const lim_at = std.mem.indexOf(u8, path, "limit=").?;
                const limit = try std.fmt.parseInt(usize, path[lim_at + 6 ..], 10);
                var arr = try json.Array.init(a);
                var i = r.events.items.len;
                var n: usize = 0;
                while (i > 0 and n < limit) : (n += 1) {
                    i -= 1;
                    const e = r.events.items[i];
                    var o = try json.Object.init(a);
                    try o.string("event_id", e.id);
                    try o.string("sender", e.sender);
                    try o.string("type", e.type);
                    try o.raw("content", e.content);
                    try o.int("origin_server_ts", e.ts);
                    try arr.raw(try o.finish());
                }
                var o = try json.Object.init(a);
                try o.raw("chunk", try arr.finish());
                return o.finish();
            }
        }
        return r.err("M_UNRECOGNIZED", path);
    }
};

/// One agent: a wallet and the state JSON its last command saved.
const Agent = struct {
    kp: keypair.Keypair,
    wallet: []const u8,
    saved: []const u8 = "",
    prng: std.Random.DefaultPrng,

    fn init(a: Allocator, seed_byte: u8) !Agent {
        const seed = [_]u8{seed_byte} ** 32;
        const pair = try crypto.Ed25519.KeyPair.generateDeterministic(seed);
        const kp: keypair.Keypair = .{ .seed = seed, .public_key = pair.public_key.toBytes() };
        return .{ .kp = kp, .wallet = try base58.encode(a, &kp.public_key), .prng = std.Random.DefaultPrng.init(seed_byte) };
    }

    fn user(ag: *const Agent, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "@{s}:slonana.com", .{ag.wallet});
    }
};

const Saver = struct {
    agent: *Agent,
    a: Allocator,

    fn save(ctx: *anyopaque, _: Allocator, st: *const state_mod.State) Allocator.Error!?[]const u8 {
        const s: *Saver = @ptrCast(@alignCast(ctx));
        s.agent.saved = try state_mod.serialize(s.a, st);
        return null;
    }
};

const Run = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
};

const Command = union(enum) {
    login,
    join: []const u8,
    send: [2][]const u8,
    read: []const u8,
    tasks_json: []const u8,
};

/// One command as one process: state from the agent's last save.
fn run(a: Allocator, relay: *Relay, ag: *Agent, cmd: Command, bound_only: bool) !Run {
    var st = if (ag.saved.len == 0) state_mod.State{} else try state_mod.parse(a, try a.dupe(u8, ag.saved));
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var saver: Saver = .{ .agent = ag, .a = a };
    var ctx: flows.Context = .{
        .a = a,
        .transport = relay.transport(),
        .rng = ag.prng.random(),
        .st = &st,
        .saver = .{ .ctx = &saver, .saveFn = Saver.save },
        .state_label = "test-state",
        .out = &out.writer,
        .err = &err.writer,
        .keypair = ag.kp,
        .wallet = ag.wallet,
        .host = "rpc.slonana.com",
        .bound_only = bound_only,
    };
    const code: u8 = switch (cmd) {
        .login => try flows.login(&ctx),
        else => blk: {
            if (try flows.prelude(&ctx, "k.json")) |c| break :blk c;
            break :blk switch (cmd) {
                .join => |room| try flows.join(&ctx, room),
                .send => |x| try flows.send(&ctx, x[0], x[1]),
                .read => |room| try flows.read(&ctx, room, 50, .lines),
                .tasks_json => |room| try flows.read(&ctx, room, 50, .board_json),
                .login => unreachable,
            };
        },
    };
    return .{ .code = code, .out = out.written(), .err = err.written() };
}

fn expectOk(r: Run) !void {
    if (r.code != 0) std.debug.print("command failed: {s}\n", .{r.err});
    try testing.expectEqual(@as(u8, 0), r.code);
}

const test_room = "!0123456789abcdef:slonana.com";

/// How many stored shares the device key `secret` opens (a share names no
/// target device, so this is how to tell who it was sealed to).
fn openableBy(a: Allocator, relay: *const Relay, secret: crypto.Key32) !usize {
    var n: usize = 0;
    for (relay.shares.items) |s| {
        const ek = (try crypto.fromHex(a, s.ek)).?;
        const k = e2ee.shareKey(secret, crypto.fromHex32(s.spub).?) catch continue;
        if (crypto.gcmOpen(a, k, ek)) |_| n += 1 else |_| {}
    }
    return n;
}

fn setUp(a: Allocator, relay: *Relay, alice: *Agent, bob: *Agent) !void {
    try expectOk(try run(a, relay, alice, .login, true));
    try expectOk(try run(a, relay, bob, .login, true));
    try relay.createRoom(test_room, try alice.user(a));
    try relay.invite(test_room, try bob.user(a));
    try expectOk(try run(a, relay, bob, .{ .join = test_room }, true));
}

test "flows: two agents, each command a new process" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var relay: Relay = .{ .a = a };
    var alice = try Agent.init(a, 0xa1);
    var bob = try Agent.init(a, 0xb0);
    try setUp(a, &relay, &alice, &bob);

    try expectOk(try run(a, &relay, &alice, .{ .send = .{ test_room, "lead -> @w1 | TASK t1 @w1 port it" } }, true));
    try expectOk(try run(a, &relay, &bob, .{ .send = .{ test_room, "w1 -> @lead | CLAIM t1" } }, true));
    try expectOk(try run(a, &relay, &bob, .{ .send = .{ test_room, "w1 -> @lead | READY host=b" } }, true));
    try expectOk(try run(a, &relay, &alice, .{ .send = .{ test_room, "lead -> @w1 | second message, same session" } }, true));

    const ra = try run(a, &relay, &alice, .{ .read = test_room }, true);
    const rb = try run(a, &relay, &bob, .{ .read = test_room }, true);
    try expectOk(ra);
    try expectOk(rb);
    // Both read all four, sender-verified (no tag), oldest first.
    const want = try std.fmt.allocPrint(a, "{s}: lead -> @w1 | TASK t1 @w1 port it\n{s}: w1 -> @lead | CLAIM t1\n" ++
        "{s}: w1 -> @lead | READY host=b\n{s}: lead -> @w1 | second message, same session\n", .{ try alice.user(a), try bob.user(a), try bob.user(a), try alice.user(a) });
    try testing.expectEqualStrings(want, ra.out);
    try testing.expectEqualStrings(want, rb.out);
    // Each saved state kept which device holds which session.
    const sa = try state_mod.parse(a, try a.dupe(u8, alice.saved));
    try testing.expectEqual(@as(usize, 1), sa.shared.count());
    try testing.expectEqual(@as(usize, 2), sa.shared.values()[0].count());

    const ta = try run(a, &relay, &alice, .{ .tasks_json = test_room }, true);
    const tb = try run(a, &relay, &bob, .{ .tasks_json = test_room }, true);
    try testing.expectEqualStrings(ta.out, tb.out);
    const doc = try json.parse(a, ta.out);
    const t = json.get(doc, "tasks").?.asArray().?;
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqualStrings("claimed", json.getString(t[0], "state").?);
    try testing.expectEqualStrings("ready", json.getString(json.get(json.get(doc, "workers"), "w1"), "state").?);
    // The board's handle chains were kept in the state.
    const sb = try state_mod.parse(a, try a.dupe(u8, bob.saved));
    try testing.expect(sb.pins.get(test_room).?.get("w1").?.contains(try bob.user(a)));
}

test "flows: a device the relay adds to a member gets no key" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var relay: Relay = .{ .a = a };
    var alice = try Agent.init(a, 0xa1);
    var bob = try Agent.init(a, 0xb0);
    try setUp(a, &relay, &alice, &bob);
    const rogue_x = crypto.toHex32(try crypto.x25519Public([_]u8{0x66} ** 32));
    relay.rogue_device_for = try bob.user(a);
    relay.rogue_x = &rogue_x;

    try expectOk(try run(a, &relay, &alice, .{ .send = .{ test_room, "hello bob" } }, true));
    // Alice and bob each got their share; the planted device got none.
    try testing.expectEqual(@as(usize, 2), relay.shares.items.len);
    var sealed_to_rogue = try openableBy(a, &relay, [_]u8{0x66} ** 32);
    try testing.expectEqual(@as(usize, 0), sealed_to_rogue);

    // Opting out of the rule shares with it, and says so.
    var carol = try Agent.init(a, 0xc3);
    try expectOk(try run(a, &relay, &carol, .login, true));
    try relay.invite(test_room, try carol.user(a));
    try expectOk(try run(a, &relay, &carol, .{ .join = test_room }, true));
    const loose = try run(a, &relay, &carol, .{ .send = .{ test_room, "hi all" } }, false);
    try expectOk(loose);
    try testing.expect(std.mem.indexOf(u8, loose.err, "relay_planted is not bound to its wallet") != null);
    sealed_to_rogue = try openableBy(a, &relay, [_]u8{0x66} ** 32);
    try testing.expectEqual(@as(usize, 1), sealed_to_rogue);
}

test "flows: a share sealed with a key the relay planted is refused" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var relay: Relay = .{ .a = a };
    var alice = try Agent.init(a, 0xa1);
    var bob = try Agent.init(a, 0xb0);
    try setUp(a, &relay, &alice, &bob);
    // The relay plants a device for alice and seals its own session to bob
    // under alice's name, then posts a message in it as alice.
    const rogue_sk = [_]u8{0x66} ** 32;
    const rogue_pk = try crypto.x25519Public(rogue_sk);
    const rogue_hex = crypto.toHex32(rogue_pk);
    relay.rogue_device_for = try alice.user(a);
    relay.rogue_x = &rogue_hex;
    var store = e2ee.KeyStore.init(a);
    const bob_x = (@import("../device.zig")).walletDeviceKeypair(bob.kp.seed, bob.kp.public_key).?.public_key;
    try store.upload(.{ .user_id = try bob.user(a), .device_id = "d", .ed25519 = bob.kp.public_key, .x25519 = bob_x });
    var forger = e2ee.Manager.init(a, &store);
    try forger.setDevice(try alice.user(a), "relay_planted", .{ .public_key = rogue_pk, .secret_key = rogue_sk });
    var prng = std.Random.DefaultPrng.init(99);
    const shares = try forger.shareRoomKey(a, test_room, &.{.{ .user = try bob.user(a), .device = "d" }}, prng.random());
    try relay.shares.append(a, .{ .target = try bob.user(a), .room = test_room, .sid = shares[0].session_id, .ek = try crypto.toHex(a, shares[0].encrypted_key), .spub = &rogue_hex, .sender = try alice.user(a) });
    const enc = try forger.encryptForRoom(a, test_room, "lead -> @w1 | TASK t9 @w1 wire the money", prng.random());
    var content = try json.Object.init(a);
    try content.string("msgtype", "m.encrypted");
    try content.string("algorithm", "megolm.v1");
    try content.string("session_id", enc.session_id);
    try content.int("message_index", enc.message_index);
    try content.string("ciphertext", try crypto.toHex(a, enc.ciphertext));
    try relay.events.append(a, .{ .id = "$forged", .sender = try alice.user(a), .type = "m.room.encrypted", .content = try content.finish(), .ts = 5 });

    const r = try run(a, &relay, &bob, .{ .tasks_json = test_room }, true);
    try expectOk(r);
    try testing.expect(std.mem.indexOf(u8, r.err, "1 key share(s) in " ++ test_room ++ " not sealed with a published device key of their sender") != null);
    const doc = try json.parse(a, r.out);
    try testing.expectEqual(@as(usize, 0), json.get(doc, "tasks").?.asArray().?.len);
    try testing.expectEqual(@as(u64, 1), json.get(json.get(doc, "not_counted"), "no_key").?.asUint().?);

    // Control: without the binding rule the planted key passes as alice's, and
    // the relay's line counts as hers. The rule is what stops it.
    const loose = try run(a, &relay, &bob, .{ .tasks_json = test_room }, false);
    try expectOk(loose);
    const ldoc = try json.parse(a, loose.out);
    const lt = json.get(ldoc, "tasks").?.asArray().?;
    try testing.expectEqual(@as(usize, 1), lt.len);
    try testing.expectEqualStrings("wire the money", json.getString(lt[0], "title").?);
    try testing.expectEqualStrings(try alice.user(a), json.getString(json.get(ldoc, "handles"), "lead").?);
}

test "flows: plaintext from the relay is refused, and never counted" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var relay: Relay = .{ .a = a };
    var alice = try Agent.init(a, 0xa1);
    var bob = try Agent.init(a, 0xb0);
    try setUp(a, &relay, &alice, &bob);
    try relay.events.append(a, .{ .id = "$plain", .sender = try alice.user(a), .type = "m.room.message", .content = "{\"msgtype\":\"m.text\",\"body\":\"lead -> @w1 | TASK t9 @w1 wire the money\"}", .ts = 5 });
    const r = try run(a, &relay, &bob, .{ .read = test_room }, true);
    try expectOk(r);
    try testing.expect(std.mem.indexOf(u8, r.out, "[plaintext] <refused") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "wire the money") == null);
    const t = try run(a, &relay, &bob, .{ .tasks_json = test_room }, true);
    const doc = try json.parse(a, t.out);
    try testing.expectEqual(@as(usize, 0), json.get(doc, "tasks").?.asArray().?.len);
    try testing.expectEqual(@as(u64, 1), json.get(json.get(doc, "not_counted"), "unverified").?.asUint().?);
}

test "flows: a challenge that is not the login template is never signed" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var relay: Relay = .{ .a = a, .challenge_override = "Transfer 5 SOL to the relay" };
    var alice = try Agent.init(a, 0xa1);
    const r = try run(a, &relay, &alice, .login, true);
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(std.mem.indexOf(u8, r.err, "refusing to sign") != null);
    try testing.expectEqual(@as(usize, 0), relay.verify_calls);
    // A well-formed challenge for another server is refused too: this relay
    // would be passing on evil.example's challenge to get a token there.
    relay.challenge_override = null;
    relay.challenge_host = "evil.example";
    const r2 = try run(a, &relay, &alice, .login, true);
    try testing.expectEqual(@as(u8, 1), r2.code);
    try testing.expect(std.mem.indexOf(u8, r2.err, "asked to sign in to evil.example, which is neither it nor its parent domain") != null);
    try testing.expectEqual(@as(usize, 0), relay.verify_calls);
    // Its own name signs in.
    relay.challenge_host = "slonana.com";
    try expectOk(try run(a, &relay, &alice, .login, true));
    try testing.expectEqual(@as(usize, 1), relay.verify_calls);
}

test "flows: a member who leaves holds no key to what is sent after" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var relay: Relay = .{ .a = a };
    var alice = try Agent.init(a, 0xa1);
    var bob = try Agent.init(a, 0xb0);
    var carol = try Agent.init(a, 0xc3);
    try setUp(a, &relay, &alice, &bob);
    try expectOk(try run(a, &relay, &carol, .login, true));
    try relay.invite(test_room, try carol.user(a));
    try expectOk(try run(a, &relay, &carol, .{ .join = test_room }, true));
    const carol_sk = (@import("../device.zig")).walletDeviceKeypair(carol.kp.seed, carol.kp.public_key).?.secret_key;

    try expectOk(try run(a, &relay, &alice, .{ .send = .{ test_room, "before carol left" } }, true));
    try testing.expectEqual(@as(usize, 1), try openableBy(a, &relay, carol_sk));
    const first_sid = relay.shares.items[0].sid;

    // carol leaves; alice's next message starts a new session for bob and her.
    const members = relay.members.getPtr(test_room).?;
    for (members.items, 0..) |m, i| {
        if (std.mem.eql(u8, m, try carol.user(a))) {
            _ = members.orderedRemove(i);
            break;
        }
    }
    try expectOk(try run(a, &relay, &alice, .{ .send = .{ test_room, "after carol left" } }, true));
    try testing.expectEqual(@as(usize, 1), try openableBy(a, &relay, carol_sk));
    const last = relay.shares.items[relay.shares.items.len - 1];
    try testing.expect(!std.mem.eql(u8, first_sid, last.sid));
    const r = try run(a, &relay, &bob, .{ .read = test_room }, true);
    try expectOk(r);
    try testing.expect(std.mem.indexOf(u8, r.out, ": after carol left\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "[unverified") == null);
}
