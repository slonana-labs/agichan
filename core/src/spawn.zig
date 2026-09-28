//! Cross-platform process supervision, replacing scripts/lib.sh's setsid/nohup
//! spawn, its /proc-or-ps liveness (crew_alive) and pid-file stop. std-only.
//!
//!   POSIX  : fork + setsid (a session of its own, so SIGHUP to the terminal
//!            spares it), stdin /dev/null, stdout+stderr appended to the log,
//!            then execve. Liveness on Linux reads /proc/<pid>/cmdline and
//!            checks the recorded handle is still in it (a reused pid runs
//!            something else); other POSIX (macOS) has no /proc, so it uses
//!            kill(pid,0) for liveness and cannot check the handle.
//!   Windows: CreateProcessW with DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
//!            std handles redirected the same way. Liveness is OpenProcess +
//!            GetExitCodeProcess == STILL_ACTIVE; the handle is not checked.
//!
//! A stop is by RECORDED pid (never a pattern, never kill(-1)/kill(0)): every
//! path guards pid > 0. The crew's own graceful stop is a `.stop` file the
//! worker reads; terminate() here is the hard stop for a stuck child.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;

pub const Pid = i64;
pub const SpawnError = error{ SpawnFailed, OutOfMemory };

/// This executable's path, for the workers supervisor to re-spawn as a worker.
pub fn selfExe(a: Allocator) Allocator.Error![]const u8 {
    return std.fs.selfExePathAlloc(a) catch a.dupe(u8, "agichan");
}

/// Starts `argv` detached from this process: it outlives the caller, its
/// output appended to `log_path`, its stdin empty. Returns the child pid.
pub fn spawnDetached(a: Allocator, argv: []const []const u8, log_path: []const u8) SpawnError!Pid {
    if (argv.len == 0) return error.SpawnFailed;
    return if (is_windows) spawnWindows(a, argv, log_path) else spawnPosix(a, argv, log_path);
}

/// Is the process `pid` alive AND (on Linux) still running `handle`? A blank
/// `handle` checks liveness only.
pub fn alive(a: Allocator, pid: Pid, handle: []const u8) bool {
    if (pid <= 0) return false;
    if (is_windows) return aliveWindows(pid);
    if (is_linux) {
        const path = std.fmt.allocPrint(a, "/proc/{d}/cmdline", .{pid}) catch return false;
        defer a.free(path);
        const data = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch return false;
        defer a.free(data);
        if (handle.len == 0) return true;
        // cmdline is NUL-separated; the crew's handle is checked as " worker --as <h> ".
        for (data) |*c| {
            if (c.* == 0) c.* = ' ';
        }
        return std.mem.indexOf(u8, data, handle) != null;
    }
    // macOS and other POSIX: liveness only (no /proc to read the argv from).
    posix.kill(@intCast(pid), 0) catch |e| return e == error.PermissionDenied;
    return true;
}

pub const TerminateError = error{ InvalidPid, TerminateFailed };

/// A hard stop of one recorded pid. Never called by the crew's normal stop
/// (that is the `.stop` file); here for a wedged child. pid > 0 is enforced.
pub fn terminate(pid: Pid) TerminateError!void {
    if (pid <= 0) return error.InvalidPid; // never kill(-1) (every process) or kill(0) (our group)
    if (is_windows) return terminateWindows(pid);
    posix.kill(@intCast(pid), posix.SIG.TERM) catch return error.TerminateFailed;
}

// ---- POSIX ----------------------------------------------------------------

fn spawnPosix(a: Allocator, argv: []const []const u8, log_path: []const u8) SpawnError!Pid {
    // Everything the child needs is built BEFORE fork: after it, only syscalls.
    // The child gets its own copy of this arena's memory, so the parent frees
    // the whole arena once fork returns; only an exiting child skips the defer.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = arena.allocator();
    const argvZ = z.allocSentinel(?[*:0]const u8, argv.len, null) catch return error.OutOfMemory;
    for (argv, 0..) |arg, i| argvZ[i] = (z.dupeZ(u8, arg) catch return error.OutOfMemory).ptr;
    const pathZ = z.dupeZ(u8, argv[0]) catch return error.OutOfMemory;
    const logZ = z.dupeZ(u8, log_path) catch return error.OutOfMemory;
    const envp = z.allocSentinel(?[*:0]const u8, std.os.environ.len, null) catch return error.OutOfMemory;
    for (std.os.environ, 0..) |e, i| envp[i] = e;

    const pid = posix.fork() catch return error.SpawnFailed;
    if (pid == 0) {
        childExec(pathZ, argvZ.ptr, envp.ptr, logZ);
        posix.exit(127); // only reached if execve failed
    }
    return @intCast(pid);
}

