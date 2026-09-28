//! The 25 pinned vectors, as literals copied from the C++ tests:
//!   tests/test_aexchat_megolm_browser_compat.cpp (browser vectors, far pins,
//!     device public keys, the browser's share and send path),
//!   tests/test_aexchat_e2ee.cpp (CppWasmRatchetParity),
//!   tests/test_ed25519_avx2.cpp (RFC 8032 test 1, as pinned there).
//! Each is checked through this package's own code, not a local copy of it.
const std = @import("std");
const testing = std.testing;
const crypto = @import("../crypto.zig");
const megolm = @import("../megolm.zig");
const e2ee = @import("../e2ee.zig");

/// A test failure, not a panic that stops the other tests, when `x` is null.
fn some(x: anytype) !@typeInfo(@TypeOf(x)).optional.child {
    return x orelse error.TestUnexpectedNull;
}
const device = @import("../device.zig");

// test_aexchat_megolm_browser_compat.cpp
const kIdx0MessageKey = "da9d2383815d52bf414c540d97e91d0facf9b98729f9a3f437ad4a9b571676a0";
const kIdx0AesKey = "4216b1f509961546a77a884f46a9bf4b09a5f64b338801d501a712a312e36ec3";
const kIdx1MessageKey = "5879cdce72e9057c4e21ac66f25c9bb05b6c5e0c27ff5634e297a7543572875b";
const kShareSid = "interop_sid_v1";
const kBrowserShareOfFixedSession =
    "8c860cfdc06267c488567563b62e784584e15e76f128d8cd88137ae19d809776" ++
    "a9aeb249c453eb72add8747a35c6cece7cb7f0c4d33f502e6e0ed0a32008ac8e" ++
    "2a617a7ce9ed85f3420f0c26842addb10043a703745176f68fd367b260d9bea9" ++
    "da39b91bfae6f44db225d8c87d9199509bc7ec300ca84720ded2b822464353ef" ++
    "60c9677011f7e5f94dcfcd34d73bb86c25de5ea3ab0688ead82bbe695df87691" ++
    "161eab573866921e375f01d86ee21666";
const kBrowserSendShare =
    "85521e8043afe55ca711163eb2d00fee0d8da24e6b390b4cf67d1073a53f6342" ++
    "90ed81761e2fab3b30df503e927f13ba9fc8895f2d5102601c01d851ee343e8d" ++
    "00f4d87d56b64d8cd58ba65f3f69710f92c28a7539a1957281ce33a99c7f18b1" ++
    "54680d6d1ddf27db5b9c999b7ebccb1f986c1adba6592a5a0eb734d268a0ffad" ++
    "17e1b84bf7b08bd0765f65901cadb3c60b58b2cdf8ab88d7ade369749fb04e83" ++
    "4b4002d7fb91368e299718b9247373383c461a1a593ffdff9816ed561461e938" ++
    "6cb78869dffb53099bc38fc9b1a1ac9ca51a2890de877797d9bfbd5813e31541" ++
    "1a8c";
const kBrowserSendSid = "c7773ef55887d12c14af2fb0a1be35751b219ac2c8ee4baf52d36dbcbb257631";
const kBrowserSendMsg0 =
    "f7d9be1048507cbc05caa9b242ae3fce7b4d05cb89cf32164d344c2fa37f874e" ++
    "cd4b499656fd309c26eaace933ad802462f4011770fe3a76d0ce7ab0d362a26b" ++
    "697fa450b8b98cd5c426";
const kBrowserSendMsg1 =
    "8c887f88630b4d93f36641a16bef8215fc665d0981f589cb360b22807c5f274f" ++
    "59beb6f48dbbcd27155e";
