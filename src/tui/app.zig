const std = @import("std");
const vaxis = @import("vaxis");
const paths_mod = @import("../core/paths.zig");
const store = @import("../core/store.zig");
const state_mod = @import("../core/state.zig");
const tree = @import("../core/tree.zig");
const task_mod = @import("../core/task.zig");
const Service = @import("../application/service.zig").Service;
const ConfigService = @import("../application/service.zig").ConfigService;
const config_mod = @import("../integrations/github/config.zig");
const gh = @import("../integrations/github/client.zig");
const issue_adapter = @import("../integrations/github/issue.zig");
const generator = @import("../proposal/generator.zig");
const proposal_editor = @import("../proposal/editor.zig");
const proposal_apply = @import("../proposal/apply.zig");
const Model = @import("model.zig").Model;

pub const panic_handler = vaxis.panic_handler;

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    operation_complete,
    winsize: vaxis.Winsize,
};
const Loop = vaxis.Loop(Event);
const Proposal = @import("../proposal/model.zig").Proposal;
const OperationBox = struct {
    loop: *Loop,
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    issue: task_mod.IssueSnapshot,
    workspace: []const u8,
    excludes: []const []const u8,
    result: ?(anyerror!Proposal) = null,
};
const Operation = struct { box: *OperationBox, future: std.Io.Future(void), cancel_requested: bool = false };

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
    const service = Service{ .allocator = allocator, .io = init.io, .state_path = paths.state };
    var config = try config_mod.load(allocator, init.io, paths.config);
    defer config.deinit();
    const config_service = ConfigService{ .allocator = allocator, .io = init.io, .config_path = paths.config };
    var model: Model = .{};

    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(init.io, &tty_buffer);
    defer tty.deinit();
    var vx = try vaxis.init(init.io, allocator, init.environ_map, .{});
    defer vx.deinit(allocator, tty.writer());
    var loop: Loop = .init(init.io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.writer());
    try vx.setMouseMode(tty.writer(), true);
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    var operation: ?Operation = null;
    defer if (operation) |*active| {
        _ = active.future.cancel(init.io);
        if (active.box.result) |result| if (result) |proposal| state_mod.freeProposal(allocator, proposal) else |_| {};
        allocator.destroy(active.box);
    };

    while (true) {
        // Vaxis cells retain slices into formatted text until render completes.
        // Keep every per-frame string alive for that entire interval.
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();
        const issue_filter = selectedIssue(&state, model.selected_issue);
        const ordered_ids = try taskOrder(frame_allocator, &state, issue_filter, model.filterSlice());
        draw(frame_allocator, &vx, &state, &config, model, ordered_ids);
        try vx.render(tty.writer());
        const event = try loop.nextEvent();
        switch (event) {
            .operation_complete => finishProposalOperation(allocator, init.io, service, &model, &state, &operation),
            .winsize => |size| try vx.resize(allocator, tty.writer(), size),
            .mouse => |mouse| handleMouse(&model, mouse, vx.window().width, vx.window().height, state.issues.items.len, ordered_ids.len),
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) break;
                model.message_len = 0;
                if (model.mode == .proposal_running) {
                    if (key.matches(vaxis.Key.escape, .{})) if (operation) |*active| {
                        _ = active.future.cancel(init.io);
                        active.cancel_requested = true;
                        model.setMessage("Proposal生成を中断しています…");
                    };
                    continue;
                }
                if (model.mode == .repository_add or model.mode == .repository_workspace) {
                    handleRepositoryInput(&model, key, &config, config_service) catch |err| setError(&model, err);
                    continue;
                }
                if (model.mode == .add or model.mode == .edit or model.mode == .search or model.mode == .proposal_add or model.mode == .proposal_edit or model.mode == .proposal_reparent) {
                    handleInput(&model, key, &state, ordered_ids, service) catch |err| setError(&model, err);
                    continue;
                }
                if (model.mode == .confirm_delete) {
                    if (key.matches(vaxis.Key.escape, .{})) model.mode = .normal else if (model.selectedTaskId(ordered_ids)) |id| {
                        if (key.matches('s', .{})) {
                            service.deleteTask(&state, id, true) catch |err| {
                                setError(&model, err);
                                continue;
                            };
                            model.mode = .normal;
                            model.selected -|= 1;
                        } else if (key.matches('p', .{})) {
                            service.deleteTask(&state, id, false) catch |err| {
                                setError(&model, err);
                                continue;
                            };
                            model.mode = .normal;
                            model.selected -|= 1;
                        }
                    }
                    continue;
                }
                if (model.mode == .help) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('?', .{}) or key.matches('q', .{})) model.mode = .normal;
                    continue;
                }
                if (model.mode == .confirm_repository_delete) {
                    handleRepositoryDelete(&model, key, &config, config_service) catch |err| setError(&model, err);
                    continue;
                }
                if (model.mode == .repositories) {
                    handleRepositories(&model, key, &config);
                    continue;
                }
                if (model.mode == .confirm_proposal_delete or model.mode == .confirm_proposal_approve or model.mode == .confirm_proposal_duplicates or model.mode == .confirm_proposal_discard) {
                    handleProposalConfirmation(service, &model, &state, key) catch |err| setError(&model, err);
                    continue;
                }
                if (model.mode == .proposal) {
                    handleProposal(allocator, init.io, init.environ_map, &config, service, &model, &state, key, &loop, &operation) catch |err| setError(&model, err);
                    continue;
                }
                if (key.matches('q', .{})) break;
                if (model.focus == .issues and key.matches('r', .{})) {
                    refreshSelectedIssue(allocator, init.io, init.environ_map, service, &model, &state) catch |err| setError(&model, err);
                    continue;
                }
                if (key.matches(vaxis.Key.tab, .{ .shift = true })) model.previousFocus() else if (key.matches(vaxis.Key.tab, .{})) model.nextFocus() else if (key.matches('/', .{})) model.beginInput(.search, model.filterSlice()) else if (key.matches('c', .{})) model.mode = .repositories else if (key.matches('?', .{})) model.mode = .help else if (key.matches('p', .{})) model.mode = .proposal else switch (model.focus) {
                    .issues => handleIssueNavigation(&model, key, state.issues.items.len),
                    .tasks => handleTaskKey(&model, key, &state, ordered_ids, issue_filter, service) catch |err| setError(&model, err),
                    .details => {},
                }
            },
        }
    }
}

