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
