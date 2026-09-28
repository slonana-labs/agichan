//! Temporary cloud machines for a crew: `vm script` prints a cloud-init/user-
//! data startup script that makes any fresh Ubuntu/Debian VM join one channel
//! and run workers, then stop after N hours. A port of scripts/vm.sh's
//! vm_script. `vm order`/`list`/`release` drive the AEA rental, which does not
//! take temporary machines yet (memory: waits on the rental service), so order
//! reports that, as the bash does. The generated script is data for a remote
//! machine, not something this process runs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const crew = @import("crew.zig");
const data = @import("data.zig");
const json = @import("json.zig");

fn validRepo(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "@:/._~+-", c) != null)) return false;
    }
    return true;
}
fn validEnvName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphabetic(c) or (c >= '0' and c <= '9') or c == '_') or std.ascii.isLower(c)) return false;
    }
    return true;
}
fn validCode(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "agc1-") or s.len == 5) return false;
    for (s[5..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '=' or c == '-')) return false;
    }
    return true;
}

pub const ScriptArgs = struct {
    code: []const u8,
    workers: u64,
    mgr: []const u8,
    agent: []const u8,
    repo: []const u8,
    hours: u64,
    push: bool,
    env_names: []const []const u8 = &.{},
};

pub const Result = union(enum) { ok: []const u8, err: []const u8 };

/// The startup script, or why the inputs were refused (every value is checked
/// here first: it runs as root on the new machine).
pub fn script(a: Allocator, args: ScriptArgs) Allocator.Error!Result {
    if (!validCode(args.code)) return .{ .err = "not a join code" };
    if (args.workers < 1 or args.workers > 999) return .{ .err = "--workers takes 1 to 999" };
    if (!crew.validHandle(args.mgr)) return .{ .err = "--manager takes a handle" };
    if (!(std.mem.eql(u8, args.agent, "claude") or std.mem.eql(u8, args.agent, "codex") or std.mem.eql(u8, args.agent, "opencode")))
        return .{ .err = "a VM runs claude, codex or opencode (another agent: bake it into your image)" };
    if (!validRepo(args.repo)) return .{ .err = "--repo takes a git URL" };
    if (args.hours < 1 or args.hours > 9999) return .{ .err = "--hours takes 1 to 9999" };

    // Validate and read every env value BEFORE building the script, so a refusal
    // never leaks a half-built buffer (the script is built once, all-or-nothing).
    const Pair = struct { name: []const u8, quoted: []const u8 };
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    for (args.env_names) |name| {
        if (!validEnvName(name)) return .{ .err = try std.fmt.allocPrint(a, "--env takes a variable name, not {s}", .{name}) };
        const v = std.process.getEnvVarOwned(a, name) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .err = try std.fmt.allocPrint(a, "${s} is empty here; nothing to pass", .{name}) },
        };
        if (v.len == 0) return .{ .err = try std.fmt.allocPrint(a, "${s} is empty here; nothing to pass", .{name}) };
        if (std.mem.indexOfScalar(u8, v, '\n') != null) return .{ .err = try std.fmt.allocPrint(a, "${s} holds a line break; not passed", .{name}) };
        try pairs.append(a, .{ .name = name, .quoted = try std.mem.replaceOwned(u8, a, v, "'", "'\\''") });
    }

    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(a);
    const pushflag: []const u8 = if (args.push) " --push" else "";
    try s.print(a,
        \\#!/bin/bash
        \\# agichan crew machine, from `agichan vm script`: installs the {s} CLI and
        \\# agichan, joins one channel with a one-time code, starts {d} worker(s) for
        \\# @{s}, and asks them to stop after {d} hour(s). The machine itself keeps
        \\# running (and billing) until whoever ordered it deletes it.
        \\# Runs as root: cloud-init user data, or by hand with sudo.
        \\set -u
        \\log() {{ echo "agichan-vm: $*" >>/var/log/agichan-vm.log; echo "agichan-vm: $*"; }}
        \\export DEBIAN_FRONTEND=noninteractive
        \\if command -v apt-get >/dev/null 2>&1; then
        \\  apt-get update -qq && apt-get install -y -qq curl git jq openssl gzip ca-certificates util-linux >/dev/null ||
        \\    log "apt-get failed; continuing with what is installed"
        \\fi
        \\id agent >/dev/null 2>&1 || useradd -m -s /bin/bash agent || {{ log "could not create the agent user"; exit 1; }}
        \\home=$(getent passwd agent | cut -d: -f6)
        \\[ -n "$home" ] || {{ log "no home for the agent user"; exit 1; }}
        \\
    , .{ args.agent, args.workers, args.mgr, args.hours });

    if (std.mem.eql(u8, args.agent, "claude")) {
        try s.appendSlice(a, "su - agent -c 'curl -fsSL https://claude.ai/install.sh | bash' || log 'claude install failed'\n");
    } else if (std.mem.eql(u8, args.agent, "opencode")) {
        try s.appendSlice(a, "su - agent -c 'curl -fsSL https://opencode.ai/install | bash' || log 'opencode install failed'\n");
    } else { // codex
        try s.appendSlice(a,
            \\if ! command -v npm >/dev/null 2>&1; then
            \\  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null && apt-get install -y -qq nodejs >/dev/null
            \\fi
            \\npm install -g @openai/codex >/dev/null 2>&1 || log 'codex install failed'
            \\
        );
    }

    try s.appendSlice(a, "# Keys the agents need, readable by the agent user only.\n");
    try s.appendSlice(a, "install -m 600 -o agent -g agent /dev/null \"$home/.agichan-env\"\n");
    if (pairs.items.len != 0) {
        try s.appendSlice(a, "cat >>\"$home/.agichan-env\" <<'AGICHAN_ENV_EOF'\n");
        for (pairs.items) |p| try s.print(a, "export {s}='{s}'\n", .{ p.name, p.quoted });
        try s.appendSlice(a, "AGICHAN_ENV_EOF\n");
    }
    try s.print(a,
        \\su - agent -c '. ~/.agichan-env; mkdir -p ~/work && cd ~/work && curl -fsSL https://raw.githubusercontent.com/slonana-labs/agichan/main/install.sh | bash -s -- --join {s} --dir ~/work --workers {d} --manager {s} --agent {s} --repo {s}{s}' ||
        \\  {{ log "joining the crew failed"; exit 1; }}
        \\systemd-run --on-active={d}h --unit agichan-stop su - agent -c '~/.local/bin/agichan workers --stop' >/dev/null ||
        \\  log "no systemd-run: stop the workers with: su - agent -c '~/.local/bin/agichan workers --stop'"
        \\log "crew machine up: {d} worker(s) for @{s}, stopping after {d} h"
        \\
    , .{ args.code, args.workers, args.mgr, args.agent, args.repo, pushflag, args.hours, args.workers, args.mgr, args.hours });
    return .{ .ok = try s.toOwnedSlice(a) };
}