fn draw(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, state: *const @import("../core/state.zig").StateRoot, config: *const config_mod.Config, model: Model, ordered_ids: []const u64) void {
    const screen = vx.window();
    screen.clear();
    screen.hideCursor();
    if (screen.width < 40 or screen.height < 10) {
        _ = screen.printSegment(.{ .text = "zt: 端末サイズが小さすぎます（40x10以上が必要です）" }, .{});
        return;
    }
    const body_height = screen.height -| 2;
    const compact = screen.width < 90;
    const left_width: u16 = if (compact) (if (model.focus == .issues) screen.width else 0) else @max(@as(u16, 20), screen.width / 4);
    const detail_width: u16 = if (compact) (if (model.focus == .details) screen.width else 0) else @max(@as(u16, 24), screen.width / 4);
    const center_width: u16 = if (compact) (if (model.focus == .tasks) screen.width else 0) else screen.width -| left_width -| detail_width;
    const left = screen.child(.{ .width = left_width, .height = body_height, .border = .{ .where = .all } });
    const center = screen.child(.{ .x_off = @intCast(left_width), .width = center_width, .height = body_height, .border = .{ .where = .all } });
    const detail = screen.child(.{ .x_off = @intCast(left_width + center_width), .width = detail_width, .height = body_height, .border = .{ .where = .all } });
    const footer = screen.child(.{ .y_off = @intCast(body_height), .height = 2 });

    _ = left.printSegment(.{ .text = "Repositories / Issues" }, .{ .wrap = .none });
    var row: u16 = 2;
    const issue_visible: usize = @max(@as(usize, 1), left.height -| 3);
    const issue_offset = if (model.selected_issue >= issue_visible) model.selected_issue - issue_visible + 1 else 0;
    for (state.issues.items[issue_offset..], issue_offset..) |issue, index| {
        if (row >= left.height) break;
        const line = std.fmt.allocPrint(allocator, "{s}#{d} [{s}] {s}", .{ issue.key.repository, issue.key.issue_number, @tagName(issue.status), issue.title }) catch continue;
        const issue_style = vaxis.Style{ .fg = .{ .index = switch (issue.status) {
            .open => 2,
            .closed => 8,
            .deleted => 1,
            .unavailable => 3,
        } }, .reverse = model.focus == .issues and index == model.selected_issue };
        _ = left.printSegment(.{ .text = line, .style = issue_style }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (row < left.height) _ = left.printSegment(.{ .text = "Unlinked", .style = if (model.focus == .issues and model.selected_issue == state.issues.items.len) .{ .reverse = true } else .{} }, .{ .row_offset = row, .wrap = .none });

    _ = center.printSegment(.{ .text = "Tasks" }, .{ .wrap = .none });
    row = 2;
    const task_visible: usize = @max(@as(usize, 1), center.height -| 3);
    const task_offset = if (model.selected >= task_visible) model.selected - task_visible + 1 else 0;
    for (ordered_ids[task_offset..], task_offset..) |id, index| {
        if (row >= center.height) break;
        const item = findTask(state, id) orelse continue;
        const depth = tree.depth(state, item.id) catch 0;
        const indent = allocator.alloc(u8, depth * 2) catch continue;
        @memset(indent, ' ');
        const line = std.fmt.allocPrint(allocator, "{s}{s} {d}: {s}", .{ indent, if (item.status == .done) "[x]" else "[ ]", item.id, item.title }) catch continue;
        _ = center.printSegment(.{ .text = line, .style = .{ .fg = if (item.status == .done) .{ .index = 8 } else .default, .reverse = model.focus == .tasks and index == model.selected } }, .{ .row_offset = row, .wrap = .none });
        row += 1;
    }
    if (state.tasks.items.len == 0) _ = center.printSegment(.{ .text = "Taskはありません" }, .{ .row_offset = 2 });

    _ = detail.printSegment(.{ .text = "Details" }, .{ .wrap = .none });
    if (model.focus == .issues and model.selected_issue < state.issues.items.len) {
        const issue = state.issues.items[model.selected_issue];
        const text = std.fmt.allocPrint(allocator, "{s}#{d}\n\n{s}\n\nStatus: {s}\n\n{s}", .{ issue.key.repository, issue.key.issue_number, issue.title, @tagName(issue.status), issue.body }) catch return;
        _ = detail.printSegment(.{ .text = text }, .{ .row_offset = 2, .wrap = .word });
    } else if (model.selectedTaskId(ordered_ids)) |id| if (findTask(state, id)) |selected| {
        const text = std.fmt.allocPrint(allocator, "Task #{d}\n\n{s}\n\nStatus: {s}", .{ selected.id, selected.title, @tagName(selected.status) }) catch return;
        _ = detail.printSegment(.{ .text = text }, .{ .row_offset = 2, .wrap = .word });
    };
    const footer_text = if (model.message_len != 0) model.messageSlice() else switch (model.mode) {
        .normal => "NORMAL  Tab:ペイン j/k:移動 a/e/d:Task p:Proposal c:Repositories ?:help q:終了",
        .add => "ADD  タイトルを入力 Enter:保存 Esc:取消",
        .edit => "EDIT  タイトルを入力 Enter:保存 Esc:取消",
        .search => "SEARCH  絞込み文字列を入力 Enter:適用 Esc:取消",
        .repositories => "REPOSITORIES  j/k:選択 a:追加 e:Workspace変更 d:削除 Esc:戻る",
        .repository_add => "REPOSITORY ADD  owner/repo /absolute/workspace Enter:保存 Esc:取消",
        .repository_workspace => "WORKSPACE  絶対pathを入力 Enter:保存 Esc:取消",
        .confirm_repository_delete => "DELETE REPOSITORY  y:削除 Esc:取消",
        .confirm_delete => "DELETE  s:部分木削除 p:子を昇格 Esc:取消",
        .help => "HELP",
        .proposal => "PROPOSAL  j/k:選択 a/e/d:編集 J/K:移動 R:親変更 g:生成 A:承認 D:破棄",
        .proposal_running => "GENERATING  fxがWorkspaceを調査しています Esc:中断",
        .proposal_add => "PROPOSAL ADD  タイトルを入力 Enter:保存 Esc:取消",
        .proposal_edit => "PROPOSAL EDIT  タイトルを入力 Enter:保存 Esc:取消",
        .proposal_reparent => "REPARENT  親candidate IDまたはrootを入力 Enter:保存 Esc:取消",
        .confirm_proposal_delete => "DELETE CANDIDATE  y:削除 Esc:取消",
        .confirm_proposal_approve => "APPROVE  y:Taskへ追加 Esc:取消",
        .confirm_proposal_duplicates => "DUPLICATES  重複候補があります y:それでも追加 Esc:取消",
        .confirm_proposal_discard => "DISCARD  y:Draft破棄 Esc:取消",
    };
    _ = footer.printSegment(.{ .text = footer_text }, .{ .row_offset = 1, .wrap = .none });

    if (model.mode == .add or model.mode == .edit) drawDialog(screen, "Task title", model.inputSlice());
    if (model.mode == .search) drawDialog(screen, "Search tasks", model.inputSlice());
    if (model.mode == .repository_add) drawDialog(screen, "Add repository", model.inputSlice());
    if (model.mode == .repository_workspace) drawDialog(screen, "Workspace path", model.inputSlice());
    if (model.mode == .confirm_repository_delete) drawDialog(screen, "Repository設定を削除します", "y: confirm / Esc: cancel");
    if (model.mode == .proposal_edit) drawDialog(screen, "Candidate title", model.inputSlice());
    if (model.mode == .proposal_add) drawDialog(screen, "New candidate title", model.inputSlice());
    if (model.mode == .proposal_reparent) drawDialog(screen, "Parent candidate ID", model.inputSlice());
    if (model.mode == .confirm_delete) drawDialog(screen, "Taskを削除します", "s: subtree / p: promote children");
    if (model.mode == .confirm_proposal_delete) drawDialog(screen, "候補を削除します", "y: confirm / Esc: cancel");
    if (model.mode == .confirm_proposal_approve) drawDialog(screen, "ProposalをTaskへ追加します", "y: confirm / Esc: cancel");
    if (model.mode == .confirm_proposal_duplicates) drawDialog(screen, "同一タイトルのTaskが存在します", "y: add anyway / Esc: cancel");
    if (model.mode == .confirm_proposal_discard) drawDialog(screen, "Proposalを破棄します", "y: confirm / Esc: cancel");
    if (model.mode == .help) drawDialog(screen, "Help", "Tab: focus  j/k: select  Space: toggle  a/e/d: task  p: proposal  q: quit");
    if (model.mode == .proposal) drawProposal(allocator, screen, state, model);
    if (model.mode == .proposal_running) drawDialog(screen, "Generating proposal…", "fx実行中です。Escで中断します");
    if (model.mode == .repositories) drawRepositories(allocator, screen, config, model);
}

fn drawDialog(screen: vaxis.Window, title: []const u8, body: []const u8) void {
    const width: u16 = @min(60, screen.width -| 4);
    const dialog = screen.child(.{ .x_off = @intCast((screen.width - width) / 2), .y_off = @intCast(screen.height / 2 -| 3), .width = width, .height = 7, .border = .{ .where = .all } });
    dialog.fill(.{ .default = true });
    _ = dialog.printSegment(.{ .text = title, .style = .{ .bold = true } }, .{ .row_offset = 1, .col_offset = 1, .wrap = .none });
    _ = dialog.printSegment(.{ .text = body }, .{ .row_offset = 3, .col_offset = 1, .wrap = .none });
}

fn drawProposal(allocator: std.mem.Allocator, screen: vaxis.Window, state: *const @import("../core/state.zig").StateRoot, model: Model) void {
    const dialog = screen.child(.{ .x_off = 2, .y_off = 1, .width = screen.width -| 4, .height = screen.height -| 3, .border = .{ .where = .all } });
    dialog.fill(.{ .default = true });
    _ = dialog.printSegment(.{ .text = "Proposal", .style = .{ .bold = true } }, .{ .col_offset = 1 });
    const key = selectedIssue(state, model.selected_issue) orelse {
        _ = dialog.printSegment(.{ .text = "Issueを選択してください" }, .{ .row_offset = 2, .col_offset = 1 });
        return;
    };
    const proposal = (for (state.proposals.items) |item| {
        if (item.issue_key.eql(key)) break item;
    } else null) orelse {
        _ = dialog.printSegment(.{ .text = "Draftはありません。gで生成します。" }, .{ .row_offset = 2, .col_offset = 1 });
        return;
    };
    _ = dialog.printSegment(.{ .text = proposal.summary }, .{ .row_offset = 2, .col_offset = 1, .wrap = .word });
    var row: u16 = 5;
    for (proposal.candidates, 0..) |candidate, index| {
        if (row >= dialog.height) break;
        const line = std.fmt.allocPrint(allocator, "{s}  {s}", .{ candidate.candidate_id, candidate.title }) catch continue;
        _ = dialog.printSegment(.{ .text = line, .style = if (index == model.selected_candidate) .{ .reverse = true } else .{} }, .{ .row_offset = row, .col_offset = 1, .wrap = .none });
        row += 1;
    }
}

fn drawRepositories(allocator: std.mem.Allocator, screen: vaxis.Window, config: *const config_mod.Config, model: Model) void {
    const dialog = screen.child(.{ .x_off = 2, .y_off = 1, .width = screen.width -| 4, .height = screen.height -| 3, .border = .{ .where = .all } });
    dialog.fill(.{ .default = true });
    _ = dialog.printSegment(.{ .text = "Repositories", .style = .{ .bold = true } }, .{ .col_offset = 1 });
    var row: u16 = 2;
    for (config.repositories.items, 0..) |repository, index| {
        if (row >= dialog.height) break;
        const line = std.fmt.allocPrint(allocator, "{s}  {s}", .{ repository.repository, repository.workspace_path }) catch continue;
        _ = dialog.printSegment(.{ .text = line, .style = if (index == model.selected_repository) .{ .reverse = true } else .{} }, .{ .row_offset = row, .col_offset = 1, .wrap = .none });
        row += 1;
    }
    if (config.repositories.items.len == 0) _ = dialog.printSegment(.{ .text = "Repositoryは未登録です。aで追加します。" }, .{ .row_offset = 2, .col_offset = 1 });
}

fn handleRepositories(model: *Model, key: vaxis.Key, config: *const config_mod.Config) void {
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
        model.mode = .normal;
    } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (model.selected_repository + 1 < config.repositories.items.len) model.selected_repository += 1;
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        model.selected_repository -|= 1;
    } else if (key.matches('a', .{})) {
        model.beginInput(.repository_add, "");
    } else if (key.matches('e', .{}) and model.selected_repository < config.repositories.items.len) {
        model.beginInput(.repository_workspace, config.repositories.items[model.selected_repository].workspace_path);
    } else if (key.matches('d', .{}) and model.selected_repository < config.repositories.items.len) {
        model.mode = .confirm_repository_delete;
    }
}

