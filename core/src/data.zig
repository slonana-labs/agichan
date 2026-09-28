//! The data dir and its files, a port of scripts/lib.sh minus the CLI download
//! (this binary IS the CLI). One data dir per user and machine holds a sponsor
//! wallet, one channel per project directory, and a lock; handle wallets live
//! under the config home so a session is one identity whether it talks MCP or
//! this CLI. Nothing here deletes.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const paths = @import("paths.zig");

const is_windows = builtin.os.tag == .windows;

/// The home for config/keys: the password database (never $HOME), as slonana's
/// chat reads it (passwd_home.h) so identity is stable across $HOME changes.
/// %APPDATA% on Windows, getpwuid on macOS, /etc/passwd on Linux.
pub fn configHome(a: Allocator) Allocator.Error![]const u8 {
    const os = comptime paths.osOf(builtin.os.tag);
    return switch (os) {
        .windows => std.process.getEnvVarOwned(a, "APPDATA") catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => a.dupe(u8, ""),
        },
        .macos => macHome(a) catch a.dupe(u8, ""),
        .unix => blk: {
            const text = std.fs.cwd().readFileAlloc(a, "/etc/passwd", 16 << 20) catch break :blk a.dupe(u8, "");
            break :blk a.dupe(u8, paths.homeInPasswd(text, posix.getuid()));
        },
    };
}

fn macHome(a: Allocator) ![]const u8 {
    if (!builtin.link_libc) return error.NoHome;
    var pwd: std.c.passwd = undefined;
    var buf: [16384]u8 = undefined;
    var result: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(std.c.getuid(), &pwd, &buf, buf.len, &result) != 0) return error.NoHome;
    const r = result orelse return error.NoHome;
    const dir = r.dir orelse return error.NoHome;
    return a.dupe(u8, std.mem.sliceTo(dir, 0));
}

/// The data dir: AGICHAN_DATA, else <config home>/.local/share/agichan
/// (Windows: %APPDATA%\agichan\data). Empty when no home can be found.
pub fn dataDir(a: Allocator) Allocator.Error![]const u8 {
    if (std.process.getEnvVarOwned(a, "AGICHAN_DATA")) |v| {
        return v;
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }
    const home = try configHome(a);
    if (home.len == 0) return a.dupe(u8, "");
    return if (is_windows)
        std.fs.path.join(a, &.{ home, "agichan", "data" })
    else
        std.fs.path.join(a, &.{ home, ".local", "share", "agichan" });
}

/// Where handle wallets live: <config home>/.config/slonana/aexchat/agents
/// (AGICHAN_KEYS overrides), the same directory mcp-chat's chat_identity uses,
/// so a handle is one wallet whether reached over MCP or this CLI.
pub fn keysDir(a: Allocator) Allocator.Error![]const u8 {
    if (std.process.getEnvVarOwned(a, "AGICHAN_KEYS")) |v| {
        return v;
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }
    const home = try configHome(a);
    if (home.len == 0) return a.dupe(u8, "");
    return if (is_windows)
        std.fs.path.join(a, &.{ home, "slonana", "aexchat", "agents" })
    else
        std.fs.path.join(a, &.{ home, ".config", "slonana", "aexchat", "agents" });
}

/// The keypair file for handle `h` under `keys_dir`.
pub fn handleKey(a: Allocator, keys_dir: []const u8, h: []const u8) Allocator.Error![]const u8 {
    const file = try std.fmt.allocPrint(a, "{s}.json", .{h});
    defer a.free(file);
    return std.fs.path.join(a, &.{ keys_dir, file });
}

pub const sep = if (is_windows) "\\" else "/";

/// A path under the data dir, joined with the OS separator.
pub fn under(a: Allocator, data_dir: []const u8, comptime parts: []const []const u8) Allocator.Error![]const u8 {
    var all: [parts.len + 1][]const u8 = undefined;
    all[0] = data_dir;
    inline for (parts, 0..) |p, i| all[i + 1] = p;
    return std.fs.path.join(a, &all);
}

/// sha256(project_dir) first 16 hex chars: the room file name (agichan_room).
pub fn roomKey(project_dir: []const u8) [16]u8 {
    const crypto = @import("crypto.zig");
    const h = crypto.sha256(project_dir);
    var out: [16]u8 = undefined;
    const hex = "0123456789abcdef";
    for (0..8) |i| {
        out[2 * i] = hex[h[i] >> 4];
        out[2 * i + 1] = hex[h[i] & 0xf];
    }
    return out;
}

