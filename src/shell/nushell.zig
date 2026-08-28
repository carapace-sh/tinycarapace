const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\let {s}_completer = {{|spans|
            \\    {s} {s} _carapace nushell ...$spans | from json
            \\}}
            \\
            \\mut current = (($env | default {{}} config).config | default {{}} completions)
            \\$current.completions = ($current.completions | default {{}} external)
            \\$current.completions.external = ($current.completions.external
            \\    | default true enable
            \\    | upsert completer {{ if $in == null {{ ${s}_completer }} else {{ $in }} }})
            \\
            \\$env.config = $current
            \\
        , .{ s.name, exe, s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\let {s}_completer = {{|spans|
        \\    {s} {s} _carapace nushell ...$spans | from json
        \\}}
        \\
        \\mut current = (($env | default {{}} config).config | default {{}} completions)
        \\$current.completions = ($current.completions | default {{}} external)
        \\$current.completions.external = ($current.completions.external
        \\    | default true enable
        \\    | upsert completer {{ if $in == null {{ ${s}_completer }} else {{ $in }} }})
        \\
        \\$env.config = $current
        \\
    , .{ name, exe, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    try buf.append(allocator, '[');
    for (candidates, 0..) |c, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.print(allocator,
            \\{{"value":"{s}","display":"{s}","description":"{s}"}}
        , .{ c.value, c.value, c.description });
    }
    try buf.append(allocator, ']');

    return buf.toOwnedSlice(allocator);
}

test "nushell init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "from json") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "completer") != null);
}

test "nushell snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "from json") != null);
}