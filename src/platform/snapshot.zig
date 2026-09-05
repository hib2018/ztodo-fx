const std = @import("std");
var snapshot_counter = std.atomic.Value(u64).init(0);
pub const standard_excludes = [_][]const u8{ ".git", ".env", ".env.local", ".DS_Store", ".zig-cache", "zig-out", "credentials", "secrets", "id_rsa", "id_ed25519", ".npmrc", ".pypirc", ".aws" };
pub const max_snapshot_bytes: u64 = 64 * 1024 * 1024;
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
        self.cleanup(a, io) catch {};
        a.free(self.path);
        a.free(self.owned_root);
    }
    pub fn cleanup(self: Snapshot, a: std.mem.Allocator, io: std.Io) !void {
        try validateOwnedRoot(self.owned_root, self.path);
        const process = @import("process.zig");
        const writable = try process.run(a, io, .{ .argv = &.{ "chmod", "-R", "u+w", self.path } });
        defer writable.deinit(a);
        if (!process.successful(writable.term)) return error.SnapshotCleanupFailed;
        std.Io.Dir.cwd().deleteTree(io, self.path) catch return error.SnapshotCleanupFailed;
    }
};
pub fn createEmpty(a: std.mem.Allocator, io: std.Io, base: []const u8) !Snapshot {
    const root = try std.fs.path.join(a, &.{ base, "ztodo-fx-snapshots" });
    errdefer a.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const serial = snapshot_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(a, "{d}-{d}", .{ std.Io.Clock.awake.now(io).toSeconds(), serial });
    defer a.free(name);
    const path = try std.fs.path.join(a, &.{ root, name });
    errdefer a.free(path);
    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
    return .{ .path = path, .owned_root = root };
}
pub fn create(a: std.mem.Allocator, io: std.Io, base: []const u8, workspace: []const u8, custom: []const []const u8) !Snapshot {
    const snap = try createEmpty(a, io, base);
    errdefer snap.deinit(a, io);
    const process = @import("process.zig");
    const source = try std.fs.path.join(a, &.{ workspace, "." });
    defer a.free(source);
    const copied = try process.run(a, io, .{ .argv = &.{ "cp", "-R", "-P", source, snap.path } });
    defer copied.deinit(a);
    if (!process.successful(copied.term)) return error.SnapshotCopyFailed;
    for (standard_excludes) |name| try removeMatches(a, io, snap.path, name);
    for (custom) |name| try removeMatches(a, io, snap.path, name);
    try enforceSize(a, io, snap.path);
    const readonly = try process.run(a, io, .{ .argv = &.{ "chmod", "-R", "a-w", snap.path } });
    defer readonly.deinit(a);
    if (!process.successful(readonly.term)) return error.SnapshotReadonlyFailed;
    return snap;
}
fn enforceSize(a: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const process = @import("process.zig");
    const result = try process.run(a, io, .{ .argv = &.{ "du", "-sk", root } });
    defer result.deinit(a);
    if (!process.successful(result.term)) return error.SnapshotSizeCheckFailed;
    var tokens = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    const first = tokens.next() orelse return error.SnapshotSizeCheckFailed;
    const kib = std.fmt.parseInt(u64, first, 10) catch return error.SnapshotSizeCheckFailed;
    if (kib * 1024 > max_snapshot_bytes) return error.SnapshotTooLarge;
}
fn removeMatches(a: std.mem.Allocator, io: std.Io, root: []const u8, pattern: []const u8) !void {
    if (pattern.len == 0 or std.mem.eql(u8, pattern, ".") or std.mem.eql(u8, pattern, "..") or std.fs.path.isAbsolute(pattern)) return error.UnsafeExcludePattern;
    const process = @import("process.zig");
    const result = try process.run(a, io, .{ .argv = &.{ "find", root, "-mindepth", "1", "-name", pattern, "-exec", "rm", "-rf", "{}", "+" } });
    defer result.deinit(a);
    if (!process.successful(result.term)) return error.SnapshotExcludeFailed;
}
test "secret and custom paths are excluded" {
    try std.testing.expect(shouldExclude(".env", &.{}));
    try std.testing.expect(shouldExclude("generated/cache", &.{"generated"}));
}
test "cleanup cannot escape owned root" {
    try std.testing.expectError(error.UnsafeCleanupTarget, validateOwnedRoot("/tmp/owned", "/tmp/other"));
}
test "snapshot size limit is bounded" {
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), max_snapshot_bytes);
}
test "snapshot directories are unique" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const first = try createEmpty(std.testing.allocator, std.testing.io, base);
    defer first.deinit(std.testing.allocator, std.testing.io);
    const second = try createEmpty(std.testing.allocator, std.testing.io, base);
    defer second.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
}
test "snapshot copies normal files excludes nested secrets and cleans read-only tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try tmp.dir.createDirPath(io, "workspace/nested");
    {
        const file = try tmp.dir.createFile(io, "workspace/visible.txt", .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, "visible");
    }
    {
        const file = try tmp.dir.createFile(io, "workspace/nested/.env", .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, "secret");
    }
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const workspace = try tmp.dir.realPathFileAlloc(io, "workspace", a);
    defer a.free(workspace);
    const snap = try create(a, io, base, workspace, &.{});
    defer {
        a.free(snap.path);
        a.free(snap.owned_root);
    }
    const visible = try std.fs.path.join(a, &.{ snap.path, "visible.txt" });
    defer a.free(visible);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, visible, a, .limited(64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("visible", bytes);
    const secret = try std.fs.path.join(a, &.{ snap.path, "nested", ".env" });
    defer a.free(secret);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, secret, .{}));
    try snap.cleanup(a, io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, snap.path, .{}));
}
