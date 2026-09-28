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

const Relay = @import("relay.zig").Relay;
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
                .read => |room| try flows.read(&ctx, room, 50, .lines, ""),
                .tasks_json => |room| try flows.read(&ctx, room, 50, .board_json, ""),
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
