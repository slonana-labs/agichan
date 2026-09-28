//! A System-Program transfer, for `chat pay`'s plain (non-escrow) settlement:
//! the legacy transaction wire format (one signer, three accounts), signed with
//! Ed25519 and sent base58, plus the JSON-RPC calls chat_pay confirms with.
//! The escrow path (aea_tasks AcceptWork) is NOT ported here; that stays on the
//! MCP/slonana client. The encoding is pinned by a known-answer test.
const std = @import("std");
const Allocator = std.mem.Allocator;
const base58 = @import("base58.zig");
const keypair = @import("keypair.zig");
const rpc = @import("rpc.zig");
const json = @import("json.zig");
const crypto = @import("crypto.zig");

/// shortvec (compact-u16): 7 bits per byte, high bit = "more".
pub fn writeShortVec(out: *std.ArrayList(u8), a: Allocator, n: u16) Allocator.Error!void {
    var v: u16 = n;
    while (true) {
        var b: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) b |= 0x80;
        try out.append(a, b);
        if (v == 0) break;
    }
}

/// The legacy transfer message: from(signer,writable), to(writable),
/// system(readonly). System Transfer data = u32 LE 2, u64 LE lamports.
pub fn transferMessage(a: Allocator, from: [32]u8, to: [32]u8, blockhash: [32]u8, lamports: u64) Allocator.Error![]u8 {
    var m: std.ArrayList(u8) = .empty;
    errdefer m.deinit(a);
    try m.appendSlice(a, &.{ 1, 0, 1 }); // header: 1 sig, 0 ro-signed, 1 ro-unsigned (system)
    try writeShortVec(&m, a, 3);
    try m.appendSlice(a, &from);
    try m.appendSlice(a, &to);
    try m.appendSlice(a, &([_]u8{0} ** 32)); // System Program id (all zero)
    try m.appendSlice(a, &blockhash);
    try writeShortVec(&m, a, 1); // one instruction
    try m.append(a, 2); // program id index = the system program
    try writeShortVec(&m, a, 2); // two account indices
    try m.appendSlice(a, &.{ 0, 1 }); // from, to
    try writeShortVec(&m, a, 12); // data length
    try m.appendSlice(a, &.{ 2, 0, 0, 0 }); // Transfer discriminant
    var le: [8]u8 = undefined;
    std.mem.writeInt(u64, &le, lamports, .little);
    try m.appendSlice(a, &le);
    return m.toOwnedSlice(a);
}

/// The signed transaction, base58, for sendTransaction with encoding "base58".
pub fn signedTransferB58(a: Allocator, kp: keypair.Keypair, to: [32]u8, blockhash: [32]u8, lamports: u64) Allocator.Error![]u8 {
    const msg = try transferMessage(a, kp.public_key, to, blockhash, lamports);
    defer a.free(msg);
    const sig = kp.sign(msg);
    var tx: std.ArrayList(u8) = .empty;
    defer tx.deinit(a);
    try writeShortVec(&tx, a, 1);
    try tx.appendSlice(a, &sig);
    try tx.appendSlice(a, msg);
    return base58.encode(a, tx.items);
}

// ---- JSON-RPC (plain, not aexchatRequest) ---------------------------------

const RpcReply = union(enum) { result: json.Value, err: []const u8 };

fn call(a: Allocator, t: rpc.Transport, request_json: []const u8) Allocator.Error!RpcReply {
    const posted = try t.post(a, request_json);
    const raw = switch (posted) {
        .failed => |why| return .{ .err = try std.fmt.allocPrint(a, "Failed to connect to {s} ({s})", .{ t.url, why }) },
        .reply => |r| r,
    };
    if (raw.len == 0) return .{ .err = try std.fmt.allocPrint(a, "empty reply from {s}", .{t.url}) };
    const doc = json.parse(a, raw) catch return .{ .err = try std.fmt.allocPrint(a, "unexpected reply: {s}", .{raw}) };
    if (doc.get("error")) |e| {
        const msg = if (e.get("message")) |m| (m.asString() orelse "") else "";
        return .{ .err = try std.fmt.allocPrint(a, "{s}", .{if (msg.len == 0) raw else msg}) };
    }
    const result = doc.get("result") orelse return .{ .err = try std.fmt.allocPrint(a, "no result: {s}", .{raw}) };
    return .{ .result = result };
}

