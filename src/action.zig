const std = @import("std");
const traverse = @import("traverse.zig");

pub fn resolveMacro(allocator: std.mem.Allocator, io: std.Io, macro: []const u8) ![]traverse.Candidate {
    // Handle exec macros: $sh(command), $bash(command), $pwsh(command)
    // Run the command via the specified shell and use stdout lines as candidates.
    const exec_macro = comptime [_]struct { prefix: []const u8, shell: []const u8 }{
        .{ .prefix = "$sh(", .shell = "sh" },
        .{ .prefix = "$bash(", .shell = "bash" },
        .{ .prefix = "$pwsh(", .shell = "pwsh" },
    };
    inline for (exec_macro) |em| {
        if (macro.len >= em.prefix.len + 1 and std.mem.startsWith(u8, macro, em.prefix) and macro[macro.len - 1] == ')') {
            const command = macro[em.prefix.len .. macro.len - 1];
            if (command.len > 0) {
                return try execCommand(allocator, io, em.shell, command);
            }
            return &.{};
        }
    }

    // Plain static value (no macro prefix)
    const val = std.mem.trim(u8, macro, " \t");
    if (val.len > 0) {
        const parsed = traverse.splitValue(val);
        var candidates = std.ArrayList(traverse.Candidate).empty;
        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, parsed.value),
            .description = try allocator.dupe(u8, parsed.description),
            .style = try allocator.dupe(u8, parsed.style),
        });
        return candidates.toOwnedSlice(allocator);
    }
    return &.{};
}

fn execCommand(allocator: std.mem.Allocator, io: std.Io, shell: []const u8, command: []const u8) ![]traverse.Candidate {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ shell, "-c", command },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
    }) catch |err| switch (err) {
        error.StreamTooLong => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            const parsed = traverse.splitValue(trimmed);
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, parsed.value),
                .description = try allocator.dupe(u8, parsed.description),
                .style = try allocator.dupe(u8, parsed.style),
            });
        }
    }

    return candidates.toOwnedSlice(allocator);
}

test "exec macro returns command output lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo one; echo two)");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}

test "exec macro handles empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(true)");
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "static value returns itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "hello");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("hello", candidates[0].value);
}

test "static value with description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "hello\tgreeting");
    // splitValue should handle tab-separated description
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("hello", candidates[0].value);
    try std.testing.expectEqualStrings("greeting", candidates[0].description);
}

test "exec macro with tab-separated descriptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(printf 'one\tfirst\\ntwo\tsecond')");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("first", candidates[0].description);
    try std.testing.expectEqualStrings("two", candidates[1].value);
    try std.testing.expectEqualStrings("second", candidates[1].description);
}