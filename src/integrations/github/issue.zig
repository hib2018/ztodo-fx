const std = @import("std");
const core = @import("../../core/task.zig");
const client = @import("client.zig");
const state_mod = @import("../../core/state.zig");
pub fn snapshot(a: std.mem.Allocator, repository: []const u8, remote: client.RemoteIssue, now: i64) !core.IssueSnapshot {
    try validateRemote(remote);
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
    // Validate the complete response before mutating state. A duplicate or
    // malformed trailing item must not leave a partially refreshed list.
    for (remotes, 0..) |remote, index| {
        try validateRemote(remote);
        for (remotes[0..index]) |prior| if (prior.number == remote.number) return error.DuplicateIssue;
    }
    var staged: std.ArrayList(?core.IssueSnapshot) = .empty;
    defer {
        for (staged.items) |item| if (item) |owned| state_mod.freeIssue(a, owned);
        staged.deinit(a);
    }
    try staged.ensureTotalCapacity(a, remotes.len);
    for (remotes) |remote| staged.appendAssumeCapacity(try snapshot(a, repository, remote, now));
    // Reserve before replacing anything, making the commit phase allocation-free.
    try state.issues.ensureUnusedCapacity(a, remotes.len);
    for (staged.items) |*entry| {
        const fresh = entry.*.?;
        var replaced = false;
        for (state.issues.items, 0..) |existing, i| if (existing.key.eql(fresh.key)) {
            state_mod.freeIssue(a, existing);
            state.issues.items[i] = fresh;
            entry.* = null;
            replaced = true;
            break;
        };
        if (!replaced) {
            state.issues.appendAssumeCapacity(fresh);
            entry.* = null;
        }
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
    normalizeIssues(a, state);
}

fn validateRemote(remote: client.RemoteIssue) !void {
    if (remote.number == 0) return error.InvalidIssueNumber;
    if (!std.unicode.utf8ValidateSlice(remote.title) or !std.unicode.utf8ValidateSlice(remote.body)) return error.InvalidUtf8;
    if (remote.title.len == 0) return error.EmptyTitle;
    if (!std.ascii.eqlIgnoreCase(remote.state, "open") and !std.ascii.eqlIgnoreCase(remote.state, "closed")) return error.InvalidIssueState;
}

fn normalizeIssues(a: std.mem.Allocator, state: *state_mod.StateRoot) void {
    var index: usize = 0;
    while (index < state.issues.items.len) : (index += 1) {
        var other = index + 1;
        while (other < state.issues.items.len) {
            if (state.issues.items[index].key.eql(state.issues.items[other].key)) {
                state_mod.freeIssue(a, state.issues.orderedRemove(other));
            } else other += 1;
        }
    }
    std.mem.sort(core.IssueSnapshot, state.issues.items, {}, struct {
        fn lessThan(_: void, left: core.IssueSnapshot, right: core.IssueSnapshot) bool {
            const order = std.mem.order(u8, left.key.repository, right.key.repository);
            return order == .lt or (order == .eq and left.key.issue_number < right.key.issue_number);
        }
    }.lessThan);
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
    const before = state.issues.items.len;
    try std.testing.expectError(error.DuplicateIssue, merge(std.testing.allocator, &state, "a/b", &.{
        .{ .number = 3, .title = "x", .state = "OPEN" },
        .{ .number = 3, .title = "y", .state = "OPEN" },
    }, 11));
    try std.testing.expectEqual(before, state.issues.items.len);
}

test "merge validates UTF-8 and sorts unique issue keys deterministically" {
    var state = state_mod.StateRoot.init(std.testing.allocator);
    defer state.deinit();
    try merge(std.testing.allocator, &state, "z/repo", &.{
        .{ .number = 9, .title = "九", .state = "OPEN" },
        .{ .number = 2, .title = "二", .state = "OPEN" },
    }, 1);
    try merge(std.testing.allocator, &state, "a/repo", &.{.{ .number = 7, .title = "七", .state = "OPEN" }}, 1);
    try std.testing.expectEqualStrings("a/repo", state.issues.items[0].key.repository);
    try std.testing.expectEqual(@as(u64, 2), state.issues.items[1].key.issue_number);
    try std.testing.expectEqual(@as(u64, 9), state.issues.items[2].key.issue_number);
    try std.testing.expectError(error.InvalidUtf8, merge(std.testing.allocator, &state, "z/repo", &.{.{ .number = 3, .title = "\xff", .state = "OPEN" }}, 2));
    try std.testing.expectEqual(@as(usize, 3), state.issues.items.len);
}
