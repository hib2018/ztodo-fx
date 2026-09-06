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
const TreeRow = union(enum) {
    issue: usize,
    unlinked,
    task: struct { id: u64, depth: usize },
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
    const service = Service{ .allocator = allocator, .io = init.io, .state_path = paths.state };
    var config = try config_mod.load(allocator, init.io, paths.config);
    defer config.deinit();
    const config_service = ConfigService{ .allocator = allocator, .io = init.io, .config_path = paths.config };
    var model: Model = .{};
    defer model.deinit(allocator);

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
        const rows = try visibleTreeRows(frame_allocator, &state, &model, model.filterSlice());
        if (model.selected >= rows.len and rows.len != 0) model.selected = rows.len - 1;
        syncSelection(&model, &state, rows);
        const selected_task = selectedTreeTask(rows, model.selected);
        draw(frame_allocator, &vx, &state, &config, model, rows);
        try vx.render(tty.writer());
        const event = try loop.nextEvent();
        switch (event) {
            .operation_complete => finishProposalOperation(allocator, init.io, service, &model, &state, &operation),
            .winsize => |size| try vx.resize(allocator, tty.writer(), size),
            .mouse => |mouse| handleMouse(&model, mouse, vx.window().width, vx.window().height, rows.len),
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
                if (model.mode == .add or model.mode == .edit or model.mode == .task_reparent or model.mode == .search or model.mode == .proposal_add or model.mode == .proposal_edit or model.mode == .proposal_reparent) {
                    handleInput(&model, key, &state, selected_task, service) catch |err| setError(&model, err);
                    continue;
                }
                if (model.mode == .confirm_delete) {
                    if (key.matches(vaxis.Key.escape, .{})) model.mode = .normal else if (selected_task) |id| {
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
                if (model.mode == .confirm_clear) {
                    if (key.matches(vaxis.Key.escape, .{})) model.mode = .normal else if (key.matches('y', .{})) {
                        const count = service.clearTasks(&state) catch |err| {
                            setError(&model, err);
                            continue;
                        };
                        var message: [128]u8 = undefined;
                        model.setMessage(std.fmt.bufPrint(&message, "{d}件のTaskを削除しました", .{count}) catch "Taskを削除しました");
                        model.mode = .normal;
                        model.selected = 0;
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
                if (model.mode == .menu) {
                    handleMenu(allocator, init.io, init.environ_map, service, &model, &state, key) catch |err| setError(&model, err);
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
                if (key.matches(vaxis.Key.tab, .{ .shift = true })) model.previousFocus() else if (key.matches(vaxis.Key.tab, .{})) model.nextFocus() else if (key.matches('/', .{})) model.beginInput(.search, model.filterSlice()) else if (key.matches('m', .{})) model.mode = .menu else if (key.matches('?', .{})) model.mode = .help else if (model.focus == .tree) handleTreeKey(&model, key, &state, rows, service) catch |err| setError(&model, err) else handleDetailKey(&model, key);
            },
        }
    }
}

fn draw(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, state: *const @import("../core/state.zig").StateRoot, config: *const config_mod.Config, model: Model, rows: []const TreeRow) void {
    const screen = vx.window();
    screen.clear();
    screen.hideCursor();
    if (screen.width < 40 or screen.height < 10) {
        _ = screen.printSegment(.{ .text = "zt: 端末サイズが小さすぎます（40x10以上が必要です）" }, .{});
        return;
    }
    const body_height = screen.height -| 2;
    const left_width: u16 = screen.width / 2;
    const detail_width: u16 = screen.width - left_width;
    const left = screen.child(.{ .width = left_width, .height = body_height, .border = .{ .where = .all } });
    const detail = screen.child(.{ .x_off = @intCast(left_width), .width = detail_width, .height = body_height, .border = .{ .where = .all } });
    const footer = screen.child(.{ .y_off = @intCast(body_height), .height = 2 });

    _ = screen.printSegment(.{ .text = " Issues / Tasks " }, .{ .col_offset = 2, .wrap = .none });
    _ = screen.printSegment(.{ .text = " Details " }, .{ .col_offset = left_width + 2, .wrap = .none });
    var row: u16 = 1;
    const visible: usize = @max(@as(usize, 1), left.height -| 3);
    const offset = if (model.selected >= visible) model.selected - visible + 1 else 0;
    for (rows[offset..], offset..) |tree_row, index| {
        if (row >= left.height) break;
        const line = treeRowText(allocator, state, &model, tree_row) catch continue;
        const style = treeRowStyle(state, tree_row, model.focus == .tree and index == model.selected);
        const printed = left.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .wrap = .grapheme });
        row = printed.row +| 1;
    }

    drawDetails(allocator, detail, state, rows, model.selected, model.detail_scroll);
    const footer_text = if (model.message_len != 0) model.messageSlice() else switch (model.mode) {
        .normal => "NORMAL  Enter:展開 Space:完了 a/e/R/d/C:Task m:Menu Tab:ペイン q:終了",
        .add => "ADD  タイトルを入力 Enter:保存 Esc:取消",
        .edit => "EDIT  タイトルを入力 Enter:保存 Esc:取消",
        .task_reparent => "REPARENT  root / unlinked / Task ID / owner/repo#番号 Enter:保存 Esc:取消",
        .search => "SEARCH  絞込み文字列を入力 Enter:適用 Esc:取消",
        .menu => "MENU  Tab/Shift-Tab:タブ j/k:選択 Enter:実行 Esc:戻る",
        .repositories => "REPOSITORIES  j/k:選択 a:追加 e:Workspace変更 d:削除 Esc:戻る",
        .repository_add => "REPOSITORY ADD  owner/repo /absolute/workspace Enter:保存 Esc:取消",
        .repository_workspace => "WORKSPACE  絶対pathを入力 Enter:保存 Esc:取消",
        .confirm_repository_delete => "DELETE REPOSITORY  y:削除 Esc:取消",
        .confirm_delete => "DELETE  s:部分木削除 p:子を昇格 Esc:取消",
        .confirm_clear => "CLEAR ALL TASKS  y:全削除 Esc:取消",
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
    if (model.mode == .task_reparent) drawDialog(screen, "Move Task", model.inputSlice());
    if (model.mode == .search) drawDialog(screen, "Search tasks", model.inputSlice());
    if (model.mode == .repository_add) drawDialog(screen, "Add repository", model.inputSlice());
    if (model.mode == .repository_workspace) drawDialog(screen, "Workspace path", model.inputSlice());
    if (model.mode == .confirm_repository_delete and model.selected_repository < config.repositories.items.len) {
        const repository = config.repositories.items[model.selected_repository].repository;
        var issue_count: usize = 0;
        var task_count: usize = 0;
        for (state.issues.items) |issue| if (std.mem.eql(u8, issue.key.repository, repository)) {
            issue_count += 1;
        };
        for (state.tasks.items) |task| if (task.issue_key) |issue| if (std.mem.eql(u8, issue.repository, repository)) {
            task_count += 1;
        };
        const body = std.fmt.allocPrint(allocator, "設定のみ削除します。Issue {d}件・Task {d}件は保持されます\ny: confirm / Esc: cancel", .{ issue_count, task_count }) catch "y: confirm / Esc: cancel";
        drawDialog(screen, "Repository設定を削除", body);
    }
    if (model.mode == .proposal_edit) drawDialog(screen, "Candidate title", model.inputSlice());
    if (model.mode == .proposal_add) drawDialog(screen, "New candidate title", model.inputSlice());
    if (model.mode == .proposal_reparent) drawDialog(screen, "Parent candidate ID", model.inputSlice());
    if (model.mode == .confirm_delete) if (selectedTreeTask(rows, model.selected)) |id| {
        const children = directChildCount(state, id);
        const descendants = descendantCount(state, id);
        const body = std.fmt.allocPrint(allocator, "Task #{d}\n子を昇格: {d}件 / 部分木削除: {d}件\np: promote / s: subtree / Esc: cancel", .{ id, children, descendants + 1 }) catch "p: promote / s: subtree / Esc: cancel";
        drawDialog(screen, "Task削除の影響", body);
    };
    if (model.mode == .confirm_clear) {
        const body = std.fmt.allocPrint(allocator, "全Task {d}件を削除します\ny: confirm / Esc: cancel", .{state.tasks.items.len}) catch "y: confirm / Esc: cancel";
        drawDialog(screen, "全Task削除", body);
    }
    if (model.mode == .confirm_proposal_delete) drawDialog(screen, "候補を削除します", "y: confirm / Esc: cancel");
    if (model.mode == .confirm_proposal_approve) drawDialog(screen, "ProposalをTaskへ追加します", "y: confirm / Esc: cancel");
    if (model.mode == .confirm_proposal_duplicates) drawDialog(screen, "同一タイトルのTaskが存在します", "y: add anyway / Esc: cancel");
    if (model.mode == .confirm_proposal_discard) drawDialog(screen, "Proposalを破棄します", "y: confirm / Esc: cancel");
    if (model.mode == .help) drawDialog(screen, "Help", "Tab: focus  j/k: select  Space: toggle  a/e/R/d: task  m: menu  q: quit");
    if (model.mode == .menu) drawMenu(screen, model);
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

fn drawMenu(screen: vaxis.Window, model: Model) void {
    const width: u16 = @min(64, screen.width -| 4);
    const menu = screen.child(.{ .x_off = @intCast((screen.width - width) / 2), .y_off = 2, .width = width, .height = @min(14, screen.height -| 4), .border = .{ .where = .all } });
    menu.fill(.{ .default = true });
    _ = menu.printSegment(.{ .text = " Proposal   Repositories   Issues ", .style = .{ .bold = true } }, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    const items: []const []const u8 = switch (model.menu_tab) {
        .proposal => &.{"Proposalを開く"},
        .repositories => &.{"Repository管理を開く"},
        .issues => &.{ "Issue詳細", "Issueを更新", "GitHubで開く", if (model.show_closed) "Closed Issueを隠す" else "Closed Issueを表示" },
    };
    for (items, 0..) |item, index| _ = menu.printSegment(.{ .text = item, .style = if (index == model.menu_selected) .{ .reverse = true } else .{} }, .{ .row_offset = @intCast(index + 2), .col_offset = 2, .wrap = .grapheme });
}

fn menuItemCount(tab: Model.MenuTab) usize {
    return switch (tab) {
        .proposal, .repositories => 1,
        .issues => 4,
    };
}

fn handleMenu(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, service: Service, model: *Model, state: *@import("../core/state.zig").StateRoot, key: vaxis.Key) !void {
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
        model.mode = .normal;
        return;
    }
    if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
        model.previousMenuTab();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        model.nextMenuTab();
        return;
    }
    const count = menuItemCount(model.menu_tab);
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (model.menu_selected + 1 < count) model.menu_selected += 1;
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        model.menu_selected -|= 1;
        return;
    }
    if (!key.matches(vaxis.Key.enter, .{})) return;
    switch (model.menu_tab) {
        .proposal => model.mode = .proposal,
        .repositories => model.mode = .repositories,
        .issues => switch (model.menu_selected) {
            0 => {
                model.focus = .details;
                model.mode = .normal;
            },
            1 => {
                try refreshSelectedIssue(allocator, io, env, service, model, state);
                model.mode = .normal;
            },
            2 => {
                const issue = selectedIssue(state, model.selected_issue) orelse return error.IssueNotFound;
                var number: [32]u8 = undefined;
                try gh.open(io, allocator, env, issue.repository, try std.fmt.bufPrint(&number, "{d}", .{issue.issue_number}));
                model.mode = .normal;
            },
            3 => {
                model.show_closed = !model.show_closed;
                model.selected = 0;
                model.mode = .normal;
            },
            else => {},
        },
    }
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

fn handleMouse(model: *Model, mouse: vaxis.Mouse, width: u16, height: u16, row_count: usize) void {
    if (mouse.button == .wheel_down) {
        if (model.focus == .tree) model.moveDown(row_count);
        return;
    }
    if (mouse.button == .wheel_up) {
        if (model.focus == .tree) model.moveUp();
        return;
    }
    if (mouse.button != .left or mouse.type != .press or mouse.row < 3) return;
    const row: usize = @intCast(mouse.row - 3);
    model.focus = if (mouse.col < width / 2) .tree else .details;
    const visible: usize = @max(@as(usize, 1), height -| 7);
    if (model.focus == .tree and row_count != 0) {
        const offset = if (model.selected >= visible) model.selected - visible + 1 else 0;
        model.selected = @min(offset + row, row_count - 1);
    }
}

fn handleTreeKey(model: *Model, key: vaxis.Key, state: *@import("../core/state.zig").StateRoot, rows: []const TreeRow, service: Service) !void {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        model.moveDown(rows.len);
        model.detail_scroll = 0;
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        model.moveUp();
        model.detail_scroll = 0;
        return;
    }
    if (model.selected >= rows.len) return;
    const selected_row = rows[model.selected];
    if (key.matches(vaxis.Key.enter, .{})) return switch (selected_row) {
        .issue => |index| try model.toggleIssue(service.allocator, issueToken(state.issues.items[index].key)),
        .unlinked => model.expanded_unlinked = !model.expanded_unlinked,
        .task => |task_row| try model.toggleTask(service.allocator, task_row.id),
    };
    if (key.matches('a', .{})) return model.beginInput(.add, "");
    if (key.matches('C', .{})) {
        model.mode = .confirm_clear;
        return;
    }
    const id = selectedTreeTask(rows, model.selected) orelse return;
    const selected = findTask(state, id) orelse return;
    const issue = selected.issue_key;
    if (key.matches(' ', .{})) try service.toggle(state, id) else if (key.matches('e', .{})) model.beginInput(.edit, selected.title) else if (key.matches('R', .{})) model.beginInput(.task_reparent, "") else if (key.matches('d', .{})) model.mode = .confirm_delete else if (key.matches('K', .{}) and selected.position > 0) try service.moveTask(state, id, selected.position) else if (key.matches('J', .{})) service.moveTask(state, id, selected.position + 2) catch |err| setError(model, err) else if (key.matches('U', .{})) try service.reparentTask(state, id, null, null) else if (key.matches('L', .{}) and issue != null) try service.reparentTask(state, id, null, issue);
}

fn handleDetailKey(model: *Model, key: vaxis.Key) void {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) model.detail_scroll += 1 else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) model.detail_scroll -|= 1 else if (key.matches('g', .{})) model.detail_scroll = 0 else if (key.matches('G', .{})) model.detail_scroll = std.math.maxInt(usize);
}

