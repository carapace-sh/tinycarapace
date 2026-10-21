const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

/// Quote a command name for use as a zsh compdef argument.
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
        \\  lines="$(echo "${{compline}}''" | CARAPACE_COMPLINE="${{compline}}" CARAPACE_ZSH_HASH_DIRS="$(hash -d)" xargs {s} "${{command}}" zsh 2>/dev/null)"
        \\  if [ $? -eq 1 ]; then
        \\    lines="$(echo "${{compline}}'" | CARAPACE_COMPLINE="${{compline}}" CARAPACE_ZSH_HASH_DIRS="$(hash -d)" xargs {s} "${{command}}" zsh 2>/dev/null)"
        \\    if [ $? -eq 1 ]; then
        \\      lines="$(echo "${{compline}}\"" | CARAPACE_COMPLINE="${{compline}}" CARAPACE_ZSH_HASH_DIRS="$(hash -d)" xargs {s} "${{command}}" zsh 2>/dev/null)"
        \\    fi
        \\  fi
        \\
        \\  local zstyle message noprefix data
        \\  IFS=$'\001' read -r -d '' zstyle message noprefix data <<<"${{lines}}"
        \\  zstyle ":completion:${{curcontext}}:*" list-colors "${{zstyle}}"
        \\  zstyle ":completion:${{curcontext}}:*" group-name ''
        \\  [ -z "${{message}}" ] || _message -r "${{message}}"
        \\  [[ "${{noprefix}}" = "true" ]] && compstate[insert]=menu
        \\
        \\  local tag displays values displaysArr valuesArr
        \\  while IFS=$'\002' read -r -d $'\002' block; do
        \\    IFS=$'\003' read -r -d '' tag displays values <<<"${{block}}"
        \\    IFS=$'\n' read -r -d $'\004' -A displaysArr <<<"${{displays}}"$'\004'
        \\    IFS=$'\n' read -r -d $'\004' -A valuesArr <<<"${{values}}"$'\004'
        \\    [[ ${{#valuesArr[@]}} -gt 1 ]] && _describe -t "${{tag}}" "${{tag}}" displaysArr valuesArr -Q -S ''
        \\  done <<<"${{data}}"
        \\}}
        \\compquote '' 2>/dev/null && _carapace_completer
        \\
    , .{ names.items, exe, exe, exe });
    try buf.appendSlice(allocator, "compdef _carapace_completer");
    for (specs) |s| {
        try buf.print(allocator, " {s}", .{try quoteName(allocator, s.name)});
    }
    try buf.appendSlice(allocator, "\n");

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
        \\  lines="$(echo "${{compline}}''" | CARAPACE_COMPLINE="${{compline}}" CARAPACE_ZSH_HASH_DIRS="$(hash -d)" xargs {s} '{s}' zsh 2>/dev/null)"
        \\  if [ $? -eq 1 ]; then
        \\    lines="$(echo "${{compline}}'" | CARAPACE_COMPLINE="${{compline}}" CARAPACE_ZSH_HASH_DIRS="$(hash -d)" xargs {s} '{s}' zsh 2>/dev/null)"
        \\    if [ $? -eq 1 ]; then
        \\      lines="$(echo "${{compline}}\"" | CARAPACE_COMPLINE="${{compline}}" CARAPACE_ZSH_HASH_DIRS="$(hash -d)" xargs {s} '{s}' zsh 2>/dev/null)"
        \\    fi
        \\  fi
        \\
        \\  local zstyle message noprefix data
        \\  IFS=$'\001' read -r -d '' zstyle message noprefix data <<<"${{lines}}"
        \\  zstyle ":completion:${{curcontext}}:*" list-colors "${{zstyle}}"
        \\  zstyle ":completion:${{curcontext}}:*" group-name ''
        \\  [ -z "${{message}}" ] || _message -r "${{message}}"
        \\  [[ "${{noprefix}}" = "true" ]] && compstate[insert]=menu
        \\
        \\  local tag displays values displaysArr valuesArr
        \\  while IFS=$'\002' read -r -d $'\002' block; do
        \\    IFS=$'\003' read -r -d '' tag displays values <<<"${{block}}"
        \\    IFS=$'\n' read -r -d $'\004' -A displaysArr <<<"${{displays}}"$'\004'
        \\    IFS=$'\n' read -r -d $'\004' -A valuesArr <<<"${{values}}"$'\004'
        \\    [[ ${{#valuesArr[@]}} -gt 1 ]] && _describe -t "${{tag}}" "${{tag}}" displaysArr valuesArr -Q -S ''
        \\  done <<<"${{data}}"
        \\}}
        \\compquote '' 2>/dev/null && _{s}_completion
        \\compdef _{s}_completion {s}
        \\
    , .{ name, name, exe, name, exe, name, exe, name, name, name, try quoteName(allocator, name) });

    return buf.toOwnedSlice(allocator);
}

