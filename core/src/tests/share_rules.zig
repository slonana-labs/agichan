//! The share rules and sender binding, as the pinned outcome strings of
//! tests/test_aexchat_megolm_browser_compat.cpp (ShareRuleOutcomesForTheBrowser,
//! SenderBindingOutcomesForTheBrowser). The scenarios are rebuilt step by
//! step with this package's manager; the expected strings are the C++'s.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const crypto = @import("../crypto.zig");
const megolm = @import("../megolm.zig");
const e2ee = @import("../e2ee.zig");

/// A test failure, not a panic that stops the other tests, when `x` is null.
fn some(x: anytype) !@typeInfo(@TypeOf(x)).optional.child {
    return x orelse error.TestUnexpectedNull;
}

const kShareRoom = "!interop:test";
const kShareSid = "interop_sid_v1";
const kShareCounter: u32 = 5;
const kNativeUser = "@native:test";
const kNativeDevice = "cli_native";
const kWebUser = "@web:test";
const kWebDevice = "web_browser";
const kCarolUser = "@carol:test";
const kCarolDevice = "carol";
const kSidG = "fefe0b60760d09ad6bc1add63edfb27b3fd077d1237a807c768a8e20416d1151";

fn fill(b: u8) crypto.Key32 {
    return [_]u8{b} ** 32;
}

fn filled4(first: u8) megolm.Ratchets {
    var r: megolm.Ratchets = undefined;
    for (&r, 0..) |*k, i| k.* = fill(first +% @as(u8, @intCast(i)));
    return r;
}

fn fixedDevice(b: u8) crypto.X25519Keypair {
    return .{ .public_key = crypto.x25519Public(fill(b)) catch unreachable, .secret_key = fill(b) };
}

const Env = struct {
    a: Allocator,
    rng: std.Random,

    /// session_json of the C++ test: `key` as the room's saved outbound session.
    fn sessionJson(env: Env, k: megolm.ExportedKey) ![]u8 {
        var r: [4][]const u8 = undefined;
        for (k.ratchets, 0..) |x, i| r[i] = try crypto.toHex(env.a, &x);
        return std.fmt.allocPrint(env.a, "{{\"outbound\":[{{\"room_id\":\"{s}\",\"session_id\":\"{s}\",\"counter\":{d},\"ratchets\":[\"{s}\",\"{s}\",\"{s}\",\"{s}\"]}}],\"inbound\":[]}}", .{ kShareRoom, k.session_id, k.counter, r[0], r[1], r[2], r[3] });
    }

    /// share_sealed_by: a share of `key` for the web device, sealed by a
    /// device of `user` whose manager imported `key` as its session.
    fn shareSealedBy(env: Env, key: megolm.ExportedKey, user: []const u8, dev: []const u8, kp: crypto.X25519Keypair) !e2ee.KeyShareEvent {
        var store = e2ee.KeyStore.init(env.a);
        try store.upload(.{ .user_id = kWebUser, .device_id = kWebDevice, .ed25519 = fill(0x07), .x25519 = fixedDevice(0xb2).public_key });
        var sender = e2ee.Manager.init(env.a, &store);
        try sender.setDevice(user, dev, kp);
        try testing.expect(try sender.importSessions(try env.sessionJson(key)));
        const shares = try sender.shareRoomKey(env.a, kShareRoom, &.{.{ .user = kWebUser, .device = kWebDevice }}, env.rng);
        try testing.expectEqual(@as(usize, 1), shares.len);
        var s = shares[0];
        s.sender_user = user;
        return s;
    }

    fn nativeShareOf(env: Env, key: megolm.ExportedKey) !e2ee.KeyShareEvent {
        return env.shareSealedBy(key, kNativeUser, kNativeDevice, fixedDevice(0xa1));
    }

    fn messageAt(env: Env, sid: []const u8, r: megolm.Ratchets, index: u32, pt: []const u8) !e2ee.EncryptedMessage {
        var out = try megolm.Outbound.fromExported(env.a, .{ .session_id = sid, .ratchets = r, .counter = index });
        const sealed = try out.encrypt(env.a, pt, env.rng);
        return .{ .session_id = sid, .message_index = sealed.index, .ciphertext = sealed.blob };
    }
};

