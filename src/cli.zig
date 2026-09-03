const std = @import("std");
const build_options = @import("build_options");
const paths_mod = @import("core/paths.zig");
const store = @import("core/store.zig");
const state_mod = @import("core/state.zig");
const task_mod = @import("core/task.zig");
const renderer = @import("cli/tree_renderer.zig");
const config_mod = @import("integrations/github/config.zig");
const gh = @import("integrations/github/client.zig");
const issue_adapter = @import("integrations/github/issue.zig");
const proposal_apply = @import("proposal/apply.zig");
const proposal_editor = @import("proposal/editor.zig");
const generator = @import("proposal/generator.zig");
const process = @import("platform/process.zig");

pub const version = build_options.version;
pub const exit_success: u8 = 0;
pub const exit_runtime: u8 = 1;
pub const exit_usage: u8 = 2;
pub const Command = union(enum) { help, version, doctor, task, repo, issue, proposal };
pub fn parse(args: []const []const u8) !Command {
    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) return .help;
    if (std.mem.eql(u8, args[1], "version") or std.mem.eql(u8, args[1], "--version")) return .version;
    if (std.mem.eql(u8, args[1], "doctor")) return .doctor;
    if (std.mem.eql(u8, args[1], "task")) return .task;
    if (std.mem.eql(u8, args[1], "repo")) return .repo;
    if (std.mem.eql(u8, args[1], "issue")) return .issue;
    if (std.mem.eql(u8, args[1], "proposal")) return .proposal;
    return error.UnknownCommand;
}
pub fn confirmed(input: []const u8, yes_flag: bool) bool {
    return yes_flag or std.mem.eql(u8, std.mem.trim(u8, input, " \t\r\n"), "y");
}

pub fn run(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const []const u8) u8 {
    var buffer: [8192]u8 = undefined;
    var out_file = std.Io.File.stdout().writer(io, &buffer);
    const out = &out_file.interface;
    const command = parse(args) catch {
        writeErr(io, "不明なコマンドです。`ztodo-fx help`を実行してください");
        return exit_usage;
    };
    const result: anyerror!void = switch (command) {
        .help => out.writeAll(usage),
        .version => out.print("ztodo-fx {s}\n", .{version}),
        .doctor => doctor(a, io, env, out),
        .task => handleTask(a, io, env, args, out),
        .repo => handleRepo(a, io, env, args, out),
        .issue => handleIssue(a, io, env, args, out),
        .proposal => handleProposal(a, io, env, args, out),
    };
    result catch |e| {
        out.flush() catch {};
        writeError(io, e);
        return if (e == error.Usage) exit_usage else exit_runtime;
    };
    out.flush() catch return exit_runtime;
    return exit_success;
}

