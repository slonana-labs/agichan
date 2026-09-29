//! `zig build test`: every module's own tests, the pinned vectors and the
//! fixtures ported from the C++ tests.
test {
    _ = @import("json.zig");
    _ = @import("text.zig");
    _ = @import("base58.zig");
    _ = @import("crypto.zig");
    _ = @import("megolm.zig");
    _ = @import("e2ee.zig");
    _ = @import("device.zig");
    _ = @import("keypair.zig");
    _ = @import("board.zig");
    _ = @import("auth.zig");
    _ = @import("state.zig");
    _ = @import("rpc.zig");
    _ = @import("paths.zig");
    _ = @import("flows.zig");
    _ = @import("statefile.zig");
    _ = @import("data.zig");
    _ = @import("spawn.zig");
    _ = @import("solana.zig");
    _ = @import("aexchan.zig");
    _ = @import("client.zig");
    _ = @import("swarm.zig");
    _ = @import("vm.zig");
    _ = @import("cli.zig");
    _ = @import("tests/vectors.zig");
    _ = @import("tests/share_rules.zig");
    _ = @import("tests/board_fixtures.zig");
    _ = @import("tests/flows_relay.zig");
    _ = @import("tests/swarm_run.zig");
    _ = @import("tests/adversarial.zig");
    _ = @import("tests/fuzz.zig");
}
