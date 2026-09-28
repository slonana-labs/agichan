//! The four-wheel ratchet and the outbound and inbound sessions of
//! src/aexchat/megolm.cpp and include/aexchat/megolm.h.
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = @import("crypto.zig");
const Key32 = crypto.Key32;

pub const num_ratchets = 4;
pub const Ratchets = [num_ratchets]Key32;

pub const Ratchet = struct {
    r: Ratchets,
    counter: u32,

    /// Bits of the counter that must be zero for wheel i to turn: R0 every
    /// 2^24 messages, R1 every 2^16, R2 every 2^8, R3 every message.
    fn wheelMask(i: usize) u32 {
        return switch (i) {
            0 => 0xFFFFFF,
            1 => 0xFFFF,
            2 => 0xFF,
            else => 0,
        };
    }

    /// R[i] = HMAC(R[i], 0x01), then R[j] = HMAC(R[i], 0x02 + j - i - 1) below.
    fn advanceWheel(self: *Ratchet, i: usize) void {
        self.r[i] = crypto.hmacByte(self.r[i], 0x01);
        var j = i + 1;
        while (j < num_ratchets) : (j += 1) {
            self.r[j] = crypto.hmacByte(self.r[i], @intCast(0x02 + j - i - 1));
        }
    }

    pub fn advance(self: *Ratchet) void {
        for (0..num_ratchets) |i| {
            if ((self.counter & wheelMask(i)) == 0) {
                self.advanceWheel(i);
                break;
            }
        }
        self.counter +%= 1;
    }

    /// Repeated advance()'s state in at most ~1027 HMACs; false (and no
    /// change) when target is behind.
    pub fn advanceTo(self: *Ratchet, target: u32) bool {
        if (target < self.counter) return false;
        var cur: u64 = self.counter;
        for (0..num_ratchets) |i| {
            const period: u64 = @as(u64, wheelMask(i)) + 1;
            const first = (cur + period - 1) / period * period;
            if (first >= target) continue;
            const last = (@as(u64, target) - 1) / period * period;
            var n = (last - first) / period;
            while (n > 0) : (n -= 1) self.r[i] = crypto.hmacByte(self.r[i], 0x01);
            self.advanceWheel(i);
            cur = last + 1;
        }
        self.counter = target;
        return true;
    }

    /// Message key = HMAC(R3, 0x01).
    pub fn messageKey(self: Ratchet) Key32 {
        return crypto.hmacByte(self.r[num_ratchets - 1], 0x01);
    }

    pub fn wipe(self: *Ratchet) void {
        for (&self.r) |*k| std.crypto.secureZero(u8, k);
    }
};

/// megolm_session_id: hex(SHA-256(R0 || R1 || R2 || R3)).
pub fn sessionId(r: Ratchets) [64]u8 {
    var data: [32 * num_ratchets]u8 = undefined;
    for (r, 0..) |k, i| @memcpy(data[32 * i ..][0..32], &k);
    const h = crypto.sha256(&data);
    std.crypto.secureZero(u8, &data);
    return crypto.toHex32(h);
}

/// The AES-256-GCM key of a message: HKDF(message key, "megolm_salt", "megolm_msg").
pub fn messageAesKey(message_key: Key32) Key32 {
    return crypto.hkdf32(&message_key, "megolm_salt", "megolm_msg");
}

pub const ExportedKey = struct {
    session_id: []const u8,
    ratchets: Ratchets,
    counter: u32,
};

/// megolm_key_reaches: ratcheting `from` forward lands exactly on `to`
/// (session ids are not compared).
pub fn keyReaches(from: ExportedKey, to: ExportedKey) bool {
    var r: Ratchet = .{ .r = from.ratchets, .counter = from.counter };
    defer r.wipe();
    if (!r.advanceTo(to.counter)) return false;
    const got: [32 * num_ratchets]u8 = @bitCast(r.r);
    const want: [32 * num_ratchets]u8 = @bitCast(to.ratchets);
    return std.crypto.timing_safe.eql([32 * num_ratchets]u8, got, want);
}

pub const Sealed = struct {
    index: u32,
    blob: []u8,
};

/// MegolmOutboundSession: one per room, advanced once per message sent.
pub const Outbound = struct {
    session_id: []const u8,
    ratchet: Ratchet,

    /// A fresh session: four random keys, counter 0, id = their hash.
    pub fn initRandom(gpa: Allocator, rng: std.Random) Allocator.Error!Outbound {
        var r: Ratchets = undefined;
        for (&r) |*k| rng.bytes(k);
        const sid = sessionId(r);
        return .{ .session_id = try gpa.dupe(u8, &sid), .ratchet = .{ .r = r, .counter = 0 } };
    }

    /// A saved session, id kept as saved.
    pub fn fromExported(gpa: Allocator, key: ExportedKey) Allocator.Error!Outbound {
        return .{ .session_id = try gpa.dupe(u8, key.session_id), .ratchet = .{ .r = key.ratchets, .counter = key.counter } };
    }

    /// Seals `plaintext` at the current index and advances: iv | ct | tag
    /// under HKDF(message key).
    pub fn encrypt(self: *Outbound, gpa: Allocator, plaintext: []const u8, rng: std.Random) Allocator.Error!Sealed {
        const idx = self.ratchet.counter;
        var mk = self.ratchet.messageKey();
        defer std.crypto.secureZero(u8, &mk);
        var aes = messageAesKey(mk);
        defer std.crypto.secureZero(u8, &aes);
        var iv: [crypto.iv_len]u8 = undefined;
        rng.bytes(&iv);
        const blob = try crypto.gcmSeal(gpa, aes, plaintext, iv);
        self.ratchet.advance();
        return .{ .index = idx, .blob = blob };
    }

    /// export_session_key: the current state, which is what a share carries.
    pub fn exportKey(self: Outbound) ExportedKey {
        return .{ .session_id = self.session_id, .ratchets = self.ratchet.r, .counter = self.ratchet.counter };
    }
};

