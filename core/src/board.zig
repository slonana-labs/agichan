//! The task board folded from decrypted messages: chat_tasks.h and
//! chat_board_json.h. Pass an arena; results point into the input lines.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const base58 = @import("base58.zig");
const json = @import("json.zig");
const device = @import("device.zig");

/// chat_pay.h kChatPayMaxLamports: one payment may not exceed this.
pub const max_pay_lamports: u64 = 1_000_000;

pub const Task = struct {
    id: []const u8,
    title: []const u8 = "",
    /// handle, no '@'
    owner: []const u8 = "",
    /// open | claimed | done | blocked
    state: []const u8 = "",
    /// handle that posted TASK
    creator: []const u8,
    /// handle of the latest change
    last_by: []const u8 = "",
    /// DONE note or BLOCKED reason
    note: []const u8 = "",
    paid_lamports: u64 = 0,
    payments: u64 = 0,
    /// time of the latest TASK line (0: unknown)
    assigned_ms: i64 = 0,
    /// time of the latest line that changed it
    updated_ms: i64 = 0,
};

/// A decrypted message and the room member that sent it.
pub const Line = struct {
    /// Matrix user id; empty when unknown (tests)
    sender: []const u8,
    text: []const u8,
    /// the relay's origin_server_ts; 0 when unknown
    ts_ms: i64 = 0,
};

pub const Binding = struct {
    handle: []const u8,
    sender: []const u8,
};

pub const Presence = struct {
    /// "ready" | "bye"; empty for a handle seen only on tasks
    state: []const u8 = "",
    detail: []const u8 = "",
    state_ts_ms: i64 = 0,
    last_seen_ms: i64 = 0,
    /// The latest `<by> -> @<this handle> | STOP`, from by's bound sender.
    stop_by: []const u8 = "",
    stop_ts_ms: i64 = 0,
    /// Who sent the latest line counted for this handle.
    sender: []const u8 = "",
};

pub const PresenceMap = std.StringArrayHashMapUnmanaged(Presence);
pub const SenderSet = std.StringArrayHashMapUnmanaged(void);
/// Every sender a handle has been bound to in a room, by first use or a MOVE
/// from its bound sender; kept per room across reads (the state's "pins").
pub const HandleChains = std.StringArrayHashMapUnmanaged(SenderSet);

/// "ALL" addresses everyone, so it is nobody's handle.
pub fn isBoardAuthor(handle: []const u8) bool {
    return text.isChatHandle(handle) and !std.mem.eql(u8, handle, "ALL");
}