fn applyTaskDestination(service: Service, state: *@import("../core/state.zig").StateRoot, id: u64, input: []const u8) !void {
    const destination = std.mem.trim(u8, input, " \t\r\n");
    const selected = findTask(state, id) orelse return error.TaskNotFound;
    if (std.mem.eql(u8, destination, "root")) return service.reparentTask(state, id, null, selected.issue_key);
    if (std.mem.eql(u8, destination, "unlinked")) return service.reparentTask(state, id, null, null);
    if (std.mem.indexOfScalar(u8, destination, '#')) |hash| {
        const number = try std.fmt.parseInt(u64, destination[hash + 1 ..], 10);
        const issue = task_mod.IssueKey{ .repository = destination[0..hash], .issue_number = number };
        try task_mod.validateIssueKey(issue);
        return service.reparentTask(state, id, null, issue);
    }
    const parent = try std.fmt.parseInt(u64, destination, 10);
    return service.reparentTask(state, id, parent, null);
}

fn directChildCount(state: *const @import("../core/state.zig").StateRoot, id: u64) usize {
    var count: usize = 0;
    for (state.tasks.items) |item| if (item.parent_id == id) {
        count += 1;
    };
    return count;
}

fn descendantCount(state: *const @import("../core/state.zig").StateRoot, id: u64) usize {
    var count: usize = 0;
    for (state.tasks.items) |item| if (item.parent_id == id) {
        count += 1 + descendantCount(state, item.id);
    };
    return count;
}