fn handleRepositoryInput(model: *Model, key: vaxis.Key, config: *config_mod.Config, service: ConfigService) !void {
    if (key.matches(vaxis.Key.escape, .{})) {
        model.mode = .repositories;
        return;
    }
    if (key.matches(vaxis.Key.backspace, .{})) return model.backspace();
    if (key.matches(vaxis.Key.enter, .{})) {
        const input = std.mem.trim(u8, model.inputSlice(), " \t\r\n");
        if (model.mode == .repository_add) {
            const split = std.mem.indexOfScalar(u8, input, ' ') orelse return error.Usage;
            const repository = input[0..split];
            const workspace = std.mem.trim(u8, input[split + 1 ..], " \t");
            try service.add(config, repository, workspace);
            model.selected_repository = config.repositories.items.len - 1;
        } else if (model.mode == .repository_workspace) {
            if (model.selected_repository >= config.repositories.items.len) return error.RepositoryNotFound;
            const repository = config.repositories.items[model.selected_repository].repository;
            try service.setWorkspace(config, repository, input);
        }
        model.input_len = 0;
        model.mode = .repositories;
        return;
    }
    if (key.text) |text| model.appendInput(text);
}

fn handleRepositoryDelete(model: *Model, key: vaxis.Key, config: *config_mod.Config, service: ConfigService) !void {
    if (key.matches(vaxis.Key.escape, .{})) {
        model.mode = .repositories;
        return;
    }
    if (!key.matches('y', .{})) return;
    if (model.selected_repository >= config.repositories.items.len) return error.RepositoryNotFound;
    const repository = config.repositories.items[model.selected_repository].repository;
    try service.delete(config, repository);
    model.selected_repository -|= 1;
    model.mode = .repositories;
}

