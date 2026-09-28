//! End-to-end impersonation resistance through the real e2ee.Manager API, from
//! the 2026-09-28 infosec audit (build/scratch/agichan-audit/adv.zig). A hostile
//! relay serving a victim's real (public, computable) wallet-derived key still
//! cannot forge a verified session, an unlisted sender key is refused, and a
//! forwarded-only session cannot be re-forwarded. Ported to the real modules.
const std = @import("std");
const crypto = @import("../crypto.zig");
const megolm = @import("../megolm.zig");
const e2ee = @import("../e2ee.zig");
const device = @import("../device.zig");
const base58 = @import("../base58.zig");

fn fill(b: u8) crypto.Key32 {
    return [_]u8{b} ** 32;
}

// Build a real wallet user_id "@<base58 ed pub>:s" and its bound device kp.
const Wallet = struct { user: []const u8, dev: crypto.X25519Keypair };
fn makeWallet(a: std.mem.Allocator, seed_byte: u8) !Wallet {
    const seed = [_]u8{seed_byte} ** 32;
    const kp = try crypto.Ed25519.KeyPair.generateDeterministic(seed);
    const dev = device.walletDeviceKeypair(seed, kp.public_key.toBytes()).?;
    const wallet_b58 = try base58.encode(a, &kp.public_key.toBytes());
    const user = try std.mem.concat(a, u8, &.{ "@", wallet_b58, ":s" });
    return .{ .user = user, .dev = dev };
}

// THREAT #1/#2: a hostile relay serves @victim's true (wallet-derived) device
// key, names the share as from @victim, but cannot seal a blob that opens under
// our key -> undecryptable, never a verified @victim session.
test "hostile relay cannot forge a verified session for a victim wallet" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const me = try makeWallet(a, 0xA1);
    const victim = try makeWallet(a, 0xB2);

    var store = e2ee.KeyStore.init(gpa);
    defer store.deinit();
    // The relay serves the victim's REAL wallet-derived key (public, computable).
    // With bound_only the client only stores such keys, so this is the strongest
    // case: the store entry is legitimate; only sealing needs the secret.
    try store.upload(.{ .user_id = victim.user, .device_id = "vdev", .ed25519 = fill(0), .x25519 = victim.dev.public_key });

    var mgr = e2ee.Manager.init(gpa, &store);
    defer mgr.deinit();
    try mgr.setDevice(me.user, "mydev", me.dev);

    // A valid megolm key the attacker wants us to accept as the victim's.
    const key: megolm.ExportedKey = .{ .session_id = "attacker_sid", .ratchets = .{ fill(9), fill(8), fill(7), fill(6) }, .counter = 3 };
    const payload = try e2ee.serializeExportedKey(a, key, null);
    // The relay does NOT know victim's x25519 secret nor ours. Best it can do is
    // seal under a key it controls (its own secret vs our public) OR ship garbage.
    const relay_secret = fill(0xEE);
    const wrong_key = try e2ee.shareKey(relay_secret, me.dev.public_key);
    const blob = try crypto.gcmSeal(a, wrong_key, payload, [_]u8{1} ** 12);

    const ev: e2ee.KeyShareEvent = .{
        .room_id = "!r:s",
        .session_id = key.session_id,
        .target_user = me.user,
        .target_device = "mydev",
        .encrypted_key = blob,
        .sender_x25519_public = victim.dev.public_key, // claims victim's real key
        .sender_user = victim.user,
    };
    const status = try mgr.receiveKeyShare(ev);
    // Passes the sealed-by-sender check (real key) but cannot open: undecryptable.
    try std.testing.expectEqual(e2ee.ShareStatus.undecryptable, status);

    // And no verified session exists for the victim afterwards.
    var prng = std.Random.DefaultPrng.init(1);
    var out = try megolm.Outbound.fromExported(a, key);
    const sealed = try out.encrypt(a, "forged text", prng.random());
    const dec = try mgr.decrypt(a, .{ .session_id = key.session_id, .message_index = sealed.index, .ciphertext = sealed.blob }, victim.user);
    try std.testing.expect(dec == null);
}

