const std = @import("std");
const state_mod = @import("../core/state.zig");

pub const Model = struct {
    selected: usize = 0,

    pub fn moveDown(self: *Model, count: usize) void {
        if (count != 0 and self.selected + 1 < count) self.selected += 1;
    }

    pub fn moveUp(self: *Model) void {
        self.selected -|= 1;
    }

    pub fn selectedTaskId(self: Model, ordered_ids: []const u64) ?u64 {
        if (self.selected >= ordered_ids.len) return null;
        return ordered_ids[self.selected];
    }
};

test "selection remains within task list" {
    var model: Model = .{};
    model.moveDown(2);
    model.moveDown(2);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    model.moveUp();
    model.moveUp();
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    try std.testing.expectEqual(@as(?u64, 7), model.selectedTaskId(&.{ 7, 8 }));
}
