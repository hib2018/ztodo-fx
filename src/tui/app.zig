const std = @import("std");
const vaxis = @import("vaxis");
const paths_mod = @import("../core/paths.zig");
const store = @import("../core/store.zig");
const tree = @import("../core/tree.zig");
const Model = @import("model.zig").Model;

pub const panic_handler = vaxis.panic_handler;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn run(init: std.process.Init) u8 {
    runFallible(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("Error ({t}): TUIを起動できません。`zt doctor`で環境を確認してください。\n", .{err}) catch {};
        stderr.interface.flush() catch {};
        return 1;
    };
    return 0;
}

fn runFallible(init: std.process.Init) !void {
    const allocator = init.gpa;
    const paths = try paths_mod.resolve(allocator, init.environ_map.*);
    defer paths_mod.deinit(allocator, paths);
    try paths_mod.ensureParents(init.io, paths);
    var state = try store.load(allocator, init.io, paths.state);
    defer state.deinit();
    var model: Model = .{};

    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(init.io, &tty_buffer);
    defer tty.deinit();
    var vx = try vaxis.init(init.io, allocator, init.environ_map, .{});
    defer vx.deinit(allocator, tty.writer());
    var loop: vaxis.Loop(Event) = .init(init.io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    while (true) {
        // Vaxis cells retain slices into formatted text until render completes.
        // Keep every per-frame string alive for that entire interval.
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();
        const ordered_ids = try taskOrder(frame_allocator, &state);
        draw(frame_allocator, &vx, &state, model, ordered_ids);
        try vx.render(tty.writer());
        const event = try loop.nextEvent();
        switch (event) {
            .winsize => |size| try vx.resize(allocator, tty.writer(), size),
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) model.moveDown(ordered_ids.len);
                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) model.moveUp();
                if (key.matches(' ', .{})) {
                    if (model.selectedTaskId(ordered_ids)) |id| {
                        _ = try state.toggle(id);
                        try store.save(allocator, init.io, paths.state, &state);
                    }
                }
            },
        }
    }
}

fn draw(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, state: *const @import("../core/state.zig").StateRoot, model: Model, ordered_ids: []const u64) void {
    const screen = vx.window();
    screen.clear();
    screen.hideCursor();
    if (screen.width < 60 or screen.height < 12) {
        _ = screen.printSegment(.{ .text = "zt: 端末サイズが小さすぎます（60x12以上が必要です）" }, .{});
        return;
    }
    const body_height = screen.height -| 2;
    const left_width = @max(@as(u16, 20), screen.width / 4);
    const detail_width = @max(@as(u16, 24), screen.width / 4);
    const center_width = screen.width -| left_width -| detail_width;
    const left = screen.child(.{ .width = left_width, .height = body_height, .border = .{ .where = .all } });
    const center = screen.child(.{ .x_off = @intCast(left_width), .width = center_width, .height = body_height, .border = .{ .where = .all } });
    const detail = screen.child(.{ .x_off = @intCast(left_width + center_width), .width = detail_width, .height = body_height, .border = .{ .where = .all } });
    const footer = screen.child(.{ .y_off = @intCast(body_height), .height = 2 });

    _ = left.printSegment(.{ .text = "Repositories / Issues" }, .{ .wrap = .none });
    var row: u16 = 2;
    for (state.issues.items) |issue| {
        if (row >= left.height) break;
        const line = std.fmt.allocPrint(allocator, "{s}#{d} [{s}] {s}", .{ issue.key.repository, issue.key.issue_number, @tagName(issue.status), issue.title }) catch continue;
        _ = left.printSegment(.{ .text = line }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (state.issues.items.len == 0) _ = left.printSegment(.{ .text = "Issue未取得" }, .{ .row_offset = 2 });

    _ = center.printSegment(.{ .text = "Tasks" }, .{ .wrap = .none });
    row = 2;
    for (ordered_ids, 0..) |id, index| {
        if (row >= center.height) break;
        const item = findTask(state, id) orelse continue;
        const depth = tree.depth(state, item.id) catch 0;
        const indent = allocator.alloc(u8, depth * 2) catch continue;
        @memset(indent, ' ');
        const line = std.fmt.allocPrint(allocator, "{s}{s} {d}: {s}", .{ indent, if (item.status == .done) "[x]" else "[ ]", item.id, item.title }) catch continue;
        _ = center.printSegment(.{ .text = line, .style = if (index == model.selected) .{ .reverse = true } else .{} }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (state.tasks.items.len == 0) _ = center.printSegment(.{ .text = "Taskはありません" }, .{ .row_offset = 2 });

    _ = detail.printSegment(.{ .text = "Details" }, .{ .wrap = .none });
    if (model.selectedTaskId(ordered_ids)) |id| if (findTask(state, id)) |selected| {
        const text = std.fmt.allocPrint(allocator, "Task #{d}\n\n{s}\n\nStatus: {s}", .{ selected.id, selected.title, @tagName(selected.status) }) catch return;
        _ = detail.printSegment(.{ .text = text }, .{ .row_offset = 2, .wrap = .word });
    };
    _ = footer.printSegment(.{ .text = "NORMAL  j/k, ↑/↓:移動  Space:完了切替  q:終了" }, .{ .row_offset = 1, .wrap = .none });
}

fn taskOrder(allocator: std.mem.Allocator, state: *const @import("../core/state.zig").StateRoot) ![]u64 {
    var result: std.ArrayList(u64) = .empty;
    errdefer result.deinit(allocator);
    for (state.issues.items) |issue| {
        const ids = try tree.preorder(allocator, state, issue.key);
        try result.appendSlice(allocator, ids);
    }
    const unlinked = try tree.preorder(allocator, state, null);
    try result.appendSlice(allocator, unlinked);
    return result.toOwnedSlice(allocator);
}

fn findTask(state: *const @import("../core/state.zig").StateRoot, id: u64) ?@import("../core/task.zig").Task {
    for (state.tasks.items) |item| if (item.id == id) return item;
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
