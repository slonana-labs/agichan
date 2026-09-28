//! Every relay route is one JSON-RPC `aexchatRequest` {path, method, body,
//! token}, built and read as RpcClient::call and aex() in the C++ do.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");

/// What a transport did with one request: the reply body (any HTTP status),
/// or why no reply arrived.
pub const Posted = union(enum) {
    reply: []const u8,
    failed: []const u8,
};

/// POSTs a JSON-RPC request to the relay's URL. Implemented over HTTPS by
/// http_transport.zig; a browser or phone host supplies its own.
pub const Transport = struct {
    ctx: *anyopaque,
    postFn: *const fn (ctx: *anyopaque, gpa: Allocator, request_json: []const u8) Allocator.Error!Posted,
    /// Shown in "Failed to connect to RPC endpoint: <url>".
    url: []const u8,

    pub fn post(t: Transport, gpa: Allocator, request_json: []const u8) Allocator.Error!Posted {
        return t.postFn(t.ctx, gpa, request_json);
    }
};

pub const Reply = struct {
    ok: bool,
    /// The handler's result, minified; also set with an errcode.
    body: []const u8 = "",
    err: []const u8 = "",
};

/// The request body RpcClient sends for aexchatRequest; body and token are
/// omitted when empty.
pub fn requestJson(a: Allocator, path: []const u8, method: []const u8, body: []const u8, token: []const u8) Allocator.Error![]u8 {
    var p = try json.Object.init(a);
    try p.string("path", path);
    try p.string("method", method);
    if (body.len != 0) try p.string("body", body);
    if (token.len != 0) try p.string("token", token);
    const params = try p.finish();
    return std.mem.concat(a, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"aexchatRequest\",\"params\":", params, "}" });
}

/// RpcClient::extract_error_message: null when the reply has no top-level
/// "error" member; otherwise how the error describes itself.
fn errorMessage(a: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    const doc = json.parse(a, raw) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return "Unknown RPC error",
    };
    if (doc.asObject() == null) return "Unknown RPC error";
    const err = doc.get("error") orelse return null;
    if (err.asObject() == null) return "Unknown RPC error";
    const msg = err.get("message") orelse return "Unknown RPC error";
    return msg.asString() orelse "";
}

/// RpcClient::call then aex(): failures carry the C++'s messages.
pub fn interpret(a: Allocator, url: []const u8, posted: Posted) Allocator.Error!Reply {
    const raw = switch (posted) {
        .failed => |why| return .{ .ok = false, .err = try std.fmt.allocPrint(a, "Failed to connect to RPC endpoint: {s} ({s})", .{ url, why }) },
        .reply => |r| r,
    };
    if (raw.len == 0) return .{ .ok = false, .err = try std.fmt.allocPrint(a, "Failed to connect to RPC endpoint: {s}", .{url}) };
    // RpcClient looks for a top-level error only when the text mentions one.
    if (std.mem.indexOf(u8, raw, "\"error\"") != null) {
        if (try errorMessage(a, raw)) |m| {
            const msg = if (m.len == 0) "RPC returned an error with no message" else m;
            return .{ .ok = false, .err = try std.fmt.allocPrint(a, "{s}: {s}", .{ msg, raw }) };
        }
    }
    const unexpected: Reply = .{ .ok = false, .err = try std.fmt.allocPrint(a, "unexpected reply: {s}", .{raw}) };
    const doc = json.parse(a, raw) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return unexpected,
    };
    const result = doc.get("result") orelse return unexpected;
    const body = try json.minify(a, result);
    if (result.get("errcode")) |code| {
        if (code.asString()) |c| {
            const msg = json.getString(result, "error") orelse "(no message)";
            return .{ .ok = false, .body = body, .err = try std.fmt.allocPrint(a, "{s}: {s}", .{ c, msg }) };
        }
    }
    return .{ .ok = true, .body = body };
}

/// One aexchat route through the transport.
pub fn call(a: Allocator, t: Transport, path: []const u8, method: []const u8, body: []const u8, token: []const u8) Allocator.Error!Reply {
    const req = try requestJson(a, path, method, body, token);
    return interpret(a, t.url, try t.post(a, req));
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "rpc: request shape and every kind of reply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"aexchatRequest\",\"params\":{\"path\":\"/aexchat/keys/query\",\"method\":\"POST\",\"body\":\"{\\\"user_ids\\\":[]}\",\"token\":\"t\"}}",
        try requestJson(a, "/aexchat/keys/query", "POST", "{\"user_ids\":[]}", "t"),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"aexchatRequest\",\"params\":{\"path\":\"/aexchat/auth/challenge\",\"method\":\"POST\"}}",
        try requestJson(a, "/aexchat/auth/challenge", "POST", "", ""),
    );
    const u = "https://x";
    const ok = try interpret(a, u, .{ .reply = "{\"jsonrpc\":\"2.0\",\"result\":{ \"room_id\" : \"!r:x\" },\"id\":1}" });
    try testing.expect(ok.ok);
    try testing.expectEqualStrings("{\"room_id\":\"!r:x\"}", ok.body);
    const refused = try interpret(a, u, .{ .reply = "{\"result\":{\"errcode\":\"M_FORBIDDEN\",\"error\":\"Cannot join room\"}}" });
    try testing.expect(!refused.ok);
    try testing.expectEqualStrings("M_FORBIDDEN: Cannot join room", refused.err);
    const no_msg = try interpret(a, u, .{ .reply = "{\"result\":{\"errcode\":\"M_X\"}}" });
    try testing.expectEqualStrings("M_X: (no message)", no_msg.err);
    const rpc_err = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"Invalid params\"},\"id\":1}";
    try testing.expectEqualStrings("Invalid params: " ++ rpc_err, (try interpret(a, u, .{ .reply = rpc_err })).err);
    const empty_msg = "{\"error\":{\"code\":1,\"message\":\"\"}}";
    try testing.expectEqualStrings("RPC returned an error with no message: " ++ empty_msg, (try interpret(a, u, .{ .reply = empty_msg })).err);
    try testing.expectEqualStrings("unexpected reply: <html>", (try interpret(a, u, .{ .reply = "<html>" })).err);
    try testing.expectEqualStrings("Unknown RPC error: <b>\"error\"</b>", (try interpret(a, u, .{ .reply = "<b>\"error\"</b>" })).err);
    try testing.expectEqualStrings("Failed to connect to RPC endpoint: https://x (ConnectionRefused)", (try interpret(a, u, .{ .failed = "ConnectionRefused" })).err);
    try testing.expectEqualStrings("Failed to connect to RPC endpoint: https://x", (try interpret(a, u, .{ .reply = "" })).err);
}
