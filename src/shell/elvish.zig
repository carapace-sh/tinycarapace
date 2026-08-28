const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

fn sanitize(s: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c == '-') {
            try buf.append(allocator, '_');
            try buf.append(allocator, '_');
        } else {
            try buf.append(allocator, c);
        }
    }
    return buf.toOwnedSlice(allocator);
}

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\set edit:completion:arg-completer[{s}] = {{|@arg|
            \\    {s} {s} _carapace elvish (all $arg) | from-json | each {{|completion|
            \\        put $completion[Messages] | all (one) | each {{|m|
            \\            edit:notify (styled "error: " red)$m
            \\        }}
            \\        if (not-eq $completion[Usage] "") {{
            \\            edit:notify (styled "usage: " $completion[DescriptionStyle])$completion[Usage]
            \\        }}
            \\        put $completion[Candidates] | all (one) | peach {{|c|
            \\            if (eq $c[Description] "") {{
            \\                edit:complex-candidate $c[Value] &display=(styled $c[Display] $c[Style]) &code-suffix=$c[CodeSuffix]
            \\            }} else {{
            \\                edit:complex-candidate $c[Value] &display=(styled $c[Display] $c[Style])(styled " " $completion[DescriptionStyle]" bg-default")(styled "("$c[Description]")" $completion[DescriptionStyle]) &code-suffix=$c[CodeSuffix]
            \\            }}
            \\        }}
            \\    }}
            \\}}
            \\
        , .{ s.name, exe, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\set edit:completion:arg-completer[{s}] = {{|@arg|
        \\    {s} {s} _carapace elvish (all $arg) | from-json | each {{|completion|
        \\        put $completion[Messages] | all (one) | each {{|m|
        \\            edit:notify (styled "error: " red)$m
        \\        }}
        \\        if (not-eq $completion[Usage] "") {{
        \\            edit:notify (styled "usage: " $completion[DescriptionStyle])$completion[Usage]
        \\        }}
        \\        put $completion[Candidates] | all (one) | peach {{|c|
        \\            if (eq $c[Description] "") {{
        \\                edit:complex-candidate $c[Value] &display=(styled $c[Display] $c[Style]) &code-suffix=$c[CodeSuffix]
        \\            }} else {{
        \\                edit:complex-candidate $c[Value] &display=(styled $c[Display] $c[Style])(styled " " $completion[DescriptionStyle]" bg-default")(styled "("$c[Description]")" $completion[DescriptionStyle]) &code-suffix=$c[CodeSuffix]
        \\            }}
        \\        }}
        \\    }}
        \\}}
        \\
    , .{ name, exe, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(allocator,
        \\[{"Messages":[],"Usage":"","DescriptionStyle":"default","Candidates":[
    );

    for (candidates, 0..) |c, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        const suffix = if (c.nospace) "" else " ";
        try buf.print(allocator,
            \\{{"Value":"{s}","Display":"{s}","Description":"{s}","CodeSuffix":"{s}","Style":"default"}}
        , .{ c.value, c.value, c.description, suffix });
    }

    try buf.appendSlice(allocator, "]}]");

    return buf.toOwnedSlice(allocator);
}

test "elvish init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "arg-completer") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "from-json") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "edit:complex-candidate") != null);
}

test "elvish snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "mycmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "from-json") != null);
}

test "elvish format output" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
        .{ .value = "yaml", .description = "" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "json") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Candidates") != null);
}