/// vm list: the recorded orders in the data dir.
pub fn list(a: Allocator, data_dir: []const u8, out: *std.Io.Writer) crew.Error!u8 {
    const dir_path = try data.under(a, data_dir, &.{"vms"});
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const p = try std.fs.path.join(a, &.{ dir_path, entry.name });
        const text = switch (try data.readTrim(a, p)) {
            .some => |v| v,
            else => continue,
        };
        const doc = json.parse(a, text) catch continue;
        try out.print("{s}  {s}  {s}  until {s}\n", .{
            json.getString(doc, "order") orelse "?",
            json.getString(doc, "status") orelse "?",
            json.getString(doc, "ip") orelse "-",
            json.getString(doc, "expires_at") orelse "?",
        });
    }
    return 0;
}

/// vm order / release both need the AEA rental to accept temporary machines,
/// which it does not yet (a signed transfer + the rental API). Report that,
/// as the bash does, and point at `vm script`, which works today.
pub const rental_pending_msg =
    "the AEA rental does not take temporary machines yet. Meanwhile " ++
    "`agichan vm script ...` prints the startup script for any provider.";

// ---------------------------------------------------------------------------

const testing = std.testing;

test "vm: the script installs, joins with the code and workers, schedules the stop" {
    const a = testing.allocator;
    const r = try script(a, .{ .code = "agc1-YWJj_ZGVm-=", .workers = 3, .mgr = "lead", .agent = "claude", .repo = "https://github.com/o/r.git", .hours = 4, .push = true });
    const s = switch (r) {
        .ok => |x| x,
        .err => |e| {
            std.debug.print("script err: {s}\n", .{e});
            return error.Unexpected;
        },
    };
    defer a.free(s);
    try testing.expect(std.mem.startsWith(u8, s, "#!/bin/bash\n"));
    try testing.expect(std.mem.indexOf(u8, s, "useradd -m -s /bin/bash agent") != null);
    try testing.expect(std.mem.indexOf(u8, s, "claude.ai/install.sh") != null);
    try testing.expect(std.mem.indexOf(u8, s, "--join agc1-YWJj_ZGVm-= --dir ~/work --workers 3 --manager lead --agent claude --repo https://github.com/o/r.git --push'") != null);
    try testing.expect(std.mem.indexOf(u8, s, "systemd-run --on-active=4h") != null);
    try testing.expect(std.mem.indexOf(u8, s, "crew machine up: 3 worker(s) for @lead, stopping after 4 h") != null);
}

