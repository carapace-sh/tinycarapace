const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    for (specs) |s| {
        try buf.print(allocator,
            \\complete -c {s} -k -f -a '(__fish_{s}_completion)'
            \\function __fish_{s}_completion --description '{s} completions'
            \\  set -l compline (commandline -cp)
            \\  set -l data
            \\  set data (echo "$compline''" | xargs {s} '{s}' fish 2>/dev/null)
            \\  if test $status -eq 1
            \\    set data (echo "$compline'" | xargs {s} '{s}' fish 2>/dev/null)
            \\    if test $status -eq 1
            \\      set data (echo "$compline\"" | xargs {s} '{s}' fish 2>/dev/null)
            \\    end
            \\  end
            \\  for line in $data
            \\    echo $line
            \\  end
            \\end
            \\
        , .{ s.name, s.name, s.name, s.name, exe, s.name, exe, s.name, exe, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\complete -c {s} -k -f -a '(__fish_{s}_completion)'
        \\function __fish_{s}_completion --description '{s} completions'
        \\  set -l compline (commandline -cp)
        \\  set -l data
        \\  set data (echo "$compline''" | xargs {s} '{s}' fish 2>/dev/null)
        \\  if test $status -eq 1
        \\    set data (echo "$compline'" | xargs {s} '{s}' fish 2>/dev/null)
        \\    if test $status -eq 1
        \\      set data (echo "$compline\"" | xargs {s} '{s}' fish 2>/dev/null)
        \\    end
        \\  end
        \\  for line in $data
        \\    echo $line
        \\  end
        \\end
        \\
    , .{ name, name, name, name, exe, name, exe, name, exe, name });

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
        // fish format: value\tdescription
        if (c.description.len > 0) {
            try buf.print(allocator, "{s}\t{s}\n", .{ c.value, c.description });
        } else {
            try buf.print(allocator, "{s}\n", .{c.value});
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "fish init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "complete -c mycmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "commandline -cp") != null);
}

test "fish snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "complete -c mycmd") != null);
}

test "fish format output" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
        .{ .value = "yaml", .description = "" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "json\tJSON format") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "yaml\n") != null);
}