fn handleInput(model: *Model, key: vaxis.Key, state: *@import("../core/state.zig").StateRoot, selected_task: ?u64, service: Service) !void {
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
            .add => {
                if (selected_task) |parent| {
                    const task = findTask(state, parent) orelse return error.TaskNotFound;
                    _ = try service.addTask(state, title, task.issue_key, parent);
                } else {
                    _ = try service.addTask(state, title, selectedIssue(state, model.selected_issue), null);
                }
            },
            .edit => if (selected_task) |id| try service.editTask(state, id, title),
            .task_reparent => if (selected_task) |id| try applyTaskDestination(service, state, id, title),
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

fn visibleTreeRows(allocator: std.mem.Allocator, state: *const @import("../core/state.zig").StateRoot, model: *const Model, filter: []const u8) ![]TreeRow {
    var rows: std.ArrayList(TreeRow) = .empty;
    errdefer rows.deinit(allocator);
    for (state.issues.items, 0..) |issue, index| {
        if (issue.status == .closed and !model.show_closed) continue;
        try rows.append(allocator, .{ .issue = index });
        if (model.issueExpanded(issueToken(issue.key)) or filter.len != 0) try appendVisibleTasks(allocator, &rows, state, model, issue.key, null, 1, filter);
    }
    try rows.append(allocator, .unlinked);
    if (model.expanded_unlinked or filter.len != 0) try appendVisibleTasks(allocator, &rows, state, model, null, null, 1, filter);
    return rows.toOwnedSlice(allocator);
}

fn appendVisibleTasks(allocator: std.mem.Allocator, rows: *std.ArrayList(TreeRow), state: *const @import("../core/state.zig").StateRoot, model: *const Model, issue: ?task_mod.IssueKey, parent: ?u64, depth: usize, filter: []const u8) !void {
    const ids = try tree.preorder(allocator, state, issue);
    defer allocator.free(ids);
    for (ids) |id| {
        const item = findTask(state, id) orelse continue;
        if (item.parent_id != parent) continue;
        const matches = filter.len == 0 or subtreeMatches(state, id, filter);
        if (matches) try rows.append(allocator, .{ .task = .{ .id = id, .depth = depth } });
        if (matches and (filter.len != 0 or model.taskExpanded(id))) try appendVisibleTasks(allocator, rows, state, model, issue, id, depth + 1, filter);
    }
}

fn subtreeMatches(state: *const @import("../core/state.zig").StateRoot, id: u64, filter: []const u8) bool {
    const item = findTask(state, id) orelse return false;
    if (containsIgnoreCase(item.title, filter)) return true;
    for (state.tasks.items) |child| if (child.parent_id == id and subtreeMatches(state, child.id, filter)) return true;
    return false;
}

fn selectedTreeTask(rows: []const TreeRow, index: usize) ?u64 {
    if (index >= rows.len) return null;
    return switch (rows[index]) {
        .task => |item| item.id,
        else => null,
    };
}

fn syncSelection(model: *Model, state: *const @import("../core/state.zig").StateRoot, rows: []const TreeRow) void {
    if (model.selected >= rows.len) return;
    switch (rows[model.selected]) {
        .issue => |index| model.selected_issue = index,
        .unlinked => model.selected_issue = state.issues.items.len,
        .task => |row| if (findTask(state, row.id)) |item| {
            if (item.issue_key) |key| {
                for (state.issues.items, 0..) |issue, index| if (issue.key.eql(key)) {
                    model.selected_issue = index;
                    break;
                };
            } else model.selected_issue = state.issues.items.len;
        },
    }
}

fn hasChildren(state: *const @import("../core/state.zig").StateRoot, id: u64) bool {
    for (state.tasks.items) |item| if (item.parent_id == id) return true;
    return false;
}

fn treeRowText(allocator: std.mem.Allocator, state: *const @import("../core/state.zig").StateRoot, model: *const Model, row: TreeRow) ![]const u8 {
    return switch (row) {
        .issue => |index| blk: {
            const issue = state.issues.items[index];
            break :blk try std.fmt.allocPrint(allocator, "{s} {s}#{d} [{s}] {s}", .{ if (model.issueExpanded(issueToken(issue.key))) "▾" else "▸", issue.key.repository, issue.key.issue_number, @tagName(issue.status), issue.title });
        },
        .unlinked => try std.fmt.allocPrint(allocator, "{s} Unlinked", .{if (model.expanded_unlinked) "▾" else "▸"}),
        .task => |task_row| blk: {
            const item = findTask(state, task_row.id) orelse break :blk "";
            const indent = try treePrefix(allocator, state, item, task_row.depth);
            const marker = if (hasChildren(state, item.id)) (if (model.taskExpanded(item.id)) "▾" else "▸") else " ";
            break :blk try std.fmt.allocPrint(allocator, "{s}{s} {s} {d}: {s}", .{ indent, marker, if (item.status == .done) "[x]" else "[ ]", item.id, item.title });
        },
    };
}

fn issueToken(key: task_mod.IssueKey) u64 {
    return std.hash.Wyhash.hash(key.issue_number, key.repository);
}

fn treePrefix(allocator: std.mem.Allocator, state: *const @import("../core/state.zig").StateRoot, item: task_mod.Task, depth: usize) ![]const u8 {
    if (depth == 0) return "";
    const chain = try allocator.alloc(u64, depth);
    defer allocator.free(chain);
    var current = item;
    var index = depth;
    while (index > 0) {
        index -= 1;
        chain[index] = current.id;
        if (index != 0) current = findTask(state, current.parent_id orelse break) orelse break;
    }

    var prefix: std.ArrayList(u8) = .empty;
    for (chain, 0..) |id, level| {
        const node = findTask(state, id) orelse continue;
        const last = isLastSibling(state, node);
        if (level + 1 == chain.len) {
            try prefix.appendSlice(allocator, if (last) "└─" else "├─");
        } else {
            try prefix.appendSlice(allocator, if (last) "  " else "│ ");
        }
    }
    return prefix.toOwnedSlice(allocator);
}

fn isLastSibling(state: *const @import("../core/state.zig").StateRoot, item: task_mod.Task) bool {
    for (state.tasks.items) |other| {
        if (other.position > item.position and other.parent_id == item.parent_id and state_mod.optionalKeyEql(other.issue_key, item.issue_key)) return false;
    }
    return true;
}

fn treeRowStyle(state: *const @import("../core/state.zig").StateRoot, row: TreeRow, selected: bool) vaxis.Style {
    const color: vaxis.Color = switch (row) {
        .issue => |index| .{ .index = switch (state.issues.items[index].status) {
            .open => 2,
            .closed => 8,
            .deleted => 1,
            .unavailable => 3,
        } },
        .task => |task_row| if ((findTask(state, task_row.id) orelse return .{ .reverse = selected }).status == .done) .{ .index = 8 } else .default,
        .unlinked => .default,
    };
    return .{ .fg = color, .reverse = selected };
}

fn drawDetails(allocator: std.mem.Allocator, detail: vaxis.Window, state: *const @import("../core/state.zig").StateRoot, rows: []const TreeRow, selected_index: usize, scroll: usize) void {
    if (selected_index >= rows.len) return;
    const text = switch (rows[selected_index]) {
        .issue => |index| issueDetails(allocator, state, index) catch return,
        .unlinked => unlinkedDetails(allocator, state) catch return,
        .task => |row| taskDetails(allocator, state, row.id) catch return,
    };
    var visible = text;
    var line_count: usize = 0;
    for (text) |byte| if (byte == '\n') {
        line_count += 1;
    };
    const effective_scroll = @min(scroll, line_count);
    var skipped: usize = 0;
    while (skipped < effective_scroll) : (skipped += 1) {
        const newline = std.mem.indexOfScalar(u8, visible, '\n') orelse {
            visible = "";
            break;
        };
        visible = visible[newline + 1 ..];
    }
    _ = detail.printSegment(.{ .text = visible }, .{ .row_offset = 1, .col_offset = 1, .wrap = .grapheme });
}

fn issueDetails(allocator: std.mem.Allocator, state: *const @import("../core/state.zig").StateRoot, index: usize) ![]const u8 {
    const issue = state.issues.items[index];
    var total: usize = 0;
    var done: usize = 0;
    for (state.tasks.items) |item| if (state_mod.optionalKeyEql(item.issue_key, issue.key)) {
        total += 1;
        if (item.status == .done) done += 1;
    };
    const fetched = if (issue.last_fetched_at) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else "未取得";
    const last_error = if (issue.last_error) |value| @tagName(value) else "なし";
    return std.fmt.allocPrint(allocator, "Issue\n\nRepository: {s}\nNumber:     #{d}\nStatus:     {s}\nUpdated:    {s}\nTasks:      {d} total / {d} completed\nLast error: {s}\n\nTitle\n{s}\n\nDescription\n{s}", .{ issue.key.repository, issue.key.issue_number, @tagName(issue.status), fetched, total, done, last_error, issue.title, issue.body });
}

fn unlinkedDetails(allocator: std.mem.Allocator, state: *const @import("../core/state.zig").StateRoot) ![]const u8 {
    var total: usize = 0;
    var done: usize = 0;
    for (state.tasks.items) |item| if (item.issue_key == null) {
        total += 1;
        if (item.status == .done) done += 1;
    };
    return std.fmt.allocPrint(allocator, "Unlinked Tasks\n\nIssueに紐付いていないTask\n\nTasks: {d} total / {d} completed", .{ total, done });
}

fn taskDetails(allocator: std.mem.Allocator, state: *const @import("../core/state.zig").StateRoot, id: u64) ![]const u8 {
    const item = findTask(state, id) orelse return error.TaskNotFound;
    const issue = if (item.issue_key) |key| try std.fmt.allocPrint(allocator, "{s}#{d}", .{ key.repository, key.issue_number }) else "Unlinked";
    const parent = if (item.parent_id) |parent_id| if (findTask(state, parent_id)) |parent_task| try std.fmt.allocPrint(allocator, "#{d} {s}", .{ parent_id, parent_task.title }) else "不明" else "Root";
    var direct: usize = 0;
    var done: usize = 0;
    for (state.tasks.items) |child| if (child.parent_id == id) {
        direct += 1;
        if (child.status == .done) done += 1;
    };
    return std.fmt.allocPrint(allocator, "Task #{d}\n\nStatus:   {s}\nIssue:    {s}\nParent:   {s}\nOrder:    {d}\nDepth:    {d}\nChildren: {d} / {d} completed\n\nTitle\n{s}", .{ item.id, @tagName(item.status), issue, parent, item.position + 1, tree.depth(state, id) catch 0, direct, done, item.title });
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

test "tree starts folded and expands issue and child task one level at a time" {
    const a = std.testing.allocator;
    var state = @import("../core/state.zig").StateRoot.init(a);
    defer state.deinit();
    try state.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, "a/b"), .issue_number = 1 }, .title = try a.dupe(u8, "Issue"), .body = try a.dupe(u8, "") });
    const root = try state.addTask("root", .{ .repository = "a/b", .issue_number = 1 }, null);
    const child = try state.addTask("child", .{ .repository = "a/b", .issue_number = 1 }, root);
    var model: Model = .{};
    defer model.deinit(a);

    const folded = try visibleTreeRows(a, &state, &model, "");
    defer a.free(folded);
    try std.testing.expectEqual(@as(usize, 2), folded.len);

    try model.toggleIssue(a, issueToken(state.issues.items[0].key));
    const issue_open = try visibleTreeRows(a, &state, &model, "");
    defer a.free(issue_open);
    try std.testing.expectEqual(@as(usize, 3), issue_open.len);

    try model.toggleTask(a, root);
    const task_open = try visibleTreeRows(a, &state, &model, "");
    defer a.free(task_open);
    try std.testing.expectEqual(@as(usize, 4), task_open.len);

    const sibling = try state.addTask("sibling", .{ .repository = "a/b", .issue_number = 1 }, null);
    const root_prefix = try treePrefix(a, &state, findTask(&state, root).?, 1);
    defer a.free(root_prefix);
    try std.testing.expectEqualStrings("├─", root_prefix);
    const child_prefix = try treePrefix(a, &state, findTask(&state, child).?, 2);
    defer a.free(child_prefix);
    try std.testing.expectEqualStrings("│ └─", child_prefix);
    const sibling_prefix = try treePrefix(a, &state, findTask(&state, sibling).?, 1);
    defer a.free(sibling_prefix);
    try std.testing.expectEqualStrings("└─", sibling_prefix);
}

