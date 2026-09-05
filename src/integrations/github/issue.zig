const std = @import("std");
const core = @import("../../core/task.zig");
const client = @import("client.zig");
const state_mod = @import("../../core/state.zig");
pub fn snapshot(a: std.mem.Allocator, repository: []const u8, remote: client.RemoteIssue, now: i64) !core.IssueSnapshot {
    return .{ .key = .{ .repository = try a.dupe(u8, repository), .issue_number = remote.number }, .title = try a.dupe(u8, remote.title), .body = try a.dupe(u8, remote.body), .status = if (std.ascii.eqlIgnoreCase(remote.state, "open")) .open else .closed, .last_fetched_at = now };
}
pub fn markFailure(existing: *core.IssueSnapshot, kind: core.IssueError) void {
    existing.status = switch (kind) {
        .not_found => .deleted,
        else => .unavailable,
    };
    existing.last_error = kind;
}
pub fn merge(a: std.mem.Allocator, state: *state_mod.StateRoot, repository: []const u8, remotes: []const client.RemoteIssue, now: i64) !void {
    for (remotes, 0..) |remote, index| {
        if (remote.number == 0) return error.InvalidIssueNumber;
        for (remotes[0..index]) |prior| if (prior.number == remote.number) return error.DuplicateIssue;
        const fresh = try snapshot(a, repository, remote, now);
        var replaced = false;
        for (state.issues.items, 0..) |existing, i| if (existing.key.eql(fresh.key)) {
            state_mod.freeIssue(a, existing);
            state.issues.items[i] = fresh;
            replaced = true;
            break;
        };
        if (!replaced) try state.issues.append(a, fresh);
    }
    for (state.issues.items) |*existing| {
        if (!std.mem.eql(u8, existing.key.repository, repository)) continue;
        var found = false;
        for (remotes) |remote| if (remote.number == existing.key.issue_number) {
            found = true;
            break;
        };
        if (!found) markFailure(existing, .not_found);
    }
}
pub fn markRepositoryFailure(state: *state_mod.StateRoot, repository: []const u8, kind: core.IssueError) void {
    for (state.issues.items) |*existing| if (std.mem.eql(u8, existing.key.repository, repository)) markFailure(existing, kind);
}
test "failed refresh keeps title" {
    var i = core.IssueSnapshot{ .key = .{ .repository = "a/b", .issue_number = 1 }, .title = "remember" };
    markFailure(&i, .network);
    try std.testing.expectEqualStrings("remember", i.title);
    try std.testing.expectEqual(core.IssueStatus.unavailable, i.status);
}
test "merge preserves missing issue as deleted" {
    var state = state_mod.StateRoot.init(std.testing.allocator);
    defer state.deinit();
    try state.issues.append(std.testing.allocator, .{ .key = .{ .repository = try std.testing.allocator.dupe(u8, "a/b"), .issue_number = 1 }, .title = try std.testing.allocator.dupe(u8, "old"), .body = try std.testing.allocator.dupe(u8, "body") });
    try merge(std.testing.allocator, &state, "a/b", &.{.{ .number = 2, .title = "new", .state = "OPEN" }}, 10);
    try std.testing.expectEqual(core.IssueStatus.deleted, state.issues.items[0].status);
    try std.testing.expectEqualStrings("old", state.issues.items[0].title);
}
test "merge handles open closed duplicate and unavailable transitions" {
    var state = state_mod.StateRoot.init(std.testing.allocator);
    defer state.deinit();
    try merge(std.testing.allocator, &state, "a/b", &.{
        .{ .number = 1, .title = "open", .body = "one", .state = "OPEN" },
        .{ .number = 2, .title = "closed", .body = "two", .state = "CLOSED" },
    }, 10);
    try std.testing.expectEqual(core.IssueStatus.open, state.issues.items[0].status);
    try std.testing.expectEqual(core.IssueStatus.closed, state.issues.items[1].status);
    markRepositoryFailure(&state, "a/b", .network);
    try std.testing.expectEqual(core.IssueStatus.unavailable, state.issues.items[0].status);
    try std.testing.expectEqualStrings("open", state.issues.items[0].title);
    try std.testing.expectError(error.DuplicateIssue, merge(std.testing.allocator, &state, "a/b", &.{
        .{ .number = 3, .title = "x", .state = "OPEN" },
        .{ .number = 3, .title = "y", .state = "OPEN" },
    }, 11));
}
