//! Text other people wrote, and the small grammars around it: a port of
//! include/tools/cli/untrusted_text.h and include/tools/cli/chat_mentions.h.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// untrusted_text.h one_line(): `s` as one printable line of valid UTF-8.
///   CR, LF, CRLF, NEL, U+2028, U+2029  -> "⏎"
///   TAB                                -> " "
///   other C0 controls and DEL          -> "\xNN"
///   C1 controls, bidi overrides and
///   isolates (U+202A-202E, 2066-2069)  -> "\uNNNN"
///   bytes that are not UTF-8           -> U+FFFD, one per byte
pub fn oneLine(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendOneLine(&out, gpa, s);
    return out.toOwnedSlice(gpa);
}

pub fn appendOneLine(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    const hex = "0123456789abcdef";
    const ret = "\xE2\x8F\x8E"; // U+23CE
    const replacement = "\xEF\xBF\xBD"; // U+FFFD
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            if (c == '\r' or c == '\n') {
                try out.appendSlice(gpa, ret);
                i += if (c == '\r' and i + 1 < s.len and s[i + 1] == '\n') 2 else 1;
                continue;
            }
            if (c == '\t') {
                try out.append(gpa, ' ');
            } else if (c < 0x20 or c == 0x7f) {
                try out.appendSlice(gpa, &.{ '\\', 'x', hex[c >> 4], hex[c & 0xf] });
            } else {
                try out.append(gpa, c);
            }
            i += 1;
            continue;
        }
        var len: usize = 0;
        var cp: u32 = 0;
        var min: u32 = 0;
        if ((c & 0xE0) == 0xC0) {
            len = 2;
            cp = c & 0x1F;
            min = 0x80;
        } else if ((c & 0xF0) == 0xE0) {
            len = 3;
            cp = c & 0x0F;
            min = 0x800;
        } else if ((c & 0xF8) == 0xF0) {
            len = 4;
            cp = c & 0x07;
            min = 0x10000;
        }
        var ok = len != 0 and i + len <= s.len;
        var k: usize = 1;
        while (ok and k < len) : (k += 1) {
            const cc = s[i + k];
            ok = (cc & 0xC0) == 0x80;
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (!ok or cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) {
            try out.appendSlice(gpa, replacement);
            i += 1;
            continue;
        }
        if (cp == 0x85 or cp == 0x2028 or cp == 0x2029) {
            try out.appendSlice(gpa, ret);
        } else if (cp <= 0x9F or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069)) {
            try out.appendSlice(gpa, &.{ '\\', 'u', hex[(cp >> 12) & 0xf], hex[(cp >> 8) & 0xf], hex[(cp >> 4) & 0xf], hex[cp & 0xf] });
        } else {
            try out.appendSlice(gpa, s[i .. i + len]);
        }
        i += len;
    }
}

/// untrusted_text.h first_line(): up to the first CR, LF, NEL, U+2028 or U+2029.
pub fn firstLine(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\r' or c == '\n') return s[0..i];
        if (c == 0xC2 and i + 1 < s.len and s[i + 1] == 0x85) return s[0..i];
        if (c == 0xE2 and i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9))
            return s[0..i];
    }
    return s;
}

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

