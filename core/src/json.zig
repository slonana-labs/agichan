//! JSON as the C++ client handles it: parsing with simdjson DOM's rules (valid
//! UTF-8, 64-bit integers, duplicate keys kept, first match wins), writing
//! with json::JsonBuilder's escaping (include/common/json_utils.h).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Member = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    /// Every integer that fits an i64.
    int: i64,
    /// Integers above maxInt(i64), as simdjson stores them.
    uint: u64,
    float: f64,
    string: []const u8,
    array: []const Value,
    object: []const Member,

    /// The first member named `key`; null when absent or `v` is no object.
    pub fn get(v: Value, key: []const u8) ?Value {
        switch (v) {
            .object => |members| {
                for (members) |m| {
                    if (std.mem.eql(u8, m.key, key)) return m.value;
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn asString(v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// simdjson's get(int64_t): an integer that fits i64, nothing else.
    pub fn asInt(v: Value) ?i64 {
        return switch (v) {
            .int => |i| i,
            else => null,
        };
    }

    /// simdjson's get_uint64(): a non-negative integer.
    pub fn asUint(v: Value) ?u64 {
        return switch (v) {
            .int => |i| if (i >= 0) @intCast(i) else null,
            .uint => |u| u,
            else => null,
        };
    }

    pub fn asArray(v: Value) ?[]const Value {
        return switch (v) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asObject(v: Value) ?[]const Member {
        return switch (v) {
            .object => |o| o,
            else => null,
        };
    }
};

/// Looks up `key` in an optional value, for chains like get(get(v, "a"), "b").
pub fn get(v: ?Value, key: []const u8) ?Value {
    const x = v orelse return null;
    return x.get(key);
}

pub fn getString(v: ?Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return x.asString();
}

pub const ParseError = error{ InvalidJson, OutOfMemory };

/// simdjson's default depth limit.
const max_depth = 1024;

/// Parses `text` into values allocated with `arena`; strings without escapes
/// point into `text`, which must outlive the result.
pub fn parse(arena: Allocator, text: []const u8) ParseError!Value {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidJson;
    var p: Parser = .{ .text = text, .arena = arena };
    p.skipWhitespace();
    const v = try p.parseValue(0);
    p.skipWhitespace();
    if (p.pos != text.len) return error.InvalidJson;
    return v;
}

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    arena: Allocator,

    fn skipWhitespace(p: *Parser) void {
        while (p.pos < p.text.len) : (p.pos += 1) {
            switch (p.text[p.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    fn expectLiteral(p: *Parser, lit: []const u8) ParseError!void {
        if (!std.mem.startsWith(u8, p.text[p.pos..], lit)) return error.InvalidJson;
        p.pos += lit.len;
        // simdjson wants a literal to end at a structural character or space.
        if (p.pos < p.text.len and !isStructuralOrSpace(p.text[p.pos])) return error.InvalidJson;
    }

    fn parseValue(p: *Parser, depth: usize) ParseError!Value {
        const c = p.peek() orelse return error.InvalidJson;
        switch (c) {
            '{' => return p.parseObject(depth + 1),
            '[' => return p.parseArray(depth + 1),
            '"' => return .{ .string = try p.parseString() },
            't' => {
                try p.expectLiteral("true");
                return .{ .bool = true };
            },
            'f' => {
                try p.expectLiteral("false");
                return .{ .bool = false };
            },
            'n' => {
                try p.expectLiteral("null");
                return .null;
            },
            '-', '0'...'9' => return p.parseNumber(),
            else => return error.InvalidJson,
        }
    }

    fn parseObject(p: *Parser, depth: usize) ParseError!Value {
        if (depth > max_depth) return error.InvalidJson;
        p.pos += 1;
        var members: std.ArrayList(Member) = .empty;
        p.skipWhitespace();
        if (p.peek() == '}') {
            p.pos += 1;
            return .{ .object = &.{} };
        }
        while (true) {
            p.skipWhitespace();
            if (p.peek() != '"') return error.InvalidJson;
            const key = try p.parseString();
            p.skipWhitespace();
            if (p.peek() != ':') return error.InvalidJson;
            p.pos += 1;
            p.skipWhitespace();
            const value = try p.parseValue(depth);
            try members.append(p.arena, .{ .key = key, .value = value });
            p.skipWhitespace();
            const sep = p.peek() orelse return error.InvalidJson;
            p.pos += 1;
            switch (sep) {
                ',' => continue,
                '}' => return .{ .object = try members.toOwnedSlice(p.arena) },
                else => return error.InvalidJson,
            }
        }
    }

    fn parseArray(p: *Parser, depth: usize) ParseError!Value {
        if (depth > max_depth) return error.InvalidJson;
        p.pos += 1;
        var items: std.ArrayList(Value) = .empty;
        p.skipWhitespace();
        if (p.peek() == ']') {
            p.pos += 1;
            return .{ .array = &.{} };
        }
        while (true) {
            p.skipWhitespace();
            try items.append(p.arena, try p.parseValue(depth));
            p.skipWhitespace();
            const sep = p.peek() orelse return error.InvalidJson;
            p.pos += 1;
            switch (sep) {
                ',' => continue,
                ']' => return .{ .array = try items.toOwnedSlice(p.arena) },
                else => return error.InvalidJson,
            }
        }
    }

    fn hex4(p: *Parser, at: usize) ParseError!u16 {
        if (at + 4 > p.text.len) return error.InvalidJson;
        var v: u16 = 0;
        for (p.text[at .. at + 4]) |ch| {
            const d: u16 = switch (ch) {
                '0'...'9' => ch - '0',
                'a'...'f' => ch - 'a' + 10,
                'A'...'F' => ch - 'A' + 10,
                else => return error.InvalidJson,
            };
            v = v * 16 + d;
        }
        return v;
    }

    fn parseString(p: *Parser) ParseError![]const u8 {
        p.pos += 1; // opening quote
        const start = p.pos;
        // Fast path: no escapes, the string is a slice of the input.
        var i = start;
        while (i < p.text.len) : (i += 1) {
            const ch = p.text[i];
            if (ch == '"') {
                p.pos = i + 1;
                return p.text[start..i];
            }
            if (ch == '\\') break;
            if (ch < 0x20) return error.InvalidJson;
        }
        if (i >= p.text.len) return error.InvalidJson;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.arena, p.text[start..i]);
        while (i < p.text.len) {
            const ch = p.text[i];
            if (ch == '"') {
                p.pos = i + 1;
                return out.toOwnedSlice(p.arena);
            }
            if (ch < 0x20) return error.InvalidJson;
            if (ch != '\\') {
                try out.append(p.arena, ch);
                i += 1;
                continue;
            }
            if (i + 1 >= p.text.len) return error.InvalidJson;
            const e = p.text[i + 1];
            switch (e) {
                '"', '\\', '/' => try out.append(p.arena, e),
                'b' => try out.append(p.arena, 0x08),
                'f' => try out.append(p.arena, 0x0c),
                'n' => try out.append(p.arena, '\n'),
                'r' => try out.append(p.arena, '\r'),
                't' => try out.append(p.arena, '\t'),
                'u' => {
                    var cp: u21 = try p.hex4(i + 2);
                    var used: usize = 6;
                    if (cp >= 0xd800 and cp < 0xdc00) {
                        // A high surrogate must be followed by \u and a low one.
                        if (i + 12 > p.text.len or p.text[i + 6] != '\\' or p.text[i + 7] != 'u')
                            return error.InvalidJson;
                        const lo = try p.hex4(i + 8);
                        if (lo < 0xdc00 or lo > 0xdfff) return error.InvalidJson;
                        cp = ((cp - 0xd800) << 10 | (lo - 0xdc00)) + 0x10000;
                        used = 12;
                    } else if (cp >= 0xdc00 and cp <= 0xdfff) {
                        return error.InvalidJson;
                    }
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidJson;
                    try out.appendSlice(p.arena, buf[0..n]);
                    i += used;
                    continue;
                },
                else => return error.InvalidJson,
            }
            i += 2;
        }
        return error.InvalidJson;
    }

    fn parseNumber(p: *Parser) ParseError!Value {
        const start = p.pos;
        var i = p.pos;
        const negative = p.text[i] == '-';
        if (negative) i += 1;
        const digits_start = i;
        while (i < p.text.len and std.ascii.isDigit(p.text[i])) i += 1;
        const digit_count = i - digits_start;
        if (digit_count == 0 or (p.text[digits_start] == '0' and digit_count > 1)) return error.InvalidJson;
        var is_float = false;
        if (i < p.text.len and p.text[i] == '.') {
            is_float = true;
            i += 1;
            const frac = i;
            while (i < p.text.len and std.ascii.isDigit(p.text[i])) i += 1;
            if (i == frac) return error.InvalidJson;
        }
        if (i < p.text.len and (p.text[i] == 'e' or p.text[i] == 'E')) {
            is_float = true;
            i += 1;
            if (i < p.text.len and (p.text[i] == '+' or p.text[i] == '-')) i += 1;
            const exp = i;
            while (i < p.text.len and std.ascii.isDigit(p.text[i])) i += 1;
            if (i == exp) return error.InvalidJson;
        }
        if (i < p.text.len and !isStructuralOrSpace(p.text[i])) return error.InvalidJson;
        p.pos = i;
        const lit = p.text[start..i];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, lit) catch return error.InvalidJson;
            if (!std.math.isFinite(f)) return error.InvalidJson;
            return .{ .float = f };
        }
        var mag: u64 = 0;
        for (p.text[digits_start..i]) |ch| {
            mag = std.math.mul(u64, mag, 10) catch return error.InvalidJson;
            mag = std.math.add(u64, mag, ch - '0') catch return error.InvalidJson;
        }
        if (negative) {
            if (mag > @as(u64, std.math.maxInt(i64)) + 1) return error.InvalidJson;
            return .{ .int = @bitCast(0 -% mag) };
        }
        if (mag > std.math.maxInt(i64)) return .{ .uint = mag };
        return .{ .int = @intCast(mag) };
    }
};

fn isStructuralOrSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ',', ':', ']', '}', '[', '{', '"' => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// JsonBuilder::escape: the body of a JSON string, without quotes.
pub fn appendEscaped(list: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(gpa, "\\\""),
            '\\' => try list.appendSlice(gpa, "\\\\"),
            0x08 => try list.appendSlice(gpa, "\\b"),
            0x0c => try list.appendSlice(gpa, "\\f"),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    try list.print(gpa, "\\u{x:0>4}", .{c});
                } else {
                    try list.append(gpa, c);
                }
            },
        }
    }
}

pub fn escapeAlloc(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try appendEscaped(&list, gpa, s);
    return list.toOwnedSlice(gpa);
}

/// json::JsonBuilder: an object built member by member.
pub const Object = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,
    first: bool = true,

    pub fn init(gpa: Allocator) Allocator.Error!Object {
        var o: Object = .{ .gpa = gpa };
        try o.list.append(gpa, '{');
        return o;
    }

    pub fn deinit(o: *Object) void {
        o.list.deinit(o.gpa);
    }

    fn key(o: *Object, k: []const u8) Allocator.Error!void {
        if (!o.first) try o.list.append(o.gpa, ',');
        o.first = false;
        try o.list.append(o.gpa, '"');
        try appendEscaped(&o.list, o.gpa, k);
        try o.list.appendSlice(o.gpa, "\":");
    }

    pub fn string(o: *Object, k: []const u8, v: []const u8) Allocator.Error!void {
        try o.key(k);
        try o.list.append(o.gpa, '"');
        try appendEscaped(&o.list, o.gpa, v);
        try o.list.append(o.gpa, '"');
    }

    pub fn int(o: *Object, k: []const u8, v: i64) Allocator.Error!void {
        try o.key(k);
        try o.list.print(o.gpa, "{d}", .{v});
    }

    pub fn uint(o: *Object, k: []const u8, v: u64) Allocator.Error!void {
        try o.key(k);
        try o.list.print(o.gpa, "{d}", .{v});
    }

    pub fn boolean(o: *Object, k: []const u8, v: bool) Allocator.Error!void {
        try o.key(k);
        try o.list.appendSlice(o.gpa, if (v) "true" else "false");
    }

    /// Pre-built JSON, inserted verbatim.
    pub fn raw(o: *Object, k: []const u8, json_text: []const u8) Allocator.Error!void {
        try o.key(k);
        try o.list.appendSlice(o.gpa, json_text);
    }

    pub fn strings(o: *Object, k: []const u8, values: []const []const u8) Allocator.Error!void {
        try o.key(k);
        try o.list.append(o.gpa, '[');
        for (values, 0..) |v, idx| {
            if (idx > 0) try o.list.append(o.gpa, ',');
            try o.list.append(o.gpa, '"');
            try appendEscaped(&o.list, o.gpa, v);
            try o.list.append(o.gpa, '"');
        }
        try o.list.append(o.gpa, ']');
    }

    /// The finished object; `o` is empty afterwards.
    pub fn finish(o: *Object) Allocator.Error![]u8 {
        try o.list.append(o.gpa, '}');
        return o.list.toOwnedSlice(o.gpa);
    }
};

