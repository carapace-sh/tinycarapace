const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\from xonsh.completers.completer import add_one_completer
            \\from xonsh.completers.tools import contextual_command_completer
            \\
            \\@contextual_command_completer
            \\def _{s}_completer(context):
            \\    """carapace multi-completer"""
            \\    if context.command not in ['{s}']:
            \\        return
            \\
            \\    from json import loads
            \\    from xonsh.completers.tools import sub_proc_get_output, RichCompletion
            \\
            \\    def fix_prefix(s):
            \\        return s.translate(str.maketrans('', '', '"'"''"'"))
            \\
            \\    output, _ = sub_proc_get_output(
            \\        '{s}', '{s}', '_carapace', 'xonsh', *[a.value for a in context.args], fix_prefix(context.prefix)
            \\    )
            \\
            \\    try:
            \\        result = {{RichCompletion(c["Value"], display=c["Display"], description=c["Description"], prefix_len=len(context.raw_prefix), append_closing_quote=False, style=c["Style"]) for c in loads(output)}}
            \\    except:
            \\        result = {{}}
            \\    if len(result) == 0:
            \\        result = {{RichCompletion(context.prefix, display=context.prefix, description='', prefix_len=len(context.raw_prefix), append_closing_quote=False)}}
            \\    return result
            \\
            \\add_one_completer('{s}', _{s}_completer, 'start')
            \\
        , .{ s.name, s.name, exe, s.name, s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\from xonsh.completers.completer import add_one_completer
        \\from xonsh.completers.tools import contextual_command_completer
        \\
        \\@contextual_command_completer
        \\def _{s}_completer(context):
        \\    """carapace completer for {s}"""
        \\    if context.completing_command('{s}'):
        \\        from json import loads
        \\        from xonsh.completers.tools import sub_proc_get_output, RichCompletion
        \\
        \\        def fix_prefix(s):
        \\            return s.translate(str.maketrans('', '', '"'"''"'"))
        \\
        \\        output, _ = sub_proc_get_output(
        \\            '{s}', '{s}', '_carapace', 'xonsh', *[a.value for a in context.args], fix_prefix(context.prefix)
        \\        )
        \\
        \\        try:
        \\            result = {{RichCompletion(c["Value"], display=c["Display"], description=c["Description"], prefix_len=len(context.raw_prefix), append_closing_quote=False, style=c["Style"]) for c in loads(output)}}
        \\        except:
        \\            result = {{}}
        \\        if len(result) == 0:
        \\            result = {{RichCompletion(context.prefix, display=context.prefix, description='', prefix_len=len(context.raw_prefix), append_closing_quote=False)}}
        \\        return result
        \\
        \\add_one_completer('{s}', _{s}_completer, 'start')
        \\
    , .{ name, name, name, exe, name, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    try buf.append(allocator, '[');
    for (candidates, 0..) |c, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.print(allocator,
            \\{{"Value":"{s}","Display":"{s}","Description":"{s}","Style":"default"}}
        , .{ c.value, c.value, c.description });
    }
    try buf.append(allocator, ']');

    return buf.toOwnedSlice(allocator);
}

test "xonsh init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "add_one_completer") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "RichCompletion") != null);
}

test "xonsh snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "add_one_completer") != null);
}

test "xonsh format output" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "json") != null);
}