fn selectedIssue(state: *const @import("../core/state.zig").StateRoot, index: usize) ?task_mod.IssueKey {
    if (index >= state.issues.items.len) return null;
    return state.issues.items[index].key;
}

fn handleMouse(model: *Model, mouse: vaxis.Mouse, width: u16, height: u16, issue_count: usize, task_count: usize) void {
    if (mouse.button == .wheel_down) {
        if (model.focus == .issues) {
            if (model.selected_issue < issue_count) model.selected_issue += 1;
        } else if (model.focus == .tasks) model.moveDown(task_count);
        return;
    }
    if (mouse.button == .wheel_up) {
        if (model.focus == .issues) model.selected_issue -|= 1 else if (model.focus == .tasks) model.moveUp();
        return;
    }
    if (mouse.button != .left or mouse.type != .press or mouse.row < 3) return;
    const row: usize = @intCast(mouse.row - 3);
    const compact = width < 90;
    if (!compact) {
        const left_width = @max(@as(u16, 20), width / 4);
        const detail_width = @max(@as(u16, 24), width / 4);
        if (mouse.col < left_width) model.focus = .issues else if (mouse.col < width - detail_width) model.focus = .tasks else model.focus = .details;
    }
    const visible: usize = @max(@as(usize, 1), height -| 7);
    if (model.focus == .issues) {
        const offset = if (model.selected_issue >= visible) model.selected_issue - visible + 1 else 0;
        model.selected_issue = @min(offset + row, issue_count);
        model.selected = 0;
    } else if (model.focus == .tasks and task_count != 0) {
        const offset = if (model.selected >= visible) model.selected - visible + 1 else 0;
        model.selected = @min(offset + row, task_count - 1);
    }
}

