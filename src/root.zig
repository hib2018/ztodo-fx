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