const kSidG = "fefe0b60760d09ad6bc1add63edfb27b3fd077d1237a807c768a8e20416d1151";
const kWebDevicePublic = "db48257e1237976a74ad8cfedca00213408fe89ac6251f1b930245f242b5c31a";
const kNativeDevicePublic = "c306fb0ef2bf8b7f93bad98155fa37daec74db0c4cbeda6c6f1dba9d36558252";
const FarPin = struct { start: u32, target: u32, key: []const u8, digest: []const u8 };
const kFarPins = [_]FarPin{
    .{ .start = 0, .target = 65536, .key = "06120ecf2f1ead266325abb843431cae7e4e29498ef801709ceaf00aa1f61ebe", .digest = "85bdddfa4b466513ea6da806ca047fc6cca1d509af64d7c69868c451606a1386" },
    .{ .start = 0, .target = 16777217, .key = "6fbfd1a48de536d78610dbe29af76250013612b9d09017978613feec8c017861", .digest = "6851683ba8eb3beb9575100c775373c177698159881bf6af032fb799f6da1786" },
    .{ .start = 0, .target = 33554433, .key = "dee2d039c70b5e910c95f152f3b9126e967ccf049229bf7c9fc84ca3e40c7a35", .digest = "49c446bf7ea2acf6231081daeb589973703c49cd50a20e4342c6a513f95e7863" },
    .{ .start = 0xFFFFFF00, .target = 0xFFFFFFFF, .key = "3829ff08524dfd089c0ef2c95041019c6843a6b4b9cc1aa69eef8d72fb3a806c", .digest = "a2eee352fb0a845e66cc585a377092b3c34bf107ba734f6d8e1999825d695e3c" },
};
// test_aexchat_e2ee.cpp CppWasmRatchetParity
const kParityKey0 = "9cccfe5fbb1a0c5ffebce52268c0219041e1168c76fea3b0474b261981e09b6a";
const kParityKey300 = "65843335d76db4b7e97f7d664a171bac1d4ca54a7e4863256d184b381cca5c28";
// test_ed25519_avx2.cpp, RFC 8032 test 1
const kRfcSeed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
const kRfcPublic = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
const kRfcSignature = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";

fn fill(b: u8) crypto.Key32 {
    return [_]u8{b} ** 32;
}

fn filled4(first: u8) megolm.Ratchets {
    var r: megolm.Ratchets = undefined;
    for (&r, 0..) |*k, i| k.* = fill(first + @as(u8, @intCast(i)));
    return r;
}

fn unhex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

fn hex32(k: crypto.Key32) [64]u8 {
    return crypto.toHex32(k);
}

fn stateDigest(r: megolm.Ratchet) [64]u8 {
    return crypto.toHex32(crypto.sha256(std.mem.asBytes(&r.r)));
}

const fixed_ratchets: megolm.Ratchets = .{ fill(0x00), fill(0x11), fill(0x22), fill(0x33) };

/// Opens a share for `my` from `sender` with the package's key-share KDF, as
/// E2eeManager::decrypt_key_from_share does.
fn openShare(gpa: std.mem.Allocator, my: crypto.Key32, sender: crypto.Key32, blob: []const u8) ![]u8 {
    return crypto.gcmOpen(gpa, try e2ee.shareKey(my, sender), blob);
}

test "vectors 1-3: the ratchet and message key match the browser" {
    var r: megolm.Ratchet = .{ .r = fixed_ratchets, .counter = 0 };
    try testing.expectEqualStrings(kIdx0MessageKey, &hex32(r.messageKey()));
    try testing.expectEqualStrings(kIdx0AesKey, &hex32(megolm.messageAesKey(r.messageKey())));
    r.advance();
    try testing.expectEqualStrings(kIdx1MessageKey, &hex32(r.messageKey()));
}

test "vectors 4-6: C++/WASM parity and the session id" {
    var r: megolm.Ratchet = .{ .r = filled4(1), .counter = 0 };
    try testing.expectEqualStrings(kParityKey0, &hex32(r.messageKey()));
    try testing.expect(r.advanceTo(300));
    try testing.expectEqualStrings(kParityKey300, &hex32(r.messageKey()));
    try testing.expectEqualStrings(kSidG, &megolm.sessionId(filled4(1)));
}

test "vectors 7-14: far pins, key and state digest" {
    for (kFarPins) |pin| {
        var r: megolm.Ratchet = .{ .r = filled4(1), .counter = pin.start };
        try testing.expect(r.advanceTo(pin.target));
        try testing.expectEqualStrings(pin.key, &hex32(r.messageKey()));
        try testing.expectEqualStrings(pin.digest, &stateDigest(r));
        try testing.expectEqual(pin.target, r.counter);
    }
}

test "vectors 15-16: X25519 public keys of the fixed devices" {
    try testing.expectEqualStrings(kNativeDevicePublic, &hex32(try crypto.x25519Public(fill(0xa1))));
    try testing.expectEqualStrings(kWebDevicePublic, &hex32(try crypto.x25519Public(fill(0xb2))));
}

