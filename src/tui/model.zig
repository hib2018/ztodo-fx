const std = @import("std");
const state_mod = @import("../core/state.zig");

pub const Model = struct {
    pub const Focus = enum { issues, tasks, details };
    pub const Mode = enum {
        normal,
        add,
        edit,
        search,
        repositories,
        repository_add,
        repository_workspace,
        confirm_repository_delete,
        confirm_delete,
        help,
        proposal,
        proposal_add,
        proposal_edit,
        proposal_reparent,
        confirm_proposal_delete,
        confirm_proposal_approve,
        confirm_proposal_duplicates,
        confirm_proposal_discard,
    };

    selected: usize = 0,
    selected_issue: usize = 0,
    selected_candidate: usize = 0,
    selected_repository: usize = 0,
    focus: Focus = .tasks,
    mode: Mode = .normal,
    input: [800]u8 = undefined,
    input_len: usize = 0,
    filter: [200]u8 = undefined,
    filter_len: usize = 0,
    message: [256]u8 = undefined,
    message_len: usize = 0,

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

    pub fn nextFocus(self: *Model) void {
        self.focus = switch (self.focus) {
            .issues => .tasks,
            .tasks => .details,
            .details => .issues,
        };
    }

    pub fn previousFocus(self: *Model) void {
        self.focus = switch (self.focus) {
            .issues => .details,
            .tasks => .issues,
            .details => .tasks,
        };
    }

    pub fn beginInput(self: *Model, mode: Mode, initial: []const u8) void {
        self.mode = mode;
        self.input_len = @min(initial.len, self.input.len);
        @memcpy(self.input[0..self.input_len], initial[0..self.input_len]);
    }

    pub fn appendInput(self: *Model, bytes: []const u8) void {
        const count = @min(bytes.len, self.input.len - self.input_len);
        @memcpy(self.input[self.input_len..][0..count], bytes[0..count]);
        self.input_len += count;
    }

    pub fn backspace(self: *Model) void {
        if (self.input_len == 0) return;
        self.input_len -= 1;
        while (self.input_len > 0 and (self.input[self.input_len] & 0xc0) == 0x80) self.input_len -= 1;
    }

    pub fn inputSlice(self: *const Model) []const u8 {
        return self.input[0..self.input_len];
    }

    pub fn setMessage(self: *Model, text: []const u8) void {
        self.message_len = @min(text.len, self.message.len);
        @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
    }

    pub fn messageSlice(self: *const Model) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn filterSlice(self: *const Model) []const u8 {
        return self.filter[0..self.filter_len];
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
    model.nextFocus();
    try std.testing.expectEqual(Model.Focus.details, model.focus);
    model.beginInput(.add, "日本語");
    model.backspace();
    try std.testing.expectEqualStrings("日本", model.inputSlice());
}
