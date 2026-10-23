const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

/// Quote a command name for use as a bash argument.
fn quoteName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.append(allocator, '"');
    for (name) |c| {
        switch (c) {
            '\\', '"', '$', '`' => {
                try buf.append(allocator, '\\');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
    return buf.toOwnedSlice(allocator);
}

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "tinycarapace";

    // Note: COMP_WORDBREAKS is exported but not used for re-lexing the command line.
    // Full carapace re-lexes COMP_LINE using COMP_WORDBREAKS characters as delimiters
    // to handle cases like --flag=value being split by bash. This is a known limitation
    // of the current xargs-based approach.
    try buf.print(allocator,
        \\#!/bin/bash
        \\_carapace_completer() {{
        \\  export COMP_LINE
        \\  export COMP_POINT
        \\  export COMP_TYPE
        \\  export COMP_WORDBREAKS
        \\
        \\  local command="${{COMP_WORDS[0]}}" nospace data compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
        \\
        \\  data=$(echo "${{compline}}''" | xargs {s} "${{command}}" bash 2>/dev/null)
        \\  if [ $? -eq 1 ]; then
        \\    data=$(echo "${{compline}}'" | xargs {s} "${{command}}" bash 2>/dev/null)
        \\    if [ $? -eq 1 ]; then
        \\      data=$(echo "${{compline}}\"" | xargs {s} "${{command}}" bash 2>/dev/null)
        \\    fi
        \\  fi
        \\
        \\  IFS=$'\001' read -r -d '' nospace data <<<"${{data}}"
        \\  mapfile -t COMPREPLY < <(echo "${{data}}")
        \\  unset COMPREPLY[-1]
        \\
        \\  [ "${{nospace}}" = true ] && compopt -o nospace
        \\  local IFS=$'\n'
        \\  [[ "${{COMPREPLY[*]}}" == "" ]] && COMPREPLY=()
        \\}}
        \\
    , .{ exe, exe, exe });

    try buf.appendSlice(allocator, "complete -o noquote -F _carapace_completer");
    for (specs) |s| {
        try buf.print(allocator, " {s}", .{try quoteName(allocator, s.name)});
    }
    try buf.appendSlice(allocator, "\n\n");

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "tinycarapace";

    try buf.print(allocator,
        \\#!/bin/bash
        \\_{s}_completion() {{
        \\  export COMP_LINE
        \\  export COMP_POINT
        \\  export COMP_TYPE
        \\  export COMP_WORDBREAKS
        \\
        \\  local nospace data compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
        \\
        \\  data=$(echo "${{compline}}''" | xargs {s} '{s}' bash 2>/dev/null)
        \\  if [ $? -eq 1 ]; then
        \\    data=$(echo "${{compline}}'" | xargs {s} '{s}' bash 2>/dev/null)
        \\    if [ $? -eq 1 ]; then
        \\      data=$(echo "${{compline}}\"" | xargs {s} '{s}' bash 2>/dev/null)
        \\    fi
        \\  fi
        \\
        \\  IFS=$'\001' read -r -d '' nospace data <<<"${{data}}"
        \\  mapfile -t COMPREPLY < <(echo "${{data}}")
        \\  unset COMPREPLY[-1]
        \\
        \\  [ "${{nospace}}" = true ] && compopt -o nospace
        \\  local IFS=$'\n'
        \\  [[ "${{COMPREPLY[*]}}" == "" ]] && COMPREPLY=()
        \\}}
        \\complete -o noquote -F _{s}_completion {s}
        \\
    , .{ name, exe, name, exe, name, exe, name, name, try quoteName(allocator, name) });

    return buf.toOwnedSlice(allocator);
}

/// Strip control characters that would corrupt the line-based protocol
/// (upstream sanitizer removes \n, \r, \t).
fn sanitize(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\n\r\t") == null) return s;
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c != '\n' and c != '\r' and c != '\t') try buf.append(allocator, c);
    }
    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, comp_type: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    var has_nospace = false;
    for (candidates) |c| {
        if (c.nospace) {
            has_nospace = true;
            break;
        }
    }

    try buf.print(allocator, "{s}\x01", .{if (has_nospace) "true" else "false"});

    const show_desc = comp_type != null and std.mem.eql(u8, comp_type.?, "63");

    for (candidates) |c| {
        if (c.value.len == 0) continue; // messages are not rendered by bash
        const value = try sanitize(allocator, c.value);
        const description = try sanitize(allocator, c.description);
        if (show_desc and description.len > 0) {
            try buf.print(allocator, "{s} ({s})\n", .{ value, description });
        } else {
            try buf.print(allocator, "{s}\n", .{value});
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "init script has COMP_WORDBREAKS and mapfile" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "chmod", .path = "/tmp/chmod.yaml", .source = .user },
        .{ .name = "git", .path = "/tmp/git.yaml", .source = .user },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "#!/bin/bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "COMP_WORDBREAKS") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "mapfile") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "unset COMPREPLY") != null);
}

test "snippet has COMP_WORDBREAKS and mapfile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "#!/bin/bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "COMP_WORDBREAKS") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "mapfile") != null);
}

test "format output" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "one", .description = "first" },
        .{ .value = "two", .description = "" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") != null);
}

test "format output with description" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), "63");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "json (JSON format)") != null);
}

test "format output with nospace" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "a/b", .nospace = true },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "true\x01"));
}

test "format output without nospace" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "plain", .nospace = false },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "false\x01"));
}
