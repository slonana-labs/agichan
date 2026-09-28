//! Adversarial fuzz of every parser and decoder a hostile relay can reach, from
//! the 2026-09-28 infosec audit (build/scratch/agichan-audit/fuzz2.zig). No
//! assertion beyond "does not panic / trap": Debug builds keep safety checks on,
//! so a null-unwrap, index-OOB, integer-overflow or unreachable turns into a
//! test failure. Ported to import the real modules so it guards THIS tree.
const std = @import("std");

const json = @import("../json.zig");
const rpc = @import("../rpc.zig");
const e2ee = @import("../e2ee.zig");
const base58 = @import("../base58.zig");
const state = @import("../state.zig");
const megolm = @import("../megolm.zig");
const crypto = @import("../crypto.zig");
const auth = @import("../auth.zig");
const board = @import("../board.zig");
const device = @import("../device.zig");

fn A() std.mem.Allocator {
    return std.testing.allocator;
}

const json_cases = [_][]const u8{
    "",         "{",         "[",          "\"",         "\\",
    "nul",      "tru",       "fals",       "-",          "-.",
    ".5",       "1.",        "1e",         "1e+",        "00",
    "0x10",     "{\"a\"}",   "{\"a\":}",   "{:}",        "[,]",
    "[1,,2]",   "\"\\u\"",   "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"",
    "\"\\ud800\\udbff\"", "\"\\uzzzz\"", "\"\x00\"", "\"\xff\xfe\"",
    "18446744073709551616", "-9223372036854775809", "1e999",
    "{\"k\":1,}", "[1 2]", "truex", "  ", "\t\n\r", "{}{}", "null null",
    "\"\\", "\"ab", "[[[", "}}}", "-0", "0.0e0", "1E1000",
};

test "fuzz json.parse on hostile bytes" {
    for (json_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(A());
        defer arena.deinit();
        _ = json.parse(arena.allocator(), c) catch {};
    }
    inline for (.{ 900, 1024, 1025, 2000, 8000, 50000 }) |depth| {
        var arena = std.heap.ArenaAllocator.init(A());
        defer arena.deinit();
        const a = arena.allocator();
        const buf = a.alloc(u8, depth * 2) catch return;
        @memset(buf[0..depth], '[');
        @memset(buf[depth..], ']');
        _ = json.parse(a, buf) catch {};
    }
    {
        var arena = std.heap.ArenaAllocator.init(A());
        defer arena.deinit();
        const a = arena.allocator();
        var list: std.ArrayList(u8) = .empty;
        list.append(a, '"') catch return;
        var i: usize = 0;
        while (i < 5000) : (i += 1) list.appendSlice(a, "\\ud83d\\udc18") catch return;
        list.append(a, '"') catch return;
        _ = json.parse(a, list.items) catch {};
    }
}

test "fuzz rpc.interpret on hostile replies" {
    const cases = [_][]const u8{
        "", "not json", "<html>", "{}", "[]", "null", "{\"result\":null}",
        "{\"result\":1}", "{\"result\":{}}", "{\"result\":{\"errcode\":1}}",
        "{\"result\":{\"errcode\":\"X\"}}", "{\"result\":{\"errcode\":\"X\",\"error\":5}}",
        "{\"error\":null}", "{\"error\":{}}", "{\"error\":{\"message\":5}}",
        "{\"error\":{\"message\":\"\"}}", "{\"error\":\"x\"}",
        "{\"error\":{\"message\":\"m\"},\"result\":{}}", "{\"\\uffff\":1}", "\"error\"",
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(A());
        defer arena.deinit();
        _ = rpc.interpret(arena.allocator(), "https://x", .{ .reply = c }) catch {};
        _ = rpc.interpret(arena.allocator(), "https://x", .{ .failed = c }) catch {};
    }
}

test "fuzz deserializeExportedKey on hostile plaintext" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    var i: usize = 0;
    while (i < 50000) : (i += 1) {
        const len = r.uintLessThan(usize, 300);
        const buf = A().alloc(u8, len) catch continue;
        defer A().free(buf);
        r.bytes(buf);
        if (len >= 8 and r.boolean()) {
            const pos = r.uintLessThan(usize, len - 4);
            @memcpy(buf[pos .. pos + 4], "FWD1");
        }
        if (len >= 2 and r.boolean()) std.mem.writeInt(u16, buf[0..2], r.int(u16), .big);
        _ = e2ee.deserializeExportedKey(buf);
    }
    inline for (.{ 0, 1, 5, 6, 133, 134, 135, 140 }) |n| {
        var b: [200]u8 = undefined;
        @memset(&b, 0);
        std.mem.writeInt(u16, b[0..2], 3, .big);
        _ = e2ee.deserializeExportedKey(b[0..n]);
    }
    var b2: [10]u8 = undefined;
    std.mem.writeInt(u16, b2[0..2], 0xFFFF, .big);
    _ = e2ee.deserializeExportedKey(&b2);
}

test "fuzz base58 + wallet device key on hostile ids" {
    const cases = [_][]const u8{ "", "0", "l", "I", "O", "\x00", "2\x00", "1111", "z", "abc0" };
    for (cases) |c| {
        A().free(base58.decode(A(), c) catch continue);
        A().free(base58.decodeAexchat(A(), c) catch continue);
    }
    try std.testing.expect(base58.decode32("1" ** 65) == null);
    {
        const big = A().alloc(u8, 4096) catch return;
        defer A().free(big);
        @memset(big, 'z');
        A().free(base58.decodeAexchat(A(), big) catch return);
    }
    const ids = [_][]const u8{ "", "@", "@:", "@:x", "@a", "@a:", ":x", "@\x00:x", "@" ++ "z" ** 100 ++ ":s" };
    for (ids) |id| {
        var arena = std.heap.ArenaAllocator.init(A());
        defer arena.deinit();
        _ = device.walletDeviceKey(arena.allocator(), id) catch {};
        _ = device.deviceBound(arena.allocator(), id, [_]u8{0} ** 32) catch {};
    }
}