// THREAT #2: a share whose sender_x25519 is NOT any published key of the named
// sender is rejected before any decryption attempt.
test "share not sealed with a published sender key is refused" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const me = try makeWallet(a, 0x11);
    const victim = try makeWallet(a, 0x22);
    var store = e2ee.KeyStore.init(gpa);
    defer store.deinit();
    try store.upload(.{ .user_id = victim.user, .device_id = "vdev", .ed25519 = fill(0), .x25519 = victim.dev.public_key });
    var mgr = e2ee.Manager.init(gpa, &store);
    defer mgr.deinit();
    try mgr.setDevice(me.user, "mydev", me.dev);
    const ev: e2ee.KeyShareEvent = .{
        .room_id = "!r:s",
        .session_id = "sid",
        .target_user = me.user,
        .target_device = "mydev",
        .encrypted_key = "\x00\x00",
        .sender_x25519_public = fill(0xEE), // an unlisted key
        .sender_user = victim.user,
    };
    try std.testing.expectEqual(e2ee.ShareStatus.not_senders_key, try mgr.receiveKeyShare(ev));
    // Empty sender is refused as naming nobody.
    var ev2 = ev;
    ev2.sender_user = "";
    try std.testing.expectEqual(e2ee.ShareStatus.no_sender, try mgr.receiveKeyShare(ev2));
}

// THREAT #2: a session held only as a FORWARD cannot be re-forwarded.
test "a forwarded-only session cannot be re-forwarded" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const me = try makeWallet(a, 0x31);
    const origin = try makeWallet(a, 0x32); // the true session creator
    const fwder = try makeWallet(a, 0x33); // who forwarded it to me
    const target = try makeWallet(a, 0x34); // who I might try to forward to

    var store = e2ee.KeyStore.init(gpa);
    defer store.deinit();
    try store.upload(.{ .user_id = fwder.user, .device_id = "fdev", .ed25519 = fill(0), .x25519 = fwder.dev.public_key });
    try store.upload(.{ .user_id = target.user, .device_id = "tdev", .ed25519 = fill(0), .x25519 = target.dev.public_key });

    var mgr = e2ee.Manager.init(gpa, &store);
    defer mgr.deinit();
    try mgr.setDevice(me.user, "mydev", me.dev);

    // Craft a forward from `fwder` naming `origin` as the session's origin,
    // sealed correctly to my device with fwder's secret.
    const key: megolm.ExportedKey = .{ .session_id = "fwd_sid", .ratchets = .{ fill(1), fill(2), fill(3), fill(4) }, .counter = 0 };
    // counter 0 must have a proven id (sid == hash(ratchets)); use the real id.
    const real_sid = megolm.sessionId(key.ratchets);
    const key2: megolm.ExportedKey = .{ .session_id = &real_sid, .ratchets = key.ratchets, .counter = 0 };
    const payload = try e2ee.serializeExportedKey(a, key2, origin.user);
    const sk = try e2ee.shareKey(fwder.dev.secret_key, me.dev.public_key);
    const blob = try crypto.gcmSeal(a, sk, payload, [_]u8{2} ** 12);
    const ev: e2ee.KeyShareEvent = .{
        .room_id = "!r:s",
        .session_id = &real_sid,
        .target_user = me.user,
        .target_device = "mydev",
        .encrypted_key = blob,
        .sender_x25519_public = fwder.dev.public_key,
        .sender_user = fwder.user,
    };
    try std.testing.expectEqual(e2ee.ShareStatus.imported, try mgr.receiveKeyShare(ev));
    try std.testing.expectEqual(@as(usize, 1), mgr.forwardedSessionCount());

    // Now try to forward that session onward. It lives only in `forwarded`,
    // keyed under origin; forwardSessions reads only `inbound` -> nothing.
    const which = [_]e2ee.SessionRef{.{ .sender = origin.user, .session_id = &real_sid }};
    const targets = [_]e2ee.Target{.{ .user = target.user, .device = "tdev" }};
    var prng = std.Random.DefaultPrng.init(2);
    const events = try mgr.forwardSessions(a, "!r:s", &which, &targets, prng.random());
    try std.testing.expectEqual(@as(usize, 0), events.len);
    // Also under the forwarder's own name -> still not in inbound -> nothing.
    const which2 = [_]e2ee.SessionRef{.{ .sender = fwder.user, .session_id = &real_sid }};
    const events2 = try mgr.forwardSessions(a, "!r:s", &which2, &targets, prng.random());
    try std.testing.expectEqual(@as(usize, 0), events2.len);
}