/// MegolmInboundSession: decrypts any index at or after the one it starts at.
pub const Inbound = struct {
    session_id: []const u8,
    first_known: u32,
    initial: Ratchets,
    ratchet: Ratchet,

    pub fn init(gpa: Allocator, key: ExportedKey) Allocator.Error!Inbound {
        return .{
            .session_id = try gpa.dupe(u8, key.session_id),
            .first_known = key.counter,
            .initial = key.ratchets,
            .ratchet = .{ .r = key.ratchets, .counter = key.counter },
        };
    }

    /// Null when the index is before this session's start or the blob does
    /// not open. Past the target the ratchet restarts from the initial copy.
    pub fn decrypt(self: *Inbound, gpa: Allocator, index: u32, blob: []const u8) Allocator.Error!?[]u8 {
        if (index < self.first_known) return null;
        if (index < self.ratchet.counter) self.ratchet = .{ .r = self.initial, .counter = self.first_known };
        if (!self.ratchet.advanceTo(index)) return null;
        var mk = self.ratchet.messageKey();
        defer std.crypto.secureZero(u8, &mk);
        var aes = messageAesKey(mk);
        defer std.crypto.secureZero(u8, &aes);
        const result: ?[]u8 = crypto.gcmOpen(gpa, aes, blob) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Undecryptable => null,
        };
        // At the last index advance() would wrap the counter to 0.
        if (index != std.math.maxInt(u32)) self.ratchet.advance();
        return result;
    }

    /// export_for_persistence: the state it started from, not where it is.
    pub fn exportKey(self: Inbound) ExportedKey {
        return .{ .session_id = self.session_id, .ratchets = self.initial, .counter = self.first_known };
    }

    pub fn wipe(self: *Inbound) void {
        for (&self.initial) |*k| std.crypto.secureZero(u8, k);
        self.ratchet.wipe();
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn filled4(first: u8) Ratchets {
    var r: Ratchets = undefined;
    for (&r, 0..) |*k, i| k.* = [_]u8{first + @as(u8, @intCast(i))} ** 32;
    return r;
}

fn digest(r: Ratchet) [64]u8 {
    return crypto.toHex32(crypto.sha256(std.mem.asBytes(&r.r)));
}

// examples/wasm/megolm_wasm.c's walks in tests/test_aexchat_megolm_browser_compat.cpp
// (AdvanceToEqualsSteppingAcrossEveryWheel): the jump equals stepping.
test "megolm: advanceTo equals stepping across every wheel" {
    const walks = [_][2]u32{
        .{ 0, 0 },                   .{ 0, 1 },                   .{ 5, 300 },
        .{ 250, 70000 },             .{ 0xFFFF00, 0x1000100 },    .{ 0xFFFEFF, 0x1010001 },
        .{ 0xFFFFFF00, 0xFFFFFFFF }, .{ 0xFEFFFF80, 0xFF000080 },
    };
    for (walks) |w| {
        var jump: Ratchet = .{ .r = filled4(0x21), .counter = w[0] };
        var step = jump;
        try testing.expect(jump.advanceTo(w[1]));
        while (step.counter < w[1]) step.advance();
        try testing.expectEqualStrings(&digest(step), &digest(jump));
        try testing.expectEqual(step.counter, jump.counter);
    }
    var r: Ratchet = .{ .r = filled4(0x21), .counter = 10 };
    try testing.expect(!r.advanceTo(9));
    try testing.expectEqual(@as(u32, 10), r.counter);
}

test "megolm: an inbound session reads any index from its start, in any order" {
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    const gpa = testing.allocator;
    var out = try Outbound.fromExported(gpa, .{ .session_id = "s", .ratchets = filled4(1), .counter = 250 });
    defer gpa.free(out.session_id);
    var in = try Inbound.init(gpa, out.exportKey());
    defer gpa.free(in.session_id);
    var blobs: [20]Sealed = undefined;
    for (&blobs, 0..) |*b, i| {
        var buf: [8]u8 = undefined;
        b.* = try out.encrypt(gpa, try std.fmt.bufPrint(&buf, "m{d}", .{i}), rng);
    }
    defer for (blobs) |b| gpa.free(b.blob);
    for ([_]usize{ 19, 0, 7, 7, 6, 12 }) |i| {
        const pt = (try in.decrypt(gpa, blobs[i].index, blobs[i].blob)).?;
        defer gpa.free(pt);
        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "m{d}", .{i}), pt);
    }
    try testing.expect((try in.decrypt(gpa, 249, blobs[0].blob)) == null);
    try testing.expect((try in.decrypt(gpa, blobs[1].index, blobs[0].blob)) == null);
}
