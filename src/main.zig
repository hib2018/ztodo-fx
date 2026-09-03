const std = @import("std");
const app = @import("ztodo_fx");

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 1;
    return app.cli.run(init.gpa, init.io, init.environ_map, args);
}
