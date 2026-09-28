//! Base58 as common::encode_base58 / decode_base58 (conversions.cpp) and
//! aexchat::decode_base58 (aexchat/types.h) do it.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

pub fn encode(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    if (data.len == 0) return gpa.alloc(u8, 0);
    const digits = try gpa.alloc(u8, data.len * 138 / 100 + 1);
    defer gpa.free(digits);
    @memset(digits, 0);
    var digits_len: usize = 1;
    for (data) |byte| {
        var carry: u32 = byte;
        for (digits[0..digits_len]) |*d| {
            carry += @as(u32, d.*) << 8;
            d.* = @intCast(carry % 58);
            carry /= 58;
        }
        while (carry > 0) {
            digits[digits_len] = @intCast(carry % 58);
            digits_len += 1;
            carry /= 58;
        }
    }
    var zeros: usize = 0;
    while (zeros < data.len and data[zeros] == 0) zeros += 1;
    var top: usize = digits_len;
    while (top > 0 and digits[top - 1] == 0) top -= 1;
    const out = try gpa.alloc(u8, zeros + top);
    @memset(out[0..zeros], '1');
    for (0..top) |k| out[zeros + k] = alphabet[digits[top - 1 - k]];
    return out;
}

fn digitOf(c: u8, nul_is_58: bool) ?u8 {
    if (c == 0 and nul_is_58) return 58;
    const at = std.mem.indexOfScalar(u8, alphabet, c) orelse return null;
    return @intCast(at);
}

// Bounds the O(N^2) decode against a hostile relay. No key or signature this
// client decodes is long: 32 bytes is <=44 base58 chars, 64 bytes <=88. Every
// caller rejects a wrong decoded length (device.zig, board.zig check !=32/!=64),
// so returning empty for an over-long string is result-identical to the full
// decode -- the C++ decoder fully decodes then rejects the same length -- while
// removing the freeze (a ~200KB relay-supplied member id hangs the O(N^2) loop
// for ~113s otherwise; a 44-char value is unaffected).
pub const max_decode_len = 256;

fn decodeWith(gpa: Allocator, s: []const u8, nul_is_58: bool) Allocator.Error![]u8 {
    if (s.len > max_decode_len) return gpa.alloc(u8, 0);
    var zeros: usize = 0;
    while (zeros < s.len and s[zeros] == '1') zeros += 1;
    // Little-endian base 256 accumulator.
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    for (s) |c| {
        const digit = digitOf(c, nul_is_58) orelse return gpa.alloc(u8, 0);
        var carry: u32 = digit;
        for (acc.items) |*b| {
            carry += @as(u32, b.*) * 58;
            b.* = @truncate(carry);
            carry >>= 8;
        }
        while (carry > 0) {
            try acc.append(gpa, @truncate(carry));
            carry >>= 8;
        }
    }
    const out = try gpa.alloc(u8, zeros + acc.items.len);
    @memset(out[0..zeros], 0);
    for (acc.items, 0..) |b, k| out[out.len - 1 - k] = b;
    return out;
}

/// common::decode_base58: the decoded bytes, or empty for any character
/// outside the alphabet.
pub fn decode(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return decodeWith(gpa, s, false);
}

/// aexchat::decode_base58 (board, device binding). Its strchr finds NUL at the
/// alphabet's end, so NUL is digit 58; kept so both boards count the same lines.
pub fn decodeAexchat(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return decodeWith(gpa, s, true);
}

/// The length aexchat::decode_base58 would return, without keeping bytes.
pub fn aexchatDecodedLen(gpa: Allocator, s: []const u8) Allocator.Error!usize {
    const d = try decodeAexchat(gpa, s);
    defer gpa.free(d);
    return d.len;
}

/// A 32-byte key from base58 (strict decoder), or null.
pub fn decode32(s: []const u8) ?[32]u8 {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    if (s.len > 64) return null;
    const d = decode(fba.allocator(), s) catch return null;
    if (d.len != 32) return null;
    return d[0..32].*;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectEncodes(hex: []const u8, want: []const u8) !void {
    var bytes: [64]u8 = undefined;
    const b = try std.fmt.hexToBytes(&bytes, hex);
    const got = try encode(testing.allocator, b);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    const back = try decode(testing.allocator, want);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, b, back);
}

