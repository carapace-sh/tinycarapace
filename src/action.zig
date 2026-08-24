const std = @import("std");
const traverse = @import("traverse.zig");

pub fn resolveMacro(allocator: std.mem.Allocator, macro: []const u8) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;

    if (std.mem.startsWith(u8, macro, "$")) {
        return candidates.toOwnedSlice(allocator);
    }

    const val = std.mem.trim(u8, macro, " \t");
    if (val.len > 0) {
        var it = std.mem.splitScalar(u8, val, '\t');
        const v = it.first();
        const desc = if (it.next()) |d| d else "";
        try candidates.append(allocator, .{ .value = v, .description = desc });
    }
    return candidates.toOwnedSlice(allocator);
}
