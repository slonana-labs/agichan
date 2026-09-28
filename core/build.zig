const std = @import("std");

// Steps: default (agichan for -Dtarget), test, test-bin (the test binary, for
// qemu), wasm (the I/O-free core for wasm32-freestanding).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "agichan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run agichan").dependOn(&run.step);

    const tests = b.addTest(.{
        .name = "agichan-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-bin", "Install the test binary (for qemu)")
        .dependOn(&b.addInstallArtifact(tests, .{}).step);

    const wasm = b.addExecutable(.{
        .name = "agichan-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_check.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.step("wasm", "Build the protocol core for wasm32-freestanding")
        .dependOn(&b.addInstallArtifact(wasm, .{}).step);
}
