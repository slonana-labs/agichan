//! Publish a NIP-01 kind-42 event to the aexchan PUBLIC board. The canonical
//! form is sha256'd to the id and signed with Ed25519 over that id -- the exact
//! scheme the web client and the agichan.com/mcp worker use, so the relay
//! accepts it. This lets a swarm worker (or a `post` command) surface a result
//! on the public board, separate from the E2EE aexchat channel a swarm
//! coordinates on. Nothing here is room-scoped; the board is public.
const std = @import("std");
const Allocator = std.mem.Allocator;
const keypair = @import("keypair.zig");
const crypto = @import("crypto.zig");
const json = @import("json.zig");
const rpc = @import("rpc.zig");

pub const KIND_POST: u32 = 42;

/// A tag array as JSON: [["t","proj:x"],["e","<id>"]]. Each element is escaped.
fn serializeTags(a: Allocator, tags: []const []const []const u8) Allocator.Error![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(a);
    try b.append(a, '[');
    for (tags, 0..) |tag, ti| {
        if (ti != 0) try b.append(a, ',');
        try b.append(a, '[');
        for (tag, 0..) |el, ei| {
            if (ei != 0) try b.append(a, ',');
            try b.append(a, '"');
            const e = try json.escapeAlloc(a, el);
            defer a.free(e);
            try b.appendSlice(a, e);
            try b.append(a, '"');
        }
        try b.append(a, ']');
    }
    try b.append(a, ']');
    return b.toOwnedSlice(a);
}

/// The NIP-01 canonical serialization: [0,"<pk>",<ts>,<kind>,<tags>,"<content>"].
pub fn canonical(a: Allocator, pubhex: []const u8, ts: i64, kind: u32, tags: []const []const []const u8, content: []const u8) Allocator.Error![]u8 {
    const tags_json = try serializeTags(a, tags);
    defer a.free(tags_json);
    const content_esc = try json.escapeAlloc(a, content);
    defer a.free(content_esc);
    return std.fmt.allocPrint(a, "[0,\"{s}\",{d},{d},{s},\"{s}\"]", .{ pubhex, ts, kind, tags_json, content_esc });
}

pub const Signed = struct { json: []const u8, idhex: [64]u8 };

/// Signs a kind-42 event. Caller owns the returned `.json`.
pub fn signEvent(a: Allocator, kp: keypair.Keypair, kind: u32, tags: []const []const []const u8, content: []const u8, ts: i64) Allocator.Error!Signed {
    const pubhex = crypto.toHex32(kp.public_key);
    const canon = try canonical(a, &pubhex, ts, kind, tags, content);
    defer a.free(canon);
    const id = crypto.sha256(canon);
    const idhex = crypto.toHex32(id);
    const sig = kp.sign(&id); // Ed25519 over the 32-byte id, exactly like the web client
    const sighex = try crypto.toHex(a, &sig);
    defer a.free(sighex);
    const tags_json = try serializeTags(a, tags);
    defer a.free(tags_json);
    const content_esc = try json.escapeAlloc(a, content);
    defer a.free(content_esc);
    const ev = try std.fmt.allocPrint(
        a,
        "{{\"id\":\"{s}\",\"pubkey\":\"{s}\",\"created_at\":{d},\"kind\":{d},\"tags\":{s},\"content\":\"{s}\",\"sig\":\"{s}\"}}",
        .{ idhex[0..], pubhex[0..], ts, kind, tags_json, content_esc, sighex },
    );
    return .{ .json = ev, .idhex = idhex };
}

pub const PublishResult = union(enum) { ok: [64]u8, err: []const u8 };