fn appPaths(a: std.mem.Allocator, env: *const std.process.Environ.Map, io: std.Io) !paths_mod.Paths {
    const p = try paths_mod.resolve(a, env.*);
    try paths_mod.ensureParents(io, p);
    return p;
}
fn handleTask(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len < 3) return error.Usage;
    const p = try appPaths(a, env, io);
    defer paths_mod.deinit(a, p);
    var s = try store.load(a, io, p.state);
    defer s.deinit();
    const action = args[2];
    if (std.mem.eql(u8, action, "ls")) {
        const filter: ?task_mod.IssueKey = if (args.len == 5 and std.mem.eql(u8, args[3], "--issue")) try parseIssueKey(args[4]) else if (args.len == 3) null else return error.Usage;
        const text = try renderer.renderFiltered(a, &s, filter);
        defer a.free(text);
        try out.writeAll(text);
        return;
    }
    if (std.mem.eql(u8, action, "add")) {
        if (args.len < 4) return error.Usage;
        var issue: ?task_mod.IssueKey = null;
        var parent: ?u64 = null;
        var title_end = args.len;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--issue") and i + 1 < args.len) {
                issue = try parseIssueKey(args[i + 1]);
                title_end = @min(title_end, i);
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--parent") and i + 1 < args.len) {
                parent = try std.fmt.parseInt(u64, args[i + 1], 10);
                title_end = @min(title_end, i);
                i += 1;
            }
        }
        const title = try joinArgs(a, args[3..title_end]);
        defer a.free(title);
        const id = try s.addTask(title, issue, parent);
        try store.save(a, io, p.state, &s);
        try out.print("Task {d} を追加しました。\n", .{id});
        return;
    }
    if (std.mem.eql(u8, action, "edit")) {
        if (args.len < 5) return error.Usage;
        const id = try std.fmt.parseInt(u64, args[3], 10);
        const title = try joinArgs(a, args[4..]);
        defer a.free(title);
        try s.edit(id, title);
        try store.save(a, io, p.state, &s);
        return;
    }
    if (std.mem.eql(u8, action, "toggle")) {
        if (args.len != 4) return error.Usage;
        const id = try std.fmt.parseInt(u64, args[3], 10);
        _ = try s.toggle(id);
        try store.save(a, io, p.state, &s);
        return;
    }
    if (std.mem.eql(u8, action, "move")) {
        if (args.len != 5) return error.Usage;
        try s.move(try std.fmt.parseInt(u64, args[3], 10), try std.fmt.parseInt(u32, args[4], 10));
        try store.save(a, io, p.state, &s);
        return;
    }
    if (std.mem.eql(u8, action, "reparent")) {
        if (args.len < 5) return error.Usage;
        const id = try std.fmt.parseInt(u64, args[3], 10);
        if (std.mem.eql(u8, args[4], "--parent") and args.len == 6) try s.reparent(id, try std.fmt.parseInt(u64, args[5], 10), null) else if (std.mem.eql(u8, args[4], "--root")) try s.reparent(id, null, null) else return error.Usage;
        try store.save(a, io, p.state, &s);
        return;
    }
    if (std.mem.eql(u8, action, "link") or std.mem.eql(u8, action, "unlink")) {
        if (args.len < 4) return error.Usage;
        const id = try std.fmt.parseInt(u64, args[3], 10);
        const key: ?task_mod.IssueKey = if (std.mem.eql(u8, action, "link") and args.len == 5) try parseIssueKey(args[4]) else if (std.mem.eql(u8, action, "unlink") and args.len == 4) null else return error.Usage;
        try s.reparent(id, null, key);
        try store.save(a, io, p.state, &s);
        return;
    }
    if (std.mem.eql(u8, action, "del")) {
        if (args.len < 5) return error.Usage;
        const id = try std.fmt.parseInt(u64, args[3], 10);
        const count = try s.subtreeCount(id);
        try out.print("{d}件のTaskに影響します。\n", .{if (hasArg(args, "--subtree")) count else 1});
        try requireConfirmation(io, out, args, "削除しますか？ [y/N] ");
        if (hasArg(args, "--subtree")) _ = try s.deleteSubtree(id) else if (hasArg(args, "--promote-children")) try s.deletePromote(id) else return error.Usage;
        try store.save(a, io, p.state, &s);
        return;
    }
    if (std.mem.eql(u8, action, "clear")) {
        try out.print("{d}件のTaskを削除します。\n", .{s.tasks.items.len});
        try requireConfirmation(io, out, args, "全Taskを削除しますか？ [y/N] ");
        _ = s.clearTasks();
        try store.save(a, io, p.state, &s);
        return;
    }
    return error.Usage;
}

fn handleRepo(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len < 3) return error.Usage;
    const p = try appPaths(a, env, io);
    defer paths_mod.deinit(a, p);
    var c = try config_mod.load(a, io, p.config);
    defer c.deinit();
    const action = args[2];
    if (std.mem.eql(u8, action, "ls")) {
        for (c.repositories.items) |r| try out.print("{s}\t{s}\n", .{ r.repository, r.workspace_path });
        return;
    }
    if (std.mem.eql(u8, action, "add") and args.len == 5) {
        try config_mod.validateWorkspace(io, args[4]);
        try c.add(args[3], args[4]);
    } else if (std.mem.eql(u8, action, "set-workspace") and args.len == 5) {
        try config_mod.validateWorkspace(io, args[4]);
        try c.setWorkspace(args[3], args[4]);
    } else if (std.mem.eql(u8, action, "del") and args.len >= 4) {
        try requireConfirmation(io, out, args, "Repository設定を削除しますか？ [y/N] ");
        try c.delete(args[3]);
    } else if (std.mem.eql(u8, action, "exclude") and args.len >= 5) {
        const r = c.find(args[4]) orelse return error.RepositoryNotFound;
        if (std.mem.eql(u8, args[3], "ls")) {
            for (r.exclude_patterns) |v| try out.print("{s}\n", .{v});
            return;
        }
        if (std.mem.eql(u8, args[3], "add") and args.len == 6) try c.addExclude(args[4], args[5]) else if (std.mem.eql(u8, args[3], "del") and args.len == 6) try c.deleteExclude(args[4], args[5]) else return error.Usage;
    } else return error.Usage;
    try config_mod.save(a, io, p.config, &c);
}

