const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

/// Run an interactive REPL with completion for the given spec.
pub fn runRepl(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, environ_map: ?*const std.process.Environ.Map) !u8 {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    const stdin_fd = stdin.handle;
    const original_termios = std.posix.tcgetattr(stdin_fd) catch {
        return runSimpleRepl(allocator, io, cmd, environ_map);
    };
    defer _ = std.posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch {};

    var raw = original_termios;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);

    var line = std.ArrayList(u8).empty;
    var cursor: usize = 0;

    try stdout.writeStreamingAll(io, "> ");

    while (true) {
        var buf: [1]u8 = undefined;
        const n = try stdin.readStreaming(io, &.{&buf});
        if (n == 0) continue;
        const byte = buf[0];

        if (byte == '\t') {
            const cmdline = line.items;
            const args = try splitLine(allocator, cmdline);
            defer allocator.free(args);

            var full_cmdline = std.ArrayList([]const u8).empty;
            try full_cmdline.append(allocator, "cmd");
            for (args) |a| {
                try full_cmdline.append(allocator, a);
            }

            const partial = try getPartialWord(allocator, cmdline);
            defer allocator.free(partial);
            if (partial.len > 0) {
                try full_cmdline.append(allocator, partial);
            }

            const candidates = traverse.completeWithEnv(allocator, io, cmd, full_cmdline.items, environ_map) catch |err| {
                std.debug.print("completion error: {s}\n", .{@errorName(err)});
                continue;
            };

            if (candidates.len == 1) {
                const candidate = candidates[0].value;
                line.shrinkRetainingCapacity(line.items.len - partial.len);
                try line.appendSlice(allocator, candidate);
                if (!candidates[0].nospace) {
                    try line.append(allocator, ' ');
                }
                cursor = line.items.len;
                try stdout.writeStreamingAll(io, "\r> ");
                try stdout.writeStreamingAll(io, line.items);
                try stdout.writeStreamingAll(io, "  ");
                try stdout.writeStreamingAll(io, "\r> ");
                try stdout.writeStreamingAll(io, line.items);
            } else if (candidates.len > 1) {
                try stdout.writeStreamingAll(io, "\n");
                for (candidates, 0..) |c, i| {
                    const line_str = if (c.description.len > 0)
                        try std.fmt.allocPrint(allocator, "{}) {s} ({s})\n", .{ i + 1, c.value, c.description })
                    else
                        try std.fmt.allocPrint(allocator, "{}) {s}\n", .{ i + 1, c.value });
                    try stdout.writeStreamingAll(io, line_str);
                    allocator.free(line_str);
                }
                try stdout.writeStreamingAll(io, "> ");
                try stdout.writeStreamingAll(io, line.items);
            }
        } else if (byte == '\r' or byte == '\n') {
            try stdout.writeStreamingAll(io, "\n");
            if (line.items.len == 0) {
                try stdout.writeStreamingAll(io, "> ");
                continue;
            }
            const result = std.process.run(allocator, io, .{
                .argv = &.{ "sh", "-c", line.items },
                .stdout_limit = .limited(1024 * 1024),
                .stderr_limit = .limited(1024 * 1024),
            }) catch |err| {
                std.debug.print("exec error: {s}\n", .{@errorName(err)});
                try stdout.writeStreamingAll(io, "> ");
                line.clearAndFree(allocator);
                cursor = 0;
                continue;
            };
            try stdout.writeStreamingAll(io, result.stdout);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            line.clearAndFree(allocator);
            cursor = 0;
            try stdout.writeStreamingAll(io, "> ");
        } else if (byte == '\x03' or byte == '\x04') {
            try stdout.writeStreamingAll(io, "\n");
            return 0;
        } else if (byte == '\x7f') {
            if (cursor > 0) {
                cursor -= 1;
                _ = line.orderedRemove(cursor);
                try stdout.writeStreamingAll(io, "\r> ");
                try stdout.writeStreamingAll(io, line.items);
                try stdout.writeStreamingAll(io, "   ");
                try stdout.writeStreamingAll(io, "\r> ");
                try stdout.writeStreamingAll(io, line.items);
            }
        } else if (byte >= 0x20 and byte <= 0x7e) {
            try line.insert(allocator, cursor, byte);
            cursor += 1;
            try stdout.writeStreamingAll(io, "\r> ");
            try stdout.writeStreamingAll(io, line.items);
            try stdout.writeStreamingAll(io, " ");
            try stdout.writeStreamingAll(io, "\r> ");
            try stdout.writeStreamingAll(io, line.items);
        }
    }

    return 0;
}

fn runSimpleRepl(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, environ_map: ?*const std.process.Environ.Map) !u8 {
    _ = cmd;
    _ = environ_map;
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    var buf: [4096]u8 = undefined;
    while (true) {
        try stdout.writeStreamingAll(io, "> ");
        const n = try stdin.readStreaming(io, &.{&buf});
        if (n == 0) break;
        const line = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) break;
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "sh", "-c", line },
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| {
            std.debug.print("exec error: {s}\n", .{@errorName(err)});
            continue;
        };
        try stdout.writeStreamingAll(io, result.stdout);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return 0;
}

fn splitLine(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var args = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, line, ' ');
    while (it.next()) |arg| {
        const trimmed = std.mem.trim(u8, arg, " \t");
        if (trimmed.len > 0) {
            try args.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return args.toOwnedSlice(allocator);
}

fn getPartialWord(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return try allocator.dupe(u8, "");
    if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |space| {
        return try allocator.dupe(u8, trimmed[space + 1 ..]);
    }
    return try allocator.dupe(u8, trimmed);
}

test "split line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try splitLine(arena.allocator(), "hello world test");
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("hello", args[0]);
    try std.testing.expectEqualStrings("world", args[1]);
    try std.testing.expectEqualStrings("test", args[2]);
}

test "get partial word from middle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial = try getPartialWord(arena.allocator(), "hello wor");
    try std.testing.expectEqualStrings("wor", partial);
}

test "get partial word at start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial = try getPartialWord(arena.allocator(), "hel");
    try std.testing.expectEqualStrings("hel", partial);
}

test "get partial word empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial = try getPartialWord(arena.allocator(), "  ");
    try std.testing.expectEqualStrings("", partial);
}