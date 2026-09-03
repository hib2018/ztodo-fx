const std = @import("std");
const model = @import("../../proposal/model.zig");
const Envelope = struct { final_output: []const u8, session_id: []const u8 };
pub fn proposalBytes(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len > 16 * 1024 * 1024) return error.OutputTooLarge;
    var parsed = std.json.parseFromSlice(Envelope, a, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidEnvelope;
    defer parsed.deinit();
    if (parsed.value.session_id.len == 0) return error.EmptySession;
    var value = std.mem.trim(u8, parsed.value.final_output, " \t\r\n");
    if (std.mem.startsWith(u8, value, "```")) {
        const first = std.mem.indexOfScalar(u8, value, '\n') orelse return error.MarkdownFence;
        const last = std.mem.lastIndexOf(u8, value, "```") orelse return error.MarkdownFence;
        value = std.mem.trim(u8, value[first + 1 .. last], " \t\r\n");
    }
    if (value.len == 0) return error.EmptyFinalOutput;
    return a.dupe(u8, value);
}
pub fn decodeProposal(a: std.mem.Allocator, envelope: []const u8) !std.json.Parsed(model.Proposal) {
    const bytes = try proposalBytes(a, envelope);
    defer a.free(bytes);
    return std.json.parseFromSlice(model.Proposal, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}
test "envelope permits unknown fields and strips fence" {
    const value = try proposalBytes(std.testing.allocator, "{\"final_output\":\"```json\\n{\\\"summary\\\":\\\"x\\\"}\\n```\",\"session_id\":\"s\",\"future\":1}");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("{\"summary\":\"x\"}", value);
}
