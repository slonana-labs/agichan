//! The state file as chat.cpp and file_lock.h keep it: 0600 temp, fsync,
//! rename, in a 0700 directory, one command at a time under "<state>.lock".
//! Windows has no mode bits: files inherit %APPDATA%'s ACL, not narrowed here.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const state_mod = @import("state.zig");
const paths = @import("paths.zig");

const is_windows = builtin.os.tag == .windows;

pub const Loaded = union(enum) {
    ok: state_mod.State,
    err: []const u8,
};

/// Reads the state at `path`; a missing file is a fresh state.
pub fn load(a: Allocator, path: []const u8) Allocator.Error!Loaded {
    const text = std.fs.cwd().readFileAlloc(a, path, 64 << 20) catch |e| switch (e) {
        error.FileNotFound => return .{ .ok = .{} },
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try std.fmt.allocPrint(a, "cannot read state file {s}: {s}", .{ path, @errorName(e) }) },
    };
    const st = state_mod.parse(a, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt => return .{ .err = try std.fmt.allocPrint(a, "state file is corrupt: {s}", .{path}) },
    };
    return .{ .ok = st };
}

/// ensure_state_dir: makes the directory 0700 (chmod beats the umask); an
/// existing one is left alone. Null on success, else why not.
pub fn ensureDir(a: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    const dir = std.fs.path.dirname(path) orelse return null;
    if (std.fs.path.dirname(dir)) |parent| {
        std.fs.cwd().makePath(parent) catch |e|
            return try std.fmt.allocPrint(a, "could not write {s}: {s}", .{ path, @errorName(e) });
    }
    if (is_windows) {
        std.fs.cwd().makePath(dir) catch |e|
            return try std.fmt.allocPrint(a, "could not write {s}: mkdir {s}: {s}", .{ path, dir, @errorName(e) });
        return null;
    }
    posix.mkdir(dir, 0o700) catch |e| switch (e) {
        error.PathAlreadyExists => return null,
        else => return try std.fmt.allocPrint(a, "could not write {s}: mkdir {s}: {s}", .{ path, dir, @errorName(e) }),
    };
    posix.fchmodat(posix.AT.FDCWD, dir, 0o700, 0) catch |e|
        return try std.fmt.allocPrint(a, "could not write {s}: chmod {s}: {s}", .{ path, dir, @errorName(e) });
    return null;
}

/// save_state: null on success, else why it was not written.
pub fn save(a: Allocator, path: []const u8, st: *const state_mod.State) Allocator.Error!?[]const u8 {
    if (try ensureDir(a, path)) |why| return why;
    const text = try state_mod.serialize(a, st);
    defer std.crypto.secureZero(u8, text);
    const tmp = try std.mem.concat(a, u8, &.{ path, ".new" });
    const sys = struct {
        fn msg(al: Allocator, p: []const u8, what: []const u8, t: []const u8, e: anyerror) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(al, "could not write {s}: {s} {s}: {s}", .{ p, what, t, @errorName(e) });
        }
    };
    const file: std.fs.File = if (is_windows)
        std.fs.cwd().createFile(tmp, .{ .truncate = true }) catch |e| return try sys.msg(a, path, "open", tmp, e)
    else blk: {
        const fd = posix.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600) catch |e|
            return try sys.msg(a, path, "open", tmp, e);
        break :blk .{ .handle = fd };
    };
    var closed = false;
    defer if (!closed) file.close();
    // A leftover temp keeps its mode, and one we do not own fails here.
    if (!is_windows) posix.fchmod(file.handle, 0o600) catch |e| return try sys.msg(a, path, "fchmod", tmp, e);
    file.writeAll(text) catch |e| return try sys.msg(a, path, "write", tmp, e);
    file.sync() catch |e| return try sys.msg(a, path, "fsync", tmp, e);
    file.close();
    closed = true;
    std.fs.cwd().rename(tmp, path) catch |e| return try sys.msg(a, path, "rename", tmp, e);
    // Best effort: makes the rename durable, so an advanced ratchet survives.
    if (!is_windows) {
        const dir = std.fs.path.dirname(path) orelse ".";
        if (posix.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0)) |dfd| {
            posix.fsync(dfd) catch {};
            posix.close(dfd);
        } else |_| {}
    }
    return null;
}

/// ExclusiveFileLock: held until release or exit.
pub const Lock = struct {
    file: std.fs.File,

    /// Waits up to `timeout_ms` for the lock on `path` (created 0600).
    pub fn acquire(path: []const u8, timeout_ms: u64) ?Lock {
        const file = if (is_windows)
            std.fs.cwd().createFile(path, .{ .read = true, .truncate = false }) catch return null
        else blk: {
            const fd = posix.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600) catch return null;
            break :blk std.fs.File{ .handle = fd };
        };
        var waited: u64 = 0;
        while (true) {
            const got = tryLockExclusive(file) catch {
                file.close();
                return null;
            };
            if (got) return .{ .file = file };
            if (waited >= timeout_ms) {
                file.close();
                return null;
            }
            std.Thread.sleep(20 * std.time.ns_per_ms);
            waited += 20;
        }
    }

    pub fn release(l: *Lock) void {
        l.file.unlock();
        l.file.close();
    }
};

/// File.tryLock(.exclusive), written out for Windows, where std 0.15.2's does
/// not compile; same byte range as File.unlock.
fn tryLockExclusive(file: std.fs.File) !bool {
    if (!is_windows) return file.tryLock(.exclusive);
    const windows = std.os.windows;
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    const off: windows.LARGE_INTEGER = 0;
    const len: windows.LARGE_INTEGER = 1;
    windows.LockFile(file.handle, null, null, null, &io_status_block, &off, &len, null, windows.TRUE, windows.TRUE) catch |e| switch (e) {
        error.WouldBlock => return false,
        else => |x| return x,
    };
    return true;
}

pub const DefaultPath = union(enum) {
    ok: []const u8,
    err: []const u8,
};

/// The default state path. Home from the password database, never $HOME:
/// /etc/passwd on Linux (as the C++), getpwuid_r on macOS; %APPDATA% on Windows.
pub fn defaultPath(a: Allocator, wallet: []const u8) Allocator.Error!DefaultPath {
    const os = comptime paths.osOf(builtin.os.tag);
    const base: []const u8 = switch (os) {
        .windows => std.process.getEnvVarOwned(a, "APPDATA") catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => "",
        },
        .macos => macHome(a) catch "",
        .unix => blk: {
            const text = std.fs.cwd().readFileAlloc(a, "/etc/passwd", 16 << 20) catch break :blk "";
            break :blk paths.homeInPasswd(text, posix.getuid());
        },
    };
    if (!paths.isAbsolute(os, base)) {
        const where = switch (os) {
            .windows => "no absolute %APPDATA%",
            else => try std.fmt.allocPrint(a, "no home for uid {d} in the password database", .{posix.getuid()}),
        };
        return .{ .err = try std.fmt.allocPrint(a, "{s}, and chat keys never go in the current directory; pass --state PATH", .{where}) };
    }
    return .{ .ok = try paths.statePath(a, os, base, wallet) };
}

fn macHome(a: Allocator) ![]const u8 {
    var pwd: std.c.passwd = undefined;
    var buf: [16384]u8 = undefined;
    var result: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(std.c.getuid(), &pwd, &buf, buf.len, &result) != 0) return error.NoHome;
    const r = result orelse return error.NoHome;
    const dir = r.dir orelse return error.NoHome;
    return a.dupe(u8, std.mem.sliceTo(dir, 0));
}
