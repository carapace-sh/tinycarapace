const std = @import("std");
const traverse = @import("../traverse.zig");
const build_options = @import("build_options");

const version_string = build_options.version ++ "-tiny";

fn writeJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, usage: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    // upstream sorts values by value before serializing
    const sorted = try allocator.dupe(traverse.Candidate, candidates);
    defer allocator.free(sorted);
    std.mem.sort(traverse.Candidate, sorted, {}, struct {
        fn lessThan(_: void, a: traverse.Candidate, b: traverse.Candidate) bool {
            return std.mem.lessThan(u8, a.value, b.value);
        }
    }.lessThan);

    // Compute global nospace flag
    var has_nospace = false;
    for (sorted) |c| {
        if (c.nospace) {
            has_nospace = true;
            break;
        }
    }

    try buf.print(allocator,
        \\{{
        \\  "version": "{s}",
        \\  "messages": [
    , .{version_string});

    // Candidates with an empty value are messages (see $message).
    var has_message = false;
    for (sorted) |c| {
        if (c.value.len == 0 and c.description.len > 0) {
            try buf.appendSlice(allocator, if (has_message) ",\n    \"" else "\n    \"");
            has_message = true;
            try writeJsonString(&buf, allocator, c.description);
            try buf.appendSlice(allocator, "\"");
        }
    }
    if (has_message) try buf.appendSlice(allocator, "\n  ");
    try buf.print(allocator,
        \\],
        \\  "nospace": {s},
        \\  "usage": "
    , .{if (has_nospace) "true" else "false"});
    try writeJsonString(&buf, allocator, usage);
    try buf.appendSlice(allocator, "\",\n  \"values\": [");

    var has_value = false;
    for (sorted) |c| {
        if (c.value.len == 0) continue;
        if (has_value) try buf.appendSlice(allocator, ",");
        has_value = true;
        try buf.appendSlice(allocator,
            \\
            \\    {
            \\      "value": "
        );
        try writeJsonString(&buf, allocator, c.value);
        try buf.appendSlice(allocator, "\",\n      \"display\": \"");
        try writeJsonString(&buf, allocator, c.value);
        try buf.appendSlice(allocator, "\"");
        if (c.description.len > 0) {
            try buf.appendSlice(allocator, ",\n      \"description\": \"");
            try writeJsonString(&buf, allocator, c.description);
            try buf.appendSlice(allocator, "\"");
        }
        if (c.style.len > 0) {
            try buf.appendSlice(allocator, ",\n      \"style\": \"");
            try writeJsonString(&buf, allocator, c.style);
            try buf.appendSlice(allocator, "\"");
        }
        if (c.nospace) {
            try buf.appendSlice(allocator, ",\n      \"nospace\": true");
        }
        if (c.tag.len > 0) {
            try buf.appendSlice(allocator, ",\n      \"tag\": \"");
            try writeJsonString(&buf, allocator, c.tag);
            try buf.appendSlice(allocator, "\"");
        }
        if (c.uid.len > 0) {
            try buf.appendSlice(allocator, ",\n      \"uid\": \"");
            try writeJsonString(&buf, allocator, c.uid);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "\n    }");
    }

    try buf.appendSlice(allocator,
        \\
        \\  ]
        \\}
        \\
    );

    return buf.toOwnedSlice(allocator);
}

test "export empty candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try formatOutput(arena.allocator(), &.{}, "");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"values\": [") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"messages\"") != null);
}

test "export single candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"value\": \"json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"display\": \"json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"description\": \"JSON format\"") != null);
}

test "export multiple candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "one", .description = "first" },
        .{ .value = "two", .description = "" },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"value\": \"one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"value\": \"two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"description\": \"first\"") != null);
}

test "export candidate with style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "bold", .style = "bright-white" },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"style\": \"bright-white\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"value\": \"bold\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"display\": \"bold\"") != null);
}

test "export json escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "quote\"test", .description = "line\nbreak" },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "");
    try std.testing.expect(std.mem.indexOf(u8, out, "quote\\\"test") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line\\nbreak") != null);
}

test "export with nospace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "a/b", .nospace = true },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"nospace\": true") != null);
}

test "export with tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "val", .tag = "mytag" },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tag\": \"mytag\"") != null);
}

test "export with uid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "val", .uid = "rails://rake/val" },
        .{ .value = "plain" },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"uid\": \"rails://rake/val\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"uid\""));
}

test "export messages and usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "", .description = "no matches" },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "mycmd <file>");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"messages\": [\n    \"no matches\"\n  ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"usage\": \"mycmd <file>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"value\": \"\"") == null);
}

test "export sorts values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_]traverse.Candidate{
        .{ .value = "b" },
        .{ .value = "a" },
    };
    const out = try formatOutput(arena.allocator(), @constCast(&candidates), "");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"value\": \"a\"").? < std.mem.indexOf(u8, out, "\"value\": \"b\"").?);
}
