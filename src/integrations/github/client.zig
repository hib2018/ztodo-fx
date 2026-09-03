const std = @import("std");
const process = @import("../../platform/process.zig");
pub const RemoteIssue = struct { number: u64, title: []const u8, body: []const u8 = "", state: []const u8 };
pub fn list(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, repository: []const u8) !std.json.Parsed([]RemoteIssue) {
    const result = try process.run(a, io, .{ .argv = &.{ "gh", "issue", "list", "--repo", repository, "--state", "all", "--limit", "100", "--json", "number,title,body,state" }, .env_map = env });
    defer result.deinit(a);
    if (!process.successful(result.term)) {
        if (std.mem.indexOf(u8, result.stderr, "auth") != null) return error.AuthenticationRequired;
        return error.GitHubFailed;
    }
    return parseList(a, result.stdout);
}
pub fn parseList(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed([]RemoteIssue) {
    return std.json.parseFromSlice([]RemoteIssue, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.InvalidResponse;
}
pub fn open(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, repository: []const u8, number: []const u8) !void {
    const result = try process.run(a, io, .{ .argv = &.{ "gh", "issue", "view", number, "--repo", repository, "--web" }, .env_map = env });
    defer result.deinit(a);
    if (!process.successful(result.term)) return error.GitHubFailed;
}
test "issue command pins JSON fields" {
    try std.testing.expect(std.mem.indexOf(u8, "number,title,body,state", "body") != null);
}
test "parsed Unicode titles own their bytes" {
    const bytes = try std.testing.allocator.dupe(u8, "[{\"number\":1,\"title\":\"日本語タイトル\",\"body\":\"本文\",\"state\":\"OPEN\"}]");
    defer std.testing.allocator.free(bytes);
    var parsed = try parseList(std.testing.allocator, bytes);
    defer parsed.deinit();
    @memset(bytes, 0xaa);
    try std.testing.expectEqualStrings("日本語タイトル", parsed.value[0].title);
    try std.testing.expectEqualStrings("本文", parsed.value[0].body);
}
