//! Wallet-bound device keys (include/tools/cli/chat_device_binding.h): the
//! X25519 key is the wallet's Ed25519 key in Montgomery form, so anyone can check it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = @import("crypto.zig");
const base58 = @import("base58.zig");

/// chat_pay.h wallet_of_sender: the wallet in "@<wallet>:<server>" when it
/// decodes (aexchat's decoder) to 32 bytes; a slice of `sender`.
pub fn walletOfSender(gpa: Allocator, sender: []const u8) Allocator.Error!?[]const u8 {
    if (sender.len < 3 or sender[0] != '@') return null;
    const colon = std.mem.indexOfScalar(u8, sender, ':') orelse return null;
    if (colon < 2) return null;
    const w = sender[1..colon];
    if (try base58.aexchatDecodedLen(gpa, w) != 32) return null;
    return w;
}

/// wallet_device_key: the device key the wallet in `user_id` has.
pub fn walletDeviceKey(gpa: Allocator, user_id: []const u8) Allocator.Error!?crypto.Key32 {
    const w = (try walletOfSender(gpa, user_id)) orelse return null;
    const ed = try base58.decodeAexchat(gpa, w);
    defer gpa.free(ed);
    return crypto.edPublicToX25519(ed[0..32].*) catch null;
}

/// wallet_device_keypair: this wallet's own device keypair, from its seed and
/// Ed25519 public key.
pub fn walletDeviceKeypair(seed: [32]u8, ed_public: crypto.Key32) ?crypto.X25519Keypair {
    const public_key = crypto.edPublicToX25519(ed_public) catch return null;
    return .{ .public_key = public_key, .secret_key = crypto.edSeedToX25519Secret(seed) };
}

/// device_bound: `x25519` is the device key `user_id`'s wallet has.
pub fn deviceBound(gpa: Allocator, user_id: []const u8, x25519: crypto.Key32) Allocator.Error!bool {
    const want = (try walletDeviceKey(gpa, user_id)) orelse return false;
    return std.mem.eql(u8, &want, &x25519);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

// tests/test_mcp_chat_protocol.cpp ("who a payment may go to"), verbatim.
test "wallet_of_sender (C++ fixtures)" {
    const gpa = testing.allocator;
    const w = "9s6dbCfbWuDxyGjMGnYiMtyL189St4cmJp3vkicYNm45";
    try testing.expectEqualStrings(w, (try walletOfSender(gpa, "@" ++ w ++ ":slonana.com")).?);
    try testing.expect((try walletOfSender(gpa, "@alice:slonana.com")) == null);
    try testing.expect((try walletOfSender(gpa, w ++ ":slonana.com")) == null);
    try testing.expect((try walletOfSender(gpa, "@" ++ w)) == null);
}

test "a device is bound only to its own wallet's key" {
    const gpa = testing.allocator;
    const seed = [_]u8{0x42} ** 32;
    const kp = try crypto.Ed25519.KeyPair.generateDeterministic(seed);
    const dev = walletDeviceKeypair(seed, kp.public_key.toBytes()).?;
    try testing.expectEqualSlices(u8, &dev.public_key, &(try crypto.x25519Public(dev.secret_key)));
    const wallet = try base58.encode(gpa, &kp.public_key.toBytes());
    defer gpa.free(wallet);
    const user = try std.mem.concat(gpa, u8, &.{ "@", wallet, ":slonana.com" });
    defer gpa.free(user);
    try testing.expect(try deviceBound(gpa, user, dev.public_key));
    var other = dev.public_key;
    other[0] ^= 1;
    try testing.expect(!(try deviceBound(gpa, user, other)));
    try testing.expect(!(try deviceBound(gpa, "@anon-1234:slonana.com", dev.public_key)));
}