fn handleIssueNavigation(model: *Model, key: vaxis.Key, issue_count: usize) void {
    const count = issue_count + 1;
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (model.selected_issue + 1 < count) model.selected_issue += 1;
        model.selected = 0;
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        model.selected_issue -|= 1;
        model.selected = 0;
    }
}

fn handleTaskKey(model: *Model, key: vaxis.Key, state: *@import("../core/state.zig").StateRoot, ordered_ids: []const u64, issue: ?task_mod.IssueKey, service: Service) !void {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) return model.moveDown(ordered_ids.len);
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) return model.moveUp();
    if (key.matches('a', .{})) return model.beginInput(.add, "");
    const id = model.selectedTaskId(ordered_ids) orelse return;
    const selected = findTask(state, id) orelse return;
    if (key.matches(' ', .{})) try service.toggle(state, id) else if (key.matches('e', .{})) model.beginInput(.edit, selected.title) else if (key.matches('d', .{})) model.mode = .confirm_delete else if (key.matches('K', .{}) and selected.position > 0) try service.moveTask(state, id, selected.position) else if (key.matches('J', .{})) service.moveTask(state, id, selected.position + 2) catch |err| setError(model, err) else if (key.matches('U', .{})) try service.reparentTask(state, id, null, null) else if (key.matches('L', .{}) and issue != null) try service.reparentTask(state, id, null, issue);
}

