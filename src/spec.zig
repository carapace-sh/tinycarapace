const std = @import("std");
const yaml = @import("yaml.zig");
const Flag = @import("flag.zig").Flag;

pub const Command = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    aliases: []const []const u8 = &.{},
    hidden: bool = false,
    parsing: Parsing = .interspersed,
    flags: []Flag = &.{},
    persistent_flags: []Flag = &.{},
    commands: []Command = &.{},
    completion: Completion = .{},
    run: []const u8 = "",

    pub const Parsing = enum { interspersed, non_interspersed, disabled };

    pub const Completion = struct {
        flag: []const FlagCompletion = &.{},
        positional: []const []const []const u8 = &.{},
        positionalany: []const []const u8 = &.{},
    };

    pub const FlagCompletion = struct {
        name: []const u8,
        values: []const []const u8,
    };

    pub fn findSubcommand(self: Command, name: []const u8) ?Command {
        for (self.commands) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) return cmd;
            for (cmd.aliases) |alias| {
                if (std.mem.eql(u8, alias, name)) return cmd;
            }
        }
        return null;
    }

    pub fn findFlag(self: Command, name: []const u8) ?Flag {
        for (self.flags) |f| {
            if (f.matches(name)) return f;
        }
        for (self.persistent_flags) |f| {
            if (f.matches(name)) return f;
        }
        return null;
    }

    pub fn findFlagCompletion(self: Command, name: []const u8) ?[]const []const u8 {
        for (self.completion.flag) |fc| {
            if (std.mem.eql(u8, fc.name, name)) return fc.values;
        }
        return null;
    }
};

pub const SpecInfo = struct {
    name: []const u8,
    path: []const u8,
};

pub fn discoverSpecs(io: std.Io, environ: *const std.process.Environ.Map, allocator: std.mem.Allocator) ![]SpecInfo {
    var specs = std.ArrayList(SpecInfo).empty;

    // Parse CARAPACE_SPECS env var override
    if (environ.get("CARAPACE_SPECS")) |src| {
        if (src.len > 0) {
            var it = std.mem.splitScalar(u8, src, ':');
            while (it.next()) |pair| {
                if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                    const name = std.mem.trim(u8, pair[0..eq], " \t");
                    const path = std.mem.trim(u8, pair[eq + 1 ..], " \t");
                    if (name.len > 0 and path.len > 0) {
                        try specs.append(allocator, .{
                            .name = try allocator.dupe(u8, name),
                            .path = try allocator.dupe(u8, path),
                        });
                    }
                }
            }
        }
    }

    // System-wide specs
    try addSpecsFromDir(io, allocator, &specs, "/etc/carapace/specs");

    // User specs: $XDG_CONFIG_HOME/carapace/specs or ~/.config/carapace/specs
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        const user_specs = try std.fs.path.join(allocator, &.{ xdg, "carapace", "specs" });
        try addSpecsFromDir(io, allocator, &specs, user_specs);
    } else if (environ.get("HOME")) |home| {
        const user_specs = try std.fs.path.join(allocator, &.{ home, ".config", "carapace", "specs" });
        try addSpecsFromDir(io, allocator, &specs, user_specs);
    }

    return specs.toOwnedSlice(allocator);
}

fn addSpecsFromDir(io: std.Io, allocator: std.mem.Allocator, specs: *std.ArrayList(SpecInfo), dir_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name_slice = entry.name;
        if (name_slice.len < 6) continue;
        if (name_slice[0] == '.') continue;
        if (!std.mem.eql(u8, name_slice[name_slice.len - 5 ..], ".yaml")) continue;

        const stem = name_slice[0 .. name_slice.len - 5];
        // Skip variant files (e.g. "app.linux.yaml")
        if (std.mem.indexOfScalar(u8, stem, '.')) |_| continue;

        // Skip if already registered (env var takes precedence)
        if (findSpec(specs.items, stem)) |_| continue;

        // Validate file is readable (silently skip unreadable files)
        dir.access(io, name_slice, .{ .read = true }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => continue,
            else => return err,
        };

        try specs.append(allocator, .{
            .name = try allocator.dupe(u8, stem),
            .path = try std.fs.path.join(allocator, &.{ dir_path, name_slice }),
        });
    }
}