/// json::JsonArray: elements are pre-built JSON (add_raw / add_object).
pub const Array = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,
    first: bool = true,

    pub fn init(gpa: Allocator) Allocator.Error!Array {
        var a: Array = .{ .gpa = gpa };
        try a.list.append(gpa, '[');
        return a;
    }

    pub fn deinit(a: *Array) void {
        a.list.deinit(a.gpa);
    }

    pub fn raw(a: *Array, json_text: []const u8) Allocator.Error!void {
        if (!a.first) try a.list.append(a.gpa, ',');
        a.first = false;
        try a.list.appendSlice(a.gpa, json_text);
    }

    pub fn finish(a: *Array) Allocator.Error![]u8 {
        try a.list.append(a.gpa, ']');
        return a.list.toOwnedSlice(a.gpa);
    }
};

/// simdjson::minify of a parsed element: no whitespace, strings escaped as
/// JsonBuilder does, members and duplicates in input order.
pub fn minify(gpa: Allocator, v: Value) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try minifyInto(&list, gpa, v);
    return list.toOwnedSlice(gpa);
}

fn minifyInto(list: *std.ArrayList(u8), gpa: Allocator, v: Value) Allocator.Error!void {
    switch (v) {
        .null => try list.appendSlice(gpa, "null"),
        .bool => |b| try list.appendSlice(gpa, if (b) "true" else "false"),
        .int => |i| try list.print(gpa, "{d}", .{i}),
        .uint => |u| try list.print(gpa, "{d}", .{u}),
        .float => |f| try list.print(gpa, "{d}", .{f}),
        .string => |s| {
            try list.append(gpa, '"');
            try appendEscaped(list, gpa, s);
            try list.append(gpa, '"');
        },
        .array => |items| {
            try list.append(gpa, '[');
            for (items, 0..) |item, idx| {
                if (idx > 0) try list.append(gpa, ',');
                try minifyInto(list, gpa, item);
            }
            try list.append(gpa, ']');
        },
        .object => |members| {
            try list.append(gpa, '{');
            for (members, 0..) |m, idx| {
                if (idx > 0) try list.append(gpa, ',');
                try list.append(gpa, '"');
                try appendEscaped(list, gpa, m.key);
                try list.appendSlice(gpa, "\":");
                try minifyInto(list, gpa, m.value);
            }
            try list.append(gpa, '}');
        },
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "json: numbers follow simdjson's ranges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(i64, -5), (try parse(a, "-5")).asInt().?);
    try testing.expectEqual(@as(i64, 0), (try parse(a, "-0")).asInt().?);
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), (try parse(a, "-9223372036854775808")).asInt().?);
    try testing.expectError(error.InvalidJson, parse(a, "-9223372036854775809"));
    const big = try parse(a, "18446744073709551615");
    try testing.expectEqual(@as(?i64, null), big.asInt());
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), big.asUint().?);
    try testing.expectError(error.InvalidJson, parse(a, "18446744073709551616"));
    try testing.expectEqual(@as(?i64, null), (try parse(a, "5.0")).asInt());
    try testing.expectError(error.InvalidJson, parse(a, "01"));
    try testing.expectError(error.InvalidJson, parse(a, "1."));
    try testing.expectError(error.InvalidJson, parse(a, "1e999"));
    try testing.expectError(error.InvalidJson, parse(a, "1x"));
    try testing.expectEqual(@as(?u64, null), (try parse(a, "-1")).asUint());
}