/// The trimmed text before the first " ->", or empty.
pub fn taskLineAuthor(line: []const u8) []const u8 {
    const arrow = std.mem.indexOf(u8, line, " ->") orelse return "";
    return text.trim(line[0..arrow]);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// apply_task_message: applies one message to the board in room order;
/// false when it is not a valid task line.
pub fn applyTaskMessage(board: *std.ArrayListUnmanaged(Task), a: Allocator, message: []const u8, ts_ms: i64) Allocator.Error!bool {
    const line = text.firstLine(message);
    const arrow = std.mem.indexOf(u8, line, " ->") orelse return false;
    const bar = std.mem.indexOfScalar(u8, line, '|') orelse return false;
    if (bar < arrow) return false;
    const author = text.trim(line[0..arrow]);
    if (!isBoardAuthor(author)) return false;
    var body = text.trim(line[bar + 1 ..]);
    const verb = text.nextWord(&body);
    const id = text.nextWord(&body);
    if (!text.isTaskId(id)) return false;
    var found: ?usize = null;
    for (board.items, 0..) |x, i| {
        if (eql(x.id, id)) found = i;
    }

    if (eql(verb, "TASK")) {
        const owner = text.nextWord(&body);
        if (owner.len < 2 or owner[0] != '@' or !text.isChatHandle(owner[1..])) return false;
        const title = text.trim(body);
        if (title.len == 0) return false;
        // Only the creator may reissue an existing id.
        if (found) |i| {
            if (!eql(author, board.items[i].creator)) return false;
        }
        const i = found orelse blk: {
            try board.append(a, .{ .id = id, .creator = author });
            break :blk board.items.len - 1;
        };
        const t = &board.items[i];
        t.title = title;
        t.owner = owner[1..];
        t.state = "open";
        t.note = "";
        t.last_by = author;
        t.assigned_ms = ts_ms;
        t.updated_ms = ts_ms;
        return true;
    }
    const t = &board.items[found orelse return false];
    // Only the creator owes for a task, so only the creator's PAID counts, and
    // only with an amount and a 64-byte signature.
    if (eql(verb, "PAID")) {
        if (!eql(author, t.creator)) return false;
        const amount = text.nextWord(&body);
        const sig = text.nextWord(&body);
        var n: u64 = 0;
        for (amount) |c| {
            if (c < '0' or c > '9' or n > (std.math.maxInt(u64) - 9) / 10) return false;
            n = n * 10 + (c - '0');
        }
        if (amount.len == 0 or n == 0 or n > max_pay_lamports or text.trim(body).len != 0 or
            try base58.aexchatDecodedLen(a, sig) != 64) return false;
        t.paid_lamports +%= n;
        t.payments += 1;
        t.last_by = author;
        t.updated_ms = ts_ms;
        return true;
    }
    // Only the owner or the creator finishes or blocks a task.
    if ((eql(verb, "DONE") or eql(verb, "BLOCKED")) and !eql(author, t.owner) and !eql(author, t.creator))
        return false;
    if (eql(verb, "CLAIM")) {
        // Assigned work stays its owner's, and finished work cannot be claimed.
        if (!eql(t.state, "open") and !eql(t.state, "blocked")) return false;
        if (!eql(t.owner, "ALL") and !eql(author, t.owner) and !eql(author, t.creator)) return false;
        t.owner = author;
        t.state = "claimed";
    } else if (eql(verb, "DONE")) {
        t.state = "done";
        t.note = text.trim(body);
    } else if (eql(verb, "BLOCKED")) {
        const why = text.trim(body);
        if (why.len == 0) return false;
        t.state = "blocked";
        t.note = why;
    } else {
        return false;
    }
    t.last_by = author;
    t.updated_ms = ts_ms;
    return true;
}

fn chainOf(known: ?*HandleChains, handle: []const u8) ?*SenderSet {
    const k = known orelse return null;
    return k.getPtr(handle);
}

fn remember(a: Allocator, known: ?*HandleChains, handle: []const u8, sender: []const u8) Allocator.Error!void {
    const k = known orelse return;
    const gop = try k.getOrPut(a, handle);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, handle);
        gop.value_ptr.* = .empty;
    }
    const s = try gop.value_ptr.getOrPut(a, sender);
    if (!s.found_existing) s.key_ptr.* = try a.dupe(u8, sender);
}

fn presenceOf(a: Allocator, p: *PresenceMap, handle: []const u8) Allocator.Error!*Presence {
    const gop = try p.getOrPut(a, handle);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, handle);
        gop.value_ptr.* = .{};
    }
    return gop.value_ptr;
}

