const std = @import("std");
const task_mod = @import("task.zig");
const proposal_mod = @import("../proposal/model.zig");

pub const StateRoot = struct {
    allocator: std.mem.Allocator,
    schema_version: u32 = 1,
    next_task_id: u64 = 1,
    tasks: std.ArrayList(task_mod.Task) = .empty,
    issues: std.ArrayList(task_mod.IssueSnapshot) = .empty,
    proposals: std.ArrayList(proposal_mod.Proposal) = .empty,

    pub fn init(allocator: std.mem.Allocator) StateRoot {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *StateRoot) void {
        for (self.tasks.items) |t| freeTask(self.allocator, t);
        for (self.issues.items) |i| freeIssue(self.allocator, i);
        for (self.proposals.items) |p| freeProposal(self.allocator, p);
        self.tasks.deinit(self.allocator);
        self.issues.deinit(self.allocator);
        self.proposals.deinit(self.allocator);
    }
    pub fn findTask(self: *StateRoot, id: u64) ?*task_mod.Task {
        for (self.tasks.items) |*t| if (t.id == id) return t;
        return null;
    }
    pub fn addTask(self: *StateRoot, title_input: []const u8, issue: ?task_mod.IssueKey, parent: ?u64) !u64 {
        const title = try task_mod.validatedTitle(title_input);
        if (parent) |id| {
            const p = self.findTask(id) orelse return error.ParentNotFound;
            if (!optionalKeyEql(p.issue_key, issue)) return error.IssueMismatch;
        }
        const pos = self.siblingCount(issue, parent);
        try self.tasks.append(self.allocator, .{ .id = self.next_task_id, .title = try self.allocator.dupe(u8, title), .issue_key = try dupeOptionalKey(self.allocator, issue), .parent_id = parent, .position = pos });
        self.next_task_id += 1;
        return self.next_task_id - 1;
    }
    fn siblingCount(self: *StateRoot, issue: ?task_mod.IssueKey, parent: ?u64) u32 {
        var n: u32 = 0;
        for (self.tasks.items) |t| {
            if (t.parent_id == parent and optionalKeyEql(t.issue_key, issue)) n += 1;
        }
        return n;
    }
    pub fn toggle(self: *StateRoot, id: u64) !task_mod.Status {
        const t = self.findTask(id) orelse return error.TaskNotFound;
        t.status = if (t.status == .todo) .done else .todo;
        return t.status;
    }
    pub fn edit(self: *StateRoot, id: u64, title_input: []const u8) !void {
        const t = self.findTask(id) orelse return error.TaskNotFound;
        const title = try task_mod.validatedTitle(title_input);
        const copy = try self.allocator.dupe(u8, title);
        self.allocator.free(t.title);
        t.title = copy;
    }
    pub fn move(self: *StateRoot, id: u64, one_based: u32) !void {
        if (one_based == 0) return error.InvalidPosition;
        const target = self.findTask(id) orelse return error.TaskNotFound;
        const issue = target.issue_key;
        const parent = target.parent_id;
        const count = self.siblingCount(issue, parent);
        if (one_based > count) return error.InvalidPosition;
        const old = target.position;
        const new = one_based - 1;
        for (self.tasks.items) |*t| if (t.id != id and t.parent_id == parent and optionalKeyEql(t.issue_key, issue)) {
            if (old < new and t.position > old and t.position <= new) t.position -= 1;
            if (new < old and t.position >= new and t.position < old) t.position += 1;
        };
        target.position = new;
    }
    pub fn reparent(self: *StateRoot, id: u64, parent: ?u64, issue: ?task_mod.IssueKey) !void {
        const target = self.findTask(id) orelse return error.TaskNotFound;
        if (parent == id) return error.Cycle;
        if (parent) |pid| {
            var cursor: ?u64 = pid;
            while (cursor) |current| {
                if (current == id) return error.Cycle;
                cursor = (self.findTask(current) orelse return error.ParentNotFound).parent_id;
            }
        }
        const old_parent = target.parent_id;
        const old_issue = target.issue_key;
        const old_position = target.position;
        for (self.tasks.items) |*t| {
            if (t.parent_id == old_parent and optionalKeyEql(t.issue_key, old_issue) and t.position > old_position) t.position -= 1;
        }
        const new_issue = if (parent) |pid| (self.findTask(pid) orelse return error.ParentNotFound).issue_key else issue;
        const new_position = self.siblingCount(new_issue, parent);
        try self.setSubtreeIssue(id, new_issue);
        target.parent_id = parent;
        target.position = new_position;
    }
    fn setSubtreeIssue(self: *StateRoot, id: u64, issue: ?task_mod.IssueKey) !void {
        const t = self.findTask(id) orelse return error.TaskNotFound;
        freeOptionalKey(self.allocator, t.issue_key);
        t.issue_key = try dupeOptionalKey(self.allocator, issue);
        var children: std.ArrayList(u64) = .empty;
        defer children.deinit(self.allocator);
        for (self.tasks.items) |child| if (child.parent_id == id) try children.append(self.allocator, child.id);
        for (children.items) |child_id| try self.setSubtreeIssue(child_id, issue);
    }
    pub fn deleteSubtree(self: *StateRoot, id: u64) !usize {
        _ = self.findTask(id) orelse return error.TaskNotFound;
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        try self.collectSubtree(id, &ids);
        var removed: usize = 0;
        var i: usize = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            for (ids.items) |rid| if (self.tasks.items[i].id == rid) {
                freeTask(self.allocator, self.tasks.orderedRemove(i));
                removed += 1;
                break;
            };
        }
        self.normalizePositions();
        return removed;
    }
    pub fn subtreeCount(self: *StateRoot, id: u64) !usize {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        try self.collectSubtree(id, &ids);
        return ids.items.len;
    }
    fn collectSubtree(self: *StateRoot, id: u64, ids: *std.ArrayList(u64)) !void {
        try ids.append(self.allocator, id);
        for (self.tasks.items) |t| if (t.parent_id == id) try self.collectSubtree(t.id, ids);
    }
    pub fn deletePromote(self: *StateRoot, id: u64) !void {
        const t = self.findTask(id) orelse return error.TaskNotFound;
        const parent = t.parent_id;
        const issue = t.issue_key;
        const pos = t.position;
        for (self.tasks.items) |*child| if (child.parent_id == id) {
            child.parent_id = parent;
            child.position += pos;
        };
        for (self.tasks.items, 0..) |item, i| if (item.id == id) {
            freeTask(self.allocator, self.tasks.orderedRemove(i));
            break;
        };
        _ = issue;
        self.normalizePositions();
    }
    pub fn clearTasks(self: *StateRoot) usize {
        const count = self.tasks.items.len;
        for (self.tasks.items) |t| freeTask(self.allocator, t);
        self.tasks.clearRetainingCapacity();
        self.next_task_id = 1;
        return count;
    }
    pub fn putProposal(self: *StateRoot, source: proposal_mod.Proposal) !void {
        try proposal_mod.validate(source);
        for (self.proposals.items, 0..) |p, i| if (p.issue_key.eql(source.issue_key)) {
            freeProposal(self.allocator, self.proposals.items[i]);
            self.proposals.items[i] = try cloneProposal(self.allocator, source);
            return;
        };
        try self.proposals.append(self.allocator, try cloneProposal(self.allocator, source));
    }
    pub fn findProposal(self: *StateRoot, key: task_mod.IssueKey) ?*proposal_mod.Proposal {
        for (self.proposals.items) |*p| if (p.issue_key.eql(key)) return p;
        return null;
    }
    pub fn removeProposal(self: *StateRoot, key: task_mod.IssueKey) bool {
        for (self.proposals.items, 0..) |p, i| if (p.issue_key.eql(key)) {
            freeProposal(self.allocator, self.proposals.orderedRemove(i));
            return true;
        };
        return false;
    }
    fn normalizePositions(self: *StateRoot) void {
        for (self.tasks.items) |*t| {
            var p: u32 = 0;
            for (self.tasks.items) |other| {
                if (other.id != t.id and other.parent_id == t.parent_id and optionalKeyEql(other.issue_key, t.issue_key) and (other.position < t.position or (other.position == t.position and other.id < t.id))) p += 1;
            }
            t.position = p;
        }
    }
    pub fn validate(self: *const StateRoot) !void {
        if (self.schema_version != 1 or self.next_task_id == 0) return error.InvalidState;
        for (self.issues.items, 0..) |issue, index| {
            if (!std.unicode.utf8ValidateSlice(issue.title) or !std.unicode.utf8ValidateSlice(issue.body)) return error.InvalidUtf8;
            for (self.issues.items[0..index]) |prior| if (prior.key.eql(issue.key)) return error.DuplicateIssue;
        }
        var max: u64 = 0;
        for (self.tasks.items, 0..) |t, i| {
            if (t.id == 0) return error.InvalidTaskId;
            max = @max(max, t.id);
            _ = try task_mod.validatedTitle(t.title);
            for (self.tasks.items[0..i]) |p| if (p.id == t.id) return error.DuplicateTaskId;
            if (t.issue_key) |key| if (!hasIssue(self.issues.items, key)) return error.IssueNotFound;
            var preceding: u32 = 0;
            for (self.tasks.items) |other| {
                if (other.id != t.id and other.parent_id == t.parent_id and optionalKeyEql(other.issue_key, t.issue_key) and other.position < t.position) preceding += 1;
            }
            if (preceding != t.position) return error.InvalidPosition;
            if (t.parent_id) |pid| {
                const p = findConst(self.tasks.items, pid) orelse return error.ParentNotFound;
                if (!optionalKeyEql(p.issue_key, t.issue_key)) return error.IssueMismatch;
                var cur: ?u64 = pid;
                var depth: usize = 0;
                while (cur) |cid| {
                    if (cid == t.id) return error.Cycle;
                    cur = (findConst(self.tasks.items, cid) orelse return error.ParentNotFound).parent_id;
                    depth += 1;
                    if (depth > self.tasks.items.len) return error.Cycle;
                }
            }
        }
        if (self.next_task_id <= max) return error.InvalidNextId;
        for (self.proposals.items, 0..) |p, i| {
            try proposal_mod.validate(p);
            if (!hasIssue(self.issues.items, p.issue_key)) return error.IssueNotFound;
            for (self.proposals.items[0..i]) |prior| if (prior.issue_key.eql(p.issue_key)) return error.DuplicateProposal;
        }
    }
};

