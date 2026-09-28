//! The relay over HTTPS (std.http.Client, system roots). std.http has no
//! timeouts, so a watchdog ends the process after 30 s, as RPC_TIMEOUT_SECONDS.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("rpc.zig");

pub const timeout_s = 30;
pub const max_reply_bytes = 64 << 20;

pub const Https = struct {
    url: []const u8,
    client: std.http.Client,

    /// `gpa` must free (the client's connections and certificates use it).
    pub fn init(gpa: Allocator, url: []const u8) Https {
        return .{ .url = url, .client = .{ .allocator = gpa } };
    }

    pub fn deinit(self: *Https) void {
        self.client.deinit();
    }

    pub fn transport(self: *Https) rpc.Transport {
        return .{ .ctx = self, .postFn = post, .url = self.url };
    }

    fn post(ctx: *anyopaque, a: Allocator, request_json: []const u8) Allocator.Error!rpc.Posted {
        const self: *Https = @ptrCast(@alignCast(ctx));
        var done: std.Thread.ResetEvent = .{};
        const dog = std.Thread.spawn(.{}, watch, .{ &done, self.url }) catch null;
        defer if (dog) |t| {
            done.set();
            t.join();
        };
        const body = self.exchange(a, request_json) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = @errorName(e) },
        };
        return .{ .reply = body };
    }

    fn watch(done: *std.Thread.ResetEvent, url: []const u8) void {
        done.timedWait(timeout_s * std.time.ns_per_s) catch {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "agichan: no reply from {s} within {d} s; the request may still have reached it\n", .{ url, timeout_s }) catch "agichan: no reply within the deadline\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            std.process.exit(1);
        };
    }

    /// One POST; the reply body whatever the status (a relay error is JSON too).
    fn exchange(self: *Https, a: Allocator, body: []const u8) ![]u8 {
        const uri = try std.Uri.parse(self.url);
        var req = try self.client.request(.POST, uri, .{
            // A redirect is returned, never followed: the token is in the body.
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "agichan/0.1" },
            },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(body);
        try bw.end();
        try req.connection.?.flush();
        var response = try req.receiveHead(&.{});
        const decompress_buf: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try a.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try a.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        var transfer_buf: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
        return reader.allocRemaining(a, .limited(max_reply_bytes)) catch |e| switch (e) {
            error.ReadFailed => return response.bodyErr().?,
            else => |x| return x,
        };
    }
};