fn handleInput(model: *Model, key: vaxis.Key, state: *@import("../core/state.zig").StateRoot, ordered_ids: []const u64, service: Service) !void {
    if (key.matches(vaxis.Key.escape, .{})) {
        model.mode = switch (model.mode) {
            .proposal_add, .proposal_edit, .proposal_reparent => .proposal,
            else => .normal,
        };
        return;
    }
    if (key.matches(vaxis.Key.backspace, .{})) return model.backspace();
    if (key.matches(vaxis.Key.enter, .{})) {
        const title = model.inputSlice();
        const completed_mode = model.mode;
        switch (completed_mode) {
            .add => _ = try service.addTask(state, title, selectedIssue(state, model.selected_issue), null),
            .edit => if (model.selectedTaskId(ordered_ids)) |id| try service.editTask(state, id, title),
            .search => {
                model.filter_len = @min(title.len, model.filter.len);
                @memcpy(model.filter[0..model.filter_len], title[0..model.filter_len]);
                model.selected = 0;
            },
            .proposal_add => {
                const issue = selectedIssue(state, model.selected_issue) orelse return;
                const proposal = state.findProposal(issue) orelse return error.ProposalNotFound;
                var id_buffer: [32]u8 = undefined;
                var serial: usize = proposal.candidates.len + 1;
                var id = try std.fmt.bufPrint(&id_buffer, "manual-{d}", .{serial});
                while (@import("../proposal/model.zig").findCandidate(proposal.candidates, id) != null) {
                    serial += 1;
                    id = try std.fmt.bufPrint(&id_buffer, "manual-{d}", .{serial});
                }
                try proposal_editor.add(service.allocator, proposal, id, title, null);
                try service.persistOrRollback(state);
                model.selected_candidate = proposal.candidates.len - 1;
            },
            .proposal_edit => {
                const issue = selectedIssue(state, model.selected_issue) orelse return;
                const proposal = state.findProposal(issue) orelse return error.ProposalNotFound;
                if (model.selected_candidate >= proposal.candidates.len) return;
                try proposal_editor.editTitle(service.allocator, proposal, proposal.candidates[model.selected_candidate].candidate_id, title);
                try service.persistOrRollback(state);
            },
            .proposal_reparent => {
                const issue = selectedIssue(state, model.selected_issue) orelse return;
                const proposal = state.findProposal(issue) orelse return error.ProposalNotFound;
                if (model.selected_candidate >= proposal.candidates.len) return;
                const parent: ?[]const u8 = if (std.mem.eql(u8, title, "root")) null else title;
                try proposal_editor.reparent(proposal, proposal.candidates[model.selected_candidate].candidate_id, parent);
                try service.persistOrRollback(state);
            },
            else => {},
        }
        model.mode = switch (completed_mode) {
            .proposal_add, .proposal_edit, .proposal_reparent => .proposal,
            else => .normal,
        };
        model.input_len = 0;
        return;
    }
    if (key.text) |text| model.appendInput(text);
}