pub const BlockhashResult = union(enum) { ok: [32]u8, err: []const u8 };

pub fn getLatestBlockhash(a: Allocator, t: rpc.Transport) Allocator.Error!BlockhashResult {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getLatestBlockhash\",\"params\":[{\"commitment\":\"finalized\"}]}";
    const r = switch (try call(a, t, req)) {
        .result => |v| v,
        .err => |e| return .{ .err = e },
    };
    const value = r.get("value") orelse r;
    const bh = json.getString(value, "blockhash") orelse return .{ .err = "getLatestBlockhash: no blockhash in reply" };
    const bytes = base58.decode32(bh) orelse return .{ .err = "getLatestBlockhash: blockhash is not 32 bytes" };
    return .{ .ok = bytes };
}

pub const SendResult = union(enum) { ok: []const u8, err: []const u8 };

/// sendTransaction with encoding base58 (this node reads base64 by default).
pub fn sendTransaction(a: Allocator, t: rpc.Transport, tx_b58: []const u8) Allocator.Error!SendResult {
    // tx_b58 is base58 (alnum only), safe to embed in a JSON string directly.
    const req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sendTransaction\",\"params\":[\"{s}\",{{\"encoding\":\"base58\"}}]}}", .{tx_b58});
    const r = switch (try call(a, t, req)) {
        .result => |v| v,
        .err => |e| return .{ .err = e },
    };
    const sig = r.asString() orelse return .{ .err = "sendTransaction: no signature in reply" };
    return .{ .ok = sig };
}

/// getSignatureStatuses for one signature: confirmed (err:null), failed, or
/// unknown (not seen yet). A degraded read never reports "failed".
pub const Status = enum { confirmed, failed, unknown };
pub const StatusResult = union(enum) { status: Status, err: []const u8 };

pub fn signatureStatus(a: Allocator, t: rpc.Transport, sig: []const u8) Allocator.Error!StatusResult {
    const req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSignatureStatuses\",\"params\":[[\"{s}\"],{{\"searchTransactionHistory\":true}}]}}", .{sig});
    const r = switch (try call(a, t, req)) {
        .result => |v| v,
        .err => |e| return .{ .err = e },
    };
    const value = (r.get("value") orelse return .{ .err = "getSignatureStatuses: no value" }).asArray() orelse
        return .{ .err = "getSignatureStatuses: value is not an array" };
    if (value.len == 0 or value[0].asObject() == null) return .{ .status = .unknown };
    const entry = value[0];
    // err present and non-null => the transaction failed on chain.
    if (entry.get("err")) |e| {
        if (e.asObject() != null or e.asArray() != null or e.asString() != null) return .{ .status = .failed };
    }
    const cs = json.getString(entry, "confirmationStatus") orelse "";
    if (std.mem.eql(u8, cs, "confirmed") or std.mem.eql(u8, cs, "finalized")) return .{ .status = .confirmed };
    return .{ .status = .unknown };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "solana: shortvec encodes like Solana's compact-u16" {
    const a = testing.allocator;
    const cases = [_]struct { n: u16, want: []const u8 }{
        .{ .n = 0, .want = &.{0x00} },
        .{ .n = 5, .want = &.{0x05} },
        .{ .n = 127, .want = &.{0x7f} },
        .{ .n = 128, .want = &.{ 0x80, 0x01 } },
        .{ .n = 256, .want = &.{ 0x80, 0x02 } },
        .{ .n = 16384, .want = &.{ 0x80, 0x80, 0x01 } },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try writeShortVec(&out, a, c.n);
        try testing.expectEqualSlices(u8, c.want, out.items);
    }
}

