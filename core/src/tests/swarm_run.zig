//! An in-process swarm: a sponsor creates a channel, a manager (@lead) and two
//! workers get wallets, the manager posts two @ALL tasks, and each worker
//! claims one, "runs" a stub agent and posts DONE. It drives the real swarm loop
//! and the real end-to-end encryption over the in-process relay, with the side
//! effects (clock, sleep, agent) stubbed so nothing sleeps or spawns. This is
//! the "manager + >=2 workers claiming/finishing tasks" check.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const client = @import("../client.zig");
const swarm = @import("../swarm.zig");
const keypair = @import("../keypair.zig");
const base58 = @import("../base58.zig");
const Relay = @import("relay.zig").Relay;

const stub_agent_output = "wrote the code\nSTATUS: done";

const Hooks = struct {
    fn nowSecs(_: *anyopaque) i64 {
        return 1790000000;
    }
    fn sleepSecs(_: *anyopaque, _: u64) void {}
    fn runAgent(_: *anyopaque, a: Allocator, _: swarm.AgentJob) swarm.AgentResult {
        return .{ .rc = 0, .output = a.dupe(u8, stub_agent_output) catch "STATUS: done" };
    }
};

const Captured = struct { code: u8, out: []const u8, err: []const u8 };

fn run(env: client.Env, key: []const u8, cmd: client.Cmd) !Captured {
    var out: std.Io.Writer.Allocating = .init(env.a);
    var err: std.Io.Writer.Allocating = .init(env.a);
    const code = try client.execAs(env, key, null, cmd, &out.writer, &err.writer);
    return .{ .code = code, .out = out.written(), .err = err.written() };
}

fn writeWallet(a: Allocator, path: []const u8, kp: keypair.Keypair) !void {
    const t = try keypair.format(a, kp);
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(t);
}

fn boardOf(env: client.Env, a: Allocator, key: []const u8, room: []const u8) !json.Value {
    const r = try run(env, key, .{ .tasks = .{ .room = room, .limit = 300, .json = true } });
    try testing.expectEqual(@as(u8, 0), r.code);
    return json.parse(a, r.out);
}

fn taskState(board: json.Value, id: []const u8) []const u8 {
    const tasks = (board.get("tasks") orelse return "").asArray() orelse return "";
    for (tasks) |t| {
        if (std.mem.eql(u8, json.getString(t, "id") orelse "", id)) return json.getString(t, "state") orelse "";
    }
    return "";
}
fn taskOwner(board: json.Value, id: []const u8) []const u8 {
    const tasks = (board.get("tasks") orelse return "").asArray() orelse return "";
    for (tasks) |t| {
        if (std.mem.eql(u8, json.getString(t, "id") orelse "", id)) return json.getString(t, "owner") orelse "";
    }
    return "";
}

test "swarm: a manager and two workers finish two tasks end to end" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var prng = std.Random.DefaultPrng.init(0xC12E);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const state_dir = try std.fs.path.join(a, &.{ root, "state" });
    const data_dir = try std.fs.path.join(a, &.{ root, "data" });
    const keys_dir = try std.fs.path.join(a, &.{ root, "keys" });
    try std.fs.cwd().makePath(state_dir);
    try std.fs.cwd().makePath(data_dir);
    try std.fs.cwd().makePath(keys_dir);

    var relay: Relay = .{ .a = a };
    const env: client.Env = .{
        .a = a,
        .backend = relay.backend(),
        .url = "https://rpc.slonana.com",
        .host = "rpc.slonana.com",
        .bound_only = true,
        .rng = prng.random(),
        .state_dir = state_dir,
    };

    // Sponsor: a wallet, logged in, that creates the channel.
    const sponsor = try std.fs.path.join(a, &.{ root, "sponsor.json" });
    try writeWallet(a, sponsor, keypair.generate(env.rng));
    try testing.expectEqual(@as(u8, 0), (try run(env, sponsor, .login)).code);
    const created = try run(env, sponsor, .{ .create = "agichan-test" });
    try testing.expectEqual(@as(u8, 0), created.code);
    const room = json.getString(json.parse(a, created.out) catch unreachable, "room_id").?;

    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var ctx: swarm.Ctx = .{
        .a = a,
        .env = env,
        .room = room,
        .sponsor = sponsor,
        .data_dir = data_dir,
        .keys_dir = keys_dir,
        .self_exe = "agichan",
        .out = &out.writer,
        .err = &err.writer,
        .hooks = .{ .nowSecs = Hooks.nowSecs, .sleepSecs = Hooks.sleepSecs, .runAgent = Hooks.runAgent },
    };

    // The manager and two workers each get a wallet in the channel.
    for ([_][]const u8{ "lead", "w1", "w2" }) |h| {
        const code = swarm.identity(&ctx, h) catch |e| {
            std.debug.print("identity {s} error {s}: {s}\n", .{ h, @errorName(e), err.written() });
            return e;
        };
        if (code != 0) std.debug.print("identity {s} failed: {s}\n", .{ h, err.written() });
        try testing.expectEqual(@as(u8, 0), code);
    }

    // The manager assigns two @ALL tasks.
    try testing.expectEqual(@as(u8, 0), try swarm.managerAssign(&ctx, "lead", "t1", "@ALL", "do thing one"));
    try testing.expectEqual(@as(u8, 0), try swarm.managerAssign(&ctx, "lead", "t2", "@ALL", "do thing two"));

    // Each worker takes exactly one task, runs the stub agent, posts DONE.
    const wopts = swarm.WorkerOpts{ .me = "w1", .mgr = "lead", .agent = "stub", .dir = root, .poll = 1, .timeout = 5, .max = 1 };
    const w1 = wopts;
    var w2 = wopts;
    w2.me = "w2";
    try testing.expectEqual(@as(u8, 0), try swarm.worker(&ctx, w1));
    try testing.expectEqual(@as(u8, 0), try swarm.worker(&ctx, w2));

    // The board, as the manager reads it: both tasks done, by different workers.
    const board = try boardOf(env, a, try dataHandleKey(a, keys_dir, "lead"), room);
    try testing.expectEqualStrings("done", taskState(board, "t1"));
    try testing.expectEqualStrings("done", taskState(board, "t2"));
    const o1 = taskOwner(board, "t1");
    const o2 = taskOwner(board, "t2");
    try testing.expect((std.mem.eql(u8, o1, "w1") and std.mem.eql(u8, o2, "w2")) or
        (std.mem.eql(u8, o1, "w2") and std.mem.eql(u8, o2, "w1")));

    // Both DONE lines carry the stub agent's summary, and both workers said BYE.
    const lead_read = try run(env, try dataHandleKey(a, keys_dir, "lead"), .{ .read = .{ .room = room, .limit = 300 } });
    try testing.expect(std.mem.indexOf(u8, lead_read.out, "DONE t1 wrote the code") != null);
    try testing.expect(std.mem.indexOf(u8, lead_read.out, "DONE t2 wrote the code") != null);
    try testing.expect(std.mem.indexOf(u8, lead_read.out, "| BYE") != null);
}

fn dataHandleKey(a: Allocator, keys_dir: []const u8, h: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ keys_dir, try std.fmt.allocPrint(a, "{s}.json", .{h}) });
}
