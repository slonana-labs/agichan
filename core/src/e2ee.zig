//! E2eeManager (src/aexchat/e2ee_manager.cpp, include/aexchat/e2ee_manager.h)
//! and the DeviceKeyStore it reads, as the C++ CLI uses them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = @import("crypto.zig");
const megolm = @import("megolm.zig");
const json = @import("json.zig");
const Key32 = crypto.Key32;

pub const DeviceKeys = struct {
    user_id: []const u8,
    device_id: []const u8,
    ed25519: Key32,
    x25519: Key32,
};

/// DeviceKeyStore without a database: per user, devices by id, an upload
/// replacing a device with the same id.
pub const KeyStore = struct {
    arena: std.heap.ArenaAllocator,
    users: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(DeviceKeys)) = .empty,

    pub fn init(child: Allocator) KeyStore {
        return .{ .arena = std.heap.ArenaAllocator.init(child) };
    }

    pub fn deinit(self: *KeyStore) void {
        self.arena.deinit();
    }

    pub fn upload(self: *KeyStore, d: DeviceKeys) Allocator.Error!void {
        const a = self.arena.allocator();
        const gop = try self.users.getOrPut(a, d.user_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, d.user_id);
            gop.value_ptr.* = .empty;
        }
        const owned: DeviceKeys = .{
            .user_id = gop.key_ptr.*,
            .device_id = try a.dupe(u8, d.device_id),
            .ed25519 = d.ed25519,
            .x25519 = d.x25519,
        };
        for (gop.value_ptr.items) |*existing| {
            if (std.mem.eql(u8, existing.device_id, d.device_id)) {
                existing.* = owned;
                return;
            }
        }
        try gop.value_ptr.append(a, owned);
    }

    pub fn query(self: *const KeyStore, user_id: []const u8) []const DeviceKeys {
        const list = self.users.get(user_id) orelse return &.{};
        return list.items;
    }
};

pub const KeyShareEvent = struct {
    room_id: []const u8,
    session_id: []const u8,
    target_user: []const u8,
    target_device: []const u8,
    /// AES-GCM(HKDF(ECDH)) of the exported key; empty when ECDH refused.
    encrypted_key: []const u8,
    sender_x25519_public: Key32,
    /// The uploader as the relay authenticated it; empty names nobody.
    sender_user: []const u8 = "",
};

/// ShareResult::Status. `imported` includes "the same chain is already held".
pub const ShareStatus = enum { imported, no_sender, not_senders_key, undecryptable, refused };

pub const EncryptedMessage = struct {
    session_id: []const u8,
    message_index: u32,
    ciphertext: []const u8,
    sender_device: []const u8 = "",
};

pub const Decrypted = struct {
    plaintext: []u8,
    /// Only the sender's own session decrypted it.
    verified: bool,
    /// Who forwarded the key, when a forwarded session decrypted it.
    forwarded_by: []const u8,
};

pub const Target = struct {
    user: []const u8,
    device: []const u8,
};

/// (original sender, session id), e.g. from a room's encrypted events.
pub const SessionRef = struct {
    sender: []const u8,
    session_id: []const u8,
};

const SessionMap = std.StringArrayHashMapUnmanaged(megolm.Inbound);
const Forwarded = struct {
    by: []const u8,
    session: megolm.Inbound,
};
const ForwardMap = std.StringArrayHashMapUnmanaged(Forwarded);

const key_share_salt = "aexchat_key_share";
const key_share_info = "megolm_key_share";
const forward_magic = "FWD1";

/// The AES-256-GCM key of a key share between two devices:
/// HKDF(X25519(ours, theirs), "aexchat_key_share", "megolm_key_share").
pub fn shareKey(secret: Key32, peer: Key32) crypto.WeakKeyError!Key32 {
    var shared = try crypto.x25519Shared(secret, peer);
    defer std.crypto.secureZero(u8, &shared);
    return crypto.hkdf32(&shared, key_share_salt, key_share_info);
}

