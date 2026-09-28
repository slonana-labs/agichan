//! The client's state and its JSON, in the C++ state file's layout
//! (load_state / save_state in chat.cpp). It holds secret keys.
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = @import("crypto.zig");
const json = @import("json.zig");
const board = @import("board.zig");

pub const StringSet = std.StringArrayHashMapUnmanaged(void);

pub const State = struct {
    token: []const u8 = "",
    user_id: []const u8 = "",
    device_id: []const u8 = "",
    device: ?crypto.X25519Keypair = null,
    /// Device keys used before the wallet-derived one; shares sealed to them
    /// still open.
    retired: std.ArrayListUnmanaged(crypto.X25519Keypair) = .empty,
    /// E2eeManager export; empty in a fresh state.
    sessions: []const u8 = "",
    /// session id -> hex X25519 keys of the devices that already hold its key
    shared: std.StringArrayHashMapUnmanaged(StringSet) = .empty,
    /// room -> every sender each handle has been bound to
    pins: std.StringArrayHashMapUnmanaged(board.HandleChains) = .empty,

    pub fn wipe(st: *State) void {
        if (st.device) |*d| d.wipe();
        for (st.retired.items) |*k| k.wipe();
    }

    /// The kept chains of `room`, created empty on first use.
    pub fn pinsOf(st: *State, a: Allocator, room: []const u8) Allocator.Error!*board.HandleChains {
        const gop = try st.pins.getOrPut(a, room);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, room);
            gop.value_ptr.* = .empty;
        }
        return gop.value_ptr;
    }

    pub fn addShared(st: *State, a: Allocator, session_id: []const u8, x25519_hex: []const u8) Allocator.Error!void {
        const gop = try st.shared.getOrPut(a, session_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, session_id);
            gop.value_ptr.* = .empty;
        }
        const k = try gop.value_ptr.getOrPut(a, x25519_hex);
        if (!k.found_existing) k.key_ptr.* = try a.dupe(u8, x25519_hex);
    }
};

pub const LoadError = error{ Corrupt, OutOfMemory };

