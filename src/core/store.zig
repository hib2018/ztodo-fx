const std = @import("std");
const state_mod = @import("state.zig");
const task_mod = @import("task.zig");
pub const max_file_size = 16 * 1024 * 1024;

const DiskState = struct { schema_version: u32, next_task_id: u64, tasks: []const task_mod.Task, issues: []const task_mod.IssueSnapshot = &.{}, proposals: []const @import("../proposal/model.zig").Proposal = &.{} };

pub fn encode(a: std.mem.Allocator, state: *const state_mod.StateRoot) ![]u8 {
    try state.validate();
    return std.json.Stringify.valueAlloc(a, DiskState{ .schema_version = state.schema_version, .next_task_id = state.next_task_id, .tasks = state.tasks.items, .issues = state.issues.items, .proposals = state.proposals.items }, .{ .whitespace = .indent_2 });
}
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !state_mod.StateRoot {
    if (bytes.len > max_file_size) return error.FileTooLarge;
    var parsed = std.json.parseFromSlice(DiskState, a, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    defer parsed.deinit();
    var s = state_mod.StateRoot.init(a);
    errdefer s.deinit();
    s.schema_version = parsed.value.schema_version;
    s.next_task_id = parsed.value.next_task_id;
    for (parsed.value.tasks) |t| try s.tasks.append(a, .{ .id = t.id, .title = try a.dupe(u8, t.title), .status = t.status, .issue_key = try state_mod.dupeOptionalKey(a, t.issue_key), .parent_id = t.parent_id, .position = t.position });
    // Issue/proposal decoding is intentionally owned below to keep allocations explicit.
    for (parsed.value.issues) |i| {
        var duplicate = false;
        for (s.issues.items) |existing| if (existing.key.eql(i.key)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        try s.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, i.key.repository), .issue_number = i.key.issue_number }, .title = try a.dupe(u8, i.title), .body = try a.dupe(u8, i.body), .status = i.status, .last_fetched_at = i.last_fetched_at, .last_error = i.last_error });
    }
    std.mem.sort(task_mod.IssueSnapshot, s.issues.items, {}, struct {
        fn lessThan(_: void, left: task_mod.IssueSnapshot, right: task_mod.IssueSnapshot) bool {
            const order = std.mem.order(u8, left.key.repository, right.key.repository);
            return order == .lt or (order == .eq and left.key.issue_number < right.key.issue_number);
        }
    }.lessThan);
    for (parsed.value.proposals) |p| try s.putProposal(p);
    try s.validate();
    return s;
}
pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !state_mod.StateRoot {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_size)) catch |e| return switch (e) {
        error.FileNotFound => state_mod.StateRoot.init(a),
        else => error.ReadFailed,
    };
    defer a.free(bytes);
    return decode(a, bytes);
}
pub fn save(a: std.mem.Allocator, io: std.Io, path: []const u8, state: *const state_mod.StateRoot) !void {
    const bytes = try encode(a, state);
    defer a.free(bytes);
    var atomic = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch return error.WriteFailed;
    defer atomic.deinit(io);
    std.Io.File.writeStreamingAll(atomic.file, io, bytes) catch return error.WriteFailed;
    atomic.file.sync(io) catch return error.WriteFailed;
    atomic.replace(io) catch return error.WriteFailed;
}

test "Unicode round trip and invalid JSON" {
    var s = state_mod.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.addTask("日本語", null, null);
    const json = try encode(std.testing.allocator, &s);
    defer std.testing.allocator.free(json);
    var restored = try decode(std.testing.allocator, json);
    defer restored.deinit();
    try std.testing.expectEqualStrings("日本語", restored.tasks.items[0].title);
    try std.testing.expectError(error.InvalidJson, decode(std.testing.allocator, "{"));
}
test "schema and size limits reject without adopting data" {
    try std.testing.expectError(error.InvalidState, decode(std.testing.allocator, "{\"schema_version\":2,\"next_task_id\":1,\"tasks\":[]}"));
    const huge = try std.testing.allocator.alloc(u8, max_file_size + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, ' ');
    try std.testing.expectError(error.FileTooLarge, decode(std.testing.allocator, huge));
}
test "decode removes duplicate issues and sorts stable keys" {
    const bytes = "{\"schema_version\":1,\"next_task_id\":1,\"tasks\":[],\"issues\":[{\"key\":{\"repository\":\"z/r\",\"issue_number\":2},\"title\":\"two\"},{\"key\":{\"repository\":\"a/r\",\"issue_number\":1},\"title\":\"one\"},{\"key\":{\"repository\":\"z/r\",\"issue_number\":2},\"title\":\"duplicate\"}]}";
    var restored = try decode(std.testing.allocator, bytes);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.issues.items.len);
    try std.testing.expectEqualStrings("a/r", restored.issues.items[0].key.repository);
    try std.testing.expectEqual(@as(u64, 2), restored.issues.items[1].key.issue_number);
}
test "failed validation leaves existing atomic file intact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const path = try std.fs.path.join(a, &.{ base, "state.json" });
    defer a.free(path);
    var good = state_mod.StateRoot.init(a);
    defer good.deinit();
    _ = try good.addTask("keep", null, null);
    try save(a, io, path, &good);
    good.next_task_id = 1;
    try std.testing.expectError(error.InvalidNextId, save(a, io, path, &good));
    var loaded = try load(a, io, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("keep", loaded.tasks.items[0].title);
}