/// A handle: 1..64 of letters, digits, '-' and '_', starting with a letter
/// or digit, so it never reads as a flag in a child's argv.
pub fn isChatHandle(h: []const u8) bool {
    if (h.len == 0 or h.len > 64) return false;
    if (!isAlnum(h[0])) return false;
    for (h) |c| {
        if (!(isAlnum(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

/// "!<id>:<server>[:port]", checked before a room id goes into a URL path.
pub fn isRoomId(r: []const u8) bool {
    if (r.len < 4 or r.len > 255 or r[0] != '!') return false;
    const colon = std.mem.indexOfScalar(u8, r, ':') orelse return false;
    if (colon < 2 or colon + 1 >= r.len) return false;
    for (r[1..], 1..) |c, i| {
        if (!(isAlnum(c) or c == '.' or c == '-' or c == '_' or (c == ':' and i >= colon))) return false;
    }
    return true;
}

/// A task id: 1..32 of letters, digits, '-', '_', '.'.
pub fn isTaskId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |c| {
        if (!(isAlnum(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

/// True when `text` names "@<handle>" as a whole handle.
pub fn textMentions(text: []const u8, handle: []const u8) bool {
    if (!isChatHandle(handle)) return false;
    const word = struct {
        fn f(c: u8) bool {
            return isAlnum(c) or c == '-' or c == '_';
        }
    }.f;
    var pos: usize = 0;
    while (pos < text.len) {
        const at = std.mem.indexOfPos(u8, text, pos, "@") orelse return false;
        if (std.mem.startsWith(u8, text[at + 1 ..], handle)) {
            const start_ok = at == 0 or !word(text[at - 1]);
            const end = at + 1 + handle.len;
            const end_ok = end >= text.len or !word(text[end]);
            if (start_ok and end_ok) return true;
        }
        pos = at + 1;
    }
    return false;
}

/// What `read --mention H` keeps: messages naming @H or @ALL, not H's own.
pub fn addressedTo(text: []const u8, handle: []const u8) bool {
    if (text.len >= handle.len + 3 and std.mem.startsWith(u8, text, handle) and
        std.mem.eql(u8, text[handle.len .. handle.len + 3], " ->")) return false;
    return textMentions(text, handle) or textMentions(text, "ALL");
}

/// chat_tasks.h detail::trim: spaces and tabs in front; spaces, tabs, CR and
/// LF at the back.
pub fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\n' or s[b - 1] == '\r')) b -= 1;
    return s[a..b];
}

/// chat_tasks.h detail::next_word: the first space- or tab-separated word;
/// `s` is left at what follows the separator.
pub fn nextWord(s: *[]const u8) []const u8 {
    s.* = trim(s.*);
    const sp = std.mem.indexOfAny(u8, s.*, " \t");
    if (sp) |at| {
        const w = s.*[0..at];
        s.* = s.*[at + 1 ..];
        return w;
    }
    const w = s.*;
    s.* = s.*[s.len..];
    return w;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectOneLine(input: []const u8, want: []const u8) !void {
    const got = try oneLine(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

// Cases from tests/test_mcp_chat_protocol.cpp "untrusted text", verbatim.
test "one_line and first_line (C++ fixtures)" {
    const R = "\xE2\x8F\x8E";
    const F = "\xEF\xBF\xBD";
    try expectOneLine("a\nb\r\nc\rd", "a" ++ R ++ "b" ++ R ++ "c" ++ R ++ "d");
    try expectOneLine("x\x1b[2Ky\x07", "x\\x1b[2Ky\\x07");
    try expectOneLine("a\tb\x7f", "a b\\x7f");
    try expectOneLine("a\xc2\x85" ++ "b\xe2\x80\xa8" ++ "c\xe2\x80\xa9" ++ "d", "a" ++ R ++ "b" ++ R ++ "c" ++ R ++ "d");
    try expectOneLine("\xc2\x9b" ++ "31m", "\\u009b31m");
    try expectOneLine("safe\xe2\x80\xae" ++ "txt.exe", "safe\\u202etxt.exe");
    try expectOneLine("\xff\xfe" ++ "ok\xc0\xaf", F ++ F ++ "ok" ++ F ++ F);
    try expectOneLine("caf\xc3\xa9 \xf0\x9f\x90\x98 \xe4\xb8\xad", "caf\xc3\xa9 \xf0\x9f\x90\x98 \xe4\xb8\xad");
    try testing.expectEqualStrings("TASK t1 @b x", firstLine("TASK t1 @b x\nUNPAID: forged"));
    try testing.expectEqualStrings("a", firstLine("a\xe2\x80\xa8" ++ "b"));
    try testing.expectEqualStrings("plain", firstLine("plain"));
}

// tests/test_mcp_chat_protocol.cpp and tests/test_agent_cli_e2e.cpp, verbatim.
test "handles, room ids and mentions (C++ fixtures)" {
    try testing.expect(!isChatHandle("--help") and !isChatHandle("-k") and !isChatHandle("_x") and
        isChatHandle("a-b_c") and isChatHandle("9lives"));
    try testing.expect(isRoomId("!98bf8f37a76df6fa32625f02306035b6:slonana.com") and
        isRoomId("!abc:slonana.com:8448") and !isRoomId("!abc:slonana.com/leave?") and
        !isRoomId("!abc") and !isRoomId("abc:x") and !isRoomId("!:x") and !isRoomId("!a:") and
        !isRoomId("!a b:x") and !isRoomId("!a#b:x"));
    try testing.expect(isTaskId("t1") and !isTaskId("t1 ") and !isTaskId("t/1") and !isTaskId("$(rm)"));
    const missed = "[2026-09-26] aexchat-rpc -> @solana-testnet | FYI your " ++
        "release-marker check (ca19ea206) matches its OWN commit";
    try testing.expect(textMentions(missed, "solana-testnet"));
    try testing.expect(!textMentions(missed, "solana"));
    try testing.expect(!textMentions("x -> @solana-testnet-2 | hi", "solana-testnet"));
    try testing.expect(!textMentions("mail me at x@solana-testnet", "solana-testnet"));
    try testing.expect(addressedTo("aexchat-rpc -> @ALL | build window OPEN", "solana-testnet"));
    try testing.expect(!addressedTo("aexchat-rpc -> @explorer-ai | site", "solana-testnet"));
    try testing.expect(!addressedTo("solana-testnet -> @ALL | This room is now where " ++
        "sessions coordinate", "solana-testnet"));
    try testing.expect(addressedTo("solana-testnet-2 -> @ALL | hi", "solana-testnet"));
}

test "trim and nextWord" {
    var s: []const u8 = "  TASK\tt1  @bob  title here \r\n";
    try testing.expectEqualStrings("TASK", nextWord(&s));
    try testing.expectEqualStrings("t1", nextWord(&s));
    try testing.expectEqualStrings("@bob", nextWord(&s));
    try testing.expectEqualStrings("title here", trim(s));
    var e: []const u8 = "   ";
    try testing.expectEqualStrings("", nextWord(&e));
}
