//! Checks before signing or sending a token: challenge_message_ok,
//! chat_url_refusal, url_host and challenge_host_ok from chat.cpp.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// `message` is exactly "Sign in to <host>\nNonce: <nonce>\nTimestamp: <digits>",
/// so a node cannot get the wallet to sign text it chose.
pub fn challengeMessageOk(message: []const u8, nonce: []const u8) bool {
    if (nonce.len != 64) return false;
    for (nonce) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    const head = "Sign in to ";
    if (!std.mem.startsWith(u8, message, head)) return false;
    var mid_buf: [8 + 64 + 12]u8 = undefined;
    const mid = std.fmt.bufPrint(&mid_buf, "\nNonce: {s}\nTimestamp: ", .{nonce}) catch return false;
    const at = std.mem.indexOfPos(u8, message, head.len, mid) orelse return false;
    const host = message[head.len..at];
    const ts = message[at + mid.len ..];
    if (host.len == 0 or host.len > 253 or ts.len == 0 or ts.len > 20) return false;
    for (host) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '.' or c == '-';
        if (!ok) return false;
    }
    for (ts) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// The name a checked challenge asks to sign in to.
pub fn challengeHost(message: []const u8) []const u8 {
    const head = "Sign in to ";
    const nl = std.mem.indexOfScalar(u8, message, '\n') orelse message.len;
    return message[head.len..nl];
}

fn lowerAlloc(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn authorityEnd(s: []const u8, start: usize) usize {
    return std.mem.indexOfAnyPos(u8, s, start, "/?#") orelse s.len;
}

/// chat_url_refusal: null when `url` may carry the token and signatures
/// (https, or plain http to this machine only), else why not.
pub fn urlRefusal(a: Allocator, url: []const u8) Allocator.Error!?[]u8 {
    const lower = try lowerAlloc(a, url);
    defer a.free(lower);
    if (std.mem.startsWith(u8, lower, "https://") and lower.len > 8) return null;
    const why = try std.fmt.allocPrint(a, "RPC URL {s} is not https, so the access token and every message would cross the network in the clear; pass -u https://... (plain http is allowed only to 127.0.0.1, localhost or [::1])", .{url});
    if (!std.mem.startsWith(u8, lower, "http://")) return why;
    const authority = lower[7..authorityEnd(lower, 7)];
    var host: []const u8 = undefined;
    var port: []const u8 = undefined;
    if (authority.len != 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return why;
        host = authority[1..close];
        port = authority[close + 1 ..];
    } else {
        const colon = std.mem.indexOfScalar(u8, authority, ':');
        host = authority[0 .. colon orelse authority.len];
        port = if (colon) |c| authority[c..] else "";
    }
    var port_ok = port.len == 0;
    if (port.len >= 2 and port.len <= 6 and port[0] == ':') {
        port_ok = true;
        for (port[1..]) |c| {
            if (c < '0' or c > '9') port_ok = false;
        }
    }
    const local = std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "::1");
    if (!port_ok or !local) return why;
    a.free(why);
    return null;
}

/// url_host: the lowercased host of an http(s) URL, without userinfo, port
/// or brackets; empty when there is none.
pub fn urlHost(a: Allocator, url: []const u8) Allocator.Error![]u8 {
    const lower = try lowerAlloc(a, url);
    defer a.free(lower);
    const start: usize = if (std.mem.startsWith(u8, lower, "https://")) 8 else if (std.mem.startsWith(u8, lower, "http://")) 7 else return a.dupe(u8, "");
    var authority = lower[start..authorityEnd(lower, start)];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len != 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return a.dupe(u8, "");
        return a.dupe(u8, authority[1..close]);
    }
    return a.dupe(u8, authority[0 .. std.mem.indexOfScalar(u8, authority, ':') orelse authority.len]);
}

/// challenge_host_ok: `named` is `host` or its parent domain (or `host` is
/// this machine), so a node cannot pass on another server's challenge.
pub fn challengeHostOk(a: Allocator, named: []const u8, host: []const u8) Allocator.Error!bool {
    if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "::1"))
        return true;
    const n = try lowerAlloc(a, named);
    defer a.free(n);
    if (n.len == 0 or host.len == 0) return false;
    return std.mem.eql(u8, host, n) or (host.len > n.len and std.mem.endsWith(u8, host, n) and
        host[host.len - n.len - 1] == '.');
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "challenge template, url and host rules" {
    const a = testing.allocator;
    const nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try testing.expect(challengeMessageOk("Sign in to slonana.com\nNonce: " ++ nonce ++ "\nTimestamp: 1790000000", nonce));
    try testing.expect(!challengeMessageOk("Sign in to slonana.com\nNonce: " ++ nonce ++ "\nTimestamp: 17x", nonce));
    try testing.expect(!challengeMessageOk("Send 5 SOL to x\nNonce: " ++ nonce ++ "\nTimestamp: 1", nonce));
    try testing.expect(!challengeMessageOk("Sign in to a b\nNonce: " ++ nonce ++ "\nTimestamp: 1", nonce));
    try testing.expect(!challengeMessageOk("Sign in to x\nNonce: " ++ nonce ++ "\nTimestamp: 1", "ABC"));
    try testing.expectEqualStrings("slonana.com", challengeHost("Sign in to slonana.com\nNonce: x"));

    try testing.expect((try urlRefusal(a, "https://rpc.slonana.com")) == null);
    try testing.expect((try urlRefusal(a, "HTTP://127.0.0.1:8899/")) == null);
    try testing.expect((try urlRefusal(a, "http://[::1]:8899")) == null);
    inline for (.{ "http://rpc.slonana.com", "http://127.0.0.1.evil.com", "http://localhost:x", "ftp://x", "https://" }) |bad| {
        const why = (try urlRefusal(a, bad)).?;
        a.free(why);
    }

    const h = try urlHost(a, "https://User@RPC.Slonana.com:443/path");
    defer a.free(h);
    try testing.expectEqualStrings("rpc.slonana.com", h);
    try testing.expect(try challengeHostOk(a, "Slonana.com", "rpc.slonana.com"));
    try testing.expect(try challengeHostOk(a, "rpc.slonana.com", "rpc.slonana.com"));
    try testing.expect(!(try challengeHostOk(a, "evil.com", "rpc.slonana.com")));
    try testing.expect(!(try challengeHostOk(a, "lonana.com", "rpc.slonana.com")));
    try testing.expect(try challengeHostOk(a, "anything", "localhost"));
}
