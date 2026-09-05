const std = @import("std");
const app = @import("ztodo_fx");

pub const panic = app.tui.panic_handler;

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 1;
    if (args.len == 1) return app.tui.run(init);
    return app.cli.run(init.gpa, init.io, init.environ_map, args);
}