fn handleIssue(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len < 3) return error.Usage;
    const p = try appPaths(a, env, io);
    defer paths_mod.deinit(a, p);
    var s = try store.load(a, io, p.state);
    defer s.deinit();
    const action = args[2];
    if (std.mem.eql(u8, action, "ls")) {
        for (s.issues.items) |i| try out.print("{s}#{d} [{s}] {s}\n", .{ i.key.repository, i.key.issue_number, @tagName(i.status), i.title });
        return;
    }
    if (std.mem.eql(u8, action, "show") and args.len == 4) {
        const key = try parseIssueKey(args[3]);
        for (s.issues.items) |i| if (i.key.eql(key)) {
            try out.print("{s}#{d} {s}\n\n{s}\n", .{ key.repository, key.issue_number, i.title, i.body });
            return;
        };
        return error.IssueNotFound;
    }
    if (std.mem.eql(u8, action, "open") and args.len == 4) {
        const key = try parseIssueKey(args[3]);
        var num: [32]u8 = undefined;
        const n = try std.fmt.bufPrint(&num, "{d}", .{key.issue_number});
        return gh.open(io, a, env, key.repository, n);
    }
    if (std.mem.eql(u8, action, "refresh") and args.len == 4) {
        var parsed = try gh.list(a, io, env, args[3]);
        defer parsed.deinit();
        try issue_adapter.merge(a, &s, args[3], parsed.value, std.Io.Clock.real.now(io).toSeconds());
        try store.save(a, io, p.state, &s);
        return;
    }
    return error.Usage;
}

fn handleProposal(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const []const u8, out: *std.Io.Writer) !void {
    if (args.len < 4) return error.Usage;
    const p = try appPaths(a, env, io);
    defer paths_mod.deinit(a, p);
    var s = try store.load(a, io, p.state);
    defer s.deinit();
    const action = args[2];
    const key = try parseIssueKey(args[3]);
    if (std.mem.eql(u8, action, "show")) {
        const prop = s.findProposal(key) orelse return error.ProposalNotFound;
        try out.print("{s}\n\n", .{prop.summary});
        for (prop.candidates) |c| try out.print("- [{s}] {s}\n", .{ c.candidate_id, c.title });
        return;
    }
    if (std.mem.eql(u8, action, "edit")) {
        const current = s.findProposal(key) orelse return error.ProposalNotFound;
        var working = try state_mod.cloneProposal(a, current.*);
        defer state_mod.freeProposal(a, working);
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
        const result = try proposal_editor.run(a, &working, &stdin.interface, out);
        if (result == .aborted) {
            try out.writeAll("変更を破棄しました。\n");
            return;
        }
        try s.putProposal(working);
        try store.save(a, io, p.state, &s);
        try out.writeAll("Proposalを保存しました。\n");
        return;
    }
    if (std.mem.eql(u8, action, "discard")) {
        try requireConfirmation(io, out, args, "Proposalを破棄しますか？ [y/N] ");
        if (!s.removeProposal(key)) return error.ProposalNotFound;
        try store.save(a, io, p.state, &s);
        return;
    }
    if (std.mem.eql(u8, action, "approve")) {
        try requireConfirmation(io, out, args, "Proposalを承認しますか？ [y/N] ");
        const warnings = try proposal_apply.duplicates(a, &s, key);
        defer a.free(warnings);
        if (warnings.len > 0) try out.print("警告: 同名Taskが{d}件あります。--yesによって承認を継続します。\n", .{warnings.len});
        const count = try proposal_apply.apply(&s, key);
        try store.save(a, io, p.state, &s);
        try out.print("{d}件のTaskを追加しました。\n", .{count});
        return;
    }
    if (std.mem.eql(u8, action, "generate")) {
        var c = try config_mod.load(a, io, p.config);
        defer c.deinit();
        const repo = c.find(key.repository) orelse return error.RepositoryNotFound;
        const issue = for (s.issues.items) |i| {
            if (i.key.eql(key)) break i;
        } else return error.IssueNotFound;
        try generator.generate(a, io, env, &s, issue, repo.workspace_path, repo.exclude_patterns);
        try store.save(a, io, p.state, &s);
        try out.writeAll("Proposalを保存しました。確認・編集後にapproveしてください。\n");
        return;
    }
    return error.Usage;
}

