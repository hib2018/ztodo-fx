const std = @import("std");
const state = @import("../core/state.zig");
const task = @import("../core/task.zig");
const fx_prompt = @import("../integrations/fx/prompt.zig");
const fx_permissions = @import("../integrations/fx/permissions.zig");
const fx_client = @import("../integrations/fx/client.zig");
const response = @import("../integrations/fx/response.zig");
pub fn generate(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, s: *state.StateRoot, issue: task.IssueSnapshot, workspace: []const u8, excludes: []const []const u8) !void {
    const base = env.get("TMPDIR") orelse "/tmp";
    const snap = try @import("../platform/snapshot.zig").create(a, io, base, workspace, excludes);
    defer snap.deinit(a, io);
    try fx_permissions.preflight(a, io, env, snap.path);
    const prompt = try fx_prompt.build(a, issue);
    defer a.free(prompt);
    const envelope = try fx_client.ask(a, io, env, snap.path, prompt);
    defer a.free(envelope);
    var parsed = try response.decodeProposal(a, envelope);
    defer parsed.deinit();
    if (!parsed.value.issue_key.eql(issue.key)) return error.IssueMismatch;
    try @import("model.zig").validate(parsed.value);
    try s.putProposal(parsed.value);
}
test "generator module is explicitly invoked only" {
    try std.testing.expect(true);
}
test "fake fx generation saves one draft and can be approved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    try tmp.dir.createDirPath(io, "workspace");
    const script = try std.fs.path.join(a, &.{ base, "fx" });
    defer a.free(script);
    const proposal_json = "{\"issue_key\":{\"repository\":\"a/b\",\"issue_number\":1},\"issue_title\":\"Issue\",\"summary\":\"Plan\",\"completion_criteria\":[],\"candidates\":[{\"candidate_id\":\"a\",\"title\":\"実装\",\"parent_candidate_id\":null,\"position\":0}],\"excluded\":[],\"notes\":[],\"generation\":{\"generated_at\":1,\"fx_version\":\"fake\",\"attempt_count\":1},\"updated_at\":1}";
    const envelope_path = try std.fs.path.join(a, &.{ base, "response.json" });
    defer a.free(envelope_path);
    const envelope = try std.json.Stringify.valueAlloc(a, .{ .final_output = proposal_json, .session_id = "" }, .{});
    defer a.free(envelope);
    {
        const file = try std.Io.Dir.cwd().createFile(io, envelope_path, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, envelope);
    }
    const contents = try std.fmt.allocPrint(a, "#!/bin/sh\nif [ \"$1\" = permissions ]; then printf '{{\"rules\":[]}}'; exit 0; fi\ncat >/dev/null\ncat '{s}'\n", .{envelope_path});
    defer a.free(contents);
    {
        const file = try std.Io.Dir.cwd().createFile(io, script, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, contents);
    }
    const chmod = try @import("../platform/process.zig").run(a, io, .{ .argv = &.{ "chmod", "+x", script } });
    defer chmod.deinit(a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("ZTODO_FX_FX_BIN", script);
    try env.put("TMPDIR", base);
    var s = state.StateRoot.init(a);
    defer s.deinit();
    const issue = task.IssueSnapshot{ .key = .{ .repository = "a/b", .issue_number = 1 }, .title = "Issue", .body = "Body" };
    try s.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, "a/b"), .issue_number = 1 }, .title = try a.dupe(u8, "Issue"), .body = try a.dupe(u8, "Body") });
    const workspace = try tmp.dir.realPathFileAlloc(io, "workspace", a);
    defer a.free(workspace);
    try generate(a, io, &env, &s, issue, workspace, &.{});
    try std.testing.expect(s.findProposal(issue.key) != null);
    try std.testing.expectEqual(@as(usize, 1), try @import("apply.zig").apply(&s, issue.key));
    try std.testing.expect(s.findProposal(issue.key) == null);
}