fn findConst(items: []const task_mod.Task, id: u64) ?task_mod.Task {
    for (items) |t| if (t.id == id) return t;
    return null;
}
fn hasIssue(items: []const task_mod.IssueSnapshot, key: task_mod.IssueKey) bool {
    for (items) |i| if (i.key.eql(key)) return true;
    return false;
}
pub fn optionalKeyEql(a: ?task_mod.IssueKey, b: ?task_mod.IssueKey) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}
pub fn dupeOptionalKey(a: std.mem.Allocator, key: ?task_mod.IssueKey) !?task_mod.IssueKey {
    const k = key orelse return null;
    return .{ .repository = try a.dupe(u8, k.repository), .issue_number = k.issue_number };
}
fn freeOptionalKey(a: std.mem.Allocator, key: ?task_mod.IssueKey) void {
    if (key) |k| a.free(k.repository);
}
pub fn freeTask(a: std.mem.Allocator, t: task_mod.Task) void {
    a.free(t.title);
    freeOptionalKey(a, t.issue_key);
}
pub fn freeIssue(a: std.mem.Allocator, i: task_mod.IssueSnapshot) void {
    a.free(i.key.repository);
    a.free(i.title);
    a.free(i.body);
}
pub fn freeProposal(a: std.mem.Allocator, p: proposal_mod.Proposal) void {
    a.free(p.issue_key.repository);
    a.free(p.issue_title);
    a.free(p.summary);
    for (p.completion_criteria) |v| a.free(v);
    a.free(p.completion_criteria);
    for (p.candidates) |c| {
        a.free(c.candidate_id);
        a.free(c.title);
        if (c.parent_candidate_id) |v| a.free(v);
    }
    a.free(p.candidates);
    for (p.excluded) |v| a.free(v);
    a.free(p.excluded);
    for (p.notes) |v| a.free(v);
    a.free(p.notes);
    a.free(p.generation.fx_version);
}
pub fn cloneProposal(a: std.mem.Allocator, p: proposal_mod.Proposal) !proposal_mod.Proposal {
    return .{ .issue_key = .{ .repository = try a.dupe(u8, p.issue_key.repository), .issue_number = p.issue_key.issue_number }, .issue_title = try a.dupe(u8, p.issue_title), .summary = try a.dupe(u8, p.summary), .completion_criteria = try cloneStrings(a, p.completion_criteria), .candidates = try cloneCandidates(a, p.candidates), .excluded = try cloneStrings(a, p.excluded), .notes = try cloneStrings(a, p.notes), .generation = .{ .generated_at = p.generation.generated_at, .fx_version = try a.dupe(u8, p.generation.fx_version), .attempt_count = p.generation.attempt_count }, .updated_at = p.updated_at };
}
fn cloneStrings(a: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, values.len);
    for (values, 0..) |v, i| out[i] = try a.dupe(u8, v);
    return out;
}
fn cloneCandidates(a: std.mem.Allocator, values: []const proposal_mod.CandidateTask) ![]const proposal_mod.CandidateTask {
    const out = try a.alloc(proposal_mod.CandidateTask, values.len);
    for (values, 0..) |v, i| out[i] = .{ .candidate_id = try a.dupe(u8, v.candidate_id), .title = try a.dupe(u8, v.title), .parent_candidate_id = if (v.parent_candidate_id) |p| try a.dupe(u8, p) else null, .position = v.position };
    return out;
}

