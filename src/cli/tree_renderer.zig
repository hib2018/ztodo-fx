const std = @import("std");
const state = @import("../core/state.zig");
pub fn render(allocator: std.mem.Allocator, s: *const state.StateRoot) ![]u8 {
    return renderFiltered(allocator, s, null);
}
pub fn renderFiltered(allocator: std.mem.Allocator, s: *const state.StateRoot, filter: ?@import("../core/task.zig").IssueKey) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (s.issues.items) |issue| {
        if (filter) |key| if (!issue.key.eql(key)) continue;
        try out.writer.print("{s}#{d} [{s}] {s}\n", .{ issue.key.repository, issue.key.issue_number, @tagName(issue.status), issue.title });
        try renderChildren(&out.writer, s, issue.key, null, 1);
    }
    if (filter == null) {
        try out.writer.writeAll("Unlinked\n");
        try renderChildren(&out.writer, s, null, null, 1);
    }
    return out.toOwnedSlice();
}

fn renderChildren(w: *std.Io.Writer, s: *const state.StateRoot, issue: ?@import("../core/task.zig").IssueKey, parent: ?u64, indent: usize) !void {
    var position: u32 = 0;
    while (true) : (position += 1) {
        var found = false;
        for (s.tasks.items) |t| {
            if (t.parent_id == parent and t.position == position and state.optionalKeyEql(t.issue_key, issue)) {
                found = true;
                for (0..indent) |_| try w.writeAll("  ");
                try w.print("{s} {d}: {s}\n", .{ if (t.status == .done) "[x]" else "[ ]", t.id, t.title });
                try renderChildren(w, s, issue, t.id, indent + 1);
            }
        }
        if (!found) break;
    }
}
test "renderer includes status and id" {
    var s = state.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.addTask("x", null, null);
    const text = try render(std.testing.allocator, &s);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[ ] 1: x") != null);
}
test "renderer shows Unicode branches issue state and filtering" {
    var s = state.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    try s.issues.append(std.testing.allocator, .{ .key = .{ .repository = try std.testing.allocator.dupe(u8, "a/b"), .issue_number = 1 }, .title = try std.testing.allocator.dupe(u8, "課題"), .body = try std.testing.allocator.dupe(u8, ""), .status = .closed });
    try s.issues.append(std.testing.allocator, .{ .key = .{ .repository = try std.testing.allocator.dupe(u8, "a/b"), .issue_number = 2 }, .title = try std.testing.allocator.dupe(u8, "除外"), .body = try std.testing.allocator.dupe(u8, "") });
    const root = try s.addTask("親", .{ .repository = "a/b", .issue_number = 1 }, null);
    const child = try s.addTask("子", .{ .repository = "a/b", .issue_number = 1 }, root);
    _ = try s.toggle(child);
    const text = try renderFiltered(std.testing.allocator, &s, .{ .repository = "a/b", .issue_number = 1 });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[closed] 課題") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[x] 2: 子") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "除外") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Unlinked") == null);
}
