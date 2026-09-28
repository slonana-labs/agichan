//! `zig build wasm`: the flows for wasm32-freestanding, transport and
//! randomness from the host. Proves the core needs no OS; not a stable ABI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const flows = @import("flows.zig");
const rpc = @import("rpc.zig");
const state_mod = @import("state.zig");
const keypair = @import("keypair.zig");
const base58 = @import("base58.zig");

/// POSTs `req` to the relay; writes the reply into `reply` and returns its
/// length, or -1 when no reply came.
extern "host" fn host_post(req: [*]const u8, req_len: usize, reply: [*]u8, reply_cap: usize) isize;
/// Fills `buf` from a CSPRNG (crypto.getRandomValues in a browser).
extern "host" fn host_random(buf: [*]u8, len: usize) void;

var heap: [16 << 20]u8 = undefined;
var saved: []const u8 = "";

fn hostFill(_: *anyopaque, buf: []u8) void {
    host_random(buf.ptr, buf.len);
}

fn hostPost(_: *anyopaque, a: Allocator, req: []const u8) Allocator.Error!rpc.Posted {
    const buf = try a.alloc(u8, 4 << 20);
    const n = host_post(req.ptr, req.len, buf.ptr, buf.len);
    if (n < 0) return .{ .failed = "host transport failed" };
    return .{ .reply = buf[0..@intCast(n)] };
}

fn keepState(_: *anyopaque, a: Allocator, st: *const state_mod.State) Allocator.Error!?[]const u8 {
    saved = try state_mod.serialize(a, st);
    return null;
}

const Command = enum(u32) { login = 0, join = 1, send = 2, read = 3, tasks_json = 4 };

/// One command on `state` (JSON) as the wallet in `kp`; output to `out`, new
/// state at agichan_state_ptr/len. The exit code, or 255 on a host error.
export fn agichan_run(
    cmd: u32,
    state_ptr: [*]const u8,
    state_len: usize,
    kp_ptr: [*]const u8,
    kp_len: usize,
    room_ptr: [*]const u8,
    room_len: usize,
    text_ptr: [*]const u8,
    text_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) u32 {
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const a = fba.allocator();
    // A host passing a cmd outside 0-4 would trap @enumFromInt; refuse it. The
    // wasm host is trusted in the threat model, so this is defense in depth.
    const command = std.meta.intToEnum(Command, cmd) catch return 255;
    return run(a, command, state_ptr[0..state_len], kp_ptr[0..kp_len], room_ptr[0..room_len], text_ptr[0..text_len], out_ptr[0..out_cap]) catch 255;
}

fn run(a: Allocator, cmd: Command, state_text: []const u8, kp_text: []const u8, room: []const u8, text: []const u8, out_buf: []u8) !u32 {
    var st = if (state_text.len == 0) state_mod.State{} else try state_mod.parse(a, state_text);
    const kp = try keypair.parse(a, kp_text);
    var out = std.Io.Writer.fixed(out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var ctx: flows.Context = .{
        .a = a,
        .transport = .{ .ctx = undefined, .postFn = hostPost, .url = "https://rpc.slonana.com" },
        .rng = .{ .ptr = undefined, .fillFn = hostFill },
        .st = &st,
        .saver = .{ .ctx = undefined, .saveFn = keepState },
        .state_label = "host state",
        .out = &out,
        .err = &err,
        .keypair = kp,
        .wallet = try base58.encode(a, &kp.public_key),
        .host = "rpc.slonana.com",
    };
    if (cmd == .login) return try flows.login(&ctx);
    if (try flows.prelude(&ctx, "host keypair")) |code| return code;
    return switch (cmd) {
        .join => try flows.join(&ctx, room),
        .send => try flows.send(&ctx, room, text),
        .read => try flows.read(&ctx, room, 50, .lines),
        .tasks_json => try flows.read(&ctx, room, 50, .board_json),
        .login => unreachable,
    };
}

export fn agichan_state_ptr() [*]const u8 {
    return saved.ptr;
}

export fn agichan_state_len() usize {
    return saved.len;
}
