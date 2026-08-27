const std = @import("std");
const traverse = @import("traverse.zig");

pub fn resolveMacro(allocator: std.mem.Allocator, macro: []const u8) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;

    if (std.mem.startsWith(u8, macro, "$")) {
        return candidates.toOwnedSlice(allocator);
    }

    const val = std.mem.trim(u8, macro, " \t");
    if (val.len > 0) {
        const parsed = traverse.splitValue(val);
        try candidates.append(allocator, .{ .value = parsed.value, .description = parsed.description, .style = parsed.style });
    }
    return candidates.toOwnedSlice(allocator);
}
