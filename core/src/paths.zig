//! The default state path per OS, under the user's config directory and never
//! the current one (an agent's cwd is usually a work tree).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Os = enum { unix, macos, windows };

pub fn osOf(tag: std.Target.Os.Tag) Os {
    return switch (tag) {
        .windows => .windows,
        .macos, .ios, .tvos, .watchos, .visionos => .macos,
        else => .unix,
    };
}

/// unix:    <home>/.config/agichan/<wallet>.json
/// macos:   <home>/Library/Application Support/agichan/<wallet>.json
/// windows: <%APPDATA%>\agichan\<wallet>.json
/// `base` must be absolute; the caller refuses otherwise.
pub fn statePath(a: Allocator, os: Os, base: []const u8, wallet: []const u8) Allocator.Error![]u8 {
    const file = try std.mem.concat(a, u8, &.{ wallet, ".json" });
    defer a.free(file);
    return switch (os) {
        .unix => std.mem.join(a, "/", &.{ base, ".config", "agichan", file }),
        .macos => std.mem.join(a, "/", &.{ base, "Library", "Application Support", "agichan", file }),
        .windows => std.mem.join(a, "\\", &.{ base, "agichan", file }),
    };
}

pub fn isAbsolute(os: Os, p: []const u8) bool {
    return switch (os) {
        .windows => std.fs.path.isAbsoluteWindows(p),
        else => p.len != 0 and p[0] == '/',
    };
}

/// passwd_uid_is: decimal digits, at most 10, equal to `uid`.
fn uidIs(field: []const u8, uid: u32) bool {
    if (field.len == 0 or field.len > 10) return false;
    var v: u64 = 0;
    for (field) |c| {
        if (c < '0' or c > '9') return false;
        v = v * 10 + (c - '0');
    }
    return v == uid;
}

/// home_in_passwd (passwd_home.h): the first matching line's home, or empty
/// when there is none or it is relative.
pub fn homeInPasswd(text: []const u8, uid: u32) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f: [7][]const u8 = undefined;
        var n: usize = 0;
        var start: usize = 0;
        while (n < f.len) {
            const colon = std.mem.indexOfScalarPos(u8, line, start, ':') orelse {
                f[n] = line[start..];
                n += 1;
                break;
            };
            f[n] = line[start..colon];
            n += 1;
            start = colon + 1;
        }
        if (n < 6 or !uidIs(f[2], uid)) continue;
        if (f[5].len == 0 or f[5][0] != '/') return "";
        return f[5];
    }
    return "";
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "paths: the default state file per OS" {
    const a = testing.allocator;
    const w = "9s6dbCfbWuDxyGjMGnYiMtyL189St4cmJp3vkicYNm45";
    const cases = [_]struct { os: Os, base: []const u8, want: []const u8 }{
        .{ .os = .unix, .base = "/home/x", .want = "/home/x/.config/agichan/" ++ w ++ ".json" },
        .{ .os = .macos, .base = "/Users/x", .want = "/Users/x/Library/Application Support/agichan/" ++ w ++ ".json" },
        .{ .os = .windows, .base = "C:\\Users\\x\\AppData\\Roaming", .want = "C:\\Users\\x\\AppData\\Roaming\\agichan\\" ++ w ++ ".json" },
    };
    for (cases) |c| {
        const p = try statePath(a, c.os, c.base, w);
        defer a.free(p);
        try testing.expectEqualStrings(c.want, p);
        try testing.expect(isAbsolute(c.os, c.base));
    }
    try testing.expect(!isAbsolute(.unix, "home/x"));
    try testing.expect(!isAbsolute(.windows, "AppData"));
}

test "paths: home from passwd, first matching line, never relative" {
    const text = "# comment\n\nroot:x:0:0:root:/root:/bin/bash\nshort:x:1000\n" ++
        "larp:x:1000:1000:Larp:/home/larp:/bin/zsh\nother:x:1000:1000::/elsewhere:/bin/sh\nrel:x:1001:1001::home/rel:/bin/sh\n";
    try testing.expectEqualStrings("/home/larp", homeInPasswd(text, 1000));
    try testing.expectEqualStrings("/root", homeInPasswd(text, 0));
    try testing.expectEqualStrings("", homeInPasswd(text, 1001));
    try testing.expectEqualStrings("", homeInPasswd(text, 4242));
}