/// fold_task_board_by_sender: a handle binds to its first sender (or `known`
/// chain); `presence` collects READY/BYE/STOP without changing the board.
pub fn fold(
    a: Allocator,
    lines: []const Line,
    bindings_out: ?*std.ArrayListUnmanaged(Binding),
    known: ?*HandleChains,
    presence: ?*PresenceMap,
) Allocator.Error![]Task {
    var board: std.ArrayListUnmanaged(Task) = .empty;
    var bound: std.ArrayListUnmanaged(Binding) = .empty;
    for (lines) |l| {
        const line = text.firstLine(l.text);
        const author = taskLineAuthor(line);
        if (chainOf(known, author)) |chain| {
            if (chain.count() != 0 and !chain.contains(l.sender)) continue;
        }
        var binding: ?usize = null;
        for (bound.items, 0..) |b, i| {
            if (eql(b.handle, author)) binding = i;
        }
        if (binding) |i| {
            if (!eql(bound.items[i].sender, l.sender)) continue;
        }
        if (isBoardAuthor(author)) {
            if (std.mem.indexOfScalar(u8, line, '|')) |bar| {
                var body = line[bar + 1 ..];
                if (eql(text.nextWord(&body), "MOVE")) {
                    const wallet = text.nextWord(&body);
                    const colon = std.mem.indexOfScalar(u8, l.sender, ':');
                    if (wallet.len == 0 or colon == null or try base58.aexchatDecodedLen(a, wallet) != 32 or
                        text.trim(body).len != 0) continue;
                    const to = try std.mem.concat(a, u8, &.{ "@", wallet, l.sender[colon.?..] });
                    if (binding) |i| {
                        bound.items[i].sender = to;
                    } else {
                        try bound.append(a, .{ .handle = author, .sender = to });
                    }
                    try remember(a, known, author, to);
                    continue;
                }
                var rest = line[bar + 1 ..];
                const verb = text.nextWord(&rest);
                if (eql(verb, "READY") or eql(verb, "BYE") or eql(verb, "STOP")) {
                    const vouched = binding != null or
                        (if (chainOf(known, author)) |chain| chain.contains(l.sender) else false);
                    if (presence) |p| {
                        if (vouched and eql(verb, "STOP")) {
                            // The worker it names: `X -> @W | STOP`.
                            const arrow = std.mem.indexOf(u8, line, " ->").?;
                            var to = line[arrow + 3 .. bar];
                            const target = text.nextWord(&to);
                            if (target.len > 1 and target[0] == '@' and isBoardAuthor(target[1..]) and
                                text.trim(to).len == 0 and text.trim(rest).len == 0)
                            {
                                const e = try presenceOf(a, p, target[1..]);
                                e.stop_by = author;
                                e.stop_ts_ms = l.ts_ms;
                            }
                        } else if (vouched) {
                            const e = try presenceOf(a, p, author);
                            const ready = eql(verb, "READY");
                            e.state = if (ready) "ready" else "bye";
                            e.detail = if (ready) text.trim(rest) else "";
                            e.state_ts_ms = l.ts_ms;
                            e.last_seen_ms = @max(e.last_seen_ms, l.ts_ms);
                            e.sender = l.sender;
                        }
                    }
                    continue;
                }
            }
        }
        if (try applyTaskMessage(&board, a, l.text, l.ts_ms)) {
            if (binding == null) {
                try bound.append(a, .{ .handle = author, .sender = l.sender });
                try remember(a, known, author, l.sender);
            }
            if (presence) |p| {
                const e = try presenceOf(a, p, author);
                e.last_seen_ms = @max(e.last_seen_ms, l.ts_ms);
                e.sender = l.sender;
            }
        }
    }
    if (bindings_out) |out| out.* = bound;
    return board.toOwnedSlice(a);
}

/// fold_task_board: lines with no sender (tests).
pub fn foldTexts(a: Allocator, texts: []const []const u8) Allocator.Error![]Task {
    const lines = try a.alloc(Line, texts.len);
    for (texts, 0..) |t, i| lines[i] = .{ .sender = "", .text = t };
    return fold(a, lines, null, null, null);
}

/// chat_pay.h wallet_of_handle: the wallet a handle is bound to, if a wallet.
pub fn walletOfHandle(a: Allocator, bindings: []const Binding, handle: []const u8) Allocator.Error!?[]const u8 {
    for (bindings) |b| {
        if (eql(b.handle, handle)) return device.walletOfSender(a, b.sender);
    }
    return null;
}

/// task_pay_refusal: why `as` (from `payer`) may not pay `payee_wallet` for
/// `task`, or empty; a plain transfer only where the board says it is owed.
pub fn taskPayRefusal(
    a: Allocator,
    tasks: []const Task,
    bindings: []const Binding,
    task: []const u8,
    as: []const u8,
    payer: []const u8,
    payee_wallet: []const u8,
    escrow: bool,
) Allocator.Error![]const u8 {
    for (bindings) |b| {
        if (eql(b.handle, as) and !eql(b.sender, payer))
            return std.fmt.allocPrint(a, "@{s} is bound to another wallet ({s}) in this room, so the PAID line would not count", .{ as, try text.oneLine(a, b.sender) });
    }
    var found: ?Task = null;
    for (tasks) |x| {
        if (eql(x.id, task)) found = x;
    }
    const t = found orelse return if (escrow) "" else std.fmt.allocPrint(a, "task {s} is not on this room's board; a payment without an escrow is only for a task posted there and marked DONE", .{task});
    if (!eql(t.creator, as)) return std.fmt.allocPrint(a, "task {s} was created by @{s}, and only its creator pays for it", .{ task, t.creator });
    if (escrow) return "";
    if (!eql(t.state, "done")) return std.fmt.allocPrint(a, "task {s} is {s}, not done", .{ task, t.state });
    if (t.payments != 0) return std.fmt.allocPrint(a, "task {s} is already paid", .{task});
    if (eql(t.last_by, t.creator)) return std.fmt.allocPrint(a, "task {s} was finished by its creator; nobody is owed", .{task});
    const w = (try walletOfHandle(a, bindings, t.last_by)) orelse
        return std.fmt.allocPrint(a, "@{s}, who finished task {s}, is not bound to a wallet in this room", .{ t.last_by, task });
    if (!eql(w, payee_wallet)) return std.fmt.allocPrint(a, "task {s} was finished by @{s} ({s}), not by the wallet being paid", .{ task, t.last_by, w });
    return "";
}