pub const Manager = struct {
    /// Owns every id, key and session held; freed (after wiping) by deinit.
    arena: std.heap.ArenaAllocator,
    store: ?*const KeyStore,
    user_id: []const u8 = "",
    device_id: []const u8 = "",
    device: crypto.X25519Keypair = .{ .public_key = [_]u8{0} ** 32, .secret_key = [_]u8{0} ** 32 },
    retired: std.ArrayListUnmanaged(crypto.X25519Keypair) = .empty,
    /// room -> session
    outbound: std.StringArrayHashMapUnmanaged(megolm.Outbound) = .empty,
    /// sender -> session id -> session: an id alone let one member squat another's.
    inbound: std.StringArrayHashMapUnmanaged(SessionMap) = .empty,
    /// Sessions with no sender (legacy imports); each decrypts for anyone.
    unbound: SessionMap = .empty,
    /// original sender -> session id -> (forwarder, session): readable, never verified.
    forwarded: std.StringArrayHashMapUnmanaged(ForwardMap) = .empty,
    refused_unbound: u64 = 0,

    pub fn init(child: Allocator, store: ?*const KeyStore) Manager {
        return .{ .arena = std.heap.ArenaAllocator.init(child), .store = store };
    }

    pub fn deinit(self: *Manager) void {
        self.device.wipe();
        for (self.retired.items) |*k| k.wipe();
        for (self.outbound.values()) |*s| s.ratchet.wipe();
        for (self.inbound.values()) |*m| {
            for (m.values()) |*s| s.wipe();
        }
        for (self.unbound.values()) |*s| s.wipe();
        for (self.forwarded.values()) |*m| {
            for (m.values()) |*f| f.session.wipe();
        }
        self.arena.deinit();
    }

    fn alloc(self: *Manager) Allocator {
        return self.arena.allocator();
    }

    pub fn setDevice(self: *Manager, user_id: []const u8, device_id: []const u8, kp: crypto.X25519Keypair) Allocator.Error!void {
        self.user_id = try self.alloc().dupe(u8, user_id);
        self.device_id = try self.alloc().dupe(u8, device_id);
        self.device = kp;
    }

    /// A key this device used before moving to its wallet-derived one: shares
    /// sealed to it still open. Never used to send.
    pub fn addRetired(self: *Manager, kp: crypto.X25519Keypair) Allocator.Error!void {
        try self.retired.append(self.alloc(), kp);
    }

    fn sessionsOf(self: *Manager, sender: []const u8) Allocator.Error!*SessionMap {
        const gop = try self.inbound.getOrPut(self.alloc(), sender);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc().dupe(u8, sender);
            gop.value_ptr.* = .empty;
        }
        return gop.value_ptr;
    }

    fn forwardsOf(self: *Manager, origin: []const u8) Allocator.Error!*ForwardMap {
        const gop = try self.forwarded.getOrPut(self.alloc(), origin);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc().dupe(u8, origin);
            gop.value_ptr.* = .empty;
        }
        return gop.value_ptr;
    }

    /// Installs (or replaces) session `key` in `map`, keyed by its id.
    fn putSession(self: *Manager, map: *SessionMap, key: megolm.ExportedKey) Allocator.Error!void {
        const s = try megolm.Inbound.init(self.alloc(), key);
        const gop = try map.getOrPut(self.alloc(), s.session_id);
        if (gop.found_existing) gop.value_ptr.wipe();
        gop.key_ptr.* = s.session_id;
        gop.value_ptr.* = s;
    }

    fn putForward(self: *Manager, map: *ForwardMap, by: []const u8, key: megolm.ExportedKey) Allocator.Error!void {
        const s = try megolm.Inbound.init(self.alloc(), key);
        const gop = try map.getOrPut(self.alloc(), s.session_id);
        if (gop.found_existing) gop.value_ptr.session.wipe();
        gop.key_ptr.* = s.session_id;
        gop.value_ptr.* = .{ .by = try self.alloc().dupe(u8, by), .session = s };
    }

    /// get_outbound: the room's session, made on first use. A new session's
    /// sender keeps an inbound copy at index 0, or it cannot read itself.
    fn getOutbound(self: *Manager, room: []const u8, rng: std.Random) Allocator.Error!*megolm.Outbound {
        if (self.outbound.getPtr(room)) |s| return s;
        const s = try megolm.Outbound.initRandom(self.alloc(), rng);
        try self.outbound.put(self.alloc(), try self.alloc().dupe(u8, room), s);
        if (self.user_id.len != 0) try self.putSession(try self.sessionsOf(self.user_id), s.exportKey());
        return self.outbound.getPtr(room).?;
    }

    pub fn outboundSessionId(self: *const Manager, room: []const u8) []const u8 {
        const s = self.outbound.get(room) orelse return "";
        return s.session_id;
    }

    /// rotate_session: the next encrypt starts a fresh session.
    pub fn rotateSession(self: *Manager, room: []const u8) void {
        if (self.outbound.getPtr(room)) |s| s.ratchet.wipe();
        _ = self.outbound.orderedRemove(room);
    }

    pub fn unboundSessionCount(self: *const Manager) usize {
        return self.unbound.count();
    }

    pub fn forwardedSessionCount(self: *const Manager) usize {
        var n: usize = 0;
        for (self.forwarded.values()) |m| n += m.count();
        return n;
    }

    /// encrypt_for_room; the ciphertext is allocated with `gpa`.
    pub fn encryptForRoom(self: *Manager, gpa: Allocator, room: []const u8, plaintext: []const u8, rng: std.Random) Allocator.Error!EncryptedMessage {
        const s = try self.getOutbound(room, rng);
        const sealed = try s.encrypt(gpa, plaintext, rng);
        return .{ .session_id = s.session_id, .message_index = sealed.index, .ciphertext = sealed.blob, .sender_device = self.device_id };
    }

    /// share_room_key: one share per target device found in the store, of the
    /// room's session at its CURRENT index; results allocated with `gpa`.
    pub fn shareRoomKey(self: *Manager, gpa: Allocator, room: []const u8, targets: []const Target, rng: std.Random) Allocator.Error![]KeyShareEvent {
        const s = try self.getOutbound(room, rng);
        const exported = s.exportKey();
        var events: std.ArrayListUnmanaged(KeyShareEvent) = .empty;
        errdefer events.deinit(gpa);
        for (targets) |t| {
            const x = self.deviceKey(t) orelse continue;
            try events.append(gpa, .{
                .room_id = room,
                .session_id = exported.session_id,
                .target_user = t.user,
                .target_device = t.device,
                .encrypted_key = try self.sealKey(gpa, exported, null, x, rng),
                .sender_x25519_public = self.device.public_key,
            });
        }
        return events.toOwnedSlice(gpa);
    }

    /// The first device of t.user with id t.device in the store.
    fn deviceKey(self: *const Manager, t: Target) ?Key32 {
        const st = self.store orelse return null;
        for (st.query(t.user)) |dk| {
            if (std.mem.eql(u8, dk.device_id, t.device)) return dk.x25519;
        }
        return null;
    }

    /// encrypt_key_for_device, and encrypt_forward_for_device when `origin`
    /// is given; empty when ECDH refuses the target key.
    fn sealKey(self: *Manager, gpa: Allocator, key: megolm.ExportedKey, origin: ?[]const u8, target: Key32, rng: std.Random) Allocator.Error![]u8 {
        if (origin) |o| {
            if (o.len == 0 or o.len > 0xFFFF) return gpa.alloc(u8, 0);
        }
        var k = shareKey(self.device.secret_key, target) catch return gpa.alloc(u8, 0);
        defer std.crypto.secureZero(u8, &k);
        const payload = try serializeExportedKey(gpa, key, origin);
        defer {
            std.crypto.secureZero(u8, payload);
            gpa.free(payload);
        }
        var iv: [crypto.iv_len]u8 = undefined;
        rng.bytes(&iv);
        return crypto.gcmSeal(gpa, k, payload, iv);
    }

    /// receive_key_share: imports the share as sender_user's session when one
    /// of sender_user's published device keys sealed it.
    pub fn receiveKeyShare(self: *Manager, event: KeyShareEvent) Allocator.Error!ShareStatus {
        if (event.sender_user.len == 0) {
            self.refused_unbound += 1;
            return .no_sender;
        }
        const devices = if (self.store) |st| st.query(event.sender_user) else &[_]DeviceKeys{};
        var sealed_by_sender = false;
        for (devices) |d| {
            if (std.mem.eql(u8, &d.x25519, &event.sender_x25519_public)) sealed_by_sender = true;
        }
        if (!sealed_by_sender) return .not_senders_key;

        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const opened = (try self.openShare(scratch.allocator(), event.encrypted_key, event.sender_x25519_public)) orelse
            return .undecryptable;
        defer std.crypto.secureZero(u8, opened.plaintext);
        const exported = opened.key;
        var origin = opened.origin;
        // A sender forwarding its own session is an ordinary share.
        if (origin) |o| {
            if (std.mem.eql(u8, o, event.sender_user)) origin = null;
        }

        // Only a counter-0 share can prove its id.
        const sid_of_ratchets = megolm.sessionId(exported.ratchets);
        const proven = exported.counter == 0 and std.mem.eql(u8, exported.session_id, &sid_of_ratchets);
        if (exported.counter == 0 and !proven) return .refused;

        if (origin) |o| {
            // The origin's own copy stays authoritative for what it covers; a
            // forward adds only an earlier start on the same chain.
            if (self.inbound.getPtr(o)) |by| {
                if (by.getPtr(exported.session_id)) |own| {
                    const held = own.exportKey();
                    if (exported.counter >= held.counter or !megolm.keyReaches(exported, held)) return .imported;
                }
            }
            const fwd = try self.forwardsOf(o);
            if (fwd.getPtr(exported.session_id)) |it| {
                const held = it.session.exportKey();
                const earlier = exported.counter < held.counter;
                const same_chain = if (earlier) megolm.keyReaches(exported, held) else megolm.keyReaches(held, exported);
                if (same_chain and !earlier) return .imported;
                if (!same_chain and !proven) return .refused;
            }
            try self.putForward(fwd, event.sender_user, exported);
            return .imported;
        }
        const senders = try self.sessionsOf(event.sender_user);
        if (senders.getPtr(exported.session_id)) |it| {
            // Same chain: keep the earlier start. Other chain: only a proven id wins.
            const held = it.exportKey();
            const earlier = exported.counter < held.counter;
            const same_chain = if (earlier) megolm.keyReaches(exported, held) else megolm.keyReaches(held, exported);
            if (same_chain and !earlier) return .imported;
            if (!same_chain and !proven) return .refused;
        }
        try self.putSession(senders, exported);
        return .imported;
    }

    const Opened = struct {
        plaintext: []u8,
        key: megolm.ExportedKey,
        origin: ?[]const u8,
    };

    /// decrypt_key_from_share: ECDH with this device's key, else a retired
    /// one, then HKDF and AES-GCM, then the payload. Null when none opens it.
    fn openShare(self: *Manager, gpa: Allocator, blob: []const u8, sender: Key32) Allocator.Error!?Opened {
        var plaintext = try openWith(gpa, self.device.secret_key, sender, blob);
        var i: usize = 0;
        while (plaintext == null and i < self.retired.items.len) : (i += 1) {
            plaintext = try openWith(gpa, self.retired.items[i].secret_key, sender, blob);
        }
        const pt = plaintext orelse return null;
        const parsed = deserializeExportedKey(pt) orelse return null;
        return .{ .plaintext = pt, .key = parsed.key, .origin = parsed.origin };
    }

    fn openWith(gpa: Allocator, secret: Key32, sender: Key32, blob: []const u8) Allocator.Error!?[]u8 {
        var k = shareKey(secret, sender) catch return null;
        defer std.crypto.secureZero(u8, &k);
        return crypto.gcmOpen(gpa, k, blob) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Undecryptable => return null,
        };
    }

    /// decrypt: the sender's own session (verified), then a session
    /// forwarded for that sender (names the forwarder), then an unbound one.
    pub fn decrypt(self: *Manager, gpa: Allocator, msg: EncryptedMessage, sender: []const u8) Allocator.Error!?Decrypted {
        if (self.inbound.getPtr(sender)) |by| {
            if (by.getPtr(msg.session_id)) |s| {
                if (try s.decrypt(gpa, msg.message_index, msg.ciphertext)) |pt|
                    return .{ .plaintext = pt, .verified = true, .forwarded_by = "" };
            }
        }
        if (self.forwarded.getPtr(sender)) |by| {
            if (by.getPtr(msg.session_id)) |f| {
                if (try f.session.decrypt(gpa, msg.message_index, msg.ciphertext)) |pt|
                    return .{ .plaintext = pt, .verified = false, .forwarded_by = f.by };
            }
        }
        if (self.unbound.getPtr(msg.session_id)) |s| {
            if (try s.decrypt(gpa, msg.message_index, msg.ciphertext)) |pt|
                return .{ .plaintext = pt, .verified = false, .forwarded_by = "" };
        }
        return null;
    }

    /// forward_sessions: the bound sessions in `which`, from their first index,
    /// sealed for `targets` with a trailer naming the original sender.
    pub fn forwardSessions(self: *Manager, gpa: Allocator, room: []const u8, which: []const SessionRef, targets: []const Target, rng: std.Random) Allocator.Error![]KeyShareEvent {
        const Held = struct { origin: []const u8, key: megolm.ExportedKey };
        var keys: std.ArrayListUnmanaged(Held) = .empty;
        defer keys.deinit(gpa);
        for (which, 0..) |w, idx| {
            var seen = false;
            for (which[0..idx]) |earlier| {
                if (std.mem.eql(u8, earlier.sender, w.sender) and std.mem.eql(u8, earlier.session_id, w.session_id)) seen = true;
            }
            if (seen) continue;
            const by = self.inbound.getPtr(w.sender) orelse continue;
            const s = by.getPtr(w.session_id) orelse continue;
            try keys.append(gpa, .{ .origin = w.sender, .key = s.exportKey() });
        }
        var events: std.ArrayListUnmanaged(KeyShareEvent) = .empty;
        errdefer events.deinit(gpa);
        for (targets) |t| {
            const x = self.deviceKey(t) orelse continue;
            for (keys.items) |h| {
                try events.append(gpa, .{
                    .room_id = room,
                    .session_id = h.key.session_id,
                    .target_user = t.user,
                    .target_device = t.device,
                    .encrypted_key = try self.sealKey(gpa, h.key, h.origin, x, rng),
                    .sender_x25519_public = self.device.public_key,
                });
            }
        }
        return events.toOwnedSlice(gpa);
    }

    /// export_sessions: compact JSON of every outbound (current state) and
    /// inbound (initial state) session. Holds key material.
    pub fn exportSessions(self: *const Manager, gpa: Allocator) Allocator.Error![]u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var outbound = try json.Array.init(a);
        var it = self.outbound.iterator();
        while (it.next()) |e| {
            var o = try sessionJson(a, e.value_ptr.exportKey());
            try o.string("room_id", e.key_ptr.*);
            try outbound.raw(try o.finish());
        }
        var inbound = try json.Array.init(a);
        var bi = self.inbound.iterator();
        while (bi.next()) |e| {
            for (e.value_ptr.values()) |s| {
                var o = try sessionJson(a, s.exportKey());
                try o.string("sender_user", e.key_ptr.*);
                try inbound.raw(try o.finish());
            }
        }
        for (self.unbound.values()) |s| {
            var o = try sessionJson(a, s.exportKey());
            try inbound.raw(try o.finish());
        }
        var fi = self.forwarded.iterator();
        while (fi.next()) |e| {
            for (e.value_ptr.values()) |f| {
                var o = try sessionJson(a, f.session.exportKey());
                try o.string("sender_user", e.key_ptr.*);
                try o.string("forwarded_by", f.by);
                try inbound.raw(try o.finish());
            }
        }
        var root = try json.Object.init(a);
        try root.raw("outbound", try outbound.finish());
        try root.raw("inbound", try inbound.finish());
        const text = try root.finish();
        return gpa.dupe(u8, text);
    }

    /// import_sessions: all or nothing; false on any malformed entry. An
    /// inbound entry without "sender_user" imports unbound.
    pub fn importSessions(self: *Manager, text: []const u8) Allocator.Error!bool {
        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const root = json.parse(sa, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => return false,
        };
        if (root.asObject() == null) return false;
        const OutEntry = struct { room: []const u8, key: megolm.ExportedKey };
        const InEntry = struct { sender: ?[]const u8, forwarded_by: ?[]const u8, key: megolm.ExportedKey };
        var outs: std.ArrayListUnmanaged(OutEntry) = .empty;
        var ins: std.ArrayListUnmanaged(InEntry) = .empty;
        const out_arr = (root.get("outbound") orelse return false).asArray() orelse return false;
        for (out_arr) |item| {
            if (item.asObject() == null) return false;
            const room = json.getString(item, "room_id") orelse return false;
            if (room.len == 0) return false;
            const key = (try parseSession(sa, item)) orelse return false;
            try outs.append(sa, .{ .room = room, .key = key });
        }
        const in_arr = (root.get("inbound") orelse return false).asArray() orelse return false;
        for (in_arr) |item| {
            if (item.asObject() == null) return false;
            const key = (try parseSession(sa, item)) orelse return false;
            const sender = userField(item, "sender_user") orelse return false;
            const fwd_by = userField(item, "forwarded_by") orelse return false;
            if (fwd_by.value != null and sender.value == null) return false;
            try ins.append(sa, .{ .sender = sender.value, .forwarded_by = fwd_by.value, .key = key });
        }

        for (outs.items) |o| {
            const s = try megolm.Outbound.fromExported(self.alloc(), o.key);
            const gop = try self.outbound.getOrPut(self.alloc(), o.room);
            if (!gop.found_existing) gop.key_ptr.* = try self.alloc().dupe(u8, o.room);
            gop.value_ptr.* = s;
        }
        for (ins.items) |e| {
            if (e.forwarded_by) |by| {
                try self.putForward(try self.forwardsOf(e.sender.?), by, e.key);
            } else if (e.sender) |sender| {
                try self.putSession(try self.sessionsOf(sender), e.key);
            } else {
                try self.putSession(&self.unbound, e.key);
            }
        }
        // A session saved before senders kept an inbound copy has none: give it
        // one at its CURRENT index, so what is sent from now on reads back.
        if (self.user_id.len != 0) {
            const own = try self.sessionsOf(self.user_id);
            for (outs.items) |o| {
                if (!own.contains(o.key.session_id)) try self.putSession(own, o.key);
            }
        }
        return true;
    }
};