/// Escape a value for insertion by zsh (upstream defaultReplacer).
fn escapeValue(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        switch (c) {
            '\\', '&', '<', '>', '`', '\'', '"', '{', '}', '$', '#', '|', '?', '(', ')', ';', ' ', '[', ']', '*', '~' => {
                try buf.append(allocator, '\\');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Escape a display string for `_describe` (upstream describeReplacer).
fn escapeDescribe(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c == '\\' or c == ':') try buf.append(allocator, '\\');
        try buf.append(allocator, c);
    }
    return buf.toOwnedSlice(allocator);
}

/// Drop control characters that would corrupt the block protocol.
fn sanitize(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\n\r\t") == null) return s;
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c != '\n' and c != '\r' and c != '\t') try buf.append(allocator, c);
    }
    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;

    // Candidates with an empty value are messages (see $message).
    var messages = std.ArrayList([]const u8).empty;
    var values = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        if (c.value.len == 0) {
            if (c.description.len > 0) try messages.append(a, c.description);
            continue;
        }
        try values.append(a, c);
    }

    var has_noprefix = false;
    for (values.items) |c| {
        if (c.noprefix) {
            has_noprefix = true;
            break;
        }
    }

    // Four fields: zstyle\x01message\x01noprefix\x01data
    const zstyles = try formatZstyles(allocator, values.items);
    try buf.appendSlice(allocator, zstyles);
    allocator.free(zstyles);
    try buf.append(allocator, '\x01');
    for (messages.items, 0..) |message, i| {
        if (i > 0) try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, try sanitize(a, message));
    }
    try buf.append(allocator, '\x01');
    try buf.print(allocator, "{s}\x01", .{if (has_noprefix) "true" else "false"});

    // Single block: tag\x03displays\x04\x03values\x04\x02
    try buf.appendSlice(allocator, "completions");
    try buf.append(allocator, '\x03');
    for (values.items) |c| {
        const display = try escapeDescribe(a, try sanitize(a, c.value));
        const description = try sanitize(a, c.description);
        if (description.len > 0) {
            try buf.print(allocator, "{s}:{s}\n", .{ display, description });
        } else {
            try buf.print(allocator, "{s}\n", .{display});
        }
    }
    try buf.append(allocator, '\x04');
    try buf.append(allocator, '\x03');
    for (values.items) |c| {
        const quoted = try escapeDescribe(a, try escapeValue(a, try sanitize(a, c.value)));
        if (c.nospace) {
            try buf.print(allocator, "{s}\n", .{quoted});
        } else {
            try buf.print(allocator, "{s} \n", .{quoted});
        }
    }
    try buf.append(allocator, '\x04');
    try buf.append(allocator, '\x02');

    return buf.toOwnedSlice(allocator);
}

/// Escape zsh list-colors pattern characters in a display string.
fn escapeZstyle(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        switch (c) {
            '#', '*', '(', ')', '[', ']', '|', '~' => {
                try buf.append(allocator, '\\');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Build zsh list-colors patterns from candidate styles (upstream zstyles.Format).
/// Styling is disabled for large amounts of values (bad performance).
fn formatZstyles(allocator: std.mem.Allocator, candidates: []traverse.Candidate) ![]const u8 {
    const style = @import("../style.zig");
    const limit = 300; // upstream default for CARAPACE_ZSH_STYLE_LIMIT

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parts = std.ArrayList(u8).empty;
    if (candidates.len < limit) {
        for (candidates) |c| {
            const value_sgr = if (style.isValid(c.style)) try style.sgr(a, c.style) else "";
            const display = try escapeZstyle(a, c.value);
            try parts.print(allocator, "=(#b)({s})([ ]## -- *)=0={s}=:", .{ display, value_sgr });
            try parts.print(allocator, "=(#b)({s})=0={s}:", .{ display, value_sgr });
        }
    }
    try parts.appendSlice(allocator, "=(#b)(-- *)=0=");
    return parts.toOwnedSlice(allocator);
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
    try std.testing.expect(std.mem.indexOf(u8, script, "CARAPACE_ZSH_HASH_DIRS") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "compstate") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "compquote") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "zstyle") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "_message") != null);
}

test "zsh snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "#compdef mycmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "CARAPACE_ZSH_HASH_DIRS") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "compquote") != null);
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
    // 4-field format: zstyle\x01message\x01noprefix\x01data
    try std.testing.expect(std.mem.indexOf(u8, out, "\x01\x01") != null);
    try std.testing.expect(std.mem.startsWith(u8, out, "=(#b)(json)([ ]## -- *)=0="));
    // displays use `value:description` and values get a trailing space
    try std.testing.expect(std.mem.indexOf(u8, out, "json:JSON format\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "json \n") != null);
}

test "zsh format output nospace and noprefix" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "a/b", .nospace = true, .noprefix = true },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "true\x01") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a/b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a/b \n") == null);
}

test "zsh format output messages" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "", .description = "no matches" },
        .{ .value = "json" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x01no matches\x01") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "json \n") != null);
}

test "zsh format output escapes special characters" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "my file", .description = "a:b" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "my\\\\ file \n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "my file:a:b\n") != null);
}
