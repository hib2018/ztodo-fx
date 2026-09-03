const std = @import("std");
const state = @import("state.zig");
const task = @import("task.zig");
pub fn depth(s: *const state.StateRoot, id: u64) !usize {
    var current = id;
    var d: usize = 0;
    while (true) {
        var found = false;
        for (s.tasks.items) |t| if (t.id == current) {
            found = true;
            if (t.parent_id) |p| {
                current = p;
                d += 1;
                break;
            } else return d;
        };
        if (!found) return error.TaskNotFound;
        if (d > s.tasks.items.len) return error.Cycle;
    }
}
pub fn preorder(a: std.mem.Allocator, s: *const state.StateRoot, issue: ?task.IssueKey) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(a);
    try appendChildren(a, &out, s, issue, null);
    return out.toOwnedSlice(a);
}
fn appendChildren(a: std.mem.Allocator, out: *std.ArrayList(u64), s: *const state.StateRoot, issue: ?task.IssueKey, parent: ?u64) !void {
    var position: u32 = 0;
    while (true) : (position += 1) {
        var child: ?u64 = null;
        for (s.tasks.items) |item| if (item.parent_id == parent and item.position == position and state.optionalKeyEql(item.issue_key, issue)) {
            if (child != null) return error.DuplicatePosition;
            child = item.id;
        };
        const id = child orelse break;
        try out.append(a, id);
        try appendChildren(a, out, s, issue, id);
    }
}
test "depth follows parents" {
    var s = state.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.addTask("a", null, null);
    const b = try s.addTask("b", null, a);
    try std.testing.expectEqual(@as(usize, 1), try depth(&s, b));
}
test "preorder follows position and arbitrary depth" {
    var s = state.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    const root = try s.addTask("root", null, null);
    const child = try s.addTask("child", null, root);
    _ = try s.addTask("sibling", null, null);
    const ids = try preorder(std.testing.allocator, &s, null);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(u64, &.{ root, child, 3 }, ids);
}