test "vectors 17-19: the browser's share of the fixed session" {
    const gpa = testing.allocator;
    const blob = unhex(kBrowserShareOfFixedSession);
    const pt = try openShare(gpa, fill(0xa1), unhex(kWebDevicePublic), &blob);
    defer gpa.free(pt);
    const d = try some(e2ee.deserializeExportedKey(pt));
    try testing.expectEqualStrings(kShareSid, d.key.session_id);
    try testing.expectEqual(@as(u32, 5), d.key.counter);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&fixed_ratchets), std.mem.asBytes(&d.key.ratchets));
    try testing.expect(d.origin == null);
}

test "vectors 20-22: the browser's send path, share then two messages" {
    const gpa = testing.allocator;
    const blob = unhex(kBrowserSendShare);
    const pt = try openShare(gpa, fill(0xa1), unhex(kWebDevicePublic), &blob);
    defer gpa.free(pt);
    const d = try some(e2ee.deserializeExportedKey(pt));
    try testing.expectEqualStrings(kBrowserSendSid, d.key.session_id);
    var in = try megolm.Inbound.init(gpa, d.key);
    defer gpa.free(in.session_id);
    const m0 = unhex(kBrowserSendMsg0);
    const p0 = try some(try in.decrypt(gpa, 0, &m0));
    defer gpa.free(p0);
    try testing.expectEqualStrings("hello native agent, from the browser send path", p0);
    const m1 = unhex(kBrowserSendMsg1);
    const p1 = try some(try in.decrypt(gpa, 1, &m1));
    defer gpa.free(p1);
    try testing.expectEqualStrings("second message", p1);
}

test "vectors 23-25: Ed25519 (RFC 8032 #1) and the wallet-derived device key" {
    const kp = try crypto.Ed25519.KeyPair.generateDeterministic(unhex(kRfcSeed));
    try testing.expectEqualStrings(kRfcPublic, &hex32(kp.public_key.toBytes()));
    const sig = try kp.sign("", null);
    try testing.expectEqualStrings(kRfcSignature, &std.fmt.bytesToHex(sig.toBytes(), .lower));
    const dev = device.walletDeviceKeypair(unhex(kRfcSeed), kp.public_key.toBytes()).?;
    try testing.expectEqualStrings(&hex32(try crypto.x25519Public(dev.secret_key)), &hex32(dev.public_key));
}

// ---------------------------------------------------------------------------
// The same shares through the E2EE manager, as the C++ tests drive
// E2eeManager (NativeImportsABrowserShare, ABrowserShareIsBoundToItsKeys,
// NativeReadsTheBrowserSendPath).

const kShareRoom = "!interop:test";
const kNativeUser = "@native:test";
const kNativeDevice = "cli_native";
const kWebUser = "@web:test";
const kWebDevice = "web_browser";

fn storeWith(store: *e2ee.KeyStore, user: []const u8, dev: []const u8, x: crypto.Key32) !void {
    try store.upload(.{ .user_id = user, .device_id = dev, .ed25519 = fill(0x07), .x25519 = x });
}

fn nativeDevice() crypto.X25519Keypair {
    return .{ .public_key = unhex(kNativeDevicePublic), .secret_key = fill(0xa1) };
}

fn webDevice() crypto.X25519Keypair {
    return .{ .public_key = unhex(kWebDevicePublic), .secret_key = fill(0xb2) };
}

fn shareFrom(blob: []const u8, sender: crypto.Key32, sid: []const u8, sender_user: []const u8) e2ee.KeyShareEvent {
    return .{ .room_id = kShareRoom, .session_id = sid, .target_user = "", .target_device = "", .encrypted_key = blob, .sender_x25519_public = sender, .sender_user = sender_user };
}

/// A message of the fixed session sealed at `index`.
fn fixedMessage(gpa: std.mem.Allocator, index: u32, pt: []const u8, rng: std.Random) ![]u8 {
    var out = try megolm.Outbound.fromExported(gpa, .{ .session_id = kShareSid, .ratchets = fixed_ratchets, .counter = index });
    defer gpa.free(out.session_id);
    return (try out.encrypt(gpa, pt, rng)).blob;
}

