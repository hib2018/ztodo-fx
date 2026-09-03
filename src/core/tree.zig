const std = @import("std");
const state = @import("state.zig");
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
test "depth follows parents" {
    var s = state.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.addTask("a", null, null);
    const b = try s.addTask("b", null, a);
    try std.testing.expectEqual(@as(usize, 1), try depth(&s, b));
}
