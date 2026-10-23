const std = @import("std");
const yaml = @import("yaml.zig");
const Flag = @import("flag.zig").Flag;

pub const Command = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    aliases: []const []const u8 = &.{},
    group: []const u8 = "",
    hidden: bool = false,
    parsing: Parsing = .interspersed,
    flags: []Flag = &.{},
    persistent_flags: []Flag = &.{},
    exclusive_flags: []const []const []const u8 = &.{},
    commands: []Command = &.{},
    completion: Completion = .{},
    run: []const u8 = "",
    documentation: Documentation = .{},
    examples: []const Documentation.Example = &.{},
    parent: ?*const Command = null,

    pub const Parsing = enum { interspersed, non_interspersed, disabled };

    pub const Documentation = struct {
        command: []const u8 = "",
        flag: []const Documentation.FlagDoc = &.{},
        positional: []const []const u8 = &.{},
        positionalany: []const u8 = "",
        dash: []const []const u8 = &.{},
        dashany: []const u8 = "",

        pub const FlagDoc = struct {
            name: []const u8,
            description: []const u8,
        };

        pub const Example = struct {
            description: []const u8,
            command: []const u8,
        };
    };

    pub const Completion = struct {
        flag: []const FlagCompletion = &.{},
        positional: []const []const []const u8 = &.{},
        positionalany: []const []const u8 = &.{},
        dash: []const []const []const u8 = &.{},
        dashany: []const []const u8 = &.{},
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
        // Walk up parent chain for inherited flags: only persistent flags are inherited
        if (self.parent) |p| {
            for (p.persistent_flags) |f| {
                if (f.matches(name)) return f;
            }
            return findPersistentFlagInAncestors(p.parent, name);
        }
        return null;
    }

    /// Walk ancestors looking only at persistent flags.
    fn findPersistentFlagInAncestors(parent: ?*const Command, name: []const u8) ?Flag {
        var current = parent;
        while (current) |cmd| {
            for (cmd.persistent_flags) |f| {
                if (f.matches(name)) return f;
            }
            current = cmd.parent;
        }
        return null;
    }

    pub fn findFlagCompletion(self: Command, name: []const u8) ?[]const []const u8 {
        for (self.completion.flag) |fc| {
            if (std.mem.eql(u8, fc.name, name)) return fc.values;
        }
        if (self.parent) |p| {
            return p.findFlagCompletion(name);
        }
        return null;
    }
};

fn scalarOf(v: yaml.Value) []const u8 {
    return switch (v) {
        .scalar => |s| s,
        else => "",
    };
}

pub const Source = enum {
    explicit,
    user,
    system,
};

pub const SpecInfo = struct {
    name: []const u8,
    path: []const u8,
    source: Source,
};

pub const SpecDir = struct {
    path: []const u8,
    source: Source,
};

pub fn discoverSpecs(io: std.Io, environ: *const std.process.Environ.Map, allocator: std.mem.Allocator) ![]SpecInfo {
    var specs = std.ArrayList(SpecInfo).empty;

    // Explicit specs: CARAPACE_SPECS env var (name=path pairs)
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
                            .source = .explicit,
                        });
                    }
                }
            }
        }
    }

    const dirs = try computeSpecDirs(environ, allocator);
    for (dirs) |d| {
        try addSpecsFromDir(io, allocator, &specs, d.path, d.source);
    }

    return specs.toOwnedSlice(allocator);
}

// Priority order (first match wins):
//   1. user dir ($XDG_CONFIG_HOME/carapace/specs or platform fallback)
//   2. user dirs from CARAPACE_SPECS_PATH
//   3. system dirs from CARAPACE_SPECS_PATH
//   4. built-in system dirs (XDG data dirs or platform fallback)
pub fn computeSpecDirs(environ: *const std.process.Environ.Map, allocator: std.mem.Allocator) ![]SpecDir {
    var dirs = std.ArrayList(SpecDir).empty;

    const user_dir = try getUserSpecDir(environ, allocator);
    if (user_dir.len > 0) {
        try dirs.append(allocator, .{ .path = user_dir, .source = .user });
    }

    var env_dirs: []SpecDir = &.{};
    if (environ.get("CARAPACE_SPECS_PATH")) |src| {
        env_dirs = try parseSpecPath(allocator, src);
    }
    for (env_dirs) |d| {
        if (d.source == .user) try dirs.append(allocator, d);
    }
    for (env_dirs) |d| {
        if (d.source != .user) try dirs.append(allocator, d);
    }

    const builtin_dirs = try getSystemSpecDirs(environ, allocator);
    for (builtin_dirs) |d| {
        try dirs.append(allocator, d);
    }

    return dirs.toOwnedSlice(allocator);
}