// Program ids against their canonical base58, from include/common/program_ids.h
// and tests/test_common.cpp (test_program_ids_match_canonical_base58), whose
// strings came from an independent bc encoder.
test "base58: program ids (C++ fixtures)" {
    try expectEncodes("06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9", "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
    try expectEncodes("06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc", "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
    try expectEncodes("8c97258f4e2489f1bb3d1029148e0d830b5a1399daff1084048e7bd8dbe9f859", "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
    try expectEncodes("069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001", "So11111111111111111111111111111111111111112");
    try expectEncodes("0000000000000000000000000000000000000000000000000000000000000000", "11111111111111111111111111111111");
    try expectEncodes("02a8f6914e88a16e395ae128948ffa695693376818dd47435221f3c600000000", "BPFLoader2111111111111111111111111111111111");
    try expectEncodes("0761481d357474bb7c4d7624ebd3bdb3d8355e73d11043fc0da3538000000000", "Vote111111111111111111111111111111111111111");
    try expectEncodes("06a1d8179137542a983437bdfe2a7ab2557f535c8a78722b68a49dc000000000", "Stake11111111111111111111111111111111111111");
    try expectEncodes("037d46d67c93fbbe12f9428f838d40ff0570744927f48a64fcca704480000000", "Ed25519SigVerify111111111111111111111111111");
}

test "base58: round trips, leading zeros and rejects" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var buf: [80]u8 = undefined;
    for (0..300) |n| {
        const len = n % buf.len;
        r.bytes(buf[0..len]);
        const zeros = r.uintLessThan(usize, 4);
        for (0..@min(zeros, len)) |k| buf[k] = 0;
        const s = try encode(testing.allocator, buf[0..len]);
        defer testing.allocator.free(s);
        const d = try decode(testing.allocator, s);
        defer testing.allocator.free(d);
        try testing.expectEqualSlices(u8, buf[0..len], d);
        const d2 = try decodeAexchat(testing.allocator, s);
        defer testing.allocator.free(d2);
        try testing.expectEqualSlices(u8, buf[0..len], d2);
    }
    const bad = try decode(testing.allocator, "abc0");
    defer testing.allocator.free(bad);
    try testing.expectEqual(@as(usize, 0), bad.len);
    const e = try decode(testing.allocator, "");
    defer testing.allocator.free(e);
    try testing.expectEqual(@as(usize, 0), e.len);
    try testing.expect(decode32("11111111111111111111111111111111") != null);
    try testing.expect(decode32("1111111111111111111111111111111") == null);
}

test "base58: NUL is digit 58 in the aexchat decoder only" {
    const strict = try decode(testing.allocator, "2\x00");
    defer testing.allocator.free(strict);
    try testing.expectEqual(@as(usize, 0), strict.len);
    // "2" is digit 1, NUL digit 58: 1*58 + 58 = 116.
    const quirk = try decodeAexchat(testing.allocator, "2\x00");
    defer testing.allocator.free(quirk);
    try testing.expectEqualSlices(u8, &.{116}, quirk);
}

test "base58: over-length input is refused (relay DoS bound)" {
    // A string past the cap returns empty (the invalid sentinel) instead of
    // running the O(N^2) decode. Without the cap this decodes to a non-empty
    // value, so this test goes red -- it pins the bound, not just documents it.
    const long = "z" ** (max_decode_len + 1);
    const d = try decode(testing.allocator, long);
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
    const da = try decodeAexchat(testing.allocator, long);
    defer testing.allocator.free(da);
    try testing.expectEqual(@as(usize, 0), da.len);
    // A value at the cap still decodes (the bound never rejects a real key: a
    // 32-byte value is <=44 chars, well under 256).
    const ok = try decode(testing.allocator, "z" ** max_decode_len);
    defer testing.allocator.free(ok);
    try testing.expect(ok.len != 0);
    // The canonical 44-char, 32-byte program id is unaffected.
    const key = try decode(testing.allocator, "So11111111111111111111111111111111111111112");
    defer testing.allocator.free(key);
    try testing.expectEqual(@as(usize, 32), key.len);
}