/// expect_holds_fixed_session: reads index 5, refuses index 4.
fn expectHoldsFixedSession(mgr: *e2ee.Manager, sender: []const u8) !void {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(3);
    const at5 = try fixedMessage(gpa, 5, "at index five", prng.random());
    defer gpa.free(at5);
    const d5 = try some(try mgr.decrypt(gpa, .{ .session_id = kShareSid, .message_index = 5, .ciphertext = at5 }, sender));
    defer gpa.free(d5.plaintext);
    try testing.expectEqualStrings("at index five", d5.plaintext);
    try testing.expect(d5.verified);
    const at4 = try fixedMessage(gpa, 4, "before the share", prng.random());
    defer gpa.free(at4);
    try testing.expect((try mgr.decrypt(gpa, .{ .session_id = kShareSid, .message_index = 4, .ciphertext = at4 }, sender)) == null);
}

test "manager: imports the browser's share, bound to its keys" {
    const gpa = testing.allocator;
    var store = e2ee.KeyStore.init(gpa);
    defer store.deinit();
    try storeWith(&store, kWebUser, kWebDevice, webDevice().public_key);
    try storeWith(&store, kNativeUser, kNativeDevice, nativeDevice().public_key);
    var mgr = e2ee.Manager.init(gpa, &store);
    defer mgr.deinit();
    try mgr.setDevice(kNativeUser, kNativeDevice, nativeDevice());

    const blob = unhex(kBrowserShareOfFixedSession);
    // One flipped bit, the wrong sender key, and a device it was not sealed for.
    var tampered = blob;
    tampered[20] ^= 0x10;
    try testing.expectEqual(e2ee.ShareStatus.undecryptable, try mgr.receiveKeyShare(shareFrom(&tampered, webDevice().public_key, kShareSid, kWebUser)));
    try testing.expectEqual(e2ee.ShareStatus.undecryptable, try mgr.receiveKeyShare(shareFrom(&blob, nativeDevice().public_key, kShareSid, kNativeUser)));
    var other = e2ee.Manager.init(gpa, &store);
    defer other.deinit();
    try other.setDevice("@other:test", "other", .{ .public_key = try crypto.x25519Public(fill(0xc3)), .secret_key = fill(0xc3) });
    try testing.expectEqual(e2ee.ShareStatus.undecryptable, try other.receiveKeyShare(shareFrom(&blob, webDevice().public_key, kShareSid, kWebUser)));

    try testing.expectEqual(e2ee.ShareStatus.imported, try mgr.receiveKeyShare(shareFrom(&blob, webDevice().public_key, kShareSid, kWebUser)));
    try expectHoldsFixedSession(&mgr, kWebUser);
}

test "manager: reads the browser's send path" {
    const gpa = testing.allocator;
    var store = e2ee.KeyStore.init(gpa);
    defer store.deinit();
    try storeWith(&store, kWebUser, kWebDevice, webDevice().public_key);
    var mgr = e2ee.Manager.init(gpa, &store);
    defer mgr.deinit();
    try mgr.setDevice(kNativeUser, kNativeDevice, nativeDevice());
    const blob = unhex(kBrowserSendShare);
    try testing.expectEqual(e2ee.ShareStatus.imported, try mgr.receiveKeyShare(shareFrom(&blob, webDevice().public_key, kBrowserSendSid, kWebUser)));
    const m0 = unhex(kBrowserSendMsg0);
    const m1 = unhex(kBrowserSendMsg1);
    const p0 = try some(try mgr.decrypt(gpa, .{ .session_id = kBrowserSendSid, .message_index = 0, .ciphertext = &m0 }, kWebUser));
    defer gpa.free(p0.plaintext);
    const p1 = try some(try mgr.decrypt(gpa, .{ .session_id = kBrowserSendSid, .message_index = 1, .ciphertext = &m1 }, kWebUser));
    defer gpa.free(p1.plaintext);
    try testing.expectEqualStrings("hello native agent, from the browser send path", p0.plaintext);
    try testing.expectEqualStrings("second message", p1.plaintext);
    try testing.expect(p0.verified and p1.verified);
    // The same message under another sender's name finds no session.
    try testing.expect((try mgr.decrypt(gpa, .{ .session_id = kBrowserSendSid, .message_index = 0, .ciphertext = &m0 }, kNativeUser)) == null);
}
