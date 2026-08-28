const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\_{s}_completer_ble() {{
            \\  if [[ ${{BLE_ATTACHED-}} ]]; then
            \\    [[ :$comp_type: == *:auto:* ]] && return
            \\
            \\    compopt -o ble/no-default
            \\    bleopt complete_menu_style=desc
            \\
            \\    local command="${{COMP_WORDS[0]}}"
            \\    local compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
            \\    local IFS=$'\n'
            \\    local c
            \\    mapfile -t c < <(echo "$compline" | sed -e "s/ $/ ''/" -e 's/"/\"/g' | xargs {s} "${{command}}" _carapace bash-ble)
            \\    [[ "${{c[*]}}" == "" ]] && c=()
            \\
            \\    local cand
            \\    for cand in "${{c[@]}}"; do
            \\      [ ! -z "$cand" ] && ble/complete/cand/yield mandb "${{cand%%$'\t'*}}" "${{cand##*$'\t'}}"
            \\    done
            \\  else
            \\    complete -F _{s}_completer {s}
            \\  fi
            \\}}
            \\
            \\complete -F _{s}_completer_ble {s}
            \\
        , .{ s.name, exe, s.name, s.name, s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\_{s}_completion_ble() {{
        \\  if [[ ${{BLE_ATTACHED-}} ]]; then
        \\    [[ :$comp_type: == *:auto:* ]] && return
        \\
        \\    compopt -o ble/no-default
        \\    bleopt complete_menu_style=desc
        \\
        \\    local compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
        \\    local IFS=$'\n'
        \\    local c
        \\    mapfile -t c < <(echo "$compline" | sed -e "s/ $/ ''/" -e 's/"/\"/g' | xargs {s} '{s}' _carapace bash-ble)
        \\    [[ "${{c[*]}}" == "" ]] && c=()
        \\
        \\    local cand
        \\    for cand in "${{c[@]}}"; do
        \\      [ ! -z "$cand" ] && ble/complete/cand/yield mandb "${{cand%%$'\t'*}}" "${{cand##*$'\t'}}"
        \\    done
        \\  else
        \\    complete -F _{s}_completion {s}
        \\  fi
        \\}}
        \\
        \\complete -F _{s}_completion_ble {s}
        \\
    , .{ name, exe, name, name, name, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    for (candidates) |c| {
        const suffix = if (c.nospace) "" else " ";
        try buf.print(allocator, "{s}\t{s}\x1c\x1c{s}\x1c{s}\n", .{ c.value, c.value, suffix, c.description });
    }

    return buf.toOwnedSlice(allocator);
}

test "bash-ble init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "BLE_ATTACHED") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "ble/complete/cand/yield") != null);
}

test "bash-ble snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "BLE_ATTACHED") != null);
}