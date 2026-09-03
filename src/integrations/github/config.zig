const std = @import("std");
pub const Repository = struct { repository: []const u8, workspace_path: []const u8, exclude_patterns: []const []const u8 = &.{}, registration_order: u32 };
pub const Config = struct {
    allocator: std.mem.Allocator,
    schema_version: u32 = 1,
    repositories: std.ArrayList(Repository) = .empty,
    pub fn init(a: std.mem.Allocator) Config {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Config) void {
        for (self.repositories.items) |r| freeRepo(self.allocator, r);
        self.repositories.deinit(self.allocator);
    }
    pub fn find(self: *Config, name: []const u8) ?*Repository {
        for (self.repositories.items) |*r| if (std.mem.eql(u8, r.repository, name)) return r;
        return null;
    }
    pub fn add(self: *Config, name: []const u8, workspace: []const u8) !void {
        if (self.repositories.items.len >= 20) return error.TooManyRepositories;
        try validateName(name);
        if (!std.fs.path.isAbsolute(workspace)) return error.WorkspaceMustBeAbsolute;
        if (self.find(name) != null) return error.RepositoryExists;
        for (self.repositories.items) |r| if (std.mem.eql(u8, r.workspace_path, workspace)) return error.WorkspaceAlreadyMapped;
        try self.repositories.append(self.allocator, .{ .repository = try self.allocator.dupe(u8, name), .workspace_path = try self.allocator.dupe(u8, workspace), .registration_order = @intCast(self.repositories.items.len) });
    }
    pub fn setWorkspace(self: *Config, name: []const u8, workspace: []const u8) !void {
        if (!std.fs.path.isAbsolute(workspace)) return error.WorkspaceMustBeAbsolute;
        const r = self.find(name) orelse return error.RepositoryNotFound;
        const copy = try self.allocator.dupe(u8, workspace);
        self.allocator.free(r.workspace_path);
        r.workspace_path = copy;
    }
    pub fn delete(self: *Config, name: []const u8) !void {
        for (self.repositories.items, 0..) |r, i| if (std.mem.eql(u8, r.repository, name)) {
            freeRepo(self.allocator, self.repositories.orderedRemove(i));
            return;
        };
        return error.RepositoryNotFound;
    }
    pub fn addExclude(self: *Config, name: []const u8, pattern: []const u8) !void {
        if (pattern.len == 0) return error.EmptyPattern;
        const r = self.find(name) orelse return error.RepositoryNotFound;
        if (r.exclude_patterns.len >= 64) return error.TooManyPatterns;
        var list = try self.allocator.alloc([]const u8, r.exclude_patterns.len + 1);
        @memcpy(list[0..r.exclude_patterns.len], r.exclude_patterns);
        list[r.exclude_patterns.len] = try self.allocator.dupe(u8, pattern);
        self.allocator.free(r.exclude_patterns);
        r.exclude_patterns = list;
    }
    pub fn deleteExclude(self: *Config, name: []const u8, pattern: []const u8) !void {
        const r = self.find(name) orelse return error.RepositoryNotFound;
        for (r.exclude_patterns, 0..) |value, i| if (std.mem.eql(u8, value, pattern)) {
            self.allocator.free(value);
            var list = try self.allocator.alloc([]const u8, r.exclude_patterns.len - 1);
            @memcpy(list[0..i], r.exclude_patterns[0..i]);
            @memcpy(list[i..], r.exclude_patterns[i + 1 ..]);
            self.allocator.free(r.exclude_patterns);
            r.exclude_patterns = list;
            return;
        };
        return error.PatternNotFound;
    }
};
fn validateName(name: []const u8) !void {
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return error.InvalidRepository;
    if (slash == 0 or slash + 1 == name.len) return error.InvalidRepository;
}
pub fn validateWorkspace(io: std.Io, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.WorkspaceMustBeAbsolute;
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return error.WorkspaceUnavailable;
    dir.close(io);
}
fn freeRepo(a: std.mem.Allocator, r: Repository) void {
    a.free(r.repository);
    a.free(r.workspace_path);
    for (r.exclude_patterns) |p| a.free(p);
    a.free(r.exclude_patterns);
}
const Disk = struct { schema_version: u32 = 1, repositories: []const Repository = &.{} };
pub fn encode(a: std.mem.Allocator, c: *const Config) ![]u8 {
    return std.json.Stringify.valueAlloc(a, Disk{ .schema_version = c.schema_version, .repositories = c.repositories.items }, .{ .whitespace = .indent_2 });
}
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Config {
    var parsed = std.json.parseFromSlice(Disk, a, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidConfig;
    defer parsed.deinit();
    if (parsed.value.schema_version != 1) return error.UnsupportedSchema;
    var c = Config.init(a);
    errdefer c.deinit();
    for (parsed.value.repositories) |r| {
        try c.add(r.repository, r.workspace_path);
        for (r.exclude_patterns) |p| try c.addExclude(r.repository, p);
    }
    return c;
}
pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |e| return switch (e) {
        error.FileNotFound => Config.init(a),
        else => error.ReadFailed,
    };
    defer a.free(bytes);
    return decode(a, bytes);
}
pub fn save(a: std.mem.Allocator, io: std.Io, path: []const u8, c: *const Config) !void {
    const bytes = try encode(a, c);
    defer a.free(bytes);
    var atomic = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch return error.WriteFailed;
    defer atomic.deinit(io);
    try std.Io.File.writeStreamingAll(atomic.file, io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
test "repository and workspace are one-to-one" {
    var c = Config.init(std.testing.allocator);
    defer c.deinit();
    try c.add("a/b", "/tmp/a");
    try std.testing.expectError(error.WorkspaceAlreadyMapped, c.add("c/d", "/tmp/a"));
}
test "config enforces limit and exclusion round trips" {
    var c = Config.init(std.testing.allocator);
    defer c.deinit();
    var names: [20][16]u8 = undefined;
    var paths: [20][32]u8 = undefined;
    for (0..20) |i| {
        const name = try std.fmt.bufPrint(&names[i], "o/r{d}", .{i});
        const path = try std.fmt.bufPrint(&paths[i], "/tmp/w{d}", .{i});
        try c.add(name, path);
    }
    try std.testing.expectError(error.TooManyRepositories, c.add("o/overflow", "/tmp/overflow"));
    try c.addExclude("o/r0", "*.secret");
    const bytes = try encode(std.testing.allocator, &c);
    defer std.testing.allocator.free(bytes);
    var restored = try decode(std.testing.allocator, bytes);
    defer restored.deinit();
    try std.testing.expectEqualStrings("*.secret", restored.find("o/r0").?.exclude_patterns[0]);
}