/// load_state: fields read only when present with the right type, as the
/// C++ does; a key pair or retired key that does not decode is corruption.
pub fn parse(a: Allocator, text: []const u8) LoadError!State {
    const doc = json.parse(a, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return error.Corrupt,
    };
    var st: State = .{};
    if (json.getString(doc, "token")) |v| st.token = v;
    if (json.getString(doc, "user_id")) |v| st.user_id = v;
    if (json.getString(doc, "device_id")) |v| st.device_id = v;
    const pk = json.getString(doc, "x25519_pk");
    const sk = json.getString(doc, "x25519_sk");
    if (pk != null and sk != null) {
        st.device = .{
            .public_key = crypto.fromHex32(pk.?) orelse return error.Corrupt,
            .secret_key = crypto.fromHex32(sk.?) orelse return error.Corrupt,
        };
    }
    if (doc.get("sessions")) |s| st.sessions = try json.minify(a, s);
    if (json.get(doc, "shared")) |shared| {
        for (shared.asObject() orelse &.{}) |m| {
            const targets = m.value.asArray() orelse continue;
            for (targets) |t| {
                if (t.asString()) |x| try st.addShared(a, m.key, x);
            }
        }
    }
    if (json.get(doc, "retired_x25519")) |retired| {
        if (retired.asArray()) |items| {
            for (items) |r| {
                const rpk = json.getString(r, "pk") orelse return error.Corrupt;
                const rsk = json.getString(r, "sk") orelse return error.Corrupt;
                try st.retired.append(a, .{
                    .public_key = crypto.fromHex32(rpk) orelse return error.Corrupt,
                    .secret_key = crypto.fromHex32(rsk) orelse return error.Corrupt,
                });
            }
        }
    }
    if (json.get(doc, "pins")) |pins| {
        for (pins.asObject() orelse &.{}) |room| {
            const handles = room.value.asObject() orelse continue;
            for (handles) |h| {
                const senders = h.value.asArray() orelse continue;
                for (senders) |s| {
                    const sender = s.asString() orelse continue;
                    // Created on the first sender, as operator[] does in the C++.
                    const chains = try st.pinsOf(a, room.key);
                    const gop = try chains.getOrPut(a, h.key);
                    if (!gop.found_existing) {
                        gop.key_ptr.* = try a.dupe(u8, h.key);
                        gop.value_ptr.* = .empty;
                    }
                    const e = try gop.value_ptr.getOrPut(a, sender);
                    if (!e.found_existing) e.key_ptr.* = try a.dupe(u8, sender);
                }
            }
        }
    }
    return st;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn sorted(a: Allocator, keys: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.dupe([]const u8, keys);
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

/// save_state's JSON: maps and sets in sorted order, as std::map and
/// std::set write them.
pub fn serialize(gpa: Allocator, st: *const State) Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try json.Object.init(a);
    try b.string("token", st.token);
    try b.string("user_id", st.user_id);
    try b.string("device_id", st.device_id);
    if (st.device) |d| {
        try b.string("x25519_pk", &crypto.toHex32(d.public_key));
        try b.string("x25519_sk", &crypto.toHex32(d.secret_key));
    }
    var retired = try json.Array.init(a);
    for (st.retired.items) |kp| {
        var r = try json.Object.init(a);
        try r.string("pk", &crypto.toHex32(kp.public_key));
        try r.string("sk", &crypto.toHex32(kp.secret_key));
        try retired.raw(try r.finish());
    }
    try b.raw("retired_x25519", try retired.finish());
    try b.raw("sessions", if (st.sessions.len == 0) "{\"outbound\":[],\"inbound\":[]}" else st.sessions);
    var shared = try json.Object.init(a);
    for (try sorted(a, st.shared.keys())) |sid| {
        try shared.strings(sid, try sorted(a, st.shared.get(sid).?.keys()));
    }
    try b.raw("shared", try shared.finish());
    var pins = try json.Object.init(a);
    for (try sorted(a, st.pins.keys())) |room| {
        const chains = st.pins.get(room).?;
        var handles = try json.Object.init(a);
        for (try sorted(a, chains.keys())) |h| {
            try handles.strings(h, try sorted(a, chains.get(h).?.keys()));
        }
        try pins.raw(room, try handles.finish());
    }
    try b.raw("pins", try pins.finish());
    const text = try b.finish();
    defer std.crypto.secureZero(u8, text);
    return gpa.dupe(u8, text);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "state: round trip in the C++ layout, sorted maps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .token = "tok", .user_id = "@w:x", .device_id = "agichan_01" };
    st.device = .{ .public_key = [_]u8{1} ** 32, .secret_key = [_]u8{2} ** 32 };
    try st.retired.append(a, .{ .public_key = [_]u8{3} ** 32, .secret_key = [_]u8{4} ** 32 });
    try st.addShared(a, "sid-b", "bb");
    try st.addShared(a, "sid-a", "zz");
    try st.addShared(a, "sid-a", "aa");
    const chains = try st.pinsOf(a, "!r:x");
    try chains.put(a, "w1", .empty);
    try chains.getPtr("w1").?.put(a, "@b:x", {});
    try chains.getPtr("w1").?.put(a, "@a:x", {});
    const text = try serialize(a, &st);
    const want = "{\"token\":\"tok\",\"user_id\":\"@w:x\",\"device_id\":\"agichan_01\"," ++
        "\"x25519_pk\":\"" ++ "01" ** 32 ++ "\",\"x25519_sk\":\"" ++ "02" ** 32 ++ "\"," ++
        "\"retired_x25519\":[{\"pk\":\"" ++ "03" ** 32 ++ "\",\"sk\":\"" ++ "04" ** 32 ++ "\"}]," ++
        "\"sessions\":{\"outbound\":[],\"inbound\":[]}," ++
        "\"shared\":{\"sid-a\":[\"aa\",\"zz\"],\"sid-b\":[\"bb\"]}," ++
        "\"pins\":{\"!r:x\":{\"w1\":[\"@a:x\",\"@b:x\"]}}}";
    try testing.expectEqualStrings(want, text);
    const back = try parse(a, text);
    try testing.expectEqualStrings("tok", back.token);
    try testing.expectEqualSlices(u8, &([_]u8{2} ** 32), &back.device.?.secret_key);
    try testing.expectEqual(@as(usize, 1), back.retired.items.len);
    try testing.expectEqualStrings(text, try serialize(a, &back));
}

test "state: what load_state calls corrupt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.Corrupt, parse(a, "{"));
    try testing.expectError(error.Corrupt, parse(a, "{\"x25519_pk\":\"00\",\"x25519_sk\":\"00\"}"));
    try testing.expectError(error.Corrupt, parse(a, "{\"retired_x25519\":[{\"pk\":\"00\"}]}"));
    // A document that is not an object reads as a fresh state, as simdjson's
    // doc["token"] fails there.
    const fresh = try parse(a, "[]");
    try testing.expectEqualStrings("", fresh.token);
    try testing.expect(fresh.device == null);
}