// CARAPACE_SPECS_PATH is a path-list (platform path-list delimiter) where each
// entry may carry a classifier suffix: "@user" or "@system". Untagged entries
// default to system so package-managed dirs (nix, etc.) cannot override the
// user's own specs; "@user" elevates a dir to user precedence.
pub fn parseSpecPath(allocator: std.mem.Allocator, src: []const u8) ![]SpecDir {
    var dirs = std.ArrayList(SpecDir).empty;
    var it = std.mem.splitScalar(u8, src, std.fs.path.delimiter);
    while (it.next()) |raw| {
        var entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;
        var source: Source = .system;
        if (std.mem.endsWith(u8, entry, "@user")) {
            source = .user;
            entry = entry[0 .. entry.len - "@user".len];
        } else if (std.mem.endsWith(u8, entry, "@system")) {
            entry = entry[0 .. entry.len - "@system".len];
        }
        const path = std.mem.trim(u8, entry, " \t");
        if (path.len == 0) continue;
        try dirs.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .source = source,
        });
    }
    return dirs.toOwnedSlice(allocator);
}

fn getUserSpecDir(environ: *const std.process.Environ.Map, allocator: std.mem.Allocator) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return std.fs.path.join(allocator, &.{ xdg, "carapace", "specs" });
        }
    }
    const native_os = @import("builtin").os.tag;
    if (native_os == .windows) {
        if (environ.get("APPDATA")) |appdata| {
            if (appdata.len > 0) {
                return std.fs.path.join(allocator, &.{ appdata, "carapace", "specs" });
            }
        }
        return "";
    }
    const home = environ.get("HOME") orelse return "";
    if (native_os == .macos) {
        return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "carapace", "specs" });
    }
    return std.fs.path.join(allocator, &.{ home, ".config", "carapace", "specs" });
}

fn getSystemSpecDirs(environ: *const std.process.Environ.Map, allocator: std.mem.Allocator) ![]SpecDir {
    var dirs = std.ArrayList(SpecDir).empty;
    const native_os = @import("builtin").os.tag;
    if (native_os == .windows) {
        if (environ.get("ProgramData")) |pd| {
            if (pd.len > 0) {
                try dirs.append(allocator, .{
                    .path = try std.fs.path.join(allocator, &.{ pd, "carapace", "specs" }),
                    .source = .system,
                });
            }
        }
        return dirs.toOwnedSlice(allocator);
    }
    if (native_os == .macos) {
        try dirs.append(allocator, .{
            .path = "/Library/Application Support/carapace/specs",
            .source = .system,
        });
        return dirs.toOwnedSlice(allocator);
    }
    const data_dirs = environ.get("XDG_DATA_DIRS") orelse "";
    if (data_dirs.len > 0) {
        var it = std.mem.splitScalar(u8, data_dirs, std.fs.path.delimiter);
        while (it.next()) |dir| {
            const trimmed = std.mem.trim(u8, dir, " \t");
            if (trimmed.len == 0) continue;
            try dirs.append(allocator, .{
                .path = try std.fs.path.join(allocator, &.{ trimmed, "carapace", "specs" }),
                .source = .system,
            });
        }
    } else {
        for ([_][]const u8{ "/usr/local/share", "/usr/share" }) |base| {
            try dirs.append(allocator, .{
                .path = try std.fs.path.join(allocator, &.{ base, "carapace", "specs" }),
                .source = .system,
            });
        }
    }
    return dirs.toOwnedSlice(allocator);
}

