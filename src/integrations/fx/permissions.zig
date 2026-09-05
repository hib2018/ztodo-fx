const std = @import("std");
const process = @import("../../platform/process.zig");
pub fn validateJson(a: std.mem.Allocator, bytes: []const u8, workspace: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidPermissions;
    defer parsed.deinit();
    try scan(parsed.value, workspace);
}
fn scan(value: std.json.Value, workspace: []const u8) !void {
    switch (value) {
        .object => |obj| {
            var action: ?[]const u8 = null;
            var tool: ?[]const u8 = null;
            var path: ?[]const u8 = null;
            if (obj.get("action")) |v| if (v == .string) {
                action = v.string;
            };
            if (obj.get("tool")) |v| if (v == .string) {
                tool = v.string;
            };
            if (obj.get("path")) |v| if (v == .string) {
                path = v.string;
            };
            if (action != null and std.mem.eql(u8, action.?, "allow")) {
                if (tool) |t| if (std.ascii.eqlIgnoreCase(t, "terminal") or std.mem.indexOf(u8, t, "write") != null or std.mem.indexOf(u8, t, "upload") != null) return error.UnsafePermission;
                if (path) |p| if (std.fs.path.isAbsolute(p) and !std.mem.startsWith(u8, p, workspace)) return error.UnsafePermission;
            }
            var it = obj.iterator();
            while (it.next()) |e| try scan(e.value_ptr.*, workspace);
        },
        .array => |arr| for (arr.items) |item| try scan(item, workspace),
        else => {},
    }
}
pub fn preflight(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, workspace: []const u8) !void {
    const result = try process.run(a, io, .{ .argv = &.{ env.get("ZTODO_FX_FX_BIN") orelse "fx", "permissions", "--json" }, .env_map = env });
    defer result.deinit(a);
    if (!process.successful(result.term)) return error.PermissionCheckFailed;
    try validateJson(a, result.stdout, workspace);
}
test "terminal allow is rejected" {
    try std.testing.expectError(error.UnsafePermission, validateJson(std.testing.allocator, "{\"rules\":[{\"action\":\"allow\",\"tool\":\"Terminal\"}]}", "/tmp/w"));
}
test "write upload and external paths are rejected" {
    for ([_][]const u8{ "write", "upload" }) |tool| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"action\":\"allow\",\"tool\":\"{s}\"}}", .{tool});
        defer std.testing.allocator.free(json);
        try std.testing.expectError(error.UnsafePermission, validateJson(std.testing.allocator, json, "/tmp/work"));
    }
    try std.testing.expectError(error.UnsafePermission, validateJson(std.testing.allocator, "{\"action\":\"allow\",\"path\":\"/etc\"}", "/tmp/work"));
}