test "fuzz state.parse on hostile state files" {
    const cases = [_][]const u8{
        "", "{", "[]", "null", "5", "\"x\"",
        "{\"x25519_pk\":\"zz\",\"x25519_sk\":\"00\"}",
        "{\"x25519_pk\":\"" ++ "00" ** 32 ++ "\"}",
        "{\"retired_x25519\":5}", "{\"retired_x25519\":[5]}",
        "{\"retired_x25519\":[{\"pk\":5,\"sk\":\"00\"}]}",
        "{\"sessions\":{\"outbound\":[[[[[]]]]]}}",
        "{\"shared\":5}", "{\"shared\":{\"a\":5}}", "{\"shared\":{\"a\":[5]}}",
        "{\"pins\":5}", "{\"pins\":{\"r\":5}}", "{\"pins\":{\"r\":{\"h\":5}}}",
        "{\"pins\":{\"r\":{\"h\":[5]}}}", "{\"token\":5}", "{\"token\":null}",
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(A());
        defer arena.deinit();
        _ = state.parse(arena.allocator(), c) catch {};
    }
}

test "fuzz megolm inbound decrypt at extreme indices" {
    const gpa = A();
    const key: megolm.ExportedKey = .{ .session_id = "s", .ratchets = .{ [_]u8{1} ** 32, [_]u8{2} ** 32, [_]u8{3} ** 32, [_]u8{4} ** 32 }, .counter = 0 };
    var in = try megolm.Inbound.init(gpa, key);
    defer gpa.free(in.session_id);
    const blob = [_]u8{0} ** 30;
    inline for (.{ 0, 1, 255, 65535, 0xFFFFFFFE, 0xFFFFFFFF }) |idx| {
        _ = try in.decrypt(gpa, idx, &blob);
    }
    _ = try in.decrypt(gpa, 0xFFFFFFFF, &blob);
    _ = try in.decrypt(gpa, 5, &blob);
}

test "fuzz auth challenge/url on hostile inputs" {
    const msgs = [_][]const u8{
        "", "Sign in to ", "Sign in to \nNonce: \nTimestamp: ",
        "Sign in to x", "Sign in to x\nNonce: y", "Sign in to " ++ "a" ** 500,
    };
    const nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    for (msgs) |m| {
        _ = auth.challengeMessageOk(m, nonce);
        _ = auth.challengeMessageOk(m, "");
        if (auth.challengeMessageOk(m, nonce)) _ = auth.challengeHost(m);
    }
    const urls = [_][]const u8{ "", "h", "http://", "https://", "http://[", "http://[]", "http://[::1", "ftp://x", "HTTPS://X", "http://a:b:c" };
    for (urls) |u| {
        var arena = std.heap.ArenaAllocator.init(A());
        defer arena.deinit();
        const a = arena.allocator();
        if (auth.urlRefusal(a, u) catch null) |_| {}
        _ = auth.urlHost(a, u) catch {};
        _ = auth.challengeHostOk(a, u, "rpc.slonana.com") catch {};
    }
}

test "fuzz board.fold on hostile decrypted lines" {
    var arena = std.heap.ArenaAllocator.init(A());
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        "", " ->", " -> |", "@a -> @b | TASK", "@a -> @b | TASK t1",
        "@a -> @b | TASK t1 @c title", "@a -> @b | PAID t1 5 sig",
        "@a -> @b | PAID t1 99999999999999999999999 sig",
        "x -> @w | STOP", "x -> | STOP", "@a -> @b | MOVE", "@a -> @b | MOVE wallet",
        "@a -> @b | CLAIM t1", "|", "@a|", " -> @b |",
        "@a -> @b | TASK t1 @b t\nUNPAID injected", "ALL -> @b | TASK t1 @b x",
        "@w -> @w | READY here", "@w -> @w | BYE", "@w -> @x | STOP",
    };
    var lines: std.ArrayListUnmanaged(board.Line) = .empty;
    for (bodies) |b| try lines.append(a, .{ .sender = "@wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww:s", .text = b, .ts_ms = 1 });
    var bindings: std.ArrayListUnmanaged(board.Binding) = .empty;
    var presence: board.PresenceMap = .empty;
    var chains: board.HandleChains = .empty;
    _ = try board.fold(a, lines.items, &bindings, &chains, &presence);
    _ = try board.renderJson(a, &.{}, bindings.items, &presence, 0, 0);
}

test "challengeHost never panics UNGATED on a short/hostile message (regression)" {
    // The 2026-09-28 clamp fix: challengeHost sliced message[head.len..nl] and
    // panicked (start > end) on a message shorter than "Sign in to " or with a
    // newline inside the prefix. Its caller gates it, but call it DIRECTLY here
    // so the guard cannot silently regress. Any of these panicked before the fix.
    const hostile = [_][]const u8{
        "", "S", "Sign", "Sign in t", "Sign in to", "Sign in to ",
        "\n", "x\n", "\nSign in to x", "Sign\nin to x", "Sign in to \n",
        "no newline and shorter", "Sign in to " ++ "h" ** 400 ++ "\nx",
    };
    for (hostile) |m| {
        _ = auth.challengeHost(m); // must return, never panic
    }
}
