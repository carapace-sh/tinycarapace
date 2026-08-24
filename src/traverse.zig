const std = @import("std");
const spec = @import("spec.zig");
const Flag = @import("flag.zig").Flag;

pub const Candidate = struct {
    value: []const u8,
    description: []const u8 = "",
};

pub const Context = struct {
    cmd: spec.Command,
    args: []const []const u8,
    value: []const u8,
    flag_values: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, cmd: spec.Command, args: []const []const u8, value: []const u8) Context {
        return .{
            .cmd = cmd,
            .args = args,
            .value = value,
            .flag_values = std.StringHashMap([]const u8).init(allocator),
        };
    }
};

pub fn complete(allocator: std.mem.Allocator, root: spec.Command, cmdline: []const []const u8) ![]Candidate {
    if (cmdline.len == 0) return &.{};

    // First arg is the command name itself — skip it
    const cmdline_args = if (cmdline.len > 1) cmdline[1..] else cmdline[0..0];
    if (cmdline_args.len == 0) return &.{};

    const args = cmdline_args[0 .. cmdline_args.len - 1];
    const value = cmdline_args[cmdline_args.len - 1];

    var current = root;
    var in_flag: ?Flag = null;
    var positional_count: usize = 0;
    var dash = false;
    var flag_parsing = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (in_flag) |_| {
            in_flag = null;
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            dash = true;
            flag_parsing = false;
            continue;
        }

        if (flag_parsing and arg.len > 0 and arg[0] == '-') {
            if (arg.len > 1 and arg[1] == '-') {
                if (std.mem.indexOfScalar(u8, arg, '=')) |_| {
                    continue;
                }
                const name = arg[2..];
                if (current.findFlag(name)) |f| {
                    if (f.takes_value and !f.optarg) {
                        in_flag = f;
                    }
                }
            } else {
                const name = arg[1..];
                if (current.findFlag(name)) |f| {
                    if (f.takes_value and !f.optarg) {
                        in_flag = f;
                    }
                }
            }
            continue;
        }

        if (!dash) {
            if (current.findSubcommand(arg)) |sub| {
                current = sub;
                positional_count = 0;
                if (current.parsing == .disabled) flag_parsing = false;
                continue;
            }
        }

        positional_count += 1;
    }

    var ctx = Context.init(allocator, current, args, value);
    _ = &ctx;

    if (in_flag) |f| {
        return completeFlagValue(allocator, current, f, value);
    }

    if (value.len > 0 and value[0] == '-' and flag_parsing) {
        if (value.len > 1 and value[1] == '-') {
            if (std.mem.indexOfScalar(u8, value, '=')) |eq| {
                const flag_name = value[2..eq];
                const prefix = value[eq + 1 ..];
                return completeFlagValueWithPrefix(allocator, current, flag_name, prefix);
            }
            return completeFlags(allocator, current, value);
        }
        return completeFlags(allocator, current, value);
    }

    if (!dash and current.commands.len > 0 and positional_count == 0) {
        var candidates = std.ArrayList(Candidate).empty;
        for (current.commands) |cmd| {
            if (!cmd.hidden and std.mem.startsWith(u8, cmd.name, value)) {
                try candidates.append(allocator, .{ .value = cmd.name, .description = cmd.description });
            }
        }
        if (current.completion.positional.len > 0) {
            const pos = current.completion.positional[0];
            for (pos) |v| {
                if (std.mem.startsWith(u8, v, value)) {
                    try candidates.append(allocator, .{ .value = v });
                }
            }
        }
        return candidates.toOwnedSlice(allocator);
    }

    if (positional_count < current.completion.positional.len) {
        const pos = current.completion.positional[positional_count];
        var candidates = std.ArrayList(Candidate).empty;
        for (pos) |v| {
            if (std.mem.startsWith(u8, v, value)) {
                try candidates.append(allocator, .{ .value = v });
            }
        }
        return candidates.toOwnedSlice(allocator);
    }

    if (current.completion.positionalany.len > 0) {
        var candidates = std.ArrayList(Candidate).empty;
        for (current.completion.positionalany) |v| {
            if (std.mem.startsWith(u8, v, value)) {
                try candidates.append(allocator, .{ .value = v });
            }
        }
        return candidates.toOwnedSlice(allocator);
    }

    return &.{};
}

fn completeFlags(allocator: std.mem.Allocator, cmd: spec.Command, prefix: []const u8) ![]Candidate {
    var candidates = std.ArrayList(Candidate).empty;

    for (cmd.flags) |f| {
        if (f.hidden) continue;
        var buf: [128]u8 = undefined;
        const display = f.display(&buf);
        if (display.len > 0 and std.mem.startsWith(u8, display, prefix)) {
            const owned = try allocator.dupe(u8, display);
            try candidates.append(allocator, .{ .value = owned, .description = f.description });
        }
    }

    for (cmd.persistent_flags) |f| {
        if (f.hidden) continue;
        var buf: [128]u8 = undefined;
        const display = f.display(&buf);
        if (display.len > 0 and std.mem.startsWith(u8, display, prefix)) {
            const owned = try allocator.dupe(u8, display);
            try candidates.append(allocator, .{ .value = owned, .description = f.description });
        }
    }

    return candidates.toOwnedSlice(allocator);
}

fn completeFlagValue(allocator: std.mem.Allocator, cmd: spec.Command, f: Flag, value: []const u8) ![]Candidate {
    const values = cmd.findFlagCompletion(f.name()) orelse return &.{};
    var candidates = std.ArrayList(Candidate).empty;
    for (values) |v| {
        const desc_split = std.mem.splitScalar(u8, v, '\t');
        var it = desc_split;
        const val = it.first();
        const desc = if (it.next()) |d| d else "";
        if (std.mem.startsWith(u8, val, value)) {
            try candidates.append(allocator, .{ .value = val, .description = desc });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

fn completeFlagValueWithPrefix(allocator: std.mem.Allocator, cmd: spec.Command, flag_name: []const u8, prefix: []const u8) ![]Candidate {
    const values = cmd.findFlagCompletion(flag_name) orelse return &.{};
    var candidates = std.ArrayList(Candidate).empty;
    for (values) |v| {
        const desc_split = std.mem.splitScalar(u8, v, '\t');
        var it = desc_split;
        const val = it.first();
        const desc = if (it.next()) |d| d else "";
        if (std.mem.startsWith(u8, val, prefix)) {
            try candidates.append(allocator, .{ .value = val, .description = desc });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

test "complete flag names" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --verbose: verbose
        \\  -o, --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("--verbose", result[0].value);
}

test "complete subcommands" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub1
        \\    description: first
        \\  - name: sub2
        \\    description: second
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("sub1", result[0].value);
}

test "complete flag value" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -o, --output=: output file
        \\completion:
        \\  flag:
        \\    output: [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "-o", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("file1", result[0].value);
}

test "complete positional" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positional:
        \\    - [a, b, c]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
}
