const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateSnippet(allocator: std.mem.Allocator, cmd: spec.Command, spec_path: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    const name = cmd.name;
    const exe = "tinycarapace";

    try buf.print(allocator,
        \\_{s}_{s}_completion() {{
        \\  local compline="${{COMP_LINE:0:${{COMP_POINT}}}}"
        \\  local data
        \\  data=$(echo "${{compline}}''" | xargs -- {s} '{s}' _complete bash 2>/dev/null)
        \\  if [ $? -ne 0 ]; then
        \\    data=$(echo "${{compline}}'" | xargs -- {s} '{s}' _complete bash 2>/dev/null)
        \\    if [ $? -ne 0 ]; then
        \\      data=$(echo "${{compline}}\"" | xargs -- {s} '{s}' _complete bash 2>/dev/null)
        \\    fi
        \\  fi
        \\  COMPREPLY=()
        \\  while IFS= read -r line; do
        \\    [ -n "$line" ] && COMPREPLY+=("$line")
        \\  done <<< "$data"
        \\}}
        \\complete -o noquote -F _{s}_{s}_completion {s}
        \\
    , .{ exe, name, exe, spec_path, exe, spec_path, exe, spec_path, exe, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, comp_type: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    const show_desc = comp_type != null and std.mem.eql(u8, comp_type.?, "63");

    for (candidates) |c| {
        if (show_desc and c.description.len > 0) {
            try buf.print(allocator, "{s}\t{s}\n", .{ c.value, c.description });
        } else {
            try buf.print(allocator, "{s}\n", .{c.value});
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "snippet contains function name" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --verbose: verbose
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("../spec.zig").loadSpec(arena.allocator(), yaml_src);
    const snippet = try generateSnippet(arena.allocator(), cmd, "/tmp/spec.yaml");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "_tinycarapace_mycmd_completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "complete") != null);
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
