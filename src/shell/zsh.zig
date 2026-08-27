const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\#compdef {s}
            \\_{s}_completion() {{
            \\  local compline="${{words[1,${{CURRENT}}]}}"
            \\  local data
            \\  data=$(echo "${{compline}}''" | xargs {s} '{s}' zsh 2>/dev/null)
            \\  if [ $? -eq 1 ]; then
            \\    data=$(echo "${{compline}}'" | xargs {s} '{s}' zsh 2>/dev/null)
            \\    if [ $? -eq 1 ]; then
            \\      data=$(echo "${{compline}}\"" | xargs {s} '{s}' zsh 2>/dev/null)
            \\    fi
            \\  fi
            \\  _describe '{s}' data
            \\}}
            \\
        , .{ s.name, s.name, exe, s.name, exe, s.name, exe, s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\#compdef {s}
        \\_{s}_completion() {{
        \\  local compline="${{words[1,${{CURRENT}}]}}"
        \\  local data
        \\  data=$(echo "${{compline}}''" | xargs {s} '{s}' zsh 2>/dev/null)
        \\  if [ $? -eq 1 ]; then
        \\    data=$(echo "${{compline}}'" | xargs {s} '{s}' zsh 2>/dev/null)
        \\    if [ $? -eq 1 ]; then
        \\      data=$(echo "${{compline}}\"" | xargs {s} '{s}' zsh 2>/dev/null)
        \\    fi
        \\  fi
        \\  _describe '{s}' data
        \\}}
        \\
    , .{ name, name, exe, name, exe, name, exe, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    // First line: nospace flag
    var has_nospace = false;
    for (candidates) |c| {
        if (c.nospace) {
            has_nospace = true;
            break;
        }
    }
    try buf.print(allocator, "{s}\x01", .{if (has_nospace) "true" else "false"});

    for (candidates) |c| {
        // zsh format: value:description
        if (c.description.len > 0) {
            try buf.print(allocator, "{s}:{s}\n", .{ c.value, c.description });
        } else {
            try buf.print(allocator, "{s}\n", .{c.value});
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "zsh init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "#compdef mycmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "_describe") != null);
}

test "zsh snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "#compdef mycmd") != null);
}

test "zsh format output" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
        .{ .value = "yaml", .description = "" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "json:JSON format") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "yaml") != null);
}