/// std.posix.setsid mis-handles the raw return on the no-libc path (a std bug),
/// so call it per-OS: the Linux syscall directly, else libc.
fn detachSession() void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.syscall0(.setsid);
    } else if (builtin.link_libc) {
        _ = std.c.setsid();
    }
}

fn childExec(pathZ: [*:0]const u8, argvZ: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, logZ: [*:0]const u8) void {
    detachSession();
    const nullfd = posix.openZ("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch posix.exit(127);
    posix.dup2(nullfd, 0) catch {};
    const logfd = posix.openZ(logZ, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch posix.exit(127);
    posix.dup2(logfd, 1) catch {};
    posix.dup2(logfd, 2) catch {};
    if (nullfd > 2) posix.close(nullfd);
    if (logfd > 2) posix.close(logfd);
    posix.execveZ(pathZ, argvZ, envp) catch {};
}

// ---- Windows --------------------------------------------------------------

const w = std.os.windows;

const DETACHED_PROCESS: w.DWORD = 0x00000008;
const CREATE_NEW_PROCESS_GROUP: w.DWORD = 0x00000200;
const STARTF_USESTDHANDLES: w.DWORD = 0x00000100;
const STILL_ACTIVE: w.DWORD = 259;
const PROCESS_QUERY_LIMITED_INFORMATION: w.DWORD = 0x1000;
const PROCESS_TERMINATE: w.DWORD = 0x0001;
const GENERIC_READ: w.DWORD = 0x80000000;
const FILE_APPEND_DATA: w.DWORD = 0x0004;
const FILE_SHARE_READ: w.DWORD = 0x00000001;
const FILE_SHARE_WRITE: w.DWORD = 0x00000002;
const OPEN_ALWAYS: w.DWORD = 4;
const OPEN_EXISTING: w.DWORD = 3;
const INVALID_HANDLE_VALUE: w.HANDLE = @ptrFromInt(std.math.maxInt(usize));

const SECURITY_ATTRIBUTES = extern struct {
    nLength: w.DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: w.BOOL,
};
const STARTUPINFOW = extern struct {
    cb: w.DWORD,
    lpReserved: ?w.LPWSTR,
    lpDesktop: ?w.LPWSTR,
    lpTitle: ?w.LPWSTR,
    dwX: w.DWORD,
    dwY: w.DWORD,
    dwXSize: w.DWORD,
    dwYSize: w.DWORD,
    dwXCountChars: w.DWORD,
    dwYCountChars: w.DWORD,
    dwFillAttribute: w.DWORD,
    dwFlags: w.DWORD,
    wShowWindow: w.WORD,
    cbReserved2: w.WORD,
    lpReserved2: ?*u8,
    hStdInput: ?w.HANDLE,
    hStdOutput: ?w.HANDLE,
    hStdError: ?w.HANDLE,
};
const PROCESS_INFORMATION = extern struct {
    hProcess: w.HANDLE,
    hThread: w.HANDLE,
    dwProcessId: w.DWORD,
    dwThreadId: w.DWORD,
};

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?w.LPCWSTR,
    lpCommandLine: ?w.LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: w.BOOL,
    dwCreationFlags: w.DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?w.LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateFileW(
    lpFileName: w.LPCWSTR,
    dwDesiredAccess: w.DWORD,
    dwShareMode: w.DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: w.DWORD,
    dwFlagsAndAttributes: w.DWORD,
    hTemplateFile: ?w.HANDLE,
) callconv(.winapi) w.HANDLE;
extern "kernel32" fn OpenProcess(dwDesiredAccess: w.DWORD, bInheritHandle: w.BOOL, dwProcessId: w.DWORD) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn GetExitCodeProcess(hProcess: w.HANDLE, lpExitCode: *w.DWORD) callconv(.winapi) w.BOOL;
extern "kernel32" fn TerminateProcess(hProcess: w.HANDLE, uExitCode: w.UINT) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(hObject: w.HANDLE) callconv(.winapi) w.BOOL;

fn wide(a: Allocator, s: []const u8) SpawnError![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch return error.SpawnFailed;
}

/// MSVC argv quoting: a word with no space/tab/quote is bare; otherwise it is
/// double-quoted, backslashes before a quote (or the close) doubled.
fn windowsCommandLine(a: Allocator, argv: []const []const u8) SpawnError![:0]u16 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (argv, 0..) |arg, i| {
        if (i != 0) out.append(a, ' ') catch return error.OutOfMemory;
        const needs = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
        if (!needs) {
            out.appendSlice(a, arg) catch return error.OutOfMemory;
            continue;
        }
        out.append(a, '"') catch return error.OutOfMemory;
        var backslashes: usize = 0;
        for (arg) |c| {
            if (c == '\\') {
                backslashes += 1;
            } else if (c == '"') {
                for (0..backslashes * 2 + 1) |_| out.append(a, '\\') catch return error.OutOfMemory;
                out.append(a, '"') catch return error.OutOfMemory;
                backslashes = 0;
            } else {
                for (0..backslashes) |_| out.append(a, '\\') catch return error.OutOfMemory;
                out.append(a, c) catch return error.OutOfMemory;
                backslashes = 0;
            }
        }
        for (0..backslashes * 2) |_| out.append(a, '\\') catch return error.OutOfMemory;
        out.append(a, '"') catch return error.OutOfMemory;
    }
    return wide(a, out.items);
}

fn spawnWindows(a: Allocator, argv: []const []const u8, log_path: []const u8) SpawnError!Pid {
    const app = try wide(a, argv[0]);
    const cmd = try windowsCommandLine(a, argv);
    const logw = try wide(a, log_path);

    var inherit: SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = w.TRUE };
    const nul = try wide(a, "NUL");
    const in_h = CreateFileW(nul.ptr, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, null);
    if (in_h == INVALID_HANDLE_VALUE) return error.SpawnFailed;
    defer _ = CloseHandle(in_h);
    const log_h = CreateFileW(logw.ptr, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_ALWAYS, 0, null);
    if (log_h == INVALID_HANDLE_VALUE) return error.SpawnFailed;
    defer _ = CloseHandle(log_h);

    var si: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_h;
    si.hStdOutput = log_h;
    si.hStdError = log_h;
    var pi: PROCESS_INFORMATION = undefined;
    const ok = CreateProcessW(app.ptr, cmd.ptr, null, null, w.TRUE, DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, null, null, &si, &pi);
    if (ok == 0) return error.SpawnFailed;
    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(pi.hProcess);
    return @intCast(pi.dwProcessId);
}

