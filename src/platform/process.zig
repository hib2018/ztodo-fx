const std = @import("std");
pub const max_output = 16 * 1024 * 1024;
pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    pub fn deinit(self: Result, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};
pub const Request = struct { argv: []const []const u8, cwd: ?[]const u8 = null, stdin: []const u8 = "", env_map: ?*const std.process.Environ.Map = null, output_limit: usize = max_output, timeout: std.Io.Timeout = .none };
pub fn run(a: std.mem.Allocator, io: std.Io, request: Request) !Result {
    if (request.argv.len == 0 or request.output_limit == 0 or request.output_limit > max_output) return error.InvalidRequest;
    if (request.stdin.len != 0) return runWithInput(a, io, request);
    const result = std.process.run(a, io, .{ .argv = request.argv, .cwd = if (request.cwd) |p| .{ .path = p } else .inherit, .environ_map = request.env_map, .stdout_limit = .limited(request.output_limit), .stderr_limit = .limited(request.output_limit) }) catch |e| return switch (e) {
        error.FileNotFound => error.ExecutableNotFound,
        error.StreamTooLong => error.OutputTooLarge,
        else => error.ProcessFailed,
    };
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}
fn runWithInput(a: std.mem.Allocator, io: std.Io, request: Request) !Result {
    var child = std.process.spawn(io, .{ .argv = request.argv, .cwd = if (request.cwd) |p| .{ .path = p } else .inherit, .environ_map = request.env_map, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe }) catch |e| return switch (e) {
        error.FileNotFound => error.ExecutableNotFound,
        else => error.ProcessFailed,
    };
    defer child.kill(io);
    std.Io.File.writeStreamingAll(child.stdin.?, io, request.stdin) catch return error.ProcessFailed;
    child.stdin.?.close(io);
    child.stdin = null;
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const stdout = reader.reader(0);
    const stderr = reader.reader(1);
    while (reader.fill(64, request.timeout)) |_| {
        if (stdout.buffered().len > request.output_limit or stderr.buffered().len > request.output_limit) return error.OutputTooLarge;
    } else |e| switch (e) {
        error.EndOfStream => {},
        error.Timeout => return error.Timeout,
        else => return error.ProcessFailed,
    }
    reader.checkAnyError() catch return error.ProcessFailed;
    const term = child.wait(io) catch return error.ProcessFailed;
    const out_bytes = try reader.toOwnedSlice(0);
    errdefer a.free(out_bytes);
    const err_bytes = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = out_bytes, .stderr = err_bytes };
}
pub fn successful(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
test "empty argv fails" {
    try std.testing.expectError(error.InvalidRequest, run(std.testing.allocator, std.testing.io, .{ .argv = &.{} }));
}