fn statusName(s: e2ee.ShareStatus) []const u8 {
    return switch (s) {
        .imported => "imported",
        .no_sender => "no_sender",
        .not_senders_key => "not_senders_key",
        .undecryptable => "undecryptable",
        .refused => "refused",
    };
}

test "share rule outcomes (ShareRuleOutcomesForTheBrowser)" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var prng = std.Random.DefaultPrng.init(11);
    const env: Env = .{ .a = ar.allocator(), .rng = prng.random() };
    const a = env.a;
    const g = filled4(0x01);
    const fr = filled4(0xf1);
    var gout = try megolm.Outbound.fromExported(a, .{ .session_id = kSidG, .ratchets = g, .counter = 0 });
    const mg0 = try gout.encrypt(a, "g0", env.rng);
    for (1..5) |i| _ = try gout.encrypt(a, try std.fmt.allocPrint(a, "g{d}", .{i}), env.rng);
    const g5 = gout.exportKey();
    try testing.expectEqual(@as(u32, 5), g5.counter);
    const mg5 = try gout.encrypt(a, "g5", env.rng);
    const mg6 = try gout.encrypt(a, "g6", env.rng);
    const gm = struct {
        fn f(s: megolm.Sealed) e2ee.EncryptedMessage {
            return .{ .session_id = kSidG, .message_index = s.index, .ciphertext = s.blob };
        }
    }.f;
    var mf: [10]e2ee.EncryptedMessage = undefined;
    for ([_]u32{ 0, 2, 3, 5, 9 }) |k| mf[k] = try env.messageAt(kSidG, fr, k, "forged");
    var bad_sid: [64]u8 = kSidG.*;
    bad_sid[63] = if (bad_sid[63] == '0') '1' else '0';

    var store = e2ee.KeyStore.init(a);
    try store.upload(.{ .user_id = kNativeUser, .device_id = kNativeDevice, .ed25519 = fill(0x07), .x25519 = fixedDevice(0xa1).public_key });
    const Fresh = struct {
        fn make(al: Allocator, st: *const e2ee.KeyStore) !e2ee.Manager {
            var m = e2ee.Manager.init(al, st);
            try m.setDevice(kWebUser, kWebDevice, fixedDevice(0xb2));
            return m;
        }
    };
    const imp = struct {
        fn f(e: Env, m: *e2ee.Manager, k: megolm.ExportedKey) ![]const u8 {
            return if (try m.receiveKeyShare(try e.nativeShareOf(k)) == .imported) "1" else "0";
        }
    }.f;
    const dec = struct {
        fn f(al: Allocator, m: *e2ee.Manager, e: e2ee.EncryptedMessage) ![]const u8 {
            const d = try m.decrypt(al, e, kNativeUser) orelse return "-";
            return d.plaintext;
        }
    }.f;
    const g0: megolm.ExportedKey = .{ .session_id = kSidG, .ratchets = g, .counter = 0 };
    const fk = struct {
        fn f(r: megolm.Ratchets, k: u32) megolm.ExportedKey {
            return .{ .session_id = kSidG, .ratchets = r, .counter = k };
        }
    }.f;

    var s_a: std.ArrayListUnmanaged(u8) = .empty;
    {
        var m = try Fresh.make(a, &store);
        for ([_]megolm.ExportedKey{ g5, fk(fr, 0), fk(fr, 2), fk(fr, 5), fk(fr, 9) }) |k| try s_a.appendSlice(a, try imp(env, &m, k));
        for ([_]e2ee.EncryptedMessage{ gm(mg6), mf[0], mf[2], mf[5], mf[9] }) |e| {
            try s_a.append(a, ',');
            try s_a.appendSlice(a, try dec(a, &m, e));
        }
    }
    var s_b: std.ArrayListUnmanaged(u8) = .empty;
    {
        var m = try Fresh.make(a, &store);
        for ([_]megolm.ExportedKey{ fk(fr, 0), fk(fr, 3), g0 }) |k| try s_b.appendSlice(a, try imp(env, &m, k));
        try s_b.print(a, ",{s},{s}", .{ try dec(a, &m, gm(mg5)), try dec(a, &m, mf[3]) });
    }
    var s_c: std.ArrayListUnmanaged(u8) = .empty;
    {
        var m = try Fresh.make(a, &store);
        try s_c.appendSlice(a, try imp(env, &m, g5));
        try s_c.appendSlice(a, try imp(env, &m, g5));
        try s_c.print(a, ",{s}", .{try dec(a, &m, gm(mg0))});
        try s_c.print(a, ",{s}", .{try imp(env, &m, g0)});
        try s_c.print(a, ",{s}", .{try dec(a, &m, gm(mg0))});
        try s_c.print(a, ",{s}", .{try dec(a, &m, gm(mg5))});
        try s_c.print(a, ",{s}", .{try imp(env, &m, g5)});
        try s_c.print(a, ",{s}", .{try dec(a, &m, gm(mg0))});
        try s_c.print(a, ",{s}", .{try dec(a, &m, gm(mg6))});
    }
    var s_d: std.ArrayListUnmanaged(u8) = .empty;
    {
        var m = try Fresh.make(a, &store);
        var under_bad = gm(mg0);
        under_bad.session_id = &bad_sid;
        try s_d.appendSlice(a, try imp(env, &m, .{ .session_id = &bad_sid, .ratchets = g, .counter = 0 }));
        try s_d.print(a, ",{s}", .{try dec(a, &m, under_bad)});
        try s_d.print(a, ",{s}", .{try imp(env, &m, g0)});
        try s_d.print(a, ",{s}", .{try dec(a, &m, gm(mg0))});
    }
    // The native rule, pinned so the browser has a fixed target.
    try testing.expectEqualStrings("10000,g6,-,-,-,-", s_a.items);
    try testing.expectEqualStrings("011,g5,-", s_b.items);
    try testing.expectEqualStrings("11,-,1,g0,g5,1,g0,g6", s_c.items);
    try testing.expectEqualStrings("0,-,1,g0", s_d.items);
}