fn addSpecsFromDir(io: std.Io, allocator: std.mem.Allocator, specs: *std.ArrayList(SpecInfo), dir_path: []const u8, source: Source) !void {
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

        // Skip if already registered (higher-priority source takes precedence)
        if (findSpec(specs.items, stem)) |_| continue;

        // Validate file is readable (silently skip unreadable files)
        dir.access(io, name_slice, .{ .read = true }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => continue,
            else => return err,
        };

        try specs.append(allocator, .{
            .name = try allocator.dupe(u8, stem),
            .path = try std.fs.path.join(allocator, &.{ dir_path, name_slice }),
            .source = source,
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
    // Parse and decode directly into the caller's allocator (usually an arena
    // owned by the caller); no intermediate arena is created.
    const val = try yaml.parse(allocator, src);
    return decodeCommand(allocator, val);
}

fn decodeCommand(allocator: std.mem.Allocator, val: yaml.Value) !Command {
    return decodeCommandWithParent(allocator, val, null);
}

fn decodeCommandWithParent(allocator: std.mem.Allocator, val: yaml.Value, parent: ?*const Command) !Command {
    // Allocate in arena so children can have stable parent pointers
    const cmd_ptr = try allocator.create(Command);
    cmd_ptr.* = Command{ .parent = parent };

    if (val.getScalar("name")) |name| cmd_ptr.name = name;
    if (val.getScalar("description")) |desc| cmd_ptr.description = desc;
    if (val.getScalar("hidden")) |hidden| {
        cmd_ptr.hidden = std.mem.eql(u8, hidden, "true");
    }
    if (val.getScalar("parsing")) |parsing| {
        if (std.mem.eql(u8, parsing, "disabled")) {
            cmd_ptr.parsing = .disabled;
        } else if (std.mem.eql(u8, parsing, "non-interspersed")) {
            cmd_ptr.parsing = .non_interspersed;
        }
    }
    if (val.getScalar("run")) |run| cmd_ptr.run = run;

    if (val.getScalar("group")) |group| cmd_ptr.group = group;

    if (val.getList("aliases")) |aliases| {
        var arr = try allocator.alloc([]const u8, aliases.len);
        for (aliases, 0..) |a, i| {
            arr[i] = scalarOf(a);
        }
        cmd_ptr.aliases = arr;
    }

    if (val.getMap("flags")) |flags| {
        cmd_ptr.flags = try decodeFlags(allocator, flags);
    }
    if (val.getMap("persistentflags")) |flags| {
        cmd_ptr.persistent_flags = try decodeFlags(allocator, flags);
    }

    if (val.getList("exclusiveflags")) |excl| {
        var arr = try allocator.alloc([]const []const u8, excl.len);
        for (excl, 0..) |group_val, i| {
            arr[i] = switch (group_val) {
                .list => |list| blk: {
                    var inner = try allocator.alloc([]const u8, list.len);
                    for (list, 0..) |item, j| inner[j] = scalarOf(item);
                    break :blk inner;
                },
                else => &.{},
            };
        }
        cmd_ptr.exclusive_flags = arr;
    }

    if (val.getList("commands")) |cmds| {
        var arr = try allocator.alloc(Command, cmds.len);
        for (cmds, 0..) |c, i| {
            arr[i] = try decodeCommandWithParent(allocator, c, cmd_ptr);
        }
        cmd_ptr.commands = arr;
    }

    if (val.get("completion")) |comp_val| {
        cmd_ptr.completion = try decodeCompletion(allocator, comp_val);
    }

    if (val.get("documentation")) |doc_val| {
        cmd_ptr.documentation = try decodeDocumentation(allocator, doc_val);
    }

    if (val.getMap("examples")) |examples| {
        var arr = try allocator.alloc(Command.Documentation.Example, examples.len);
        for (examples, 0..) |kv, i| {
            arr[i] = .{
                .description = kv.key,
                .command = switch (kv.value) {
                    .scalar => |s| s,
                    else => "",
                },
            };
        }
        cmd_ptr.examples = arr;
    }

    return cmd_ptr.*;
}

fn decodeFlags(allocator: std.mem.Allocator, flags: []yaml.Value.KV) ![]Flag {
    var arr = try allocator.alloc(Flag, flags.len);
    for (flags, 0..) |kv, i| {
        const desc = switch (kv.value) {
            .scalar => |s| s,
            .map => |m| blk: {
                // Extended notation: value is a map with description, nargs, default
                if (yaml.getScalarFromMap(m, "description")) |d| break :blk d;
                break :blk "";
            },
            else => "",
        };
        var f = @import("flag.zig").parseFlag(kv.key, desc);
        // Parse extended fields from map notation
        if (kv.value == .map) {
            const m = kv.value.map;
            if (yaml.getScalarFromMap(m, "nargs")) |nargs_str| {
                f.nargs = std.fmt.parseInt(i32, nargs_str, 10) catch 0;
            }
            if (yaml.getScalarFromMap(m, "default")) |default| {
                f.default = default;
            }
        }
        arr[i] = f;
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
                    for (l, 0..) |item, j| v[j] = scalarOf(item);
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
            arr[i] = switch (p) {
                .list => |list| blk: {
                    var inner = try allocator.alloc([]const u8, list.len);
                    for (list, 0..) |item, j| inner[j] = scalarOf(item);
                    break :blk inner;
                },
                // A scalar entry is a single action string (e.g. a chained
                // "[a, b] ||| $style(...)" expression).
                .scalar => |s| blk: {
                    var inner = try allocator.alloc([]const u8, 1);
                    inner[0] = s;
                    break :blk inner;
                },
                else => &.{},
            };
        }
        comp.positional = arr;
    }

    if (val.getList("positionalany")) |pos| {
        var arr = try allocator.alloc([]const u8, pos.len);
        for (pos, 0..) |p, i| arr[i] = switch (p) {
            .scalar => |s| s,
            else => "",
        };
        comp.positionalany = arr;
    }

    if (val.getList("dash")) |dash| {
        var arr = try allocator.alloc([]const []const u8, dash.len);
        for (dash, 0..) |d, i| {
            arr[i] = switch (d) {
                .list => |list| blk: {
                    var inner = try allocator.alloc([]const u8, list.len);
                    for (list, 0..) |item, j| inner[j] = scalarOf(item);
                    break :blk inner;
                },
                .scalar => |s| blk: {
                    var inner = try allocator.alloc([]const u8, 1);
                    inner[0] = s;
                    break :blk inner;
                },
                else => &.{},
            };
        }
        comp.dash = arr;
    }

    if (val.getList("dashany")) |dashany| {
        var arr = try allocator.alloc([]const u8, dashany.len);
        for (dashany, 0..) |d, i| arr[i] = scalarOf(d);
        comp.dashany = arr;
    }

    return comp;
}

fn decodeDocumentation(allocator: std.mem.Allocator, val: yaml.Value) !Command.Documentation {
    var doc = Command.Documentation{};

    if (val.getScalar("command")) |cmd_doc| doc.command = cmd_doc;

    if (val.getMap("flag")) |flag_map| {
        var arr = try allocator.alloc(Command.Documentation.FlagDoc, flag_map.len);
        for (flag_map, 0..) |kv, i| {
            arr[i] = .{
                .name = kv.key,
                .description = switch (kv.value) {
                    .scalar => |s| s,
                    else => "",
                },
            };
        }
        doc.flag = arr;
    }

    if (val.getList("positional")) |pos| {
        var arr = try allocator.alloc([]const u8, pos.len);
        for (pos, 0..) |p, i| arr[i] = scalarOf(p);
        doc.positional = arr;
    }

    if (val.getScalar("positionalany")) |pos| doc.positionalany = pos;

    if (val.getList("dash")) |dash| {
        var arr = try allocator.alloc([]const u8, dash.len);
        for (dash, 0..) |d, i| arr[i] = scalarOf(d);
        doc.dash = arr;
    }

    if (val.getScalar("dashany")) |dash| doc.dashany = dash;

    return doc;
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

test "non-scalar list entries decode as empty" {
    const yaml_src =
        \\name: mycmd
        \\aliases:
        \\  - {a: b}
        \\completion:
        \\  dashany: [{x: y}]
        \\  positionalany: [[q], r]
        \\documentation:
        \\  positional: [desc]
        \\  dash: [{t: u}]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try loadSpec(arena.allocator(), yaml_src);
    try std.testing.expectEqualStrings("", cmd.aliases[0]);
    try std.testing.expectEqualStrings("", cmd.completion.dashany[0]);
    try std.testing.expectEqualStrings("", cmd.completion.positionalany[0]);
    try std.testing.expectEqualStrings("", cmd.documentation.dash[0]);
    try std.testing.expectEqualStrings("desc", cmd.documentation.positional[0]);
}

test "parseSpecPath classifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dirs = try parseSpecPath(arena.allocator(), "/a@user:/b:/c@system");
    if (std.fs.path.delimiter == ':') {
        try std.testing.expectEqual(@as(usize, 3), dirs.len);
        try std.testing.expectEqualStrings("/a", dirs[0].path);
        try std.testing.expectEqual(Source.user, dirs[0].source);
        try std.testing.expectEqualStrings("/b", dirs[1].path);
        try std.testing.expectEqual(Source.system, dirs[1].source);
        try std.testing.expectEqualStrings("/c", dirs[2].path);
        try std.testing.expectEqual(Source.system, dirs[2].source);
    } else {
        // ';' separator: no '@' suffixes present in one entry
        try std.testing.expectEqual(@as(usize, 1), dirs.len);
        try std.testing.expectEqual(Source.system, dirs[0].source);
    }
}

test "computeSpecDirs precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try env.put("XDG_CONFIG_HOME", "/user/cfg");
    try env.put("XDG_DATA_DIRS", "/data1:/data2");
    try env.put("CARAPACE_SPECS_PATH", "/env/user@user:/env/sys");
    const dirs = try computeSpecDirs(&env, arena.allocator());
    try std.testing.expectEqual(@as(usize, 5), dirs.len);
    try std.testing.expectEqualStrings("/user/cfg/carapace/specs", dirs[0].path);
    try std.testing.expectEqual(Source.user, dirs[0].source);
    try std.testing.expectEqualStrings("/env/user", dirs[1].path);
    try std.testing.expectEqual(Source.user, dirs[1].source);
    try std.testing.expectEqualStrings("/env/sys", dirs[2].path);
    try std.testing.expectEqual(Source.system, dirs[2].source);
    try std.testing.expectEqualStrings("/data1/carapace/specs", dirs[3].path);
    try std.testing.expectEqual(Source.system, dirs[3].source);
    try std.testing.expectEqualStrings("/data2/carapace/specs", dirs[4].path);
}