test "json: strings, escapes and UTF-8" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a\"b\\c/\n\u{e9}\u{1f418}", (try parse(a, "\"a\\\"b\\\\c\\/\\n\\u00e9\\ud83d\\udc18\"")).asString().?);
    try testing.expectError(error.InvalidJson, parse(a, "\"\\ud83d\""));
    try testing.expectError(error.InvalidJson, parse(a, "\"\\udc18\""));
    try testing.expectError(error.InvalidJson, parse(a, "\"a\x01b\""));
    try testing.expectError(error.InvalidJson, parse(a, "\"\xff\""));
    try testing.expectError(error.InvalidJson, parse(a, "\"\\x41\""));
    try testing.expectEqualStrings("\x00", (try parse(a, "\"\\u0000\"")).asString().?);
}

test "json: duplicate keys are kept and the first wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, " {\"k\":1, \"k\":2 ,\"o\":{\"x\":[true,false,null]}} ");
    try testing.expectEqual(@as(i64, 1), v.get("k").?.asInt().?);
    try testing.expectEqual(@as(usize, 3), v.asObject().?.len);
    try testing.expectEqualStrings("{\"k\":1,\"k\":2,\"o\":{\"x\":[true,false,null]}}", try minify(a, v));
    try testing.expectError(error.InvalidJson, parse(a, "{\"a\":1}x"));
    try testing.expectError(error.InvalidJson, parse(a, "{\"a\":1,}"));
    try testing.expectError(error.InvalidJson, parse(a, "[1,]"));
    try testing.expectError(error.InvalidJson, parse(a, ""));
    try testing.expectError(error.InvalidJson, parse(a, "truex"));
}

test "json: JsonBuilder escaping and member order" {
    const gpa = testing.allocator;
    var o = try Object.init(gpa);
    defer o.deinit();
    try o.string("s", "q\"b\\n\n\x01\x7f\u{e9}");
    try o.int("i", -3);
    try o.uint("u", 7);
    try o.boolean("b", true);
    try o.raw("r", "[1]");
    try o.strings("a", &.{ "x", "y" });
    const out = try o.finish();
    defer gpa.free(out);
    try testing.expectEqualStrings("{\"s\":\"q\\\"b\\\\n\\n\\u0001\x7f\u{e9}\",\"i\":-3,\"u\":7,\"b\":true,\"r\":[1],\"a\":[\"x\",\"y\"]}", out);
}