test "sender binding outcomes (SenderBindingOutcomesForTheBrowser)" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var prng = std.Random.DefaultPrng.init(12);
    const env: Env = .{ .a = ar.allocator(), .rng = prng.random() };
    const a = env.a;
    var store = e2ee.KeyStore.init(a);
    try store.upload(.{ .user_id = kNativeUser, .device_id = kNativeDevice, .ed25519 = fill(0x07), .x25519 = fixedDevice(0xa1).public_key });
    try store.upload(.{ .user_id = kCarolUser, .device_id = kCarolDevice, .ed25519 = fill(0x07), .x25519 = fixedDevice(0xc3).public_key });
    const fresh = struct {
        fn f(al: Allocator, st: *const e2ee.KeyStore) !e2ee.Manager {
            var m = e2ee.Manager.init(al, st);
            try m.setDevice(kWebUser, kWebDevice, fixedDevice(0xb2));
            return m;
        }
    }.f;
    const decAs = struct {
        fn f(al: Allocator, m: *e2ee.Manager, e: e2ee.EncryptedMessage, who: []const u8) ![]const u8 {
            const d = try m.decrypt(al, e, who) orelse return "-";
            return d.plaintext;
        }
    }.f;

    const g = filled4(0x01);
    const fr = filled4(0xf1);
    var gout = try megolm.Outbound.fromExported(a, .{ .session_id = kSidG, .ratchets = g, .counter = 0 });
    for (0..5) |i| _ = try gout.encrypt(a, try std.fmt.allocPrint(a, "g{d}", .{i}), env.rng);
    const g5 = gout.exportKey();
    const s5 = try gout.encrypt(a, "g5", env.rng);
    const s6 = try gout.encrypt(a, "g6", env.rng);
    const mg5: e2ee.EncryptedMessage = .{ .session_id = kSidG, .message_index = s5.index, .ciphertext = s5.blob };
    const mg6: e2ee.EncryptedMessage = .{ .session_id = kSidG, .message_index = s6.index, .ciphertext = s6.blob };
    const mf3 = try env.messageAt(kSidG, fr, 3, "forged");

    var squat: std.ArrayListUnmanaged(u8) = .empty;
    {
        var m = try fresh(a, &store);
        try squat.print(a, "plant={s}", .{statusName(try m.receiveKeyShare(try env.shareSealedBy(.{ .session_id = kSidG, .ratchets = fr, .counter = 3 }, kCarolUser, kCarolDevice, fixedDevice(0xc3))))});
        try squat.print(a, " genuine={s}", .{statusName(try m.receiveKeyShare(try env.nativeShareOf(g5)))});
        try squat.print(a, " mg5@native={s}", .{try decAs(a, &m, mg5, kNativeUser)});
        try squat.print(a, " mg6@native={s}", .{try decAs(a, &m, mg6, kNativeUser)});
        try squat.print(a, " mg5@carol={s}", .{try decAs(a, &m, mg5, kCarolUser)});
        try squat.print(a, " mf3@carol={s}", .{try decAs(a, &m, mf3, kCarolUser)});
        try squat.print(a, " mf3@native={s}", .{try decAs(a, &m, mf3, kNativeUser)});
    }

    const fixed = try env.nativeShareOf(.{ .session_id = kShareSid, .ratchets = .{ fill(0x00), fill(0x11), fill(0x22), fill(0x33) }, .counter = kShareCounter });
    const fmsg = try env.messageAt(kShareSid, .{ fill(0x00), fill(0x11), fill(0x22), fill(0x33) }, 5, "hello from a native agent");
    const fixed_hex = try crypto.toHex(a, fixed.encrypted_key);
    var sender: std.ArrayListUnmanaged(u8) = .empty;
    {
        var m = try fresh(a, &store);
        const named = struct {
            fn f(mm: *e2ee.Manager, base: e2ee.KeyShareEvent, who: []const u8) ![]const u8 {
                var s = base;
                s.sender_user = who;
                return statusName(try mm.receiveKeyShare(s));
            }
        }.f;
        try sender.print(a, "count0={d}", .{m.refused_unbound});
        // The browser's missing sender_user; the CLI reads it as empty too.
        try sender.print(a, " empty_sender={s}", .{try named(&m, fixed, "")});
        try sender.print(a, " missing_sender={s}", .{try named(&m, fixed, "")});
        try sender.print(a, " count={d}", .{m.refused_unbound});
        try sender.print(a, " read={s}", .{try decAs(a, &m, fmsg, kNativeUser)});
        try sender.print(a, " nobody={s}", .{try named(&m, fixed, "@nobody:test")});
        try sender.print(a, " named_carol={s}", .{try named(&m, fixed, kCarolUser)});
        var carols_key = fixed;
        carols_key.sender_x25519_public = fixedDevice(0xc3).public_key;
        try sender.print(a, " carols_key_naming_native={s}", .{statusName(try m.receiveKeyShare(carols_key))});
        var no_store = e2ee.Manager.init(a, null);
        try no_store.setDevice(kWebUser, kWebDevice, fixedDevice(0xb2));
        try sender.print(a, " no_member_keys={s}", .{statusName(try no_store.receiveKeyShare(fixed))});
        var t = try a.dupe(u8, fixed_hex);
        t[40] = if (t[40] == '0') '1' else '0';
        var tampered = fixed;
        tampered.encrypted_key = try some(try crypto.fromHex(a, t));
        try sender.print(a, " tampered={s}", .{statusName(try m.receiveKeyShare(tampered))});
        try sender.print(a, " read={s}", .{try decAs(a, &m, fmsg, kNativeUser)});
        try sender.print(a, " control={s}", .{try named(&m, fixed, kNativeUser)});
        try sender.print(a, " read@native={s}", .{try decAs(a, &m, fmsg, kNativeUser)});
        try sender.print(a, " read@carol={s}", .{try decAs(a, &m, fmsg, kCarolUser)});
        try sender.print(a, " read@nosender={s}", .{try decAs(a, &m, fmsg, "")});
        try sender.print(a, " count={d}", .{m.refused_unbound});
    }

    try testing.expectEqualStrings("plant=imported genuine=imported mg5@native=g5 " ++
        "mg6@native=g6 mg5@carol=- mf3@carol=forged mf3@native=-", squat.items);
    try testing.expectEqualStrings("count0=0 empty_sender=no_sender missing_sender=no_sender count=2 " ++
        "read=- nobody=not_senders_key named_carol=not_senders_key " ++
        "carols_key_naming_native=not_senders_key " ++
        "no_member_keys=not_senders_key tampered=undecryptable read=- " ++
        "control=imported read@native=hello from a native agent " ++
        "read@carol=- read@nosender=- count=2", sender.items);
}

