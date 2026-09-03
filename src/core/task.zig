const std = @import("std");

pub const Status = enum { todo, done };
pub const IssueStatus = enum { open, closed, deleted, unavailable };
pub const IssueError = enum { not_found, forbidden, network, unknown };

pub const IssueKey = struct {
    repository: []const u8,
    issue_number: u64,

    pub fn eql(a: IssueKey, b: IssueKey) bool {
        return a.issue_number == b.issue_number and std.mem.eql(u8, a.repository, b.repository);
    }
};

pub const IssueSnapshot = struct {
    key: IssueKey,
    title: []const u8,
    body: []const u8 = "",
    status: IssueStatus = .open,
    last_fetched_at: ?i64 = null,
    last_error: ?IssueError = null,
};

pub const Task = struct {
    id: u64,
    title: []const u8,
    status: Status = .todo,
    issue_key: ?IssueKey = null,
    parent_id: ?u64 = null,
    position: u32 = 0,
};

pub fn validatedTitle(input: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    const title = std.mem.trim(u8, input, " \t\r\n");
    if (title.len == 0) return error.EmptyTitle;
    var view = try std.unicode.Utf8View.init(title);
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or cp == 0x7f) return error.ControlCharacter;
        count += 1;
        if (count > 200) return error.TitleTooLong;
    }
    return title;
}

pub fn validateIssueKey(key: IssueKey) !void {
    if (key.issue_number == 0) return error.InvalidIssueNumber;
    const slash = std.mem.indexOfScalar(u8, key.repository, '/') orelse return error.InvalidRepository;
    if (slash == 0 or slash + 1 == key.repository.len) return error.InvalidRepository;
}

test "Unicode title validation" {
    try std.testing.expectEqualStrings("日本語 task", try validatedTitle("  日本語 task  "));
    try std.testing.expectError(error.EmptyTitle, validatedTitle(" \n"));
    try std.testing.expectError(error.ControlCharacter, validatedTitle("bad\x01"));
}

test "IssueKey requires owner/name and positive number" {
    try validateIssueKey(.{ .repository = "owner/repo", .issue_number = 1 });
    try std.testing.expectError(error.InvalidIssueNumber, validateIssueKey(.{ .repository = "owner/repo", .issue_number = 0 }));
}
