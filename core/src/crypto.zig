//! The primitives of src/aexchat/crypto.cpp, and the libsodium-compatible
//! conversions chat relies on (src/crypto/sodium_compat.cpp), on std.crypto.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Key32 = [32]u8;
pub const iv_len = 12;
pub const tag_len = 16;
pub const seal_overhead = iv_len + tag_len;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const X25519 = std.crypto.dh.X25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Fe = std.crypto.ecc.Curve25519.Fe;
pub const Ed25519 = std.crypto.sign.Ed25519;

pub const X25519Keypair = struct {
    public_key: Key32,
    secret_key: Key32,

    pub fn wipe(kp: *X25519Keypair) void {
        std.crypto.secureZero(u8, &kp.secret_key);
    }
};

/// HMAC-SHA256(key, one byte): the ratchet step.
pub fn hmacByte(key: Key32, byte: u8) Key32 {
    var out: Key32 = undefined;
    HmacSha256.create(&out, &.{byte}, &key);
    return out;
}

pub fn sha256(data: []const u8) Key32 {
    var out: Key32 = undefined;
    Sha256.hash(data, &out, .{});
    return out;
}

/// crypto::hkdf_sha256 with a 32-byte output: RFC 5869 extract, then expand.
pub fn hkdf32(ikm: []const u8, salt: []const u8, info: []const u8) Key32 {
    const prk = HkdfSha256.extract(salt, ikm);
    var out: Key32 = undefined;
    HkdfSha256.expand(&out, info, prk);
    return out;
}

/// crypto::aes256_gcm_seal: iv(12) | ciphertext | tag(16), WebCrypto's layout,
/// no associated data.
pub fn gcmSeal(gpa: Allocator, key: Key32, plaintext: []const u8, iv: [iv_len]u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, seal_overhead + plaintext.len);
    @memcpy(out[0..iv_len], &iv);
    var tag: [tag_len]u8 = undefined;
    Aes256Gcm.encrypt(out[iv_len..][0..plaintext.len], &tag, plaintext, "", iv, key);
    @memcpy(out[iv_len + plaintext.len ..], &tag);
    return out;
}

pub const OpenError = error{ Undecryptable, OutOfMemory };

/// crypto::aes256_gcm_open of an iv | ciphertext | tag blob.
pub fn gcmOpen(gpa: Allocator, key: Key32, blob: []const u8) OpenError![]u8 {
    if (blob.len < seal_overhead) return error.Undecryptable;
    const ct = blob[iv_len .. blob.len - tag_len];
    const out = try gpa.alloc(u8, ct.len);
    Aes256Gcm.decrypt(out, ct, blob[blob.len - tag_len ..][0..tag_len].*, "", blob[0..iv_len].*, key) catch {
        gpa.free(out);
        return error.Undecryptable;
    };
    return out;
}

pub const WeakKeyError = error{WeakKey};

/// crypto::x25519_shared_secret: refuses the all-zero result, as OpenSSL does.
pub fn x25519Shared(secret: Key32, public: Key32) WeakKeyError!Key32 {
    const shared = X25519.scalarmult(secret, public) catch return error.WeakKey;
    return shared;
}

pub fn x25519Public(secret: Key32) WeakKeyError!Key32 {
    return X25519.recoverPublicKey(secret) catch error.WeakKey;
}

pub const NotConvertibleError = error{NotConvertible};

/// sodium_compat's pk_to_curve25519: u = (1 + y) / (1 - y) mod p with no curve
/// check, where std's version refuses off-curve and small-order keys.
pub fn edPublicToX25519(ed_public: Key32) NotConvertibleError!Key32 {
    const y = Fe.fromBytes(ed_public); // bit 255 is ignored, as the C++ clears it
    const den = Fe.one.sub(y);
    if (den.isZero()) return error.NotConvertible;
    return Fe.one.add(y).mul(den.invert()).toBytes();
}

/// crypto_sign_ed25519_sk_to_curve25519: SHA-512 of the 32-byte seed, clamped.
pub fn edSeedToX25519Secret(seed: [32]u8) Key32 {
    var h: [64]u8 = undefined;
    Sha512.hash(&seed, &h, .{});
    h[0] &= 248;
    h[31] &= 127;
    h[31] |= 64;
    const sk = h[0..32].*;
    std.crypto.secureZero(u8, &h);
    return sk;
}

/// crypto::to_hex: lowercase.
pub fn toHex(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const digits = "0123456789abcdef";
    const out = try gpa.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0xf];
    }
    return out;
}

pub fn toHex32(bytes: Key32) [64]u8 {
    return std.fmt.bytesToHex(bytes, .lower);
}