fn doctor(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer) !void {
    const p = try appPaths(a, env, io);
    defer paths_mod.deinit(a, p);
    try out.print("state: {s}\nconfig: {s}\n", .{ p.state, p.config });
    const gh_version = process.run(a, io, .{ .argv = &.{ "gh", "--version" }, .env_map = env }) catch null;
    if (gh_version) |r| {
        defer r.deinit(a);
        try out.print("gh: {s}\n", .{if (process.successful(r.term)) "available" else "unavailable"});
    } else try out.writeAll("gh: not found（インストール後に gh auth login）\n");
    const gh_auth = process.run(a, io, .{ .argv = &.{ "gh", "auth", "status" }, .env_map = env }) catch null;
    if (gh_auth) |r| {
        defer r.deinit(a);
        try out.print("gh authentication: {s}\n", .{if (process.successful(r.term)) "ok" else "required（gh auth login）"});
    }
    const fx_version = process.run(a, io, .{ .argv = &.{ "fx", "--version" }, .env_map = env }) catch null;
    if (fx_version) |r| {
        defer r.deinit(a);
        try out.print("fx: {s}\n", .{if (process.successful(r.term)) "available" else "unavailable"});
    } else try out.writeAll("fx: not found（別途インストール・ログインが必要）\n");
    const fx_help = process.run(a, io, .{ .argv = &.{ "fx", "ask", "--help" }, .env_map = env }) catch null;
    if (fx_help) |r| {
        defer r.deinit(a);
        const compatible = process.successful(r.term) and std.mem.indexOf(u8, r.stdout, "--json") != null and std.mem.indexOf(u8, r.stdout, "--no-save") != null;
        try out.print("fx ask capability: {s}\n", .{if (compatible) "ok" else "unsupported"});
    }
    var config = config_mod.load(a, io, p.config) catch {
        try out.writeAll("config: unreadable\n");
        return;
    };
    defer config.deinit();
    for (config.repositories.items) |repo| {
        config_mod.validateWorkspace(io, repo.workspace_path) catch {
            try out.print("workspace {s}: unavailable ({s})\n", .{ repo.repository, repo.workspace_path });
            continue;
        };
        try out.print("workspace {s}: ok ({s})\n", .{ repo.repository, repo.workspace_path });
    }
}
fn parseIssueKey(text: []const u8) !task_mod.IssueKey {
    const hash = std.mem.lastIndexOfScalar(u8, text, '#') orelse return error.InvalidIssueKey;
    const key = task_mod.IssueKey{ .repository = text[0..hash], .issue_number = try std.fmt.parseInt(u64, text[hash + 1 ..], 10) };
    try task_mod.validateIssueKey(key);
    return key;
}
fn joinArgs(a: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    for (values, 0..) |v, i| {
        if (i > 0) try w.writer.writeByte(' ');
        try w.writer.writeAll(v);
    }
    return w.toOwnedSlice();
}
fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, needle)) return true;
    return false;
}
fn requireConfirmation(io: std.Io, out: *std.Io.Writer, args: []const []const u8, prompt: []const u8) !void {
    if (hasArg(args, "--yes")) return;
    try out.writeAll(prompt);
    try out.flush();
    var buffer: [64]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &buffer);
    const answer = try stdin.interface.takeDelimiter('\n') orelse return error.ConfirmationRequired;
    if (!confirmed(answer, false)) return error.ConfirmationRequired;
}
fn writeErr(io: std.Io, msg: []const u8) void {
    var b: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &b);
    w.interface.print("Error: {s}\n", .{msg}) catch {};
    w.interface.flush() catch {};
}
fn writeError(io: std.Io, e: anyerror) void {
    var b: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &b);
    const guidance = switch (e) {
        error.ExecutableNotFound => "ghまたはfxをインストールしてください",
        error.AuthenticationRequired => "gh auth login または fx login を実行してください",
        error.UnsafePermission => "fxの書込み・Terminal・upload許可を取り消してください",
        error.ConfirmationRequired => "破壊的操作には小文字yでの確認、または--yesが必要です",
        error.InvalidJson, error.InvalidState => "state.jsonをバックアップから復旧してください。元データは上書きされていません",
        else => "docs/troubleshooting.mdを参照してください",
    };
    w.interface.print("Error ({t}): {s}\n", .{ e, guidance }) catch {};
    w.interface.flush() catch {};
}
const usage = "Usage: ztodo-fx <doctor|task|repo|issue|proposal|help|version>\nRun `ztodo-fx help <command>` or see docs/command-reference.md.\n";
test "only lowercase y or flag confirms" {
    try std.testing.expect(confirmed("y\n", false));
    try std.testing.expect(!confirmed("Y\n", false));
    try std.testing.expect(confirmed("", true));
}
test "all command groups parse" {
    for ([_][]const u8{ "doctor", "task", "repo", "issue", "proposal" }) |name| _ = try parse(&.{ "ztodo-fx", name });
}