test "state detects cycle and assigns ids" {
    var s = StateRoot.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.addTask("a", null, null);
    _ = try s.addTask("b", null, a);
    try s.validate();
    s.findTask(a).?.parent_id = 2;
    try std.testing.expectError(error.Cycle, s.validate());
}
test "state rejects missing parent duplicate id and broken positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = StateRoot.init(arena.allocator());
    try s.tasks.append(arena.allocator(), .{ .id = 1, .title = "x", .parent_id = 99, .position = 0 });
    s.next_task_id = 2;
    try std.testing.expectError(error.ParentNotFound, s.validate());
    s.tasks.items[0].parent_id = null;
    try s.tasks.append(arena.allocator(), .{ .id = 1, .title = "y", .position = 1 });
    try std.testing.expectError(error.DuplicateTaskId, s.validate());
    s.tasks.items[1].id = 2;
    s.next_task_id = 3;
    s.tasks.items[1].position = 2;
    try std.testing.expectError(error.InvalidPosition, s.validate());
}
test "manual operations preserve subtree issue and reject cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = StateRoot.init(arena.allocator());
    try s.issues.append(arena.allocator(), .{ .key = .{ .repository = "a/b", .issue_number = 1 }, .title = "issue" });
    const root = try s.addTask("root", null, null);
    const child = try s.addTask("child", null, root);
    try s.reparent(root, null, .{ .repository = "a/b", .issue_number = 1 });
    try std.testing.expect(s.findTask(child).?.issue_key.?.eql(.{ .repository = "a/b", .issue_number = 1 }));
    try std.testing.expectError(error.Cycle, s.reparent(root, child, null));
    _ = try s.toggle(root);
    try std.testing.expectEqual(task_mod.Status.todo, s.findTask(child).?.status);
}
test "promote and subtree deletion keep remaining positions contiguous" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = StateRoot.init(arena.allocator());
    defer s.deinit();
    const root = try s.addTask("root", null, null);
    _ = try s.addTask("before", null, null);
    _ = try s.addTask("child-a", null, root);
    _ = try s.addTask("child-b", null, root);
    try s.deletePromote(root);
    try s.validate();
    try std.testing.expectEqual(@as(usize, 3), s.tasks.items.len);
    try std.testing.expectEqual(@as(usize, 1), try s.deleteSubtree(2));
    try s.validate();
    try std.testing.expectEqual(@as(usize, 2), s.tasks.items.len);
}