fn sessionJson(a: Allocator, k: megolm.ExportedKey) Allocator.Error!json.Object {
    var o = try json.Object.init(a);
    try o.string("session_id", k.session_id);
    try o.uint("counter", k.counter);
    var hexes: [megolm.num_ratchets][]const u8 = undefined;
    for (k.ratchets, 0..) |r, i| hexes[i] = try crypto.toHex(a, &r);
    try o.strings("ratchets", &hexes);
    return o;
}

/// parse_session: session_id non-empty, counter <= u32 max, exactly four
/// 64-character hex ratchets.
fn parseSession(a: Allocator, obj: json.Value) Allocator.Error!?megolm.ExportedKey {
    const sid = json.getString(obj, "session_id") orelse return null;
    if (sid.len == 0) return null;
    const counter = (obj.get("counter") orelse return null).asUint() orelse return null;
    if (counter > std.math.maxInt(u32)) return null;
    const arr = (obj.get("ratchets") orelse return null).asArray() orelse return null;
    if (arr.len != megolm.num_ratchets) return null;
    var key: megolm.ExportedKey = .{ .session_id = sid, .ratchets = undefined, .counter = @intCast(counter) };
    for (arr, 0..) |v, i| {
        const s = v.asString() orelse return null;
        key.ratchets[i] = crypto.fromHex32(s) orelse return null;
    }
    _ = a;
    return key;
}

