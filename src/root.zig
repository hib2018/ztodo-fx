pub const cli = @import("cli.zig");
pub const task = @import("core/task.zig");
pub const state = @import("core/state.zig");
pub const store = @import("core/store.zig");
pub const paths = @import("core/paths.zig");
pub const tree = @import("core/tree.zig");
pub const proposal = @import("proposal/model.zig");

test {
    _ = cli;
    _ = task;
    _ = state;
    _ = store;
    _ = paths;
    _ = tree;
    _ = proposal;
    _ = @import("proposal/editor.zig");
    _ = @import("proposal/apply.zig");
    _ = @import("proposal/generator.zig");
    _ = @import("integrations/github/config.zig");
    _ = @import("integrations/github/client.zig");
    _ = @import("integrations/github/issue.zig");
    _ = @import("integrations/fx/client.zig");
    _ = @import("integrations/fx/permissions.zig");
    _ = @import("integrations/fx/prompt.zig");
    _ = @import("integrations/fx/response.zig");
    _ = @import("platform/process.zig");
    _ = @import("platform/snapshot.zig");
    _ = @import("cli/tree_renderer.zig");
}

test "200 tasks at ten levels render within two seconds" {
    const std = @import("std");
    var s = state.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    var parent: ?u64 = null;
    for (0..200) |i| {
        var title: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&title, "task-{d}", .{i});
        const id = try s.addTask(text, null, parent);
        parent = if (i % 10 == 9) null else id;
    }
    const started = std.Io.Clock.awake.now(std.testing.io);
    const rendered = try @import("cli/tree_renderer.zig").render(std.testing.allocator, &s);
    defer std.testing.allocator.free(rendered);
    const ended = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expect(rendered.len > 2000);
    try std.testing.expect(started.durationTo(ended).toMilliseconds() < 2000);
}

test "manual task tree survives atomic save and reload" {
    const std = @import("std");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "state.json" });
    defer std.testing.allocator.free(path);
    var s = state.StateRoot.init(std.testing.allocator);
    defer s.deinit();
    const root_id = try s.addTask("root", null, null);
    _ = try s.addTask("child", null, root_id);
    try store.save(std.testing.allocator, std.testing.io, path, &s);
    var loaded = try store.load(std.testing.allocator, std.testing.io, path);
    defer loaded.deinit();
    try loaded.validate();
    try std.testing.expectEqual(@as(?u64, root_id), loaded.tasks.items[1].parent_id);
}

test "security diagnostics never contain prompt response credential or issue body" {
    const std = @import("std");
    const secret = "super-secret-token-value";
    const message = @errorName(error.InvalidEnvelope);
    try std.testing.expect(std.mem.indexOf(u8, message, secret) == null);
    try std.testing.expectError(error.UnsafeCleanupTarget, @import("platform/snapshot.zig").validateOwnedRoot("/tmp/owned", "/tmp/outside"));
}
test "fake gh repository registration and refresh persist snapshots" {
    const std = @import("std");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const state_path = try std.fs.path.join(a, &.{ base, "state.json" });
    defer a.free(state_path);
    const config_path = try std.fs.path.join(a, &.{ base, "config.json" });
    defer a.free(config_path);
    const script = try std.fs.path.join(a, &.{ base, "gh" });
    defer a.free(script);
    {
        const file = try std.Io.Dir.cwd().createFile(io, script, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, "#!/bin/sh\nprintf '[{\"number\":7,\"title\":\"偽Issue\",\"body\":\"body\",\"state\":\"OPEN\"}]'\n");
    }
    const chmod = try @import("platform/process.zig").run(a, io, .{ .argv = &.{ "chmod", "+x", script } });
    defer chmod.deinit(a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("ZTODO_FX_DATA_FILE", state_path);
    try env.put("ZTODO_FX_CONFIG_FILE", config_path);
    try env.put("ZTODO_FX_GH_BIN", script);
    try std.testing.expectEqual(@as(u8, 0), cli.run(a, io, &env, &.{ "ztodo-fx", "repo", "add", "a/b", base }));
    try std.testing.expectEqual(@as(u8, 0), cli.run(a, io, &env, &.{ "ztodo-fx", "issue", "refresh", "a/b" }));
    var loaded = try store.load(a, io, state_path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.issues.items.len);
    try std.testing.expectEqualStrings("偽Issue", loaded.issues.items[0].title);
}