test "mouse selects panes rows and scrolls" {
    var model: Model = .{};
    handleMouse(&model, .{ .col = 1, .row = 4, .button = .left, .type = .press, .mods = .{} }, 120, 30, 10);
    try std.testing.expectEqual(Model.Focus.tree, model.focus);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
    handleMouse(&model, .{ .col = 40, .row = 4, .button = .wheel_down, .type = .press, .mods = .{} }, 120, 30, 10);
    try std.testing.expectEqual(@as(usize, 2), model.selected);
}

test "search reveals matching descendants with their ancestors" {
    const a = std.testing.allocator;
    var state = @import("../core/state.zig").StateRoot.init(a);
    defer state.deinit();
    try state.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, "a/b"), .issue_number = 1 }, .title = try a.dupe(u8, "Issue"), .body = try a.dupe(u8, "") });
    const root = try state.addTask("parent", .{ .repository = "a/b", .issue_number = 1 }, null);
    _ = try state.addTask("needle", .{ .repository = "a/b", .issue_number = 1 }, root);
    var model: Model = .{};
    const rows = try visibleTreeRows(a, &state, &model, "needle");
    defer a.free(rows);
    try std.testing.expectEqual(@as(usize, 4), rows.len);
}

test "closed issues are hidden by default and can be shown" {
    const a = std.testing.allocator;
    var state = @import("../core/state.zig").StateRoot.init(a);
    defer state.deinit();
    try state.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, "a/b"), .issue_number = 1 }, .title = try a.dupe(u8, "open"), .body = try a.dupe(u8, "") });
    try state.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, "a/b"), .issue_number = 2 }, .title = try a.dupe(u8, "closed"), .body = try a.dupe(u8, ""), .status = .closed });
    var model: Model = .{};
    defer model.deinit(a);
    const hidden = try visibleTreeRows(a, &state, &model, "");
    defer a.free(hidden);
    try std.testing.expectEqual(@as(usize, 2), hidden.len);
    model.show_closed = true;
    const shown = try visibleTreeRows(a, &state, &model, "");
    defer a.free(shown);
    try std.testing.expectEqual(@as(usize, 3), shown.len);
}

