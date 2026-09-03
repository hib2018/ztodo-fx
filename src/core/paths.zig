const std = @import("std");

pub const Paths = struct { state: []u8, config: []u8 };

pub fn resolve(allocator: std.mem.Allocator, env: std.process.Environ.Map) !Paths {
    if (env.get("ZTODO_FX_DATA_FILE")) |state_override| {
        const config = env.get("ZTODO_FX_CONFIG_FILE") orelse return error.MissingConfigOverride;
        return .{ .state = try allocator.dupe(u8, state_override), .config = try allocator.dupe(u8, config) };
    }
    const home = env.get("HOME") orelse return error.HomeNotSet;
    const data_root = env.get("XDG_DATA_HOME") orelse try std.fs.path.join(allocator, &.{ home, ".local", "share" });
    defer if (env.get("XDG_DATA_HOME") == null) allocator.free(data_root);
    const config_root = env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(allocator, &.{ home, ".config" });
    defer if (env.get("XDG_CONFIG_HOME") == null) allocator.free(config_root);
    return .{
        .state = try std.fs.path.join(allocator, &.{ data_root, "ztodo-fx", "state.json" }),
        .config = try std.fs.path.join(allocator, &.{ config_root, "ztodo-fx", "config.json" }),
    };
}

pub fn deinit(allocator: std.mem.Allocator, value: Paths) void {
    allocator.free(value.state);
    allocator.free(value.config);
}

pub fn ensureParents(io: std.Io, value: Paths) !void {
    if (std.fs.path.dirname(value.state)) |p| try std.Io.Dir.cwd().createDirPath(io, p);
    if (std.fs.path.dirname(value.config)) |p| try std.Io.Dir.cwd().createDirPath(io, p);
}

test "paths use only ztodo-fx namespace" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/person");
    const value = try resolve(std.testing.allocator, env);
    defer deinit(std.testing.allocator, value);
    try std.testing.expect(std.mem.indexOf(u8, value.state, "ztodo-fx") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.state, "/ztodo/") == null);
}
