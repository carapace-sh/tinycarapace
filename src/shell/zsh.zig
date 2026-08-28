const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    // Build space-separated names for #compdef
    var names = std.ArrayList(u8).empty;
    for (specs, 0..) |s, i| {
        if (i > 0) try names.append(allocator, ' ');
        try names.appendSlice(allocator, s.name);
    }
    defer names.deinit(allocator);

    try buf.print(allocator,
        \\#compdef {s}
        \\_carapace_completer() {{
        \\  local command="$(basename $words[1])"
        \\  local compline=${{words[@]:0:$CURRENT}}
        \\  local IFS=$'\n'
        \\  local lines
        \\
        \\  lines="$(echo "${{compline}}''" | CARAPACE_COMPLINE="${{compline}}" xargs {s} "${{command}}" zsh 2>/dev/null)"
        \\  if [ $? -eq 1 ]; then
        \\    lines="$(echo "${{compline}}'" | CARAPACE_COMPLINE="${{compline}}" xargs {s} "${{command}}" zsh 2>/dev/null)"
        \\    if [ $? -eq 1 ]; then
        \\      lines="$(echo "${{compline}}\"" | CARAPACE_COMPLINE="${{compline}}" xargs {s} "${{command}}" zsh 2>/dev/null)"
        \\    fi
        \\  fi
        \\
        \\  local nospace data
        \\  IFS=$'\001' read -r -d '' nospace data <<<"${{lines}}"
        \\  [[ "${{nospace}}z" = "truez" ]] && compstate[insert]=menu
        \\
        \\  local tag displays values displaysArr valuesArr
        \\  while IFS=$'\002' read -r -d $'\002' block; do
        \\    IFS=$'\003' read -r -d '' tag displays values <<<"${{block}}"
        \\    IFS=$'\n' read -r -d $'\004' -A displaysArr <<<"${{displays}}"$'\004'
        \\    IFS=$'\n' read -r -d $'\004' -A valuesArr <<<"${{values}}"$'\004'
        \\    [[ ${{#valuesArr[@]}} -gt 1 ]] && _describe -t "${{tag}}" "${{tag}}" displaysArr valuesArr -Q -S ''
        \\  done <<<"${{data}}"
        \\}}
        \\compdef _carapace_completer {s}
        \\
    , .{ names.items, exe, exe, exe, names.items });

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\#compdef {s}
        \\_{s}_completion() {{
        \\  local compline=${{words[@]:0:$CURRENT}}
        \\  local IFS=$'\n'
        \\  local lines
        \\
        \\  lines="$(echo "${{compline}}''" | CARAPACE_COMPLINE="${{compline}}" xargs {s} '{s}' zsh 2>/dev/null)"
        \\  if [ $? -eq 1 ]; then
        \\    lines="$(echo "${{compline}}'" | CARAPACE_COMPLINE="${{compline}}" xargs {s} '{s}' zsh 2>/dev/null)"
        \\    if [ $? -eq 1 ]; then
        \\      lines="$(echo "${{compline}}\"" | CARAPACE_COMPLINE="${{compline}}" xargs {s} '{s}' zsh 2>/dev/null)"
        \\    fi
        \\  fi
        \\
        \\  local nospace data
        \\  IFS=$'\001' read -r -d '' nospace data <<<"${{lines}}"
        \\  [[ "${{nospace}}z" = "truez" ]] && compstate[insert]=menu
        \\
        \\  local tag displays values displaysArr valuesArr
        \\  while IFS=$'\002' read -r -d $'\002' block; do
        \\    IFS=$'\003' read -r -d '' tag displays values <<<"${{block}}"
        \\    IFS=$'\n' read -r -d $'\004' -A displaysArr <<<"${{displays}}"$'\004'
        \\    IFS=$'\n' read -r -d $'\004' -A valuesArr <<<"${{values}}"$'\004'
        \\    [[ ${{#valuesArr[@]}} -gt 1 ]] && _describe -t "${{tag}}" "${{tag}}" displaysArr valuesArr -Q -S ''
        \\  done <<<"${{data}}"
        \\}}
        \\compdef _{s}_completion {s}
        \\
    , .{ name, name, exe, name, exe, name, exe, name, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    var has_nospace = false;
    for (candidates) |c| {
        if (c.nospace) {
            has_nospace = true;
            break;
        }
    }

    // Line: nospace\x01 then data blocks
    try buf.print(allocator, "{s}\x01", .{if (has_nospace) "true" else "false"});

    // Single block: tag\x03displays\x04\x03values\x04\x02
    try buf.appendSlice(allocator, "completions");
    try buf.append(allocator, '\x03');
    for (candidates) |c| {
        if (c.description.len > 0) {
            try buf.print(allocator, "{s} - {s}\n", .{ c.value, c.description });
        } else {
            try buf.print(allocator, "{s}\n", .{c.value});
        }
    }
    try buf.append(allocator, '\x04');
    try buf.append(allocator, '\x03');
    for (candidates) |c| {
        try buf.print(allocator, "{s}\n", .{c.value});
    }
    try buf.append(allocator, '\x04');
    try buf.append(allocator, '\x02');

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
    try std.testing.expect(std.mem.indexOf(u8, script, "CARAPACE_COMPLINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "compstate") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "\x01") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x03") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x02") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "json") != null);
}