const UserField = struct { value: ?[]const u8 };

/// parse_user_field: absent is fine; present must be a non-empty string.
fn userField(obj: json.Value, field: []const u8) ?UserField {
    const v = obj.get(field) orelse return .{ .value = null };
    const s = v.asString() orelse return null;
    if (s.len == 0) return null;
    return .{ .value = s };
}

/// Format: u16 BE id length, id, u32 BE counter, R0..R3; a forward appends
/// "FWD1", a u16 BE length and the original sender.
pub fn serializeExportedKey(gpa: Allocator, key: megolm.ExportedKey, origin: ?[]const u8) Allocator.Error![]u8 {
    const sid_len: u16 = @truncate(key.session_id.len);
    var n: usize = 2 + key.session_id.len + 4 + 32 * megolm.num_ratchets;
    if (origin) |o| n += forward_magic.len + 2 + o.len;
    const out = try gpa.alloc(u8, n);
    std.mem.writeInt(u16, out[0..2], sid_len, .big);
    @memcpy(out[2..][0..key.session_id.len], key.session_id);
    var pos = 2 + key.session_id.len;
    std.mem.writeInt(u32, out[pos..][0..4], key.counter, .big);
    pos += 4;
    for (key.ratchets) |r| {
        @memcpy(out[pos..][0..32], &r);
        pos += 32;
    }
    if (origin) |o| {
        @memcpy(out[pos..][0..4], forward_magic);
        std.mem.writeInt(u16, out[pos + 4 ..][0..2], @intCast(o.len), .big);
        @memcpy(out[pos + 6 ..][0..o.len], o);
    }
    return out;
}