test "computeSpecDirs default data dirs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const dirs = try computeSpecDirs(&env, arena.allocator());
    if (std.fs.path.delimiter == ':') {
        try std.testing.expectEqualStrings("/usr/local/share/carapace/specs", dirs[dirs.len - 2].path);
        try std.testing.expectEqualStrings("/usr/share/carapace/specs", dirs[dirs.len - 1].path);
        try std.testing.expectEqual(Source.system, dirs[dirs.len - 1].source);
    }
}

test "discoverSpecs precedence user over system" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const user_specs = try std.fmt.allocPrint(allocator, "{s}/user/carapace/specs", .{&tmp.sub_path});
    const sys_specs = try std.fmt.allocPrint(allocator, "{s}/sys/carapace/specs", .{&tmp.sub_path});
    try tmp.dir.createDirPath(std.testing.io, user_specs);
    try tmp.dir.createDirPath(std.testing.io, sys_specs);
    const user_dir = try tmp.dir.openDir(std.testing.io, user_specs, .{});
    defer user_dir.close(std.testing.io);
    const sys_dir = try tmp.dir.openDir(std.testing.io, sys_specs, .{});
    defer sys_dir.close(std.testing.io);

    const user_file = try user_dir.createFile(std.testing.io, "a.yaml", .{});
    try user_file.writeStreamingAll(std.testing.io, "\nname: a\n");
    user_file.close(std.testing.io);
    const shared_user_file = try user_dir.createFile(std.testing.io, "dupe.yaml", .{});
    try shared_user_file.writeStreamingAll(std.testing.io, "\nname: dupe\nuser\n");
    shared_user_file.close(std.testing.io);
    const sys_a_file = try sys_dir.createFile(std.testing.io, "b.yaml", .{});
    try sys_a_file.writeStreamingAll(std.testing.io, "\nname: b\n");
    sys_a_file.close(std.testing.io);
    const shared_sys_file = try sys_dir.createFile(std.testing.io, "dupe.yaml", .{});
    try shared_sys_file.writeStreamingAll(std.testing.io, "\nname: dupe\nsystem\n");
    shared_sys_file.close(std.testing.io);

    const user_config = try tmp.dir.realPathFileAlloc(std.testing.io, user_specs[0 .. user_specs.len - "carapace/specs".len], allocator);
    const sys_data = try tmp.dir.realPathFileAlloc(std.testing.io, sys_specs[0 .. sys_specs.len - "carapace/specs".len], allocator);

    var env = std.process.Environ.Map.init(allocator);
    try env.put("XDG_CONFIG_HOME", user_config);
    try env.put("XDG_DATA_DIRS", sys_data);

    const specs = try discoverSpecs(std.testing.io, &env, allocator);
    const a = findSpec(specs, "a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Source.user, a.source);
    const b = findSpec(specs, "b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Source.system, b.source);
    const dupe = findSpec(specs, "dupe") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Source.user, dupe.source);
    try std.testing.expectEqualStrings("\nname: dupe\nuser\n", try std.Io.Dir.cwd().readFileAlloc(std.testing.io, dupe.path, allocator, .limited(1024)));
}
