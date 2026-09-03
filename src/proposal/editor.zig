const std = @import("std");
const model = @import("model.zig");
pub fn editTitle(a: std.mem.Allocator, p: *model.Proposal, id: []const u8, title: []const u8) !void {
    _ = try @import("../core/task.zig").validatedTitle(title);
    for (@constCast(p.candidates)) |*c| if (std.mem.eql(u8, c.candidate_id, id)) {
        c.title = try a.dupe(u8, title);
        p.updated_at += 1;
        return;
    };
    return error.CandidateNotFound;
}
pub fn reparent(p: *model.Proposal, id: []const u8, parent: ?[]const u8) !void {
    for (@constCast(p.candidates)) |*c| if (std.mem.eql(u8, c.candidate_id, id)) {
        c.parent_candidate_id = parent;
        try model.validate(p.*);
        p.updated_at += 1;
        return;
    };
    return error.CandidateNotFound;
}
pub fn move(p: *model.Proposal, id: []const u8, position: u32) !void {
    for (@constCast(p.candidates)) |*c| if (std.mem.eql(u8, c.candidate_id, id)) {
        const old = c.position;
        for (@constCast(p.candidates)) |*other| if (other.parent_candidate_id == c.parent_candidate_id and !std.mem.eql(u8, other.candidate_id, id)) {
            if (old < position and other.position > old and other.position <= position) other.position -= 1;
            if (position < old and other.position >= position and other.position < old) other.position += 1;
        };
        c.position = position;
        try model.validate(p.*);
        p.updated_at += 1;
        return;
    };
    return error.CandidateNotFound;
}
pub fn delete(a: std.mem.Allocator, p: *model.Proposal, id: []const u8) !void {
    var index: ?usize = null;
    for (p.candidates, 0..) |c, i| if (std.mem.eql(u8, c.candidate_id, id)) {
        index = i;
        break;
    };
    const at = index orelse return error.CandidateNotFound;
    var list = try a.alloc(model.CandidateTask, p.candidates.len - 1);
    var next: usize = 0;
    for (p.candidates, 0..) |c, i| if (i != at) {
        list[next] = c;
        if (list[next].parent_candidate_id) |parent| {
            if (std.mem.eql(u8, parent, id)) list[next].parent_candidate_id = p.candidates[at].parent_candidate_id;
        }
        next += 1;
    };
    p.candidates = list;
    p.updated_at += 1;
    try model.validate(p.*);
}
test "self reparent rolls back validation" {
    var list = [_]model.CandidateTask{.{ .candidate_id = "a", .title = "x", .position = 0 }};
    var p = model.Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &list, .generation = .{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 }, .updated_at = 1 };
    try std.testing.expectError(error.Cycle, reparent(&p, "a", "a"));
}