pub const Deserialized = struct {
    key: megolm.ExportedKey,
    origin: ?[]const u8,
};

/// deserialize_exported_key; slices point into `data`. Trailing bytes that
/// are not a forward trailer are ignored, as older readers do.
pub fn deserializeExportedKey(data: []const u8) ?Deserialized {
    if (data.len < 2) return null;
    const sid_len: usize = std.mem.readInt(u16, data[0..2], .big);
    var pos: usize = 2;
    if (pos + sid_len + 4 + 32 * megolm.num_ratchets > data.len) return null;
    var key: megolm.ExportedKey = .{ .session_id = data[pos .. pos + sid_len], .ratchets = undefined, .counter = 0 };
    pos += sid_len;
    key.counter = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4;
    for (&key.ratchets) |*r| {
        r.* = data[pos..][0..32].*;
        pos += 32;
    }
    var origin: ?[]const u8 = null;
    if (data.len - pos >= 4 and std.mem.eql(u8, data[pos .. pos + 4], forward_magic)) {
        if (data.len - pos < 6) return null;
        const n: usize = std.mem.readInt(u16, data[pos + 4 ..][0..2], .big);
        if (n == 0 or pos + 6 + n != data.len) return null;
        origin = data[pos + 6 .. pos + 6 + n];
    }
    return .{ .key = key, .origin = origin };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "exported key: the forward trailer must end the payload exactly" {
    const gpa = testing.allocator;
    const r: megolm.Ratchets = .{ [_]u8{1} ** 32, [_]u8{2} ** 32, [_]u8{3} ** 32, [_]u8{4} ** 32 };
    const key: megolm.ExportedKey = .{ .session_id = "sid", .ratchets = r, .counter = 9 };
    const plain = try serializeExportedKey(gpa, key, null);
    defer gpa.free(plain);
    try testing.expectEqual(@as(usize, 2 + 3 + 4 + 128), plain.len);
    const back = deserializeExportedKey(plain).?;
    try testing.expectEqualStrings("sid", back.key.session_id);
    try testing.expectEqual(@as(u32, 9), back.key.counter);
    try testing.expect(back.origin == null);

    const fwd = try serializeExportedKey(gpa, key, "@a:x");
    defer gpa.free(fwd);
    try testing.expectEqualStrings("@a:x", deserializeExportedKey(fwd).?.origin.?);
    // A trailer that does not end the payload, or names nobody, is malformed.
    const longer = try std.mem.concat(gpa, u8, &.{ fwd, "z" });
    defer gpa.free(longer);
    try testing.expect(deserializeExportedKey(longer) == null);
    var empty = try gpa.dupe(u8, fwd[0 .. fwd.len - 4]);
    defer gpa.free(empty);
    std.mem.writeInt(u16, empty[empty.len - 2 ..][0..2], 0, .big);
    try testing.expect(deserializeExportedKey(empty) == null);
    // Other trailing bytes are ignored.
    const junk = try std.mem.concat(gpa, u8, &.{ plain, "xyz" });
    defer gpa.free(junk);
    try testing.expect(deserializeExportedKey(junk).?.origin == null);
    try testing.expect(deserializeExportedKey(plain[0 .. plain.len - 1]) == null);
}
