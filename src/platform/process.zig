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
        error.Canceled => error.Canceled,
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
    std.Io.File.writeStreamingAll(child.stdin.?, io, request.stdin) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.ProcessFailed,
    };
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
        error.Canceled => return error.Canceled,
        else => return error.ProcessFailed,
    }
    reader.checkAnyError() catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.ProcessFailed,
    };
    const term = child.wait(io) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.ProcessFailed,
    };
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
test "runner passes stdin cwd env and typed output" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUNNER_TEST", "ok");
    const result = try run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "printf '%s:' \"$RUNNER_TEST\"; pwd; cat" }, .cwd = "/tmp", .stdin = "payload", .env_map = &env });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(successful(result.term));
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "ok:"));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "/tmp") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "payload"));
}
test "runner classifies output limit timeout and signal" {
    try std.testing.expectError(error.OutputTooLarge, run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "printf 12345" }, .output_limit = 4 }));
    try std.testing.expectError(error.Timeout, run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 1" }, .stdin = "x", .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromNanoseconds(1), .clock = .awake } } }));
    const signaled = try run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "kill -TERM $$" } });
    defer signaled.deinit(std.testing.allocator);
    try std.testing.expect(!successful(signaled.term));
}
test "runner propagates concurrent cancellation and terminates child" {
    var future = try std.testing.io.concurrent(run, .{ std.testing.allocator, std.testing.io, Request{ .argv = &.{ "/bin/sh", "-c", "sleep 10" }, .stdin = "start" } });
    try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
}
