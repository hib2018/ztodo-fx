const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.1.0");

    const mod = b.addModule("ztodo_fx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "ztodo-fx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ztodo_fx", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run ztodo-fx").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run all tests").dependOn(&run_tests.step);
}
