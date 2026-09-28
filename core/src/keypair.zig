//! Wallet keypair files: a JSON array of 64 integers, seed then public key
//! (tx_build.h load_keypair). Stricter than the C++: the public half must be
//! the seed's, or it would sign as one key and log in as another.
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = @import("crypto.zig");
const json = @import("json.zig");

pub const Keypair = struct {
    seed: [32]u8,
    public_key: [32]u8,

    pub fn ed25519(kp: Keypair) crypto.Ed25519.KeyPair {
        // parse() already proved the seed derives this public key.
        return crypto.Ed25519.KeyPair.generateDeterministic(kp.seed) catch unreachable;
    }

    pub fn sign(kp: Keypair, message: []const u8) [64]u8 {
        var pair = kp.ed25519();
        defer std.crypto.secureZero(u8, &pair.secret_key.bytes);
        const sig = pair.sign(message, null) catch unreachable;
        return sig.toBytes();
    }

    pub fn wipe(kp: *Keypair) void {
        std.crypto.secureZero(u8, &kp.seed);
    }
};

/// A fresh random wallet keypair (keygen). generateDeterministic rejects only
/// the astronomically unlikely all-zero-derived identity, so a retry never loops.
pub fn generate(rng: std.Random) Keypair {
    while (true) {
        var seed: [32]u8 = undefined;
        rng.bytes(&seed);
        const pair = crypto.Ed25519.KeyPair.generateDeterministic(seed) catch continue;
        return .{ .seed = seed, .public_key = pair.public_key.toBytes() };
    }
}

pub const ParseError = error{ InvalidKeypair, KeypairMismatch, OutOfMemory };

pub fn parse(gpa: Allocator, text: []const u8) ParseError!Keypair {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = json.parse(arena.allocator(), text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return error.InvalidKeypair,
    };
    const items = v.asArray() orelse return error.InvalidKeypair;
    if (items.len != 64) return error.InvalidKeypair;
    var bytes: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    for (items, 0..) |item, i| {
        const n = item.asInt() orelse return error.InvalidKeypair;
        if (n < 0 or n > 255) return error.InvalidKeypair;
        bytes[i] = @intCast(n);
    }
    const kp: Keypair = .{ .seed = bytes[0..32].*, .public_key = bytes[32..64].* };
    var derived = crypto.Ed25519.KeyPair.generateDeterministic(kp.seed) catch return error.InvalidKeypair;
    defer std.crypto.secureZero(u8, &derived.secret_key.bytes);
    if (!std.mem.eql(u8, &derived.public_key.toBytes(), &kp.public_key)) return error.KeypairMismatch;
    return kp;
}

/// The file text for `kp`: "[b0,b1,...,b63]", as keygen writes it.
pub fn format(gpa: Allocator, kp: Keypair) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.append(gpa, '[');
    for (kp.seed ++ kp.public_key, 0..) |b, i| {
        if (i > 0) try list.append(gpa, ',');
        try list.print(gpa, "{d}", .{b});
    }
    try list.append(gpa, ']');
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "keypair: round trip, and a public half that is not the seed's is refused" {
    const gpa = testing.allocator;
    const seed = [_]u8{9} ** 32;
    const pair = try crypto.Ed25519.KeyPair.generateDeterministic(seed);
    const kp: Keypair = .{ .seed = seed, .public_key = pair.public_key.toBytes() };
    const text = try format(gpa, kp);
    defer gpa.free(text);
    const back = try parse(gpa, text);
    try testing.expectEqualSlices(u8, &kp.public_key, &back.public_key);
    const spaced = try std.mem.replaceOwned(u8, gpa, text, ",", " ,\n ");
    defer gpa.free(spaced);
    _ = try parse(gpa, spaced);

    var bad = kp;
    bad.public_key[5] ^= 1;
    const bad_text = try format(gpa, bad);
    defer gpa.free(bad_text);
    try testing.expectError(error.KeypairMismatch, parse(gpa, bad_text));
    try testing.expectError(error.InvalidKeypair, parse(gpa, "[1,2,3]"));
    try testing.expectError(error.InvalidKeypair, parse(gpa, text[0 .. text.len - 1]));
    const big = try std.mem.replaceOwned(u8, gpa, text, "[9,", "[265,");
    defer gpa.free(big);
    try testing.expectError(error.InvalidKeypair, parse(gpa, big));
}
