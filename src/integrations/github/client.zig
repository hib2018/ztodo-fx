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

fn mutate(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, argv: []const []const u8) !void {
    const result = try process.run(a, io, .{ .argv = argv, .env_map = env });
    defer result.deinit(a);
    if (!process.successful(result.term)) return classifyFailure(result.stderr);
}

pub fn edit(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, repository: []const u8, number: []const u8, title: []const u8, body: []const u8) !void {
    return mutate(io, a, env, &.{ env.get("ZTODO_FX_GH_BIN") orelse "gh", "issue", "edit", number, "--repo", repository, "--title", title, "--body", body });
}

pub fn create(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, repository: []const u8, title: []const u8, body: []const u8) !void {
    return mutate(io, a, env, &.{ env.get("ZTODO_FX_GH_BIN") orelse "gh", "issue", "create", "--repo", repository, "--title", title, "--body", body });
}

pub fn setClosed(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, repository: []const u8, number: []const u8, closed: bool) !void {
    return mutate(io, a, env, &.{ env.get("ZTODO_FX_GH_BIN") orelse "gh", "issue", if (closed) "close" else "reopen", number, "--repo", repository });
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

test "issue open uses gh web mode and reports failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const script = try std.fs.path.join(a, &.{ base, "gh-open" });
    defer a.free(script);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, script, .{});
        defer file.close(std.testing.io);
        try std.Io.File.writeStreamingAll(file, std.testing.io, "#!/bin/sh\ncase \"$*\" in *'issue view 7 --repo a/b --web'*) exit 0;; *) exit 1;; esac\n");
    }
    const chmod = try process.run(a, std.testing.io, .{ .argv = &.{ "chmod", "+x", script } });
    defer chmod.deinit(a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("ZTODO_FX_GH_BIN", script);
    try open(std.testing.io, a, &env, "a/b", "7");
    try std.testing.expectError(error.GitHubFailed, open(std.testing.io, a, &env, "a/b", "8"));
}

test "issue mutations use non-interactive gh arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const script = try std.fs.path.join(a, &.{ base, "gh-mutate" });
    defer a.free(script);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, script, .{});
        defer file.close(std.testing.io);
        try std.Io.File.writeStreamingAll(file, std.testing.io, "#!/bin/sh\ncase \"$*\" in\n'issue edit 7 --repo a/b --title New title --body New body'|'issue create --repo a/b --title New title --body New body'|'issue close 7 --repo a/b'|'issue reopen 7 --repo a/b') exit 0;;\n*) echo bad arguments >&2; exit 1;;\nesac\n");
    }
    const chmod = try process.run(a, std.testing.io, .{ .argv = &.{ "chmod", "+x", script } });
    defer chmod.deinit(a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("ZTODO_FX_GH_BIN", script);
    try edit(std.testing.io, a, &env, "a/b", "7", "New title", "New body");
    try create(std.testing.io, a, &env, "a/b", "New title", "New body");
    try setClosed(std.testing.io, a, &env, "a/b", "7", true);
    try setClosed(std.testing.io, a, &env, "a/b", "7", false);
}