test "forwarded sessions: readable, tagged with the forwarder, never verified" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var prng = std.Random.DefaultPrng.init(13);
    const rng = prng.random();
    const a = ar.allocator();
    var store = e2ee.KeyStore.init(a);
    const native = fixedDevice(0xa1);
    const web = fixedDevice(0xb2);
    const carol = fixedDevice(0xc3);
    try store.upload(.{ .user_id = kNativeUser, .device_id = kNativeDevice, .ed25519 = fill(7), .x25519 = native.public_key });
    try store.upload(.{ .user_id = kWebUser, .device_id = kWebDevice, .ed25519 = fill(7), .x25519 = web.public_key });
    try store.upload(.{ .user_id = kCarolUser, .device_id = kCarolDevice, .ed25519 = fill(7), .x25519 = carol.public_key });

    // native sends two messages and shares its session with web.
    var sender = e2ee.Manager.init(a, &store);
    try sender.setDevice(kNativeUser, kNativeDevice, native);
    const shares = try sender.shareRoomKey(a, kShareRoom, &.{.{ .user = kWebUser, .device = kWebDevice }}, rng);
    const m0 = try sender.encryptForRoom(a, kShareRoom, "first", rng);
    const m1 = try sender.encryptForRoom(a, kShareRoom, "second", rng);
    // The sender reads itself (its own inbound copy).
    try testing.expect((try some(try sender.decrypt(a, m0, kNativeUser))).verified);

    var webm = e2ee.Manager.init(a, &store);
    try webm.setDevice(kWebUser, kWebDevice, web);
    var s = shares[0];
    s.sender_user = kNativeUser;
    try testing.expectEqual(e2ee.ShareStatus.imported, try webm.receiveKeyShare(s));

    // web forwards native's session to carol, a late joiner.
    const fwd = try webm.forwardSessions(a, kShareRoom, &.{ .{ .sender = kNativeUser, .session_id = m0.session_id }, .{ .sender = kNativeUser, .session_id = m0.session_id }, .{ .sender = kCarolUser, .session_id = "none" } }, &.{.{ .user = kCarolUser, .device = kCarolDevice }}, rng);
    try testing.expectEqual(@as(usize, 1), fwd.len);
    var carolm = e2ee.Manager.init(a, &store);
    try carolm.setDevice(kCarolUser, kCarolDevice, carol);
    var f0 = fwd[0];
    f0.sender_user = kWebUser;
    try testing.expectEqual(e2ee.ShareStatus.imported, try carolm.receiveKeyShare(f0));
    const d = try some(try carolm.decrypt(a, m1, kNativeUser));
    try testing.expectEqualStrings("second", d.plaintext);
    try testing.expect(!d.verified);
    try testing.expectEqualStrings(kWebUser, d.forwarded_by);
    // It decrypts for native only, never as web's own message.
    try testing.expect((try carolm.decrypt(a, m1, kWebUser)) == null);
    // native's own share later outranks the forward for what it covers.
    var own = (try sender.shareRoomKey(a, kShareRoom, &.{.{ .user = kCarolUser, .device = kCarolDevice }}, rng))[0];
    own.sender_user = kNativeUser;
    try testing.expectEqual(e2ee.ShareStatus.imported, try carolm.receiveKeyShare(own));
    const m2 = try sender.encryptForRoom(a, kShareRoom, "third", rng);
    try testing.expect((try some(try carolm.decrypt(a, m2, kNativeUser))).verified);
    // The forward still serves the indices before native's own share.
    try testing.expectEqualStrings(kWebUser, (try some(try carolm.decrypt(a, m0, kNativeUser))).forwarded_by);

    // Sessions survive export and import, forwards included.
    var again = e2ee.Manager.init(a, &store);
    try again.setDevice(kCarolUser, kCarolDevice, carol);
    try testing.expect(try again.importSessions(try carolm.exportSessions(a)));
    try testing.expectEqual(@as(usize, 1), again.forwardedSessionCount());
    try testing.expectEqualStrings("first", (try some(try again.decrypt(a, m0, kNativeUser))).plaintext);
    try testing.expect(!try again.importSessions("{\"outbound\":[],\"inbound\":[{\"session_id\":\"x\",\"counter\":0,\"ratchets\":[]}]}"));
    const z = "\"" ++ "0" ** 64 ++ "\"";
    const entry = "{\"outbound\":[],\"inbound\":[{\"session_id\":\"x\",\"counter\":0,\"ratchets\":[" ++ z ++ "," ++ z ++ "," ++ z ++ "," ++ z ++ "]";
    // forwarded_by without sender_user is malformed; with it, it imports.
    try testing.expect(!try again.importSessions(entry ++ ",\"forwarded_by\":\"@a:b\"}]}"));
    try testing.expect(!try again.importSessions(entry ++ ",\"sender_user\":\"\"}]}"));
    try testing.expect(try again.importSessions(entry ++ ",\"sender_user\":\"@o:b\",\"forwarded_by\":\"@a:b\"}]}"));
    try testing.expectEqual(@as(usize, 2), again.forwardedSessionCount());
}