pub fn findSpec(specs: []SpecInfo, name: []const u8) ?SpecInfo {
    for (specs) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

pub fn loadSpec(allocator: std.mem.Allocator, src: []const u8) !Command {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const val = try yaml.parse(arena.allocator(), src);
    return decodeCommand(arena.allocator(), val);
}

fn decodeCommand(allocator: std.mem.Allocator, val: yaml.Value) !Command {
    var cmd = Command{};

    if (val.getScalar("name")) |name| cmd.name = name;
    if (val.getScalar("description")) |desc| cmd.description = desc;
    if (val.getScalar("hidden")) |hidden| {
        cmd.hidden = std.mem.eql(u8, hidden, "true");
    }
    if (val.getScalar("parsing")) |parsing| {
        if (std.mem.eql(u8, parsing, "disabled")) {
            cmd.parsing = .disabled;
        } else if (std.mem.eql(u8, parsing, "non-interspersed")) {
            cmd.parsing = .non_interspersed;
        }
    }
    if (val.getScalar("run")) |run| cmd.run = run;

    if (val.getList("aliases")) |aliases| {
        var arr = try allocator.alloc([]const u8, aliases.len);
        for (aliases, 0..) |a, i| {
            arr[i] = a.scalar;
        }
        cmd.aliases = arr;
    }

    if (val.getMap("flags")) |flags| {
        cmd.flags = try decodeFlags(allocator, flags);
    }
    if (val.getMap("persistentflags")) |flags| {
        cmd.persistent_flags = try decodeFlags(allocator, flags);
    }

    if (val.getList("commands")) |cmds| {
        var arr = try allocator.alloc(Command, cmds.len);
        for (cmds, 0..) |c, i| {
            arr[i] = try decodeCommand(allocator, c);
        }
        cmd.commands = arr;
    }

    if (val.get("completion")) |comp_val| {
        cmd.completion = try decodeCompletion(allocator, comp_val);
    }

    return cmd;
}

fn decodeFlags(allocator: std.mem.Allocator, flags: []yaml.Value.KV) ![]Flag {
    var arr = try allocator.alloc(Flag, flags.len);
    for (flags, 0..) |kv, i| {
        arr[i] = @import("flag.zig").parseFlag(kv.key, switch (kv.value) {
            .scalar => |s| s,
            else => "",
        });
    }
    return arr;
}

fn decodeCompletion(allocator: std.mem.Allocator, val: yaml.Value) !Command.Completion {
    var comp = Command.Completion{};

    if (val.getMap("flag")) |flag_map| {
        var arr = try allocator.alloc(Command.FlagCompletion, flag_map.len);
        for (flag_map, 0..) |kv, i| {
            const values = switch (kv.value) {
                .list => |l| blk: {
                    var v = try allocator.alloc([]const u8, l.len);
                    for (l, 0..) |item, j| v[j] = item.scalar;
                    break :blk v;
                },
                .scalar => |s| try allocator.dupe([]const u8, &.{s}),
                else => &.{},
            };
            arr[i] = .{ .name = kv.key, .values = values };
        }
        comp.flag = arr;
    }

    if (val.getList("positional")) |pos| {
        var arr = try allocator.alloc([]const []const u8, pos.len);
        for (pos, 0..) |p, i| {
            const list = p.list;
            var inner = try allocator.alloc([]const u8, list.len);
            for (list, 0..) |item, j| inner[j] = item.scalar;
            arr[i] = inner;
        }
        comp.positional = arr;
    }

    if (val.getList("positionalany")) |pos| {
        var arr = try allocator.alloc([]const u8, pos.len);
        for (pos, 0..) |p, i| arr[i] = p.scalar;
        comp.positionalany = arr;
    }

    return comp;
}

test "load spec" {
    const yaml_src =
        \\name: mycmd
        \\description: my command
        \\flags:
        \\  --verbose: verbose
        \\  -o, --output=: output file
        \\commands:
        \\  - name: sub
        \\    description: subcommand
        \\completion:
        \\  flag:
        \\    output: [file1, file2]
        \\  positional:
        \\    - [a, b]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try loadSpec(arena.allocator(), yaml_src);
    try std.testing.expectEqualStrings("mycmd", cmd.name);
    try std.testing.expectEqualStrings("my command", cmd.description);
    try std.testing.expectEqual(@as(usize, 2), cmd.flags.len);
    try std.testing.expectEqual(@as(usize, 1), cmd.commands.len);
    try std.testing.expectEqualStrings("sub", cmd.commands[0].name);
    try std.testing.expectEqual(@as(usize, 1), cmd.completion.flag.len);
    try std.testing.expectEqual(@as(usize, 1), cmd.completion.positional.len);
}
