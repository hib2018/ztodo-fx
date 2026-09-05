const std = @import("std");
const state_mod = @import("../core/state.zig");
const task = @import("../core/task.zig");
pub const DuplicateWarning = struct { candidate_id: []const u8, existing_task_id: u64, title: []const u8 };
pub fn duplicates(a: std.mem.Allocator, s: *const state_mod.StateRoot, key: task.IssueKey) ![]DuplicateWarning {
    var out: std.ArrayList(DuplicateWarning) = .empty;
    const p = for (s.proposals.items) |proposal| {
        if (proposal.issue_key.eql(key)) break proposal;
    } else return error.ProposalNotFound;
    for (p.candidates) |c| for (s.tasks.items) |t| if (state_mod.optionalKeyEql(t.issue_key, key) and std.mem.eql(u8, std.mem.trim(u8, t.title, " \t\r\n"), std.mem.trim(u8, c.title, " \t\r\n"))) try out.append(a, .{ .candidate_id = c.candidate_id, .existing_task_id = t.id, .title = c.title });
    return out.toOwnedSlice(a);
}
pub fn apply(s: *state_mod.StateRoot, key: task.IssueKey) !usize {
    const p = s.findProposal(key) orelse return error.ProposalNotFound;
    const count = p.candidates.len;
    var map = std.StringHashMap(u64).init(s.allocator);
    defer map.deinit();
    var remaining = count;
    while (remaining > 0) {
        var progressed = false;
        for (p.candidates) |c| {
            if (map.contains(c.candidate_id)) continue;
            const parent = if (c.parent_candidate_id) |pid| map.get(pid) orelse continue else null;
            const id = try s.addTask(c.title, key, parent);
            try map.put(c.candidate_id, id);
            progressed = true;
            remaining -= 1;
        }
        if (!progressed) return error.InvalidProposalTree;
    }
    _ = s.removeProposal(key);
    try s.validate();
    return count;
}
test "approval preserves parent relationship and removes proposal" {
    var s = state_mod.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    try s.issues.append(std.testing.allocator, .{ .key = .{ .repository = try std.testing.allocator.dupe(u8, "a/b"), .issue_number = 1 }, .title = try std.testing.allocator.dupe(u8, "i"), .body = try std.testing.allocator.dupe(u8, "") });
    const p = @import("model.zig").Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &.{ .{ .candidate_id = "a", .title = "root", .position = 0 }, .{ .candidate_id = "b", .title = "child", .parent_candidate_id = "a", .position = 0 } }, .generation = .{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 }, .updated_at = 1 };
    try s.putProposal(p);
    try std.testing.expectEqual(@as(usize, 2), try apply(&s, p.issue_key));
    try std.testing.expectEqual(@as(?u64, 1), s.tasks.items[1].parent_id);
}
test "duplicate warnings are scoped to the same issue" {
    var s = state_mod.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    for ([_]task.IssueKey{ .{ .repository = "a/b", .issue_number = 1 }, .{ .repository = "a/b", .issue_number = 2 } }) |key| try s.issues.append(std.testing.allocator, .{ .key = .{ .repository = try std.testing.allocator.dupe(u8, key.repository), .issue_number = key.issue_number }, .title = try std.testing.allocator.dupe(u8, "i"), .body = try std.testing.allocator.dupe(u8, "") });
    _ = try s.addTask("same", .{ .repository = "a/b", .issue_number = 1 }, null);
    _ = try s.addTask("same", .{ .repository = "a/b", .issue_number = 2 }, null);
    const p = @import("model.zig").Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &.{.{ .candidate_id = "a", .title = "same", .position = 0 }}, .generation = .{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 }, .updated_at = 1 };
    try s.putProposal(p);
    const warnings = try duplicates(std.testing.allocator, &s, p.issue_key);
    defer std.testing.allocator.free(warnings);
    try std.testing.expectEqual(@as(usize, 1), warnings.len);
    try std.testing.expectEqual(@as(u64, 1), warnings[0].existing_task_id);
}
test "approval appends tasks in dependency order with monotonic ids" {
    var s = state_mod.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    try s.issues.append(std.testing.allocator, .{ .key = .{ .repository = try std.testing.allocator.dupe(u8, "a/b"), .issue_number = 1 }, .title = try std.testing.allocator.dupe(u8, "i"), .body = try std.testing.allocator.dupe(u8, "") });
    _ = try s.addTask("existing", .{ .repository = "a/b", .issue_number = 1 }, null);
    const p = @import("model.zig").Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &.{ .{ .candidate_id = "child", .title = "child", .parent_candidate_id = "root", .position = 0 }, .{ .candidate_id = "root", .title = "root", .position = 0 } }, .generation = .{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 }, .updated_at = 1 };
    try s.putProposal(p);
    try std.testing.expectEqual(@as(usize, 2), try apply(&s, p.issue_key));
    try std.testing.expectEqual(@as(u64, 2), s.tasks.items[1].id);
    try std.testing.expectEqual(@as(u64, 3), s.tasks.items[2].id);
    try std.testing.expectEqual(@as(?u64, 2), s.tasks.items[2].parent_id);
    try s.validate();
}