test "solana: transfer message bytes (known answer, pins the wire layout)" {
    const a = testing.allocator;
    const from = [_]u8{0x11} ** 32;
    const to = [_]u8{0x22} ** 32;
    const bh = [_]u8{0x33} ** 32;
    const msg = try transferMessage(a, from, to, bh, 10000);
    defer a.free(msg);
    // header(3) + [03] + from + to + system(00*32) + blockhash + [01][02][02][00 01][0c] + data(12)
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(a);
    try want.appendSlice(a, &.{ 1, 0, 1, 3 });
    try want.appendSlice(a, &from);
    try want.appendSlice(a, &to);
    try want.appendSlice(a, &([_]u8{0} ** 32));
    try want.appendSlice(a, &bh);
    try want.appendSlice(a, &.{ 1, 2, 2, 0, 1, 12, 2, 0, 0, 0, 0x10, 0x27, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqualSlices(u8, want.items, msg);
    try testing.expectEqual(@as(usize, 150), msg.len);
}

test "solana: a signed transfer is base58([01][sig][message]) with a valid signature" {
    const a = testing.allocator;
    const seed = [_]u8{7} ** 32;
    const pair = try crypto.Ed25519.KeyPair.generateDeterministic(seed);
    const kp: keypair.Keypair = .{ .seed = seed, .public_key = pair.public_key.toBytes() };
    const to = [_]u8{0x44} ** 32;
    const bh = [_]u8{0x55} ** 32;
    const msg = try transferMessage(a, kp.public_key, to, bh, 42);
    defer a.free(msg);
    const sig = kp.sign(msg);
    // The signature is over the message bytes.
    try crypto.Ed25519.Signature.fromBytes(sig).verify(msg, pair.public_key);
    // The transaction is [shortvec 1][64-byte sig][message], base58 (whole tx is
    // ~296 chars, past base58.decode's relay-DoS cap, so compare the string).
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    try expected.append(a, 1);
    try expected.appendSlice(a, &sig);
    try expected.appendSlice(a, msg);
    const want = try base58.encode(a, expected.items);
    defer a.free(want);
    const got = try signedTransferB58(a, kp, to, bh, 42);
    defer a.free(got);
    try testing.expectEqualStrings(want, got);
}

const TestTransport = struct {
    reply: []const u8,
    seen: *[]const u8,
    fn post(ctx: *anyopaque, a: Allocator, request_json: []const u8) Allocator.Error!rpc.Posted {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        self.seen.* = try a.dupe(u8, request_json);
        return .{ .reply = self.reply };
    }
    fn transport(self: *TestTransport) rpc.Transport {
        return .{ .ctx = self, .postFn = post, .url = "https://x" };
    }
};

test "solana: RPC replies are parsed, and a failed tx is never read as confirmed" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var seen: []const u8 = "";
    {
        var tt = TestTransport{ .reply = "{\"jsonrpc\":\"2.0\",\"result\":{\"context\":{\"slot\":1},\"value\":{\"blockhash\":\"11111111111111111111111111111112\",\"lastValidBlockHeight\":9}},\"id\":1}", .seen = &seen };
        const bh = try getLatestBlockhash(a, tt.transport());
        try testing.expect(bh == .ok);
    }
    {
        var tt = TestTransport{ .reply = "{\"jsonrpc\":\"2.0\",\"result\":\"5SIGnature\",\"id\":1}", .seen = &seen };
        const s = try sendTransaction(a, tt.transport(), "TXb58");
        try testing.expectEqualStrings("5SIGnature", s.ok);
        try testing.expect(std.mem.indexOf(u8, seen, "\"encoding\":\"base58\"") != null);
        try testing.expect(std.mem.indexOf(u8, seen, "\"TXb58\"") != null);
    }
    {
        var tt = TestTransport{ .reply = "{\"result\":{\"value\":[{\"confirmationStatus\":\"finalized\",\"err\":null}]}}", .seen = &seen };
        try testing.expectEqual(Status.confirmed, (try signatureStatus(a, tt.transport(), "s")).status);
    }
    {
        var tt = TestTransport{ .reply = "{\"result\":{\"value\":[{\"confirmationStatus\":\"finalized\",\"err\":{\"InstructionError\":[0,\"X\"]}}]}}", .seen = &seen };
        try testing.expectEqual(Status.failed, (try signatureStatus(a, tt.transport(), "s")).status);
    }
    {
        var tt = TestTransport{ .reply = "{\"result\":{\"value\":[null]}}", .seen = &seen };
        try testing.expectEqual(Status.unknown, (try signatureStatus(a, tt.transport(), "s")).status);
    }
    {
        var tt = TestTransport{ .reply = "{\"error\":{\"code\":-32002,\"message\":\"blockhash not found\"}}", .seen = &seen };
        try testing.expect((try sendTransaction(a, tt.transport(), "TX")) == .err);
    }
}
