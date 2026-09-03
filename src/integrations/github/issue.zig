const std = @import("std");
const core = @import("../../core/task.zig");
const client = @import("client.zig");
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
test "failed refresh keeps title" {
    var i = core.IssueSnapshot{ .key = .{ .repository = "a/b", .issue_number = 1 }, .title = "remember" };
    markFailure(&i, .network);
    try std.testing.expectEqualStrings("remember", i.title);
    try std.testing.expectEqual(core.IssueStatus.unavailable, i.status);
}
