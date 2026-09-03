const std = @import("std");
const model = @import("model.zig");
pub fn editTitle(a: std.mem.Allocator, p: *model.Proposal, id: []const u8, title: []const u8) !void {
    _ = try @import("../core/task.zig").validatedTitle(title);
    for (@constCast(p.candidates)) |*c| if (std.mem.eql(u8, c.candidate_id, id)) {
        const replacement = try a.dupe(u8, title);
        a.free(c.title);
        c.title = replacement;
        p.updated_at += 1;
        return;
    };
    return error.CandidateNotFound;
}
pub fn reparent(p: *model.Proposal, id: []const u8, parent: ?[]const u8) !void {
    for (@constCast(p.candidates)) |*c| if (std.mem.eql(u8, c.candidate_id, id)) {
        const previous = c.parent_candidate_id;
        c.parent_candidate_id = parent;
        model.validate(p.*) catch |err| {
            c.parent_candidate_id = previous;
            return err;
        };
        p.updated_at += 1;
        return;
    };
    return error.CandidateNotFound;
}
pub fn move(p: *model.Proposal, id: []const u8, position: u32) !void {
    if (position >= p.candidates.len) return error.InvalidPosition;
    var previous: [20]u32 = undefined;
    for (p.candidates, 0..) |candidate, i| previous[i] = candidate.position;
    for (@constCast(p.candidates)) |*c| if (std.mem.eql(u8, c.candidate_id, id)) {
        const old = c.position;
        for (@constCast(p.candidates)) |*other| if (optionalEql(other.parent_candidate_id, c.parent_candidate_id) and !std.mem.eql(u8, other.candidate_id, id)) {
            if (old < position and other.position > old and other.position <= position) other.position -= 1;
            if (position < old and other.position >= position and other.position < old) other.position += 1;
        };
        c.position = position;
        model.validate(p.*) catch |err| {
            for (@constCast(p.candidates), 0..) |*candidate, i| candidate.position = previous[i];
            return err;
        };
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
    const old = p.candidates;
    p.candidates = list;
    p.updated_at += 1;
    model.validate(p.*) catch |err| {
        p.candidates = old;
        a.free(list);
        return err;
    };
    const removed = old[at];
    a.free(removed.candidate_id);
    a.free(removed.title);
    if (removed.parent_candidate_id) |parent| a.free(parent);
    a.free(old);
}
pub fn add(a: std.mem.Allocator, p: *model.Proposal, id: []const u8, title: []const u8, parent: ?[]const u8) !void {
    if (p.candidates.len >= 20) return error.InvalidCandidateCount;
    _ = try @import("../core/task.zig").validatedTitle(title);
    if (model.findCandidate(p.candidates, id) != null) return error.DuplicateCandidateId;
    const list = try a.alloc(model.CandidateTask, p.candidates.len + 1);
    @memcpy(list[0..p.candidates.len], p.candidates);
    var position: u32 = 0;
    for (p.candidates) |candidate| if (optionalEql(candidate.parent_candidate_id, parent)) {
        position = @max(position, candidate.position + 1);
    };
    list[p.candidates.len] = .{ .candidate_id = try a.dupe(u8, id), .title = try a.dupe(u8, title), .parent_candidate_id = if (parent) |value| try a.dupe(u8, value) else null, .position = position };
    const old = p.candidates;
    p.candidates = list;
    model.validate(p.*) catch |err| {
        p.candidates = old;
        return err;
    };
    a.free(old);
    p.updated_at += 1;
}
fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const Result = enum { save, aborted };
pub fn run(a: std.mem.Allocator, p: *model.Proposal, reader: *std.Io.Reader, writer: *std.Io.Writer) !Result {
    try show(p, writer);
    while (true) {
        try writer.writeAll("> ");
        try writer.flush();
        const raw = try reader.takeDelimiter('\n') orelse return .aborted;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "q") or std.mem.eql(u8, line, "save")) return .save;
        if (std.mem.eql(u8, line, "abort")) return .aborted;
        if (std.mem.eql(u8, line, "show")) {
            try show(p, writer);
            continue;
        }
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        const command = tokens.next() orelse continue;
        const id = tokens.next() orelse {
            try writer.writeAll("candidate IDが必要です。\n");
            continue;
        };
        if (std.mem.eql(u8, command, "delete")) delete(a, p, id) catch {
            try writer.writeAll("削除できません。\n");
        } else if (std.mem.eql(u8, command, "move")) {
            const pos = std.fmt.parseInt(u32, tokens.next() orelse "", 10) catch {
                try writer.writeAll("位置が不正です。\n");
                continue;
            };
            move(p, id, pos -| 1) catch {
                try writer.writeAll("移動できません。\n");
            };
        } else if (std.mem.eql(u8, command, "reparent")) {
            const parent_text = tokens.next() orelse "root";
            reparent(p, id, if (std.mem.eql(u8, parent_text, "root")) null else parent_text) catch {
                try writer.writeAll("親を変更できません。\n");
            };
        } else if (std.mem.eql(u8, command, "edit")) {
            const title = tokens.rest();
            editTitle(a, p, id, title) catch {
                try writer.writeAll("編集できません。\n");
            };
        } else if (std.mem.eql(u8, command, "add")) {
            const title = tokens.rest();
            var id_buf: [32]u8 = undefined;
            const generated = try std.fmt.bufPrint(&id_buf, "manual-{d}", .{p.candidates.len + 1});
            add(a, p, generated, title, null) catch {
                try writer.writeAll("追加できません。\n");
            };
        } else try writer.writeAll("不明な編集コマンドです。\n");
    }
}
fn show(p: *const model.Proposal, writer: *std.Io.Writer) !void {
    try writer.print("{s}\n", .{p.summary});
    for (p.candidates) |candidate| try writer.print("  {s} ({d}): {s}\n", .{ candidate.candidate_id, candidate.position + 1, candidate.title });
    try writer.writeAll("commands: add <title>, edit <id> <title>, delete <id>, move <id> <position>, reparent <id> <parent|root>, show, save, abort\n");
}
test "self reparent rolls back validation" {
    var list = [_]model.CandidateTask{.{ .candidate_id = "a", .title = "x", .position = 0 }};
    var p = model.Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &list, .generation = .{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 }, .updated_at = 1 };
    try std.testing.expectError(error.Cycle, reparent(&p, "a", "a"));
    try std.testing.expect(p.candidates[0].parent_candidate_id == null);
}
test "editor abort is distinguishable from save" {
    var candidates = [_]model.CandidateTask{.{ .candidate_id = "a", .title = "x", .position = 0 }};
    var p = model.Proposal{ .issue_key = .{ .repository = "a/b", .issue_number = 1 }, .issue_title = "i", .summary = "s", .candidates = &candidates, .generation = .{ .generated_at = 1, .fx_version = "1", .attempt_count = 1 }, .updated_at = 1 };
    var reader: std.Io.Reader = .fixed("abort\n");
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(Result.aborted, try run(std.testing.allocator, &p, &reader, &writer));
}