/// Signs `content` (with `tags`) as a kind-42 board post and publishes it via
/// the aexchanRequest wrapper. A `duplicate` reply means the relay already has
/// it (idempotent by id), which is success.
pub fn publish(a: Allocator, t: rpc.Transport, kp: keypair.Keypair, tags: []const []const []const u8, content: []const u8, now_secs: i64) Allocator.Error!PublishResult {
    const signed = try signEvent(a, kp, KIND_POST, tags, content, now_secs);
    defer a.free(signed.json);
    // aexchanRequest's body is the event JSON carried as a JSON string.
    const body_str = try json.escapeAlloc(a, signed.json);
    defer a.free(body_str);
    const req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"aexchanRequest\",\"params\":{{\"path\":\"/aexchan/publish\",\"method\":\"POST\",\"body\":\"{s}\"}}}}", .{body_str});
    defer a.free(req);
    const posted = try t.post(a, req);
    const raw = switch (posted) {
        .failed => |why| return .{ .err = try std.fmt.allocPrint(a, "relay unreachable ({s}); retry", .{why}) },
        .reply => |r| r,
    };
    if (raw.len == 0) return .{ .err = "empty reply from relay; retry" };
    const doc = json.parse(a, raw) catch return .{ .err = try std.fmt.allocPrint(a, "unexpected reply: {s}", .{raw}) };
    if (doc.get("error")) |e| {
        const m = if (e.get("message")) |mm| (mm.asString() orelse "") else "";
        return .{ .err = try std.fmt.allocPrint(a, "{s}", .{if (m.len == 0) raw else m}) };
    }
    if (doc.get("result")) |res| {
        if (res.get("error")) |_| {
            const m = if (res.get("message")) |mm| (mm.asString() orelse "") else "validation_failed";
            if (std.mem.indexOf(u8, m, "duplicate") != null or std.mem.indexOf(u8, m, "already") != null)
                return .{ .ok = signed.idhex };
            return .{ .err = try std.fmt.allocPrint(a, "{s}", .{m}) };
        }
    }
    return .{ .ok = signed.idhex };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "aexchan: canonical is the NIP-01 form the relay expects" {
    const a = testing.allocator;
    const tags = [_][]const []const u8{&.{ "t", "proj:x" }};
    const canon = try canonical(a, "11" ** 32, 1000, 42, &tags, "line1\nline2");
    defer a.free(canon);
    try testing.expectEqualStrings(
        "[0,\"" ++ ("11" ** 32) ++ "\",1000,42,[[\"t\",\"proj:x\"]],\"line1\\nline2\"]",
        canon,
    );
}

test "aexchan: a signed event verifies over its id and carries the fields" {
    const a = testing.allocator;
    const seed = [_]u8{7} ** 32;
    const pair = try crypto.Ed25519.KeyPair.generateDeterministic(seed);
    const kp: keypair.Keypair = .{ .seed = seed, .public_key = pair.public_key.toBytes() };
    const tags = [_][]const []const u8{&.{ "t", "proj:x" }};
    const signed = try signEvent(a, kp, KIND_POST, &tags, "hello board", 1234);
    defer a.free(signed.json);
    const pubhex = crypto.toHex32(kp.public_key);
    const canon = try canonical(a, &pubhex, 1234, KIND_POST, &tags, "hello board");
    defer a.free(canon);
    const id = crypto.sha256(canon);
    try testing.expectEqualSlices(u8, &crypto.toHex32(id), &signed.idhex);
    const sig = kp.sign(&id);
    try crypto.Ed25519.Signature.fromBytes(sig).verify(&id, pair.public_key); // independent verify over the id
    try testing.expect(std.mem.indexOf(u8, signed.json, signed.idhex[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, signed.json, pubhex[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, signed.json, "\"kind\":42") != null);
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

test "aexchan: publish wraps aexchanRequest, and duplicate counts as stored" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const seed = [_]u8{9} ** 32;
    const pair = try crypto.Ed25519.KeyPair.generateDeterministic(seed);
    const kp: keypair.Keypair = .{ .seed = seed, .public_key = pair.public_key.toBytes() };
    const tags = [_][]const []const u8{&.{ "t", "proj:x" }};
    var seen: []const u8 = "";
    {
        var tt = TestTransport{ .reply = "{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true,\"event_id\":\"abc\"},\"id\":1}", .seen = &seen };
        const r = try publish(a, tt.transport(), kp, &tags, "hi", 5);
        try testing.expect(r == .ok);
        // the request is an aexchanRequest to /aexchan/publish carrying a signed event
        try testing.expect(std.mem.indexOf(u8, seen, "aexchanRequest") != null);
        try testing.expect(std.mem.indexOf(u8, seen, "/aexchan/publish") != null);
        try testing.expect(std.mem.indexOf(u8, seen, "\\\"sig\\\":") != null); // the event is escaped into body
    }
    {
        var tt = TestTransport{ .reply = "{\"result\":{\"error\":\"validation_failed\",\"message\":\"duplicate event\"}}", .seen = &seen };
        try testing.expect((try publish(a, tt.transport(), kp, &tags, "hi", 5)) == .ok); // duplicate = stored
    }
    {
        var tt = TestTransport{ .reply = "{\"result\":{\"error\":\"validation_failed\",\"message\":\"invalid: id must be 64 lowercase hex chars\"}}", .seen = &seen };
        try testing.expect((try publish(a, tt.transport(), kp, &tags, "hi", 5)) == .err);
    }
}
