const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\#!/bin/osh
            \\_{s}_completer() {{
            \\  local command="${{COMP_WORDS[0]}}"
            \\  local compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
            \\  local IFS=$'\n'
            \\  mapfile -t COMPREPLY < <(echo "$compline" | sed -e "s/ $/ ''/" -e 's/"/\"/g' | xargs {s} "${{command}}" _carapace oil)
            \\  [[ "${{COMPREPLY[@]}}" == "" ]] && COMPREPLY=()
            \\  [[ ${{COMPREPLY[0]}} == *[/=@:.,$'\001'] ]] && compopt -o nospace
            \\  [[ ${{#COMPREPLY[@]}} -eq 1 ]] && COMPREPLY=(${{COMPREPLY[@]%%$'\001'}})
            \\}}
            \\
            \\complete -F _{s}_completer {s}
            \\
        , .{ s.name, exe, s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\#!/bin/osh
        \\_{s}_completion() {{
        \\  local compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
        \\  local IFS=$'\n'
        \\  mapfile -t COMPREPLY < <(echo "$compline" | sed -e "s/ $/ ''/" -e 's/"/\"/g' | xargs {s} '{s}' _carapace oil)
        \\  [[ "${{COMPREPLY[@]}}" == "" ]] && COMPREPLY=()
        \\  [[ ${{COMPREPLY[0]}} == *[/=@:.,$'\001'] ]] && compopt -o nospace
        \\  [[ ${{#COMPREPLY[@]}} -eq 1 ]] && COMPREPLY=(${{COMPREPLY[@]%%$'\001'}})
        \\}}
        \\
        \\complete -F _{s}_completion {s}
        \\
    , .{ name, exe, name, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    for (candidates) |c| {
        if (c.nospace) {
            try buf.print(allocator, "{s}\x01\n", .{c.value});
        } else if (c.description.len > 0) {
            try buf.print(allocator, "{s} ({s})\n", .{ c.value, c.description });
        } else {
            try buf.print(allocator, "{s}\n", .{c.value});
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "oil init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "#!/bin/osh") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "complete -F") != null);
}

test "oil snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "#!/bin/osh") != null);
}