test "a device with a low-order key gets no share (ECDH refuses the zero result)" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var prng = std.Random.DefaultPrng.init(14);
    const a = ar.allocator();
    var store = e2ee.KeyStore.init(a);
    // u = 0: every scalar times it is zero, so a share "sealed" to it would be
    // under HKDF of an all-zero secret that anyone can compute.
    try store.upload(.{ .user_id = "@low:test", .device_id = "low", .ed25519 = fill(7), .x25519 = [_]u8{0} ** 32 });
    try store.upload(.{ .user_id = kWebUser, .device_id = kWebDevice, .ed25519 = fill(7), .x25519 = fixedDevice(0xb2).public_key });
    var mgr = e2ee.Manager.init(a, &store);
    try mgr.setDevice(kNativeUser, kNativeDevice, fixedDevice(0xa1));
    const shares = try mgr.shareRoomKey(a, kShareRoom, &.{ .{ .user = "@low:test", .device = "low" }, .{ .user = kWebUser, .device = kWebDevice } }, prng.random());
    try testing.expectEqual(@as(usize, 2), shares.len);
    try testing.expectEqual(@as(usize, 0), shares[0].encrypted_key.len);
    try testing.expect(shares[1].encrypted_key.len != 0);
    try testing.expectError(error.WeakKey, e2ee.shareKey(fill(0x55), [_]u8{0} ** 32));
}
