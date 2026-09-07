const std = @import("std");

pub const Model = struct {
    pub const Focus = enum { tree, details };
    pub const Mode = enum {
        normal,
        add,
        edit,
        task_reparent,
        search,
        menu,
        repositories,
        repository_add,
        repository_workspace,
        confirm_repository_delete,
        confirm_delete,
        confirm_clear,
        help,
        proposal,
        proposal_running,
        proposal_add,
        proposal_edit,
        proposal_reparent,
        confirm_proposal_delete,
        confirm_proposal_approve,
        confirm_proposal_duplicates,
        confirm_proposal_discard,
        issue_edit_title,
        issue_edit_body,
        issue_create_title,
        issue_create_body,
        issue_create_repository,
        confirm_issue_edit,
        confirm_issue_create,
        confirm_issue_state,
    };
    pub const MenuTab = enum { proposal, repositories, issues };

    selected: usize = 0,
    selected_issue: usize = 0,
    selected_candidate: usize = 0,
    selected_repository: usize = 0,
    menu_tab: MenuTab = .proposal,
    menu_selected: usize = 0,
    show_closed: bool = false,
    focus: Focus = .tree,
    mode: Mode = .normal,
    input: [800]u8 = undefined,
    input_len: usize = 0,
    filter: [200]u8 = undefined,
    filter_len: usize = 0,
    message: [256]u8 = undefined,
    message_len: usize = 0,
    expanded_issues: std.AutoHashMapUnmanaged(u64, void) = .empty,
    expanded_unlinked: bool = false,
    expanded_tasks: std.AutoHashMapUnmanaged(u64, void) = .empty,
    detail_scroll: usize = 0,
    selected_task: ?u64 = null,
    selected_issue_token: ?u64 = null,
    selected_unlinked: bool = false,
    selection_restored: bool = false,
    issue_draft_title: [800]u8 = undefined,
    issue_draft_title_len: usize = 0,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.expanded_issues.deinit(allocator);
        self.expanded_tasks.deinit(allocator);
    }

    pub fn moveDown(self: *Model, count: usize) void {
        if (count != 0 and self.selected + 1 < count) self.selected += 1;
    }

    pub fn moveUp(self: *Model) void {
        self.selected -|= 1;
    }

    pub fn nextFocus(self: *Model) void {
        self.focus = switch (self.focus) {
            .tree => .details,
            .details => .tree,
        };
    }

    pub fn previousFocus(self: *Model) void {
        self.focus = switch (self.focus) {
            .tree => .details,
            .details => .tree,
        };
    }

    pub fn issueExpanded(self: *const Model, token: u64) bool {
        return self.expanded_issues.contains(token);
    }

    pub fn toggleIssue(self: *Model, allocator: std.mem.Allocator, token: u64) !void {
        if (!self.expanded_issues.remove(token)) try self.expanded_issues.put(allocator, token, {});
    }

    pub fn nextMenuTab(self: *Model) void {
        self.menu_tab = switch (self.menu_tab) {
            .proposal => .repositories,
            .repositories => .issues,
            .issues => .proposal,
        };
        self.menu_selected = 0;
    }

    pub fn previousMenuTab(self: *Model) void {
        self.menu_tab = switch (self.menu_tab) {
            .proposal => .issues,
            .repositories => .proposal,
            .issues => .repositories,
        };
        self.menu_selected = 0;
    }

    pub fn taskExpanded(self: *const Model, id: u64) bool {
        return self.expanded_tasks.contains(id);
    }

    pub fn toggleTask(self: *Model, allocator: std.mem.Allocator, id: u64) !void {
        if (!self.expanded_tasks.remove(id)) try self.expanded_tasks.put(allocator, id, {});
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
    model.nextFocus();
    try std.testing.expectEqual(Model.Focus.details, model.focus);
    model.beginInput(.add, "日本語");
    model.backspace();
    try std.testing.expectEqualStrings("日本", model.inputSlice());
}

test "expanded nodes have no fixed item limit" {
    const allocator = std.testing.allocator;
    var model: Model = .{};
    defer model.deinit(allocator);
    var index: usize = 0;
    while (index < 1500) : (index += 1) {
        try model.toggleIssue(allocator, index);
        try model.toggleTask(allocator, @intCast(index + 1));
    }
    try std.testing.expect(model.issueExpanded(1499));
    try std.testing.expect(model.taskExpanded(1500));
}

test "menu tabs cycle and reset their selection" {
    var model: Model = .{};
    model.menu_selected = 3;
    model.nextMenuTab();
    try std.testing.expectEqual(Model.MenuTab.repositories, model.menu_tab);
    try std.testing.expectEqual(@as(usize, 0), model.menu_selected);
    model.previousMenuTab();
    try std.testing.expectEqual(Model.MenuTab.proposal, model.menu_tab);
}
