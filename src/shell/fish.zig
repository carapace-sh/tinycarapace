const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    // For init script, use one function that dispatches per command
    try buf.appendSlice(allocator,
        \\function _carapace_completer
        \\  set --local data
        \\  IFS='' set data (echo (commandline -cp)'' | sed "s/ $/ ''/" | xargs 
    );
    try buf.appendSlice(allocator, exe);
    try buf.appendSlice(allocator,
        \\ $argv[1] fish 2>/dev/null)
        \\  if [ $status -eq 1 ]
        \\    IFS='' set data (echo (commandline -cp)"'" | sed "s/ $/ ''/" | xargs 
    );
    try buf.appendSlice(allocator, exe);
    try buf.appendSlice(allocator,
        \\ $argv[1] fish 2>/dev/null)
        \\    if [ $status -eq 1 ]
        \\      IFS='' set data (echo (commandline -cp)'"' | sed "s/ $/ ''/" | xargs 
    );
    try buf.appendSlice(allocator, exe);
    try buf.appendSlice(allocator,
        \\ $argv[1] fish 2>/dev/null)
        \\    end
        \\  end
        \\  echo $data
        \\end
        \\
    );

    for (specs) |s| {
        try buf.print(allocator,
            \\complete -e '{s}'
            \\complete -c '{s}' -f -a '(_carapace_completer {s})' -r
            \\
        , .{ s.name, s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\function _{s}_completion
        \\  set --local data
        \\  IFS='' set data (echo (commandline -cp)'' | sed "s/ $/ ''/" | xargs {s} '{s}' fish 2>/dev/null)
        \\  if [ $status -eq 1 ]
        \\    IFS='' set data (echo (commandline -cp)"'" | sed "s/ $/ ''/" | xargs {s} '{s}' fish 2>/dev/null)
        \\    if [ $status -eq 1 ]
        \\      IFS='' set data (echo (commandline -cp)'"' | sed "s/ $/ ''/" | xargs {s} '{s}' fish 2>/dev/null)
        \\    end
        \\  end
        \\  echo $data
        \\end
        \\
        \\complete -e '{s}'
        \\complete -c '{s}' -f -a '(_{s}_completion)' -r
        \\
    , .{ name, exe, name, exe, name, exe, name, name, name, name });

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
    try std.testing.expect(std.mem.indexOf(u8, script, "complete -e") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "sed \"s/ $/ ''/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "commandline -cp") != null);
}

test "fish snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "complete -e") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "sed \"s/ $/ ''/\"") != null);
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