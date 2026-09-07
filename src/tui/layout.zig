const std = @import("std");

/// Leaves a guard cell between wrapped text and a terminal border. This is
/// required for a two-cell-wide grapheme at the end of a row.
pub fn safeContentWidth(width: u16) u16 {
    return width -| 1;
}

/// Returns the byte position where a tree node's human-readable title starts.
/// Wrapped continuation rows use this as their hanging indent.
pub fn titleStart(line: []const u8) usize {
    if (std.mem.indexOf(u8, line, ": ")) |delimiter| return delimiter + 2;
    if (std.mem.lastIndexOf(u8, line, "] ")) |delimiter| return delimiter + 2;
    return 0;
}

/// Finds the first logical row for a variable-height viewport while keeping
/// the selected row visible. Row heights are already projected terminal rows.
pub fn viewportStart(heights: []const usize, selected: usize, capacity: usize) usize {
    if (heights.len == 0 or selected >= heights.len or capacity == 0) return 0;
    var start = selected;
    var used = @min(heights[selected], capacity);
    while (start > 0 and heights[start - 1] <= capacity - used) {
        start -= 1;
        used += heights[start];
    }
    return start;
}

test "guard width and hanging indent are deterministic for Unicode titles" {
    try std.testing.expectEqual(@as(u16, 19), safeContentWidth(20));
    try std.testing.expectEqual(@as(u16, 0), safeContentWidth(0));
    const line = "  └─ [ ] 12: 長い日本語Task";
    try std.testing.expectEqualStrings("長い日本語Task", line[titleStart(line)..]);
}

test "variable-height viewport keeps selection visible after expansion" {
    try std.testing.expectEqual(@as(usize, 1), viewportStart(&.{ 1, 3, 1, 2 }, 3, 6));
    try std.testing.expectEqual(@as(usize, 2), viewportStart(&.{ 1, 4, 1, 2 }, 3, 4));
    try std.testing.expectEqual(@as(usize, 0), viewportStart(&.{ 8, 1 }, 0, 4));
}
