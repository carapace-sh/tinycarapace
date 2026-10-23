const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

/// Escape a command name for use inside fish single quotes.
fn escapeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (name) |c| {
        if (c == '\'') try buf.appendSlice(allocator, "\\'") else try buf.append(allocator, c);
    }
    return buf.toOwnedSlice(allocator);
}

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "tinycarapace";

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
        const name = try escapeName(allocator, s.name);
        try buf.print(allocator,
            \\complete -e '{s}'
            \\complete -c '{s}' -f -a '(_carapace_completer {s})' -r
            \\
        , .{ name, name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "tinycarapace";
    const name_escaped = try escapeName(allocator, name);

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
    , .{ name, exe, name, exe, name, exe, name, name_escaped, name_escaped, name });

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

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    for (candidates) |c| {
        if (c.value.len == 0) continue; // messages are not rendered by fish
        const value = try sanitize(allocator, c.value);
        const description = try sanitize(allocator, c.description);
        if (description.len > 0) {
            try buf.print(allocator, "{s}\t{s}\n", .{ value, description });
        } else {
            try buf.print(allocator, "{s}\n", .{value});
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "fish init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml", .source = .user },
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
    try std.testing.expect(!std.mem.startsWith(u8, out, "true\x01"));
    try std.testing.expect(!std.mem.startsWith(u8, out, "false\x01"));
}
