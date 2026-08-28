const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\complete "{s}" 'p@*@`echo "$COMMAND_LINE'\"''\"'" | xargs {s} "{s}" _carapace tcsh `@@' ;
            \\
        , .{ s.name, exe, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\complete "{s}" 'p@*@`echo "$COMMAND_LINE'\"''\"'" | xargs {s} "{s}" _carapace tcsh `@@' ;
        \\
    , .{ name, exe, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    for (candidates, 0..) |c, i| {
        if (i > 0) try buf.append(allocator, '\n');
        if (c.description.len > 0) {
            try buf.print(allocator, "{s}_( {s} )", .{ c.value, c.description });
        } else {
            try buf.print(allocator, "{s}", .{c.value});
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "tcsh init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "COMMAND_LINE") != null);
}