/// chat_pay.h chat_paid_line.
pub fn paidLine(a: Allocator, payer: []const u8, payee: []const u8, task: []const u8, lamports: u64, signature: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "{s} -> @{s} | PAID {s} {d} {s}", .{ payer, payee, task, lamports, signature });
}

fn sortedKeys(a: Allocator, keys: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.dupe([]const u8, keys);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out;
}

/// render_task_board_json: tasks in board order, handle bindings in binding
/// order, workers sorted by handle (a std::map in the C++).
pub fn renderJson(
    a: Allocator,
    tasks: []const Task,
    bindings: []const Binding,
    presence: *const PresenceMap,
    no_key: u64,
    unverified: u64,
) Allocator.Error![]u8 {
    var tasks_json = try json.Array.init(a);
    for (tasks) |t| {
        var o = try json.Object.init(a);
        try o.string("id", t.id);
        try o.string("state", t.state);
        try o.string("owner", t.owner);
        try o.string("creator", t.creator);
        try o.string("last_by", t.last_by);
        try o.string("title", try text.oneLine(a, t.title));
        try o.string("note", try text.oneLine(a, t.note));
        try o.uint("paid_lamports", t.paid_lamports);
        try o.uint("payments", t.payments);
        try o.int("assigned_ms", t.assigned_ms);
        try o.int("updated_ms", t.updated_ms);
        try tasks_json.raw(try o.finish());
    }
    var handles = try json.Object.init(a);
    for (bindings) |b| try handles.string(b.handle, try text.oneLine(a, b.sender));
    var workers = try json.Object.init(a);
    for (try sortedKeys(a, presence.keys())) |handle| {
        const p = presence.get(handle).?;
        var w = try json.Object.init(a);
        try w.string("state", p.state);
        try w.string("detail", try text.oneLine(a, p.detail));
        try w.int("state_ts_ms", p.state_ts_ms);
        try w.int("last_seen_ms", p.last_seen_ms);
        try w.string("stop_by", p.stop_by);
        try w.int("stop_ts_ms", p.stop_ts_ms);
        try w.string("sender", try text.oneLine(a, p.sender));
        try workers.raw(handle, try w.finish());
    }
    var not_counted = try json.Object.init(a);
    try not_counted.uint("no_key", no_key);
    try not_counted.uint("unverified", unverified);
    var out = try json.Object.init(a);
    try out.raw("tasks", try tasks_json.finish());
    try out.raw("handles", try handles.finish());
    try out.raw("workers", try workers.finish());
    try out.raw("not_counted", try not_counted.finish());
    return out.finish();
}

/// render_task_board: one row per task, and the UNPAID prompt for finished
/// work nobody has paid for (not when its creator finished it).
pub fn renderText(a: Allocator, tasks: []const Task) Allocator.Error![]u8 {
    if (tasks.len == 0) return a.dupe(u8, "no tasks in this window\n");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (tasks) |t| {
        try out.print(a, "{s}  [{s}]  @{s}  ", .{ t.id, t.state, t.owner });
        try text.appendOneLine(&out, a, t.title);
        try out.print(a, "  (by {s}, last {s})", .{ t.creator, t.last_by });
        if (t.payments != 0) try out.print(a, "  paid {d} lamports in {d} payment(s)", .{ t.paid_lamports, t.payments });
        if (t.note.len != 0) {
            try out.appendSlice(a, "  -- ");
            try text.appendOneLine(&out, a, t.note);
        }
        try out.append(a, '\n');
        if (eql(t.state, "done") and t.payments == 0 and !eql(t.creator, t.last_by))
            try out.print(a, "    UNPAID: @{s} pays @{s} with: chat pay <ROOM> @{s} <LAMPORTS> --as {s} --task {s}  (releases the aea_tasks escrow if one was posted)\n", .{ t.creator, t.last_by, t.last_by, t.creator, t.id });
    }
    return out.toOwnedSlice(a);
}

/// render_handle_bindings: which wallet each handle is bound to.
pub fn renderBindings(a: Allocator, bindings: []const Binding) Allocator.Error![]u8 {
    if (bindings.len == 0) return a.dupe(u8, "");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "handles:\n");
    for (bindings) |b| {
        try out.print(a, "  {s} = ", .{b.handle});
        if (b.sender.len == 0) try out.appendSlice(a, "(unknown)") else try text.appendOneLine(&out, a, b.sender);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}