test "details scroll independently" {
    var model: Model = .{};
    model.focus = .details;
    handleDetailKey(&model, .{ .codepoint = 'j' });
    try std.testing.expectEqual(@as(usize, 1), model.detail_scroll);
    handleDetailKey(&model, .{ .codepoint = 'g' });
    try std.testing.expectEqual(@as(usize, 0), model.detail_scroll);
}

test "task destination supports parent issue root and unlinked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const path = try std.fs.path.join(a, &.{ base, "state.json" });
    defer a.free(path);
    var state = @import("../core/state.zig").StateRoot.init(a);
    defer state.deinit();
    try state.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, "a/b"), .issue_number = 1 }, .title = try a.dupe(u8, "one"), .body = try a.dupe(u8, "") });
    try state.issues.append(a, .{ .key = .{ .repository = try a.dupe(u8, "a/b"), .issue_number = 2 }, .title = try a.dupe(u8, "two"), .body = try a.dupe(u8, "") });
    const parent = try state.addTask("parent", .{ .repository = "a/b", .issue_number = 1 }, null);
    const child = try state.addTask("child", .{ .repository = "a/b", .issue_number = 1 }, null);
    const service = Service{ .allocator = a, .io = std.testing.io, .state_path = path };
    var parent_text: [32]u8 = undefined;
    try applyTaskDestination(service, &state, child, try std.fmt.bufPrint(&parent_text, "{d}", .{parent}));
    try std.testing.expectEqual(parent, findTask(&state, child).?.parent_id.?);
    try applyTaskDestination(service, &state, child, "a/b#2");
    try std.testing.expect(findTask(&state, child).?.parent_id == null);
    try std.testing.expect(findTask(&state, child).?.issue_key.?.eql(.{ .repository = "a/b", .issue_number = 2 }));
    try applyTaskDestination(service, &state, child, "unlinked");
    try std.testing.expect(findTask(&state, child).?.issue_key == null);
}

test "delete impact counts direct children and complete subtree" {
    const a = std.testing.allocator;
    var state = @import("../core/state.zig").StateRoot.init(a);
    defer state.deinit();
    const root = try state.addTask("root", null, null);
    const child = try state.addTask("child", null, root);
    _ = try state.addTask("grandchild", null, child);
    _ = try state.addTask("sibling", null, root);
    try std.testing.expectEqual(@as(usize, 2), directChildCount(&state, root));
    try std.testing.expectEqual(@as(usize, 3), descendantCount(&state, root));
}