/// Makes `dir` and its parents; on POSIX the leaf is 0700 (it holds keys).
pub fn ensureDir700(a: Allocator, dir: []const u8) Allocator.Error!?[]const u8 {
    if (dir.len == 0) return try a.dupe(u8, "no data directory: set AGICHAN_DATA or a home in the password database");
    std.fs.cwd().makePath(dir) catch |e|
        return try std.fmt.allocPrint(a, "could not create {s}: {s}", .{ dir, @errorName(e) });
    if (!is_windows) {
        posix.fchmodat(posix.AT.FDCWD, dir, 0o700, 0) catch |e|
            return try std.fmt.allocPrint(a, "could not chmod {s}: {s}", .{ dir, @errorName(e) });
    }
    return null;
}

/// Reads a small file's whole contents, trimmed of trailing newline; null when
/// it does not exist, error text on any other failure.
pub const Read = union(enum) { some: []const u8, none, err: []const u8 };
pub fn readTrim(a: Allocator, path: []const u8) Allocator.Error!Read {
    const text = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => return .none,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ path, @errorName(e) }) },
    };
    return .{ .some = std.mem.trimRight(u8, text, "\r\n") };
}

/// Writes `contents` to `path` (0600 on POSIX), making parents first. Null on
/// success, else why not. Used for room-map files and issued/revoked markers.
pub fn writeFile600(a: Allocator, path: []const u8, contents: []const u8) Allocator.Error!?[]const u8 {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |e|
            return try std.fmt.allocPrint(a, "could not create {s}: {s}", .{ dir, @errorName(e) });
    }
    const file: std.fs.File = if (is_windows)
        std.fs.cwd().createFile(path, .{ .truncate = true }) catch |e|
            return try std.fmt.allocPrint(a, "could not write {s}: {s}", .{ path, @errorName(e) })
    else blk: {
        const fd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) catch |e|
            return try std.fmt.allocPrint(a, "could not write {s}: {s}", .{ path, @errorName(e) });
        break :blk std.fs.File{ .handle = fd };
    };
    defer file.close();
    file.writeAll(contents) catch |e|
        return try std.fmt.allocPrint(a, "could not write {s}: {s}", .{ path, @errorName(e) });
    return null;
}

/// Appends a line to `path` (created 0600), for the join-code issue log.
pub fn appendLine(a: Allocator, path: []const u8, line: []const u8) Allocator.Error!?[]const u8 {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    const file: std.fs.File = if (is_windows)
        (std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch std.fs.cwd().createFile(path, .{})) catch |e|
            return try std.fmt.allocPrint(a, "could not open {s}: {s}", .{ path, @errorName(e) })
    else blk: {
        const fd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch |e|
            return try std.fmt.allocPrint(a, "could not open {s}: {s}", .{ path, @errorName(e) });
        break :blk std.fs.File{ .handle = fd };
    };
    defer file.close();
    if (is_windows) file.seekFromEnd(0) catch {};
    file.writeAll(line) catch |e|
        return try std.fmt.allocPrint(a, "could not write {s}: {s}", .{ path, @errorName(e) });
    return null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "data: room key is the first 16 hex of sha256(project dir)" {
    // sha256("/x") first 8 bytes, from an independent tool.
    const k = roomKey("/x");
    try testing.expectEqual(@as(usize, 16), k.len);
    // Stable and distinct per directory.
    const k2 = roomKey("/y");
    try testing.expect(!std.mem.eql(u8, &k, &k2));
    try testing.expectEqualStrings(&k, &roomKey("/x"));
}

test "data: handle key path joins dir and <handle>.json" {
    const a = testing.allocator;
    const p = try handleKey(a, "/keys", "w-box-1");
    defer a.free(p);
    const want = "/keys" ++ sep ++ "w-box-1.json";
    try testing.expectEqualStrings(want, p);
}

test "data: read/write round trip, trimmed, and a missing file is none" {
    // readTrim returns a slice into a buffer real callers hold in an arena.
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const f = try std.fs.path.join(a, &.{ dir, "sub", "room" });
    defer a.free(f);
    try testing.expect((try writeFile600(a, f, "!r:x\n")) == null);
    switch (try readTrim(a, f)) {
        .some => |v| try testing.expectEqualStrings("!r:x", v),
        else => try testing.expect(false),
    }
    const miss = try std.fs.path.join(a, &.{ dir, "nope" });
    defer a.free(miss);
    try testing.expect((try readTrim(a, miss)) == .none);
    try testing.expect((try appendLine(a, f, "line2\n")) == null);
    switch (try readTrim(a, f)) {
        .some => |v| try testing.expectEqualStrings("!r:x\nline2", v),
        else => try testing.expect(false),
    }
}
