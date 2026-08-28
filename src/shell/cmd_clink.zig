const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\local function {s}_completion(word, word_index, line_state, match_builder)
            \\    match_builder:setnosort()
            \\    match_builder:setvolatile()
            \\    os.setenv('CARAPACE_COMPLINE', line_state:getline():sub(1, line_state:getcursor()))
            \\
            \\    local file, pclose = io.popenyield('{s} _carapace cmd-clink {s}')
            \\
            \\    if not file then
            \\        return false
            \\    end
            \\
            \\    for line in file:lines() do
            \\        local matches = string.explode(line, '\t')
            \\
            \\        if matches[1] then
            \\            match_builder:addmatch({{
            \\                match       = matches[1],
            \\                display     = matches[2],
            \\                description = matches[3],
            \\                type        = 'word',
            \\                appendchar  = matches[4] or ''
            \\            }})
            \\        end
            \\    end
            \\
            \\    if pclose then
            \\        pclose()
            \\    else
            \\        file:close()
            \\    end
            \\
            \\    return not match_builder:isempty()
            \\end
            \\
            \\clink.argmatcher(50, '{s}', '{s}.exe'):addarg({{nowordbreakchars="'`=+;,", {s}_completion}}):loop(1)
            \\
        , .{ s.name, exe, s.name, s.name, s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\local function {s}_completion(word, word_index, line_state, match_builder)
        \\    match_builder:setnosort()
        \\    match_builder:setvolatile()
        \\    os.setenv('CARAPACE_COMPLINE', line_state:getline():sub(1, line_state:getcursor()))
        \\
        \\    local file, pclose = io.popenyield('{s} _carapace cmd-clink {s}')
        \\
        \\    if not file then
        \\        return false
        \\    end
        \\
        \\    for line in file:lines() do
        \\        local matches = string.explode(line, '\t')
        \\
        \\        if matches[1] then
        \\            match_builder:addmatch({{
        \\                match       = matches[1],
        \\                display     = matches[2],
        \\                description = matches[3],
        \\                type        = 'word',
        \\                appendchar  = matches[4] or ''
        \\            }})
        \\        end
        \\    end
        \\
        \\    if pclose then
        \\        pclose()
        \\    else
        \\        file:close()
        \\    end
        \\
        \\    return not match_builder:isempty()
        \\end
        \\
        \\clink.argmatcher(50, '{s}', '{s}.exe'):addarg({{nowordbreakchars="'`=+;,", {s}_completion}}):loop(1)
        \\
    , .{ name, exe, name, name, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    for (candidates) |c| {
        const append_char = if (c.nospace) "" else " ";
        try buf.print(allocator, "{s}\t{s}\t{s}\t{s}\n", .{ c.value, c.value, c.description, append_char });
    }

    return buf.toOwnedSlice(allocator);
}

test "cmd-clink init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "clink.argmatcher") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "io.popenyield") != null);
}

test "cmd-clink snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "clink.argmatcher") != null);
}