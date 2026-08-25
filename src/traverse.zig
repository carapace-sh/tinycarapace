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
        try addFlagCandidate(allocator, &candidates, f, prefix);
    }

    for (cmd.persistent_flags) |f| {
        if (f.hidden) continue;
        try addFlagCandidate(allocator, &candidates, f, prefix);
    }

    return candidates.toOwnedSlice(allocator);
}

fn addFlagCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList(Candidate), f: Flag, prefix: []const u8) !void {
    if (f.longhand.len > 0) {
        const form = try std.fmt.allocPrint(allocator, "--{s}", .{f.longhand});
        if (std.mem.startsWith(u8, form, prefix)) {
            try candidates.append(allocator, .{ .value = form, .description = f.description });
        } else {
            allocator.free(form);
        }
    }
    if (f.shorthand.len > 0) {
        const form = try std.fmt.allocPrint(allocator, "-{s}", .{f.shorthand});
        if (std.mem.startsWith(u8, form, prefix)) {
            try candidates.append(allocator, .{ .value = form, .description = f.description });
        } else {
            allocator.free(form);
        }
    }
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
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--verbose", result[0].value);
    try std.testing.expectEqualStrings("--output", result[1].value);
}

test "complete flag names with shorthand prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --verbose: verbose
        \\  -o, --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "-" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("--verbose", result[0].value);
    try std.testing.expectEqualStrings("--output", result[1].value);
    try std.testing.expectEqualStrings("-o", result[2].value);
}

test "complete flag names filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --verbose: verbose
        \\  --version: show version
        \\  --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--ver" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--verbose", result[0].value);
    try std.testing.expectEqualStrings("--version", result[1].value);
}

test "complete flag names excludes hidden flags" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --visible: visible flag
        \\  --hidden&: hidden flag
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("--visible", result[0].value);
}

test "complete flag value after space" {
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
    try std.testing.expectEqualStrings("file2", result[1].value);
}

test "complete flag value with --flag= prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --output=: output file
        \\completion:
        \\  flag:
        \\    output: [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--output=fi" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("file1", result[0].value);
    try std.testing.expectEqualStrings("file2", result[1].value);
}

test "complete flag value with longhand" {
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
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--output", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("file1", result[0].value);
}

test "complete flag value with description" {
    const yaml_src =
        "name: mycmd\n" ++
        "flags:\n" ++
        "  --format=: output format\n" ++
        "completion:\n" ++
        "  flag:\n" ++
        "    format: [json\tJSON, yaml\tYAML, toml\tTOML]\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--format", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("json", result[0].value);
    try std.testing.expectEqualStrings("JSON", result[0].description);
    try std.testing.expectEqualStrings("yaml", result[1].value);
    try std.testing.expectEqualStrings("YAML", result[1].description);
    try std.testing.expectEqualStrings("toml", result[2].value);
    try std.testing.expectEqualStrings("TOML", result[2].description);
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
    try std.testing.expectEqualStrings("first", result[0].description);
    try std.testing.expectEqualStrings("sub2", result[1].value);
    try std.testing.expectEqualStrings("second", result[1].description);
}

test "complete subcommands filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    description: build the project
        \\  - name: run
        \\    description: run the project
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "b" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("build", result[0].value);
}

test "complete subcommands excludes hidden" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: visible
        \\    description: visible subcommand
        \\  - name: hidden
        \\    hidden: true
        \\    description: hidden subcommand
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("visible", result[0].value);
}

test "complete nested subcommand" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub
        \\    commands:
        \\      - name: subsub1
        \\        description: first nested
        \\      - name: subsub2
        \\        description: second nested
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "sub", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("subsub1", result[0].value);
    try std.testing.expectEqualStrings("subsub2", result[1].value);
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

test "complete positionalany" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positionalany: [unit, integration, e2e]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("unit", result[0].value);
    try std.testing.expectEqualStrings("integration", result[1].value);
    try std.testing.expectEqualStrings("e2e", result[2].value);
}

test "complete positionalany after positional consumed" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positional:
        \\    - [first, second]
        \\  positionalany: [any1, any2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "first", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("any1", result[0].value);
    try std.testing.expectEqualStrings("any2", result[1].value);
}

test "complete subcommand and positional batch" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    description: build it
        \\completion:
        \\  positional:
        \\    - [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("build", result[0].value);
    try std.testing.expectEqualStrings("file1", result[1].value);
    try std.testing.expectEqualStrings("file2", result[2].value);
}

