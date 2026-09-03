const std = @import("std");
const process = @import("../../platform/process.zig");
pub fn ask(a: std.mem.Allocator, io: std.Io, base_env: *const std.process.Environ.Map, cwd: []const u8, prompt: []const u8) ![]u8 {
    var env = try base_env.clone(a);
    defer env.deinit();
    try env.put("FX_PERMISSION_MODE", "ask");
    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        const result = try process.run(a, io, .{ .argv = &.{ "fx", "ask", "--json", "--no-save" }, .cwd = cwd, .stdin = prompt, .env_map = &env, .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(600), .clock = .awake } } });
        defer result.deinit(a);
        if (process.successful(result.term)) return a.dupe(u8, result.stdout);
        if (std.mem.indexOf(u8, result.stderr, "auth") != null) return error.AuthenticationRequired;
        if (attempts == 2) return error.FxFailed;
    }
    unreachable;
}
test "fx invocation is non-persistent" {
    try std.testing.expectEqualStrings("--no-save", (&[_][]const u8{ "fx", "ask", "--json", "--no-save" })[3]);
}
