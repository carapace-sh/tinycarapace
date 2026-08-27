const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\_carapace_completer() {{
        \\  export COMP_LINE
        \\  export COMP_POINT
        \\  export COMP_TYPE
        \\
        \\  local command="${{COMP_WORDS[0]}}" data nospace compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
        \\
        \\  data=$(echo "${{compline}}''" | xargs {s} "${{command}}" bash 2>/dev/null)
        \\  if [ $? -eq 1 ]; then
        \\    data=$(echo "${{compline}}'" | xargs {s} "${{command}}" bash 2>/dev/null)
        \\    if [ $? -eq 1 ]; then
        \\      data=$(echo "${{compline}}\"" | xargs {s} "${{command}}" bash 2>/dev/null)
        \\    fi
        \\  fi
        \\
        \\  IFS=$'\x01' read -r nospace data <<< "${{data}}"
        \\  COMPREPLY=()
        \\  while IFS= read -r line; do
        \\    [ -n "$line" ] && COMPREPLY+=("$line")
        \\  done <<< "$data"
        \\  [ "${{nospace}}" = true ] && compopt -o nospace
        \\  local IFS=$'\n'
        \\  [[ "${{COMPREPLY[*]}}" == "" ]] && COMPREPLY=()
        \\}}
        \\
    , .{ exe, exe, exe });

    try buf.appendSlice(allocator, "complete -o noquote -F _carapace_completer");
    for (specs) |s| {
        try buf.print(allocator, " {s}", .{s.name});
    }
    try buf.appendSlice(allocator, "\n\n");

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";
    const func_prefix = "carapace_tiny";

    try buf.print(allocator,
        \\_{s}_{s}_completion() {{
        \\  local compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
        \\  local data nospace
        \\  data=$(echo "${{compline}}''" | xargs {s} '{s}' bash 2>/dev/null)
        \\  if [ $? -ne 0 ]; then
        \\    data=$(echo "${{compline}}'" | xargs {s} '{s}' bash 2>/dev/null)
        \\    if [ $? -ne 0 ]; then
        \\      data=$(echo "${{compline}}\"" | xargs {s} '{s}' bash 2>/dev/null)
        \\    fi
        \\  fi
        \\  IFS=$'\x01' read -r nospace data <<< "${{data}}"
        \\  COMPREPLY=()
        \\  while IFS= read -r line; do
        \\    [ -n "$line" ] && COMPREPLY+=("$line")
        \\  done <<< "$data"
        \\  [ "${{nospace}}" = true ] && compopt -o nospace
        \\  local IFS=$'\n'
        \\  [[ "${{COMPREPLY[*]}}" == "" ]] && COMPREPLY=()
        \\}}
        \\complete -o noquote -F _{s}_{s}_completion {s}
        \\
    , .{ func_prefix, name, exe, name, exe, name, exe, name, func_prefix, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, comp_type: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    // Compute global nospace flag
    var has_nospace = false;
    for (candidates) |c| {
        if (c.nospace) {
            has_nospace = true;
            break;
        }
    }

    // First line: nospace flag followed by \x01 delimiter
    try buf.print(allocator, "{s}\x01", .{if (has_nospace) "true" else "false"});

    const show_desc = comp_type != null and std.mem.eql(u8, comp_type.?, "63");

    for (candidates) |c| {
        if (show_desc and c.description.len > 0) {
            try buf.print(allocator, "{s} ({s})\n", .{ c.value, c.description });
        } else {
            try buf.print(allocator, "{s}\n", .{c.value});
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "init script contains completers" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "chmod", .path = "/tmp/chmod.yaml" },
        .{ .name = "git", .path = "/tmp/git.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "_carapace_completer") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "chmod") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "git") != null);
}

test "snippet contains function name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "_carapace_tiny_mycmd_completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "mycmd") != null);
}

test "format output" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "one", .description = "first" },
        .{ .value = "two", .description = "" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "first") == null);
}

test "format output with description" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
        .{ .value = "yaml", .description = "YAML format" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), "63");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "json (JSON format)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "yaml (YAML format)") != null);
}

test "format output with description and style" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format", .style = "bold" },
        .{ .value = "yaml", .description = "YAML format", .style = "italic" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), "63");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "json (JSON format)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "yaml (YAML format)") != null);
}

test "format output with nospace" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "a/b", .nospace = true },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true\x01") != null);
}

test "format output without nospace" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "plain", .nospace = false },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "false\x01"));
}