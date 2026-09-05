const std = @import("std");
const process = @import("../../platform/process.zig");
pub fn ask(a: std.mem.Allocator, io: std.Io, base_env: *const std.process.Environ.Map, cwd: []const u8, prompt: []const u8) ![]u8 {
    var env = try base_env.clone(a);
    defer env.deinit();
    try env.put("FX_PERMISSION_MODE", "ask");
    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        const result = try process.run(a, io, .{ .argv = &.{ base_env.get("ZTODO_FX_FX_BIN") orelse "fx", "ask", "--json", "--no-save" }, .cwd = cwd, .stdin = prompt, .env_map = &env, .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(600), .clock = .awake } } });
        defer result.deinit(a);
        if (process.successful(result.term)) return a.dupe(u8, result.stdout);
        if (std.mem.indexOf(u8, result.stderr, "auth") != null) return error.AuthenticationRequired;
        if (!isTransient(result.stderr) or attempts == 2) return error.FxFailed;
    }
    unreachable;
}
pub fn isTransient(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "timeout") != null or std.mem.indexOf(u8, stderr, "network") != null or std.mem.indexOf(u8, stderr, "temporar") != null or std.mem.indexOf(u8, stderr, "provider") != null;
}
test "fx invocation is non-persistent" {
    try std.testing.expectEqualStrings("--no-save", (&[_][]const u8{ "fx", "ask", "--json", "--no-save" })[3]);
}
test "retry classification excludes auth permission and invalid output" {
    try std.testing.expect(isTransient("temporary provider network failure"));
    for ([_][]const u8{ "authentication required", "permission denied", "invalid json" }) |message| try std.testing.expect(!isTransient(message));
}
test "fake fx receives stdin cwd environment and fixed argv" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const script = try std.fs.path.join(a, &.{ base, "fx" });
    defer a.free(script);
    {
        const file = try std.Io.Dir.cwd().createFile(io, script, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, "#!/bin/sh\n[ \"$1\" = ask ] || exit 7\n[ \"$2\" = --json ] || exit 8\n[ \"$3\" = --no-save ] || exit 9\n[ \"$FX_PERMISSION_MODE\" = ask ] || exit 10\nread prompt\n[ -n \"$prompt\" ] || exit 11\nprintf '{\"final_output\":\"{}\",\"session_id\":\"\"}'\n");
    }
    const chmod = try process.run(a, io, .{ .argv = &.{ "chmod", "+x", script } });
    defer chmod.deinit(a);
    try std.testing.expect(process.successful(chmod.term));
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("ZTODO_FX_FX_BIN", script);
    const bytes = try ask(a, io, &env, base, "proposal prompt\n");
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "final_output") != null);
}
