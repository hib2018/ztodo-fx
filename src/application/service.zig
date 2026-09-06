const std = @import("std");
const state_mod = @import("../core/state.zig");
const store = @import("../core/store.zig");
const task = @import("../core/task.zig");
const proposal_apply = @import("../proposal/apply.zig");

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state_path: []const u8,

    pub fn persistOrRollback(self: Service, state: *state_mod.StateRoot) !void {
        store.save(self.allocator, self.io, self.state_path, state) catch |err| {
            const restored = store.load(self.allocator, self.io, self.state_path) catch return err;
            state.deinit();
            state.* = restored;
            return err;
        };
    }

    pub fn toggle(self: Service, state: *state_mod.StateRoot, id: u64) !void {
        _ = try state.toggle(id);
        try self.persistOrRollback(state);
    }

    pub fn addTask(self: Service, state: *state_mod.StateRoot, title: []const u8, issue: ?task.IssueKey, parent: ?u64) !u64 {
        const id = try state.addTask(title, issue, parent);
        try self.persistOrRollback(state);
        return id;
    }

    pub fn editTask(self: Service, state: *state_mod.StateRoot, id: u64, title: []const u8) !void {
        try state.edit(id, title);
        try self.persistOrRollback(state);
    }

    pub fn moveTask(self: Service, state: *state_mod.StateRoot, id: u64, position: u32) !void {
        try state.move(id, position);
        try self.persistOrRollback(state);
    }

    pub fn reparentTask(self: Service, state: *state_mod.StateRoot, id: u64, parent: ?u64, issue: ?task.IssueKey) !void {
        try state.reparent(id, parent, issue);
        try self.persistOrRollback(state);
    }

    pub fn deleteTask(self: Service, state: *state_mod.StateRoot, id: u64, subtree: bool) !void {
        if (subtree) _ = try state.deleteSubtree(id) else try state.deletePromote(id);
        try self.persistOrRollback(state);
    }

    pub fn clearTasks(self: Service, state: *state_mod.StateRoot) !usize {
        const count = state.clearTasks();
        try self.persistOrRollback(state);
        return count;
    }

    pub fn approveProposal(self: Service, state: *state_mod.StateRoot, key: task.IssueKey) !usize {
        const count = try proposal_apply.apply(state, key);
        try self.persistOrRollback(state);
        return count;
    }

    pub fn discardProposal(self: Service, state: *state_mod.StateRoot, key: task.IssueKey) !void {
        if (!state.removeProposal(key)) return error.ProposalNotFound;
        try self.persistOrRollback(state);
    }
};

test "service persists mutations through the shared core" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const path = try std.fs.path.join(a, &.{ base, "state.json" });
    defer a.free(path);
    var state = state_mod.StateRoot.init(a);
    defer state.deinit();
    const service = Service{ .allocator = a, .io = std.testing.io, .state_path = path };
    const id = try service.addTask(&state, "日本語", null, null);
    try service.toggle(&state, id);
    var loaded = try store.load(a, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(task.Status.done, loaded.tasks.items[0].status);

    state.next_task_id = 0;
    try std.testing.expectError(error.InvalidState, service.persistOrRollback(&state));
    try std.testing.expectEqual(@as(usize, 1), state.tasks.items.len);
    try std.testing.expectEqual(task.Status.done, state.tasks.items[0].status);
}