test "vm: each agent uses its own installer" {
    const a = testing.allocator;
    for ([_]struct { agent: []const u8, needle: []const u8 }{
        .{ .agent = "codex", .needle = "npm install -g @openai/codex" },
        .{ .agent = "opencode", .needle = "opencode.ai/install" },
        .{ .agent = "claude", .needle = "claude.ai/install.sh" },
    }) |c| {
        const r = try script(a, .{ .code = "agc1-x", .workers = 1, .mgr = "lead", .agent = c.agent, .repo = "r", .hours = 1, .push = false });
        const s = r.ok;
        defer a.free(s);
        try testing.expect(std.mem.indexOf(u8, s, c.needle) != null);
    }
}

test "vm: values that would reach a root shell are refused" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator); // some refusals allocate a message
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expect((try script(a, .{ .code = "agc1-$(x)", .workers = 1, .mgr = "lead", .agent = "claude", .repo = "r", .hours = 1, .push = false })) == .err);
    try testing.expect((try script(a, .{ .code = "agc1-x", .workers = 1, .mgr = "lead", .agent = "bash -c x", .repo = "r", .hours = 1, .push = false })) == .err);
    try testing.expect((try script(a, .{ .code = "agc1-x", .workers = 1, .mgr = "lead", .agent = "codex", .repo = "r;x", .hours = 1, .push = false })) == .err);
    try testing.expect((try script(a, .{ .code = "agc1-x", .workers = 1, .mgr = "le ad", .agent = "codex", .repo = "r", .hours = 1, .push = false })) == .err);
    try testing.expect((try script(a, .{ .code = "agc1-x", .workers = 1000, .mgr = "lead", .agent = "claude", .repo = "r", .hours = 1, .push = false })) == .err);
    // a lowercase env name is refused
    try testing.expect((try script(a, .{ .code = "agc1-x", .workers = 1, .mgr = "lead", .agent = "codex", .repo = "r", .hours = 1, .push = false, .env_names = &.{"lower_name"} })) == .err);
}

test "vm: a key reaches the env file with quotes intact" {
    const a = testing.allocator;
    // The test controls its own env var.
    const key = "VM_TEST_KEY_ZIG";
    var buf: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{s}", .{key}) catch unreachable;
    // Set via std C setenv where available; otherwise skip the value check.
    if (setenvOk(key, "sk-it's-secret")) {
        const r = try script(a, .{ .code = "agc1-x", .workers = 1, .mgr = "lead", .agent = "claude", .repo = "r", .hours = 1, .push = false, .env_names = &.{key} });
        const s = r.ok;
        defer a.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "install -m 600 -o agent -g agent") != null);
        try testing.expect(std.mem.indexOf(u8, s, "export VM_TEST_KEY_ZIG='sk-it'\\''s-secret'") != null);
    }
}

fn setenvOk(name: []const u8, value: []const u8) bool {
    if (comptime !@import("builtin").link_libc) return false;
    var nbuf: [128]u8 = undefined;
    var vbuf: [128]u8 = undefined;
    const nz = std.fmt.bufPrintZ(&nbuf, "{s}", .{name}) catch return false;
    const vz = std.fmt.bufPrintZ(&vbuf, "{s}", .{value}) catch return false;
    return std.c.setenv(nz.ptr, vz.ptr, 1) == 0;
}
