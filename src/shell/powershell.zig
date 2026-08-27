const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\#compdef {s}
            \\function _{s}_completion {{
            \\  $compline = $words[1..$CURRENT] -join ' '
            \\  $data = &{s} '{s}' powershell -- $compline 2>$null
            \\  if ($LASTEXITCODE -eq 1) {{
            \\    $data = &{s} '{s}' powershell -- $compline 2>$null
            \\  }}
            \\  return $data
            \\}}
            \\Register-ArgumentCompleter -Native -CommandName {s} -ScriptBlock ${{function:_{s}_completion}}
            \\
        , .{ s.name, s.name, exe, s.name, exe, s.name, s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\#compdef {s}
        \\function _{s}_completion {{
        \\  $compline = $words[1..$CURRENT] -join ' '
        \\  $data = &{s} '{s}' powershell -- $compline 2>$null
        \\  if ($LASTEXITCODE -eq 1) {{
        \\    $data = &{s} '{s}' powershell -- $compline 2>$null
        \\  }}
        \\  return $data
        \\}}
        \\Register-ArgumentCompleter -Native -CommandName {s} -ScriptBlock ${{function:_{s}_completion}}
        \\
    , .{ name, name, exe, name, exe, name, name, name });

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
    try buf.print(allocator, "{s}\x01", .{if (has_nospace) "true" else "false"});

    for (candidates) |c| {
        // powershell format: CompletionResult format
        if (c.description.len > 0) {
            try buf.print(allocator, "{s}\t{s}\t{s}\n", .{ c.value, c.description, c.value });
        } else {
            try buf.print(allocator, "{s}\t\t{s}\n", .{ c.value, c.value });
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "powershell init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "Register-ArgumentCompleter") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "mycmd") != null);
}

test "powershell snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "Register-ArgumentCompleter") != null);
}

test "powershell format output" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
        .{ .value = "yaml", .description = "" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "json\tJSON format\tjson") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "yaml\t\tyaml") != null);
}