//! The in-process aexchat relay used by the flow and crew tests: it speaks the
//! aexchatRequest envelope and enforces what src/aexchat/aexchat_server.cpp
//! enforces for these routes (signed challenges, tokens, membership, a share's
//! sender key being one of the uploader's devices). Hostile knobs make it a
//! bad actor. Extracted from tests/flows_relay.zig so the crew tests reuse it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const crypto = @import("../crypto.zig");
const base58 = @import("../base58.zig");
const rpc = @import("../rpc.zig");
const client = @import("../client.zig");

pub const Device = struct { user: []const u8, id: []const u8, ed: []const u8, x: []const u8 };
pub const Share = struct { target: []const u8, room: []const u8, sid: []const u8, ek: []const u8, spub: []const u8, sender: []const u8 };
pub const Event = struct { id: []const u8, sender: []const u8, type: []const u8, content: []const u8, ts: i64 };
pub const Pending = struct { wallet: []const u8, message: []const u8 };

pub const Relay = struct {
    a: Allocator,
    counter: u64 = 0,
    challenges: std.StringArrayHashMapUnmanaged(Pending) = .empty,
    tokens: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    devices: std.ArrayListUnmanaged(Device) = .empty,
    members: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,
    invited: std.ArrayListUnmanaged([2][]const u8) = .empty,
    shares: std.ArrayListUnmanaged(Share) = .empty,
    events: std.ArrayListUnmanaged(Event) = .empty,
    verify_calls: usize = 0,
    // Hostile knobs.
    challenge_override: ?[]const u8 = null,
    challenge_host: []const u8 = "slonana.com",
    rogue_device_for: ?[]const u8 = null,
    rogue_x: []const u8 = "",

    fn next(r: *Relay) u64 {
        r.counter += 1;
        return r.counter;
    }

    fn err(r: *Relay, code: []const u8, msg: []const u8) ![]const u8 {
        var o = try json.Object.init(r.a);
        try o.string("errcode", code);
        try o.string("error", msg);
        return o.finish();
    }

    pub fn joined(r: *Relay, room: []const u8, user: []const u8) bool {
        const list = r.members.get(room) orelse return false;
        for (list.items) |u| {
            if (std.mem.eql(u8, u, user)) return true;
        }
        return false;
    }

    pub fn createRoom(r: *Relay, room: []const u8, creator: []const u8) !void {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        try list.append(r.a, creator);
        try r.members.put(r.a, room, list);
    }

    pub fn invite(r: *Relay, room: []const u8, user: []const u8) !void {
        try r.invited.append(r.a, .{ room, user });
    }

    fn post(ctx: *anyopaque, a: Allocator, request_json: []const u8) Allocator.Error!rpc.Posted {
        const r: *Relay = @ptrCast(@alignCast(ctx));
        const result = r.route(request_json) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try r.err("M_BAD_JSON", @errorName(e)),
        };
        return .{ .reply = try std.mem.concat(a, u8, &.{ "{\"jsonrpc\":\"2.0\",\"result\":", result, ",\"id\":1}" }) };
    }

    pub fn transport(r: *Relay) rpc.Transport {
        return .{ .ctx = r, .postFn = post, .url = "https://rpc.slonana.com" };
    }

    /// A client.Backend that hands every command this relay's transport.
    pub fn backend(r: *Relay) client.Backend {
        return .{ .ctx = r, .openFn = open };
    }
    fn open(ctx: *anyopaque, url: []const u8) client.Conn {
        _ = url;
        const r: *Relay = @ptrCast(@alignCast(ctx));
        return .{ .ctx = r, .t = r.transport(), .closeFn = noopClose };
    }
    fn noopClose(_: *anyopaque) void {}

    fn route(r: *Relay, request_json: []const u8) ![]const u8 {
        const a = r.a;
        const req = try json.parse(a, try a.dupe(u8, request_json));
        // Plain JSON-RPC (getLatestBlockhash/sendTransaction/...) is not an
        // aexchatRequest: answer a generic error so `pay` degrades cleanly here.
        const params = json.get(req, "params") orelse return r.err("M_NO_PARAMS", "no params");
        if (params.asObject() == null) return r.err("M_NO_PARAMS", "params is not an object");
        const path = json.getString(params, "path") orelse return r.err("M_NO_PATH", "no path");
        const method = json.getString(params, "method").?;
        const body_text = json.getString(params, "body") orelse "{}";
        const body = try json.parse(a, try a.dupe(u8, body_text));
        const token = json.getString(params, "token") orelse "";

        if (std.mem.eql(u8, path, "/aexchat/auth/challenge")) {
            const wallet = json.getString(body, "wallet").?;
            const nonce = std.fmt.bytesToHex(crypto.sha256(std.mem.asBytes(&r.next())), .lower);
            const message = r.challenge_override orelse
                try std.fmt.allocPrint(a, "Sign in to {s}\nNonce: {s}\nTimestamp: 1790000000", .{ r.challenge_host, nonce });
            try r.challenges.put(a, try a.dupe(u8, &nonce), .{ .wallet = wallet, .message = message });
            var o = try json.Object.init(a);
            try o.string("nonce", &nonce);
            try o.string("message", message);
            try o.int("expires_at", 1790000300);
            return o.finish();
        }
        if (std.mem.eql(u8, path, "/aexchat/auth/verify")) {
            r.verify_calls += 1;
            const wallet = json.getString(body, "wallet").?;
            const nonce = json.getString(body, "nonce").?;
            const pending = r.challenges.get(nonce) orelse return r.err("M_FORBIDDEN", "Signature verification failed");
            if (!std.mem.eql(u8, pending.wallet, wallet)) return r.err("M_FORBIDDEN", "Signature verification failed");
            const sig = try base58.decode(a, json.getString(body, "signature").?);
            const pk = base58.decode32(wallet) orelse return r.err("M_FORBIDDEN", "bad wallet");
            if (sig.len != 64) return r.err("M_FORBIDDEN", "Signature verification failed");
            const signature = crypto.Ed25519.Signature.fromBytes(sig[0..64].*);
            const public = crypto.Ed25519.PublicKey.fromBytes(pk) catch return r.err("M_FORBIDDEN", "bad key");
            signature.verify(pending.message, public) catch return r.err("M_FORBIDDEN", "Signature verification failed");
            const tok = try std.fmt.allocPrint(a, "tok-{d}", .{r.next()});
            const user = try std.fmt.allocPrint(a, "@{s}:slonana.com", .{wallet});
            try r.tokens.put(a, tok, user);
            var o = try json.Object.init(a);
            try o.string("access_token", tok);
            try o.string("user_id", user);
            try o.string("device_id", json.getString(body, "device_id") orelse "");
            return o.finish();
        }
        const user = r.tokens.get(token) orelse return r.err("M_UNKNOWN_TOKEN", "no token");

        if (std.mem.eql(u8, path, "/aexchat/keys/upload")) {
            const id = json.getString(body, "device_id").?;
            const d: Device = .{ .user = user, .id = id, .ed = json.getString(body, "ed25519_key").?, .x = json.getString(body, "x25519_key").? };
            for (r.devices.items) |*e| {
                if (std.mem.eql(u8, e.user, user) and std.mem.eql(u8, e.id, id)) {
                    e.* = d;
                    return "{\"one_time_key_counts\":0}";
                }
            }
            try r.devices.append(a, d);
            return "{\"one_time_key_counts\":0}";
        }
        if (std.mem.eql(u8, path, "/aexchat/keys/query")) {
            var by_user = try json.Object.init(a);
            for (json.get(body, "user_ids").?.asArray().?) |u| {
                const uid = u.asString().?;
                var arr = try json.Array.init(a);
                for (r.devices.items) |d| {
                    if (!std.mem.eql(u8, d.user, uid)) continue;
                    var o = try json.Object.init(a);
                    try o.string("device_id", d.id);
                    try o.string("ed25519_key", d.ed);
                    try o.string("x25519_key", d.x);
                    try arr.raw(try o.finish());
                }
                if (r.rogue_device_for) |victim| {
                    if (std.mem.eql(u8, victim, uid)) {
                        var o = try json.Object.init(a);
                        try o.string("device_id", "relay_planted");
                        try o.string("ed25519_key", "07" ** 32);
                        try o.string("x25519_key", r.rogue_x);
                        try arr.raw(try o.finish());
                    }
                }
                try by_user.raw(uid, try arr.finish());
            }
            var o = try json.Object.init(a);
            try o.raw("device_keys", try by_user.finish());
            return o.finish();
        }
        if (std.mem.eql(u8, path, "/aexchat/keys/share")) {
            const items = json.get(body, "shares").?.asArray().?;
            for (items) |s| {
                const room = json.getString(s, "room_id").?;
                const target = json.getString(s, "target_user").?;
                if (!r.joined(room, user) or !r.joined(room, target)) return r.err("M_FORBIDDEN", "not joined");
                const spub = json.getString(s, "sender_x25519_public").?;
                var own = false;
                for (r.devices.items) |d| {
                    if (std.mem.eql(u8, d.user, user) and std.mem.eql(u8, d.x, spub)) own = true;
                }
                if (!own) return r.err("M_FORBIDDEN", "sender_x25519_public is not the x25519 key of any device you uploaded");
            }
            for (items) |s| try r.shares.append(a, .{
                .target = json.getString(s, "target_user").?,
                .room = json.getString(s, "room_id").?,
                .sid = json.getString(s, "session_id").?,
                .ek = json.getString(s, "encrypted_key").?,
                .spub = json.getString(s, "sender_x25519_public").?,
                .sender = user,
            });
            return std.fmt.allocPrint(a, "{{\"shared\":{d}}}", .{items.len});
        }
        if (std.mem.startsWith(u8, path, "/aexchat/keys/pending?room_id=")) {
            const room = path["/aexchat/keys/pending?room_id=".len..];
            if (!r.joined(room, user)) return r.err("M_FORBIDDEN", "join first");
            var arr = try json.Array.init(a);
            for (r.shares.items) |s| {
                if (!std.mem.eql(u8, s.target, user) or !std.mem.eql(u8, s.room, room)) continue;
                var o = try json.Object.init(a);
                try o.string("room_id", s.room);
                try o.string("session_id", s.sid);
                try o.string("encrypted_key", s.ek);
                try o.string("sender_x25519_public", s.spub);
                try o.string("sender_user", s.sender);
                try arr.raw(try o.finish());
            }
            var o = try json.Object.init(a);
            try o.raw("key_shares", try arr.finish());
            try o.boolean("truncated", false);
            return o.finish();
        }
        if (std.mem.startsWith(u8, path, "/aexchat/rooms/")) {
            const rest = path["/aexchat/rooms/".len..];
            if (std.mem.eql(u8, rest, "create")) {
                const name = json.getString(body, "name") orelse "room";
                const id = try std.fmt.allocPrint(a, "!{s}{d}:slonana.com", .{ name, r.next() });
                try r.createRoom(id, user);
                return std.fmt.allocPrint(a, "{{\"room_id\":\"{s}\"}}", .{id});
            }
            const slash = std.mem.lastIndexOfScalar(u8, rest, '/').?;
            const room = rest[0..slash];
            var action = rest[slash + 1 ..];
            if (std.mem.indexOfScalar(u8, action, '?')) |q| action = action[0..q];
            if (std.mem.eql(u8, action, "invite") and std.mem.eql(u8, method, "POST")) {
                if (!r.joined(room, user)) return r.err("M_FORBIDDEN", "You must join this room");
                const w = json.getString(body, "wallet") orelse return r.err("M_BAD", "no wallet");
                try r.invite(room, try std.fmt.allocPrint(a, "@{s}:slonana.com", .{w}));
                return "{\"ok\":true}";
            }
            if (std.mem.eql(u8, action, "join") and std.mem.eql(u8, method, "POST")) {
                var ok = r.joined(room, user);
                for (r.invited.items) |iv| {
                    if (std.mem.eql(u8, iv[0], room) and std.mem.eql(u8, iv[1], user)) ok = true;
                }
                if (!ok) return r.err("M_FORBIDDEN", "Cannot join room");
                if (!r.joined(room, user)) try r.members.getPtr(room).?.append(a, user);
                return std.fmt.allocPrint(a, "{{\"room_id\":\"{s}\"}}", .{room});
            }
            if (std.mem.eql(u8, action, "leave") and std.mem.eql(u8, method, "POST")) {
                if (r.members.getPtr(room)) |list| {
                    for (list.items, 0..) |m, i| {
                        if (std.mem.eql(u8, m, user)) {
                            _ = list.orderedRemove(i);
                            break;
                        }
                    }
                }
                return "{\"ok\":true}";
            }
            if (!r.joined(room, user)) return r.err("M_FORBIDDEN", "You must join this room");
            if (std.mem.eql(u8, action, "members")) {
                var arr = try json.Array.init(a);
                for (r.members.get(room).?.items) |m| {
                    var o = try json.Object.init(a);
                    try o.string("user_id", m);
                    try o.string("membership", "join");
                    try arr.raw(try o.finish());
                }
                var o = try json.Object.init(a);
                try o.raw("members", try arr.finish());
                return o.finish();
            }
            if (std.mem.eql(u8, action, "send")) {
                const id = try std.fmt.allocPrint(a, "$ev{d}", .{r.next()});
                try r.events.append(a, .{ .id = id, .sender = user, .type = json.getString(body, "type").?, .content = json.getString(body, "content").?, .ts = @intCast(1790000000000 + r.counter) });
                return std.fmt.allocPrint(a, "{{\"event_id\":\"{s}\"}}", .{id});
            }
            if (std.mem.eql(u8, action, "messages")) {
                const lim_at = std.mem.indexOf(u8, path, "limit=").?;
                const limit = try std.fmt.parseInt(usize, path[lim_at + 6 ..], 10);
                var arr = try json.Array.init(a);
                var i = r.events.items.len;
                var n: usize = 0;
                while (i > 0 and n < limit) : (n += 1) {
                    i -= 1;
                    const e = r.events.items[i];
                    var o = try json.Object.init(a);
                    try o.string("event_id", e.id);
                    try o.string("sender", e.sender);
                    try o.string("type", e.type);
                    try o.raw("content", e.content);
                    try o.int("origin_server_ts", e.ts);
                    try arr.raw(try o.finish());
                }
                var o = try json.Object.init(a);
                try o.raw("chunk", try arr.finish());
                return o.finish();
            }
        }
        return r.err("M_UNRECOGNIZED", path);
    }
};
