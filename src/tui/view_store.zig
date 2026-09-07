const std = @import("std");
const Model = @import("model.zig").Model;

const Disk = struct {
    schema_version: u32 = 1,
    show_closed: bool = false,
    expanded_issues: []const u64 = &.{},
    expanded_tasks: []const u64 = &.{},
    selected_task: ?u64 = null,
    selected_issue_token: ?u64 = null,
    selected_unlinked: bool = false,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8, model: *Model) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| return switch (err) {
        error.FileNotFound => {},
        else => error.ReadFailed,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(Disk, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidViewState;
    defer parsed.deinit();
    if (parsed.value.schema_version != 1) return error.InvalidViewState;
    model.show_closed = parsed.value.show_closed;
    for (parsed.value.expanded_issues) |token| try model.expanded_issues.put(allocator, token, {});
    for (parsed.value.expanded_tasks) |id| try model.expanded_tasks.put(allocator, id, {});
    model.selected_task = parsed.value.selected_task;
    model.selected_issue_token = parsed.value.selected_issue_token;
    model.selected_unlinked = parsed.value.selected_unlinked;
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, path: []const u8, model: *const Model) !void {
    var issues: std.ArrayList(u64) = .empty;
    defer issues.deinit(allocator);
    var issue_it = model.expanded_issues.keyIterator();
    while (issue_it.next()) |key| try issues.append(allocator, key.*);
    var tasks: std.ArrayList(u64) = .empty;
    defer tasks.deinit(allocator);
    var task_it = model.expanded_tasks.keyIterator();
    while (task_it.next()) |key| try tasks.append(allocator, key.*);
    std.mem.sort(u64, issues.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, tasks.items, {}, std.sort.asc(u64));
    const bytes = try std.json.Stringify.valueAlloc(allocator, Disk{ .show_closed = model.show_closed, .expanded_issues = issues.items, .expanded_tasks = tasks.items, .selected_task = model.selected_task, .selected_issue_token = model.selected_issue_token, .selected_unlinked = model.selected_unlinked }, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    var atomic = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch return error.WriteFailed;
    defer atomic.deinit(io);
    std.Io.File.writeStreamingAll(atomic.file, io, bytes) catch return error.WriteFailed;
    atomic.file.sync(io) catch return error.WriteFailed;
    atomic.replace(io) catch return error.WriteFailed;
}

test "view state round trips independently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const path = try std.fs.path.join(a, &.{ base, "view.json" });
    defer a.free(path);
    var source: Model = .{};
    defer source.deinit(a);
    source.show_closed = true;
    try source.expanded_issues.put(a, 42, {});
    try source.expanded_tasks.put(a, 7, {});
    source.selected_task = 7;
    try save(a, std.testing.io, path, &source);
    var restored: Model = .{};
    defer restored.deinit(a);
    try load(a, std.testing.io, path, &restored);
    try std.testing.expect(restored.show_closed);
    try std.testing.expect(restored.expanded_issues.contains(42));
    try std.testing.expect(restored.expanded_tasks.contains(7));
    try std.testing.expectEqual(@as(?u64, 7), restored.selected_task);
}

test "invalid view state is rejected without mutating the model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const path = try std.fs.path.join(a, &.{ base, "view.json" });
    defer a.free(path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try std.Io.File.writeStreamingAll(file, std.testing.io, "{broken");

    var model: Model = .{ .show_closed = true };
    defer model.deinit(a);
    try std.testing.expectError(error.InvalidViewState, load(a, std.testing.io, path, &model));
    try std.testing.expect(model.show_closed);
}

test "atomic save reports failure when destination parent is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const path = try std.fs.path.join(a, &.{ base, "missing", "view.json" });
    defer a.free(path);
    var model: Model = .{};
    defer model.deinit(a);
    try std.testing.expectError(error.WriteFailed, save(a, std.testing.io, path, &model));
}
