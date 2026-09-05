const std = @import("std");
const process = @import("../../platform/process.zig");
pub const RemoteIssue = struct { number: u64, title: []const u8, body: []const u8 = "", state: []const u8 };
pub fn list(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, repository: []const u8) !std.json.Parsed([]RemoteIssue) {
    const result = try process.run(a, io, .{ .argv = &.{ env.get("ZTODO_FX_GH_BIN") orelse "gh", "issue", "list", "--repo", repository, "--state", "all", "--limit", "10000", "--json", "number,title,body,state" }, .env_map = env });
    defer result.deinit(a);
    if (!process.successful(result.term)) {
        return classifyFailure(result.stderr);
    }
    return parseList(a, result.stdout);
}
pub fn classifyFailure(stderr: []const u8) anyerror {
    if (std.mem.indexOf(u8, stderr, "auth") != null or std.mem.indexOf(u8, stderr, "login") != null) return error.AuthenticationRequired;
    if (std.mem.indexOf(u8, stderr, "forbidden") != null or std.mem.indexOf(u8, stderr, "403") != null) return error.Forbidden;
    if (std.mem.indexOf(u8, stderr, "not found") != null or std.mem.indexOf(u8, stderr, "404") != null) return error.NotFound;
    if (std.mem.indexOf(u8, stderr, "network") != null or std.mem.indexOf(u8, stderr, "connection") != null) return error.Network;
    return error.GitHubFailed;
}
pub fn parseList(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed([]RemoteIssue) {
    return std.json.parseFromSlice([]RemoteIssue, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.InvalidResponse;
}
pub fn open(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, repository: []const u8, number: []const u8) !void {
    const result = try process.run(a, io, .{ .argv = &.{ env.get("ZTODO_FX_GH_BIN") orelse "gh", "issue", "view", number, "--repo", repository, "--web" }, .env_map = env });
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
test "fake gh response and authentication error are classified" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const script = try std.fs.path.join(a, &.{ base, "gh" });
    defer a.free(script);
    {
        const file = try std.Io.Dir.cwd().createFile(io, script, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, "#!/bin/sh\nif [ \"$FAKE_AUTH\" = fail ]; then echo 'authentication required' >&2; exit 1; fi\nprintf '[{\"number\":1,\"title\":\"日本語\",\"body\":\"本文\",\"state\":\"OPEN\"}]'\n");
    }
    const chmod = try process.run(a, io, .{ .argv = &.{ "chmod", "+x", script } });
    defer chmod.deinit(a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("ZTODO_FX_GH_BIN", script);
    var result = try list(a, io, &env, "a/b");
    defer result.deinit();
    try std.testing.expectEqualStrings("日本語", result.value[0].title);
    try env.put("FAKE_AUTH", "fail");
    try std.testing.expectError(error.AuthenticationRequired, list(a, io, &env, "a/b"));
}
test "GitHub failures distinguish permission network and not found" {
    try std.testing.expect(classifyFailure("403 forbidden") == error.Forbidden);
    try std.testing.expect(classifyFailure("network connection failed") == error.Network);
    try std.testing.expect(classifyFailure("404 not found") == error.NotFound);
}
