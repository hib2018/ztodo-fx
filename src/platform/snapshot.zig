const std = @import("std");
pub const standard_excludes = [_][]const u8{ ".git", ".env", ".env.local", "credentials", "secrets", "id_rsa", "id_ed25519", ".npmrc", ".pypirc", ".aws" };
pub fn shouldExclude(relative: []const u8, custom: []const []const u8) bool {
    for (standard_excludes) |pattern| if (std.mem.eql(u8, relative, pattern) or std.mem.startsWith(u8, relative, pattern)) return true;
    for (custom) |pattern| if (std.mem.indexOf(u8, relative, pattern) != null) return true;
    return false;
}
pub fn validateOwnedRoot(root: []const u8, target: []const u8) !void {
    if (!std.fs.path.isAbsolute(root) or !std.fs.path.isAbsolute(target) or !std.mem.startsWith(u8, target, root) or target.len <= root.len) return error.UnsafeCleanupTarget;
}
pub const Snapshot = struct {
    path: []u8,
    owned_root: []u8,
    pub fn deinit(self: Snapshot, a: std.mem.Allocator, io: std.Io) void {
        validateOwnedRoot(self.owned_root, self.path) catch return;
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        a.free(self.path);
        a.free(self.owned_root);
    }
};
pub fn createEmpty(a: std.mem.Allocator, io: std.Io, base: []const u8) !Snapshot {
    const root = try std.fs.path.join(a, &.{ base, "ztodo-fx-snapshots" });
    errdefer a.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const path = try std.fs.path.join(a, &.{ root, "current" });
    errdefer a.free(path);
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    return .{ .path = path, .owned_root = root };
}
pub fn create(a: std.mem.Allocator, io: std.Io, base: []const u8, workspace: []const u8, custom: []const []const u8) !Snapshot {
    const snap = try createEmpty(a, io, base);
    errdefer snap.deinit(a, io);
    const process = @import("process.zig");
    const source = try std.fs.path.join(a, &.{ workspace, "." });
    defer a.free(source);
    const copied = try process.run(a, io, .{ .argv = &.{ "cp", "-R", source, snap.path } });
    defer copied.deinit(a);
    if (!process.successful(copied.term)) return error.SnapshotCopyFailed;
    for (standard_excludes) |name| {
        const target = try std.fs.path.join(a, &.{ snap.path, name });
        defer a.free(target);
        std.Io.Dir.cwd().deleteTree(io, target) catch {};
    }
    for (custom) |name| {
        if (std.mem.indexOfAny(u8, name, "*?[") == null) {
            const target = try std.fs.path.join(a, &.{ snap.path, name });
            defer a.free(target);
            std.Io.Dir.cwd().deleteTree(io, target) catch {};
        }
    }
    const readonly = try process.run(a, io, .{ .argv = &.{ "chmod", "-R", "a-w", snap.path } });
    defer readonly.deinit(a);
    if (!process.successful(readonly.term)) return error.SnapshotReadonlyFailed;
    return snap;
}
test "secret and custom paths are excluded" {
    try std.testing.expect(shouldExclude(".env", &.{}));
    try std.testing.expect(shouldExclude("generated/cache", &.{"generated"}));
}
test "cleanup cannot escape owned root" {
    try std.testing.expectError(error.UnsafeCleanupTarget, validateOwnedRoot("/tmp/owned", "/tmp/other"));
}