test "complete flag value in subcommand" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    flags:
        \\      --target=: target triple
        \\    completion:
        \\      flag:
        \\        target: [x86_64-linux, aarch64-linux]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "build", "--target", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("x86_64-linux", result[0].value);
    try std.testing.expectEqualStrings("aarch64-linux", result[1].value);
}

test "complete flags in subcommand does not inherit parent persistent flags" {
    // Known limitation: persistent flags are NOT inherited from ancestor commands.
    // Only persistent_flags defined on the current command are visible via findFlag().
    const yaml_src =
        \\name: mycmd
        \\persistentflags:
        \\  -v, --verbose: verbose
        \\commands:
        \\  - name: build
        \\    flags:
        \\      --target=: target triple
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "build", "--" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("--target", result[0].value);
}

test "complete flags after consuming persistent flag value" {
    const yaml_src =
        \\name: mycmd
        \\persistentflags:
        \\  --config=: config file
        \\commands:
        \\  - name: build
        \\    flags:
        \\      --target=: target triple
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--config", "/etc/app.conf", "build", "--" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("--target", result[0].value);
}

test "complete positional after flag" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --bool: bool flag
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--bool", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
    try std.testing.expectEqualStrings("three", result[2].value);
}

test "complete positional after flag with value" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--format", "json", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
}

test "complete after dash disables flag parsing" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --bool: bool flag
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--", "-" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete positional after dash" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --bool: bool flag
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
    try std.testing.expectEqualStrings("three", result[2].value);
}

test "complete subcommand with disabled parsing" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub
        \\    parsing: disabled
        \\    flags:
        \\      --flag: a flag
        \\    completion:
        \\      positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "sub", "--" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete subcommand with disabled parsing shows positionals for empty string" {
    // With parsing disabled, flag_parsing is false, so -- is not treated as a flag prefix.
    // It becomes a positional value prefix, but no positional values start with --.
    // Use empty string to verify positionals still work with disabled parsing.
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub
        \\    parsing: disabled
        \\    completion:
        \\      positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "sub", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
    try std.testing.expectEqualStrings("three", result[2].value);
}

test "complete repeatable flag shown again" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --repeatable*: repeatable flag
        \\  --other: other flag
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--repeatable", "--" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--repeatable", result[0].value);
    try std.testing.expectEqualStrings("--other", result[1].value);
}

test "complete optarg flag as bare name" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --optarg?: optional argument flag
        \\  --normal: normal flag
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--optarg", result[0].value);
    try std.testing.expectEqualStrings("--normal", result[1].value);
}

test "complete flag value via attached equals" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--format=" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("json", result[0].value);
    try std.testing.expectEqualStrings("yaml", result[1].value);
}

test "complete flag value via attached equals with prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--format=ya" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("yaml", result[0].value);
}

test "complete no candidates for unknown flag value" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--unknown", "" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete empty command returns nothing" {
    const yaml_src =
        \\name: mycmd
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete only command name returns nothing" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{"mycmd"});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete no args returns nothing" {
    const yaml_src =
        \\name: mycmd
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete subcommand via alias enters subcommand" {
    // Aliases are used for subcommand matching during traversal but not completed.
    // Entering via alias 'b' resolves to 'build' subcommand, which has no completions.
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    aliases: [b, bu]
        \\    description: build the project
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "b", "" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete flag value filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --color=: color
        \\completion:
        \\  flag:
        \\    color: [red, green, blue]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--color", "b" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("blue", result[0].value);
}

test "complete positional filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positional:
        \\    - [apple, banana, cherry]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "a" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("apple", result[0].value);
}

test "complete positionalany filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positionalany: [unit, integration, e2e]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "e" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("e2e", result[0].value);
}

test "complete second positional position" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positional:
        \\    - [src, dst]
        \\    - [fast, slow]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "src", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("fast", result[0].value);
    try std.testing.expectEqualStrings("slow", result[1].value);
}

test "complete flag value via attached equals for longhand only" {
    // Shorthand attached equals (-f=value) is not handled by the traversal engine.
    // Only longhand --flag=value is supported for attached value completion.
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -f, --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), cmd, &.{ "mycmd", "--format=ya" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("yaml", result[0].value);
}