fn handleProposal(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, config: *config_mod.Config, service: Service, model: *Model, state: *@import("../core/state.zig").StateRoot, key: vaxis.Key, loop: *Loop, operation: *?Operation) !void {
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
        model.mode = .normal;
        return;
    }
    const issue_key = selectedIssue(state, model.selected_issue) orelse return;
    const proposal = state.findProposal(issue_key);
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (proposal) |p| {
            if (model.selected_candidate + 1 < p.candidates.len) model.selected_candidate += 1;
        }
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) model.selected_candidate -|= 1 else if (key.matches('e', .{})) {
        const p = proposal orelse return;
        if (model.selected_candidate < p.candidates.len) model.beginInput(.proposal_edit, p.candidates[model.selected_candidate].title);
    } else if (key.matches('a', .{})) {
        if (proposal == null) return error.ProposalNotFound;
        model.beginInput(.proposal_add, "");
    } else if (key.matches('d', .{})) {
        if (proposal == null) return error.ProposalNotFound;
        model.mode = .confirm_proposal_delete;
    } else if (key.matches('R', .{})) {
        const p = proposal orelse return;
        if (model.selected_candidate < p.candidates.len) model.beginInput(.proposal_reparent, p.candidates[model.selected_candidate].parent_candidate_id orelse "root");
    } else if (key.matches('K', .{})) {
        const p = proposal orelse return;
        if (model.selected_candidate < p.candidates.len and p.candidates[model.selected_candidate].position > 0) {
            try proposal_editor.move(p, p.candidates[model.selected_candidate].candidate_id, p.candidates[model.selected_candidate].position - 1);
            try service.persistOrRollback(state);
            model.selected_candidate -|= 1;
        }
    } else if (key.matches('J', .{})) {
        const p = proposal orelse return;
        if (model.selected_candidate < p.candidates.len) {
            try proposal_editor.move(p, p.candidates[model.selected_candidate].candidate_id, p.candidates[model.selected_candidate].position + 1);
            try service.persistOrRollback(state);
            model.selected_candidate += 1;
        }
    } else if (key.matches('A', .{})) {
        if (proposal == null) return error.ProposalNotFound;
        model.mode = .confirm_proposal_approve;
    } else if (key.matches('D', .{})) {
        if (proposal == null) return error.ProposalNotFound;
        model.mode = .confirm_proposal_discard;
    } else if (key.matches('g', .{})) {
        if (proposal != null) return error.ProposalAlreadyExists;
        const issue = &state.issues.items[model.selected_issue];
        const repository = config.find(issue.key.repository) orelse return error.RepositoryNotFound;
        const box = try allocator.create(OperationBox);
        errdefer allocator.destroy(box);
        box.* = .{ .loop = loop, .allocator = allocator, .io = io, .env = env, .issue = issue.*, .workspace = repository.workspace_path, .excludes = repository.exclude_patterns };
        operation.* = .{ .box = box, .future = try io.concurrent(proposalWorker, .{box}) };
        model.mode = .proposal_running;
    } else if (key.matches('r', .{})) {
        var remote = try gh.list(allocator, io, env, issue_key.repository);
        defer remote.deinit();
        try issue_adapter.merge(allocator, state, issue_key.repository, remote.value, @intCast(std.Io.Clock.real.now(io).toSeconds()));
        try service.persistOrRollback(state);
        model.setMessage("Issueを更新しました");
    }
}

fn proposalWorker(box: *OperationBox) void {
    box.result = generator.buildDraft(box.allocator, box.io, box.env, box.issue, box.workspace, box.excludes);
    box.loop.postEvent(.operation_complete) catch {};
}

fn finishProposalOperation(allocator: std.mem.Allocator, io: std.Io, service: Service, model: *Model, state: *state_mod.StateRoot, operation: *?Operation) void {
    var active = operation.* orelse return;
    _ = active.future.await(io);
    defer allocator.destroy(active.box);
    defer operation.* = null;
    const result = active.box.result orelse {
        setError(model, error.ProcessFailed);
        model.mode = .proposal;
        return;
    };
    const draft = result catch |err| {
        if (active.cancel_requested or err == error.Canceled) model.setMessage("Proposal生成を中断しました") else setError(model, err);
        model.mode = .proposal;
        return;
    };
    defer state_mod.freeProposal(allocator, draft);
    if (active.cancel_requested) {
        model.setMessage("Proposal生成を中断しました");
        model.mode = .proposal;
        return;
    }
    state.putProposal(draft) catch |err| {
        setError(model, err);
        model.mode = .proposal;
        return;
    };
    service.persistOrRollback(state) catch |err| {
        setError(model, err);
        model.mode = .proposal;
        return;
    };
    model.selected_candidate = 0;
    model.setMessage("Proposalを生成しました");
    model.mode = .proposal;
}

fn refreshSelectedIssue(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, service: Service, model: *Model, state: *@import("../core/state.zig").StateRoot) !void {
    const issue = selectedIssue(state, model.selected_issue) orelse return error.IssueNotFound;
    var remote = try gh.list(allocator, io, env, issue.repository);
    defer remote.deinit();
    try issue_adapter.merge(allocator, state, issue.repository, remote.value, std.Io.Clock.real.now(io).toSeconds());
    try service.persistOrRollback(state);
    model.setMessage("Issueを更新しました");
}