fn aliveWindows(pid: Pid) bool {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, w.FALSE, @intCast(pid)) orelse return false;
    defer _ = CloseHandle(h);
    var code: w.DWORD = 0;
    if (GetExitCodeProcess(h, &code) == 0) return false;
    return code == STILL_ACTIVE;
}

fn terminateWindows(pid: Pid) TerminateError!void {
    const h = OpenProcess(PROCESS_TERMINATE, w.FALSE, @intCast(pid)) orelse return error.TerminateFailed;
    defer _ = CloseHandle(h);
    if (TerminateProcess(h, 1) == 0) return error.TerminateFailed;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "spawn: alive reads this process, rejects a missing pid and a wrong handle" {
    if (is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    const me: Pid = @intCast(std.os.linux.getpid());
    try testing.expect(alive(a, me, "")); // liveness of ourselves
    try testing.expect(!alive(a, 0, "")); // never probes pid 0
    try testing.expect(!alive(a, -1, "")); // never probes the whole group
    try testing.expect(!alive(a, 2147480000, "")); // a pid that is not running
    if (is_linux) {
        try testing.expect(!alive(a, me, "zzz-not-in-our-cmdline-zzz"));
    }
}

test "spawn: terminate refuses pid <= 0 (never kill(-1)/kill(0))" {
    try testing.expectError(error.InvalidPid, terminate(0));
    try testing.expectError(error.InvalidPid, terminate(-1));
}

test "spawn: a detached child runs, is found by its handle, and stops" {
    if (!is_linux) return error.SkipZigTest;
    const a = testing.allocator;
    const sleep_bin = for ([_][]const u8{ "/usr/bin/sleep", "/bin/sleep" }) |p| {
        std.fs.cwd().access(p, .{}) catch continue;
        break p;
    } else return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const log = try std.fs.path.join(a, &.{ dir, "child.log" });
    defer a.free(log);

    // sleep only accepts numeric durations, so the handle we look for is the
    // exe name in its cmdline (the crew looks for `worker --as <h>` the same way).
    const pid = try spawnDetached(a, &.{ sleep_bin, "37" }, log);
    try testing.expect(pid > 0);
    // Give fork+exec a moment to replace the image so the argv is in cmdline.
    var found = false;
    for (0..200) |_| {
        if (alive(a, pid, "sleep")) {
            found = true;
            break;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expect(found);
    try testing.expect(!alive(a, pid, "zzz-different-token-zzz")); // a reused pid runs something else
    try terminate(pid);
    _ = posix.waitpid(@intCast(pid), 0); // reap so /proc/<pid> goes away
    try testing.expect(!alive(a, pid, "sleep"));
}