fn nibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// crypto::from_hex: either case, even length; null otherwise.
pub fn fromHex(gpa: Allocator, s: []const u8) Allocator.Error!?[]u8 {
    if (s.len % 2 != 0) return null;
    const out = try gpa.alloc(u8, s.len / 2);
    for (out, 0..) |*b, i| {
        const hi = nibble(s[2 * i]) orelse {
            gpa.free(out);
            return null;
        };
        const lo = nibble(s[2 * i + 1]) orelse {
            gpa.free(out);
            return null;
        };
        b.* = hi << 4 | lo;
    }
    return out;
}

/// from_hex of exactly 32 bytes, or null.
pub fn fromHex32(s: []const u8) ?Key32 {
    if (s.len != 64) return null;
    var out: Key32 = undefined;
    for (&out, 0..) |*b, i| {
        const hi = nibble(s[2 * i]) orelse return null;
        const lo = nibble(s[2 * i + 1]) orelse return null;
        b.* = hi << 4 | lo;
    }
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn unhex32(comptime s: []const u8) Key32 {
    return fromHex32(s).?;
}

test "x25519 refuses every low-order public key (the all-zero result)" {
    const sk = [_]u8{0xa1} ** 32;
    // The Curve25519 points of small order, and non-canonical copies of them.
    const low_order = [_][]const u8{
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    };
    for (low_order) |h| {
        try testing.expectError(error.WeakKey, x25519Shared(sk, fromHex32(h).?));
    }
    // A real key agrees in both directions.
    const other = [_]u8{0xb2} ** 32;
    const a = try x25519Shared(sk, try x25519Public(other));
    const b = try x25519Shared(other, try x25519Public(sk));
    try testing.expectEqualSlices(u8, &a, &b);
}

test "ed25519 -> x25519: the map equals std's on real keys and X25519 of the secret" {
    var prng = std.Random.DefaultPrng.init(42);
    for (0..64) |_| {
        var seed: [32]u8 = undefined;
        prng.random().bytes(&seed);
        const kp = try Ed25519.KeyPair.generateDeterministic(seed);
        const mine = try edPublicToX25519(kp.public_key.toBytes());
        const std_map = try X25519.publicKeyFromEd25519(kp.public_key);
        try testing.expectEqualSlices(u8, &std_map, &mine);
        const via_secret = try x25519Public(edSeedToX25519Secret(seed));
        try testing.expectEqualSlices(u8, &via_secret, &mine);
    }
}

test "ed25519 -> x25519: plain arithmetic where std refuses, as the C++ does" {
    // y = 2 is not on the curve: std refuses, the C++ (and this) give 3/(-1).
    var y2 = [_]u8{0} ** 32;
    y2[0] = 2;
    try testing.expectError(error.InvalidEncoding, X25519.publicKeyFromEd25519(.{ .bytes = y2 }));
    const u = try edPublicToX25519(y2);
    const minus3 = unhex32("eaffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f");
    try testing.expectEqualSlices(u8, &minus3, &u);
    // y = -1 (order 2) maps to u = 0; std calls it the identity.
    const ym1 = unhex32("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f");
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &(try edPublicToX25519(ym1)));
    // y = 1, and its non-canonical copy p + 1, have no image.
    var y1 = [_]u8{0} ** 32;
    y1[0] = 1;
    try testing.expectError(error.NotConvertible, edPublicToX25519(y1));
    try testing.expectError(error.NotConvertible, edPublicToX25519(unhex32("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")));
    // The sign bit does not change u.
    var signed = y2;
    signed[31] |= 0x80;
    try testing.expectEqualSlices(u8, &u, &(try edPublicToX25519(signed)));
}

test "hex: either case in, lowercase out" {
    const gpa = testing.allocator;
    const b = (try fromHex(gpa, "00fFaB")).?;
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xff, 0xab }, b);
    const h = try toHex(gpa, b);
    defer gpa.free(h);
    try testing.expectEqualStrings("00ffab", h);
    try testing.expect((try fromHex(gpa, "abc")) == null);
    try testing.expect((try fromHex(gpa, "zz")) == null);
}

test "gcm: iv | ct | tag, and any flipped bit is refused" {
    const gpa = testing.allocator;
    const key = [_]u8{7} ** 32;
    const blob = try gcmSeal(gpa, key, "abc", [_]u8{0x5a} ** 12);
    defer gpa.free(blob);
    try testing.expectEqual(@as(usize, 12 + 3 + 16), blob.len);
    try testing.expectEqualSlices(u8, &([_]u8{0x5a} ** 12), blob[0..12]);
    const pt = try gcmOpen(gpa, key, blob);
    defer gpa.free(pt);
    try testing.expectEqualStrings("abc", pt);
    for (0..blob.len) |i| {
        blob[i] ^= 1;
        try testing.expectError(error.Undecryptable, gcmOpen(gpa, key, blob));
        blob[i] ^= 1;
    }
    try testing.expectError(error.Undecryptable, gcmOpen(gpa, key, blob[0..27]));
}
