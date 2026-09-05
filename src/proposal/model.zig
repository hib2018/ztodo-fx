const std = @import("std");
const task = @import("../core/task.zig");

pub const CandidateTask = struct {
    candidate_id: []const u8,
    title: []const u8,
    parent_candidate_id: ?[]const u8 = null,
    position: u32,
};
pub const GenerationMetadata = struct { generated_at: i64, fx_version: []const u8, attempt_count: u8 };
pub const Proposal = struct {
    issue_key: task.IssueKey,
    issue_title: []const u8,
    summary: []const u8,
    completion_criteria: []const []const u8 = &.{},
    candidates: []const CandidateTask,
    excluded: []const []const u8 = &.{},
    notes: []const []const u8 = &.{},
    generation: GenerationMetadata,
    updated_at: i64,
};

pub fn validate(value: Proposal) !void {
    try task.validateIssueKey(value.issue_key);
    if (value.summary.len == 0) return error.EmptySummary;
    if (value.candidates.len == 0 or value.candidates.len > 20) return error.InvalidCandidateCount;
    for (value.candidates, 0..) |candidate, i| {
        if (candidate.candidate_id.len == 0) return error.EmptyCandidateId;
        _ = try task.validatedTitle(candidate.title);
        for (value.candidates[0..i]) |prior| {
            if (std.mem.eql(u8, prior.candidate_id, candidate.candidate_id)) return error.DuplicateCandidateId;
            if (std.mem.eql(u8, std.mem.trim(u8, prior.title, " \t\r\n"), std.mem.trim(u8, candidate.title, " \t\r\n"))) return error.DuplicateTitle;
        }
        if (candidate.parent_candidate_id) |parent| {
            var found = false;
            var cursor: ?[]const u8 = parent;
            var depth: usize = 0;
            while (cursor) |id| {
                if (std.mem.eql(u8, id, candidate.candidate_id)) return error.Cycle;
                const p = findCandidate(value.candidates, id) orelse return error.MissingParent;
                found = true;
                cursor = p.parent_candidate_id;
                depth += 1;
                if (depth > value.candidates.len) return error.Cycle;
            }
            if (!found) return error.MissingParent;
        }
        var preceding: u32 = 0;
        for (value.candidates) |other| {
            if (!std.mem.eql(u8, other.candidate_id, candidate.candidate_id) and optionalStringEql(other.parent_candidate_id, candidate.parent_candidate_id) and other.position < candidate.position) preceding += 1;
        }
        if (preceding != candidate.position) return error.InvalidPosition;
    }
    if (value.generation.attempt_count == 0 or value.generation.attempt_count > 3) return error.InvalidAttemptCount;
}
fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn findCandidate(items: []const CandidateTask, id: []const u8) ?CandidateTask {
    for (items) |item| if (std.mem.eql(u8, item.candidate_id, id)) return item;
    return null;
}

test "proposal rejects duplicate and cycles" {
    const base = Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &.{.{ .candidate_id = "a", .title = "x", .parent_candidate_id = "a", .position = 0 }}, .generation = .{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 }, .updated_at = 1 };
    try std.testing.expectError(error.Cycle, validate(base));
}
test "proposal candidate count duplicate title and missing parent are rejected" {
    const empty = Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &.{}, .generation = .{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 }, .updated_at = 1 };
    try std.testing.expectError(error.InvalidCandidateCount, validate(empty));
    var duplicate = empty;
    duplicate.candidates = &.{ .{ .candidate_id = "a", .title = "same", .position = 0 }, .{ .candidate_id = "b", .title = "same", .position = 1 } };
    try std.testing.expectError(error.DuplicateTitle, validate(duplicate));
    var missing = empty;
    missing.candidates = &.{.{ .candidate_id = "a", .title = "x", .parent_candidate_id = "missing", .position = 0 }};
    try std.testing.expectError(error.MissingParent, validate(missing));
}
test "proposal rejects duplicate candidate ids and oversized Unicode titles" {
    const meta = GenerationMetadata{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 };
    const duplicate = Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &.{ .{ .candidate_id = "a", .title = "one", .position = 0 }, .{ .candidate_id = "a", .title = "two", .position = 1 } }, .generation = meta, .updated_at = 1 };
    try std.testing.expectError(error.DuplicateCandidateId, validate(duplicate));
    var bytes: [201]u8 = @splat('x');
    const long = Proposal{ .issue_key = duplicate.issue_key, .issue_title = "i", .summary = "s", .candidates = &.{.{ .candidate_id = "a", .title = &bytes, .position = 0 }}, .generation = meta, .updated_at = 1 };
    try std.testing.expectError(error.TitleTooLong, validate(long));
}
test "proposal rejects more than twenty candidates and discontinuous positions" {
    const meta = GenerationMetadata{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 };
    var candidates: [21]CandidateTask = undefined;
    var ids: [21][4]u8 = undefined;
    for (&candidates, 0..) |*candidate, i| {
        const id = try std.fmt.bufPrint(&ids[i], "c{d}", .{i});
        candidate.* = .{ .candidate_id = id, .title = id, .position = @intCast(i) };
    }
    const too_many = Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &candidates, .generation = meta, .updated_at = 1 };
    try std.testing.expectError(error.InvalidCandidateCount, validate(too_many));

    var invalid_position = too_many;
    invalid_position.candidates = &.{.{ .candidate_id = "a", .title = "x", .position = 1 }};
    try std.testing.expectError(error.InvalidPosition, validate(invalid_position));
}