fn handleProposalConfirmation(service: Service, model: *Model, state: *@import("../core/state.zig").StateRoot, key: vaxis.Key) !void {
    if (key.matches(vaxis.Key.escape, .{})) {
        model.mode = .proposal;
        return;
    }
    if (!key.matches('y', .{})) return;
    const issue = selectedIssue(state, model.selected_issue) orelse return error.IssueNotFound;
    switch (model.mode) {
        .confirm_proposal_delete => {
            const proposal = state.findProposal(issue) orelse return error.ProposalNotFound;
            if (model.selected_candidate >= proposal.candidates.len) return error.CandidateNotFound;
            const id = proposal.candidates[model.selected_candidate].candidate_id;
            try proposal_editor.delete(service.allocator, proposal, id);
            try service.persistOrRollback(state);
            model.selected_candidate -|= 1;
            model.mode = .proposal;
        },
        .confirm_proposal_approve => {
            const duplicates = try proposal_apply.duplicates(service.allocator, state, issue);
            defer service.allocator.free(duplicates);
            if (duplicates.len != 0) {
                model.mode = .confirm_proposal_duplicates;
                return;
            }
            const count = try service.approveProposal(state, issue);
            var buffer: [128]u8 = undefined;
            model.setMessage(try std.fmt.bufPrint(&buffer, "Proposalを承認し、{d} Taskを追加しました", .{count}));
            model.mode = .normal;
        },
        .confirm_proposal_duplicates => {
            const count = try service.approveProposal(state, issue);
            var buffer: [128]u8 = undefined;
            model.setMessage(try std.fmt.bufPrint(&buffer, "重複を含むProposalを承認し、{d} Taskを追加しました", .{count}));
            model.mode = .normal;
        },
        .confirm_proposal_discard => {
            try service.discardProposal(state, issue);
            model.setMessage("Proposalを破棄しました");
            model.mode = .proposal;
        },
        else => {},
    }
}

fn taskOrder(allocator: std.mem.Allocator, state: *const @import("../core/state.zig").StateRoot, issue: ?task_mod.IssueKey, filter: []const u8) ![]u64 {
    var result: std.ArrayList(u64) = .empty;
    errdefer result.deinit(allocator);
    const ids = try tree.preorder(allocator, state, issue);
    defer allocator.free(ids);
    for (ids) |id| {
        const item = findTask(state, id) orelse continue;
        if (filter.len == 0 or containsIgnoreCase(item.title, filter)) try result.append(allocator, id);
    }
    return result.toOwnedSlice(allocator);
}

fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn setError(model: *Model, err: anyerror) void {
    model.setMessage(switch (err) {
        error.UnexpectedToken, error.InvalidEnvelope, error.InvalidResponse => "JSON応答が不正です。再生成または再取得してください",
        error.AuthenticationRequired => "認証が必要です。`zt doctor`を確認してください",
        error.ExecutableNotFound => "ghまたはfxが見つかりません。`zt doctor`を確認してください",
        error.UnsafePermission => "fxの危険な権限を取り消してください",
        error.WorkspaceUnavailable => "Workspaceを`zt repo set-workspace`で修正してください",
        error.ProposalAlreadyExists => "既存Draftがあります。確認または破棄してから再生成してください",
        error.ProposalNotFound => "このIssueにはProposalがありません",
        error.InvalidPosition => "この位置へは移動できません",
        error.Cycle => "親子関係が循環するため変更できません",
        error.WriteFailed => "保存に失敗しました。元のStateへ戻しました",
        else => @errorName(err),
    });
}

fn findTask(state: *const @import("../core/state.zig").StateRoot, id: u64) ?@import("../core/task.zig").Task {
    for (state.tasks.items) |item| if (item.id == id) return item;
    return null;
}

test {
    std.testing.refAllDecls(@This());
}

test "task search is ASCII case-insensitive and preserves Unicode matching" {
    try std.testing.expect(containsIgnoreCase("Implement API", "api"));
    try std.testing.expect(containsIgnoreCase("日本語タスク", "日本語"));
    try std.testing.expect(!containsIgnoreCase("日本語タスク", "API"));
}

test "task order follows the selected issue and search filter" {
    const a = std.testing.allocator;
    var state = @import("../core/state.zig").StateRoot.init(a);
    defer state.deinit();
    try state.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, "a/b"), .issue_number = 1 }, .title = try a.dupe(u8, "Issue"), .body = try a.dupe(u8, "") });
    const root = try state.addTask("API root", .{ .repository = "a/b", .issue_number = 1 }, null);
    _ = try state.addTask("日本語 child", .{ .repository = "a/b", .issue_number = 1 }, root);
    _ = try state.addTask("unlinked", null, null);
    const filtered = try taskOrder(a, &state, .{ .repository = "a/b", .issue_number = 1 }, "日本語");
    defer a.free(filtered);
    try std.testing.expectEqualSlices(u64, &.{2}, filtered);
}

test "mouse selects panes rows and scrolls" {
    var model: Model = .{};
    handleMouse(&model, .{ .col = 1, .row = 4, .button = .left, .type = .press, .mods = .{} }, 120, 30, 4, 10);
    try std.testing.expectEqual(Model.Focus.issues, model.focus);
    try std.testing.expectEqual(@as(usize, 1), model.selected_issue);
    model.focus = .tasks;
    handleMouse(&model, .{ .col = 40, .row = 4, .button = .wheel_down, .type = .press, .mods = .{} }, 120, 30, 4, 10);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
}
