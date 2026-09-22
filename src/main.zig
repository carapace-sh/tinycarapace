const std = @import("std");
const spec = @import("spec.zig");
const traverse = @import("traverse.zig");
const bash = @import("shell/bash.zig");
const zsh = @import("shell/zsh.zig");
const fish = @import("shell/fish.zig");
const powershell = @import("shell/powershell.zig");
const export_shell = @import("shell/export.zig");
const action = @import("action.zig");

/// Load a spec or return null if not found.
fn loadSpecOrNull(allocator: std.mem.Allocator, io: std.Io, name: []const u8, environ_map: *const std.process.Environ.Map) !?spec.Command {
    const specs = try spec.discoverSpecs(io, environ_map, allocator);
    const spec_info = spec.findSpec(specs, name) orelse return null;
    const content = std.Io.Dir.cwd().readFileAlloc(io, spec_info.path, allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(content);
    return spec.loadSpec(allocator, content) catch return null;
}

/// Build completion candidates, falling back to bridges if no spec is found.
/// `cmdline_args` includes the command name as the first element (like traverse.complete expects).
fn completeWithFallback(allocator: std.mem.Allocator, io: std.Io, name: []const u8, cmdline_args: []const []const u8, environ_map: *const std.process.Environ.Map) ![]traverse.Candidate {
    if (try loadSpecOrNull(allocator, io, name, environ_map)) |cmd| {
        return try traverse.completeWithEnv(allocator, io, cmd, cmdline_args, environ_map);
    }
    // No spec found — try CARAPACE_BRIDGES fallback
    if (environ_map.get("CARAPACE_BRIDGES")) |bridges| {
        var bridge_names = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, bridges, ',');
        while (it.next()) |b| {
            const trimmed = std.mem.trim(u8, b, " \t");
            if (trimmed.len > 0) try bridge_names.append(allocator, trimmed);
        }
        // cmdline_args[0] is the command name, rest are consumed args + partial word
        const consumed_args = if (cmdline_args.len > 2) cmdline_args[1 .. cmdline_args.len - 1] else &.{};
        const prefix = if (cmdline_args.len > 1) cmdline_args[cmdline_args.len - 1] else "";
        return try traverse.resolveBridgeFallback(allocator, io, name, consumed_args, prefix, bridge_names.items, environ_map);
    }
    return &.{};
}

/// Execute a command's `run` field.
/// Supports: alias strings, macro ($(...)), and scripts (#!/...)
fn runCommand(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, extra_args: *const std.ArrayList([]const u8), environ_map: ?*const std.process.Environ.Map) !u8 {
    const run = cmd.run;

    // Script mode: starts with #!
    if (run.len >= 2 and run[0] == '#' and run[1] == '!') {
        // Write script to an exclusive temp file, run it, clean up
        const tmp_dir = if (environ_map) |env| env.get("TMPDIR") orelse "/tmp" else "/tmp";
        // Unique-enough suffix: wall-clock nanoseconds (createFile uses
        // .exclusive, so collisions fail safely rather than clobbering).
        const now = std.Io.Timestamp.now(io, .real);
        const suffix: u64 = @intCast(@mod(now.nanoseconds, 1 << 32));
        const script_name = try std.fmt.allocPrint(allocator, "tinycarapace-run-{x}.sh", .{suffix});
        defer allocator.free(script_name);
        const script_path = try std.fs.path.join(allocator, &.{ tmp_dir, script_name });
        defer allocator.free(script_path);

        var script_file = std.Io.Dir.cwd().createFile(io, script_path, .{ .exclusive = true }) catch {
            std.debug.print("error: cannot create temp script\n", .{});
            return 1;
        };
        script_file.writeStreamingAll(io, run) catch {
            script_file.close(io);
            std.Io.Dir.cwd().deleteFile(io, script_path) catch {};
            std.debug.print("error: cannot write temp script\n", .{});
            return 1;
        };
        script_file.close(io);
        defer std.Io.Dir.cwd().deleteFile(io, script_path) catch {};

        // Build argv: sh script_path <extra_args>
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(allocator, "sh");
        try argv.append(allocator, script_path);
        for (extra_args.items) |a| try argv.append(allocator, a);

        const result = std.process.run(allocator, io, .{
            .argv = argv.items,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .environ_map = environ_map,
        }) catch |err| {
            std.debug.print("error: script execution failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        std.Io.File.stdout().writeStreamingAll(io, result.stdout) catch {};
        if (result.stderr.len > 0) std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return 0;
    }

    // Macro mode: starts with $(
    if (run.len >= 2 and run[0] == '$' and run[1] == '(') {
        if (run[run.len - 1] == ')') {
            const command = run[2 .. run.len - 1];
            if (command.len > 0) {
                // Expand variables in the command
                var flag_values = std.StringHashMap([]const u8).init(allocator);
                var positional_args = std.ArrayList([]const u8).empty;
                for (extra_args.items, 0..) |a, i| {
                    try positional_args.append(allocator, a);
                    const key = try std.fmt.allocPrint(allocator, "C_ARG{d}", .{i});
                    try flag_values.put(key, a);
                }

                const expanded = try traverse.expandVariables(allocator, command, &flag_values, positional_args.items, "");
                defer allocator.free(expanded);

                const result = std.process.run(allocator, io, .{
                    .argv = &.{ "sh", "-c", expanded },
                    .stdout_limit = .limited(1024 * 1024),
                    .stderr_limit = .limited(1024 * 1024),
                    .environ_map = environ_map,
                }) catch |err| {
                    std.debug.print("error: macro execution failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                std.Io.File.stdout().writeStreamingAll(io, result.stdout) catch {};
                if (result.stderr.len > 0) std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
                allocator.free(result.stdout);
                allocator.free(result.stderr);
                return 0;
            }
        }
    }

    // Alias mode: JSON array string like "[tail, --lines, '${NUM:-1}']" or plain string like "tail -f"
    // Parse as space-separated or JSON array
    var argv = std.ArrayList([]const u8).empty;

    if (run.len >= 2 and run[0] == '[') {
        // JSON array format: parse it
        const items = try parseRunArgs(allocator, run);
        defer allocator.free(items);
        for (items) |item| {
            // Expand variables in each arg
            var flag_values = std.StringHashMap([]const u8).init(allocator);
            var positional_args = std.ArrayList([]const u8).empty;
            for (extra_args.items, 0..) |a, i| {
                try positional_args.append(allocator, a);
                const key = try std.fmt.allocPrint(allocator, "C_ARG{d}", .{i});
                try flag_values.put(key, a);
            }
            const expanded = try traverse.expandVariables(allocator, item, &flag_values, positional_args.items, "");
            defer allocator.free(expanded);
            // Store a stable copy: `expanded` is freed at the end of this iteration
            try argv.append(allocator, try allocator.dupe(u8, expanded));
        }
    } else {
        // Plain string: space-separated
        var it = std.mem.splitScalar(u8, run, ' ');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len > 0) {
                try argv.append(allocator, try allocator.dupe(u8, trimmed));
            }
        }
    }

    // Append extra args
    for (extra_args.items) |a| try argv.append(allocator, a);

    if (argv.items.len == 0) {
        std.debug.print("error: empty run command\n", .{});
        return 1;
    }

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .environ_map = environ_map,
    }) catch |err| {
        std.debug.print("error: command execution failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.Io.File.stdout().writeStreamingAll(io, result.stdout) catch {};
    if (result.stderr.len > 0) std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return 0;
}

/// Parse a JSON array of string arguments: `[tail, --lines, '${NUM:-1}']`
fn parseRunArgs(allocator: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, src, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return &.{};
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return &.{};

    var items = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == ',')) : (i += 1) {}
        if (i >= inner.len) break;

        if (inner[i] == '"' or inner[i] == '\'') {
            const quote = inner[i];
            i += 1;
            var buf = std.ArrayList(u8).empty;
            while (i < inner.len and inner[i] != quote) {
                if (inner[i] == '\\' and i + 1 < inner.len) {
                    i += 1;
                    try buf.append(allocator, inner[i]);
                    i += 1;
                } else {
                    try buf.append(allocator, inner[i]);
                    i += 1;
                }
            }
            try items.append(allocator, buf.items);
            if (i < inner.len) i += 1;
        } else {
            const start = i;
            while (i < inner.len and inner[i] != ',' and inner[i] != ']' and inner[i] != ' ') : (i += 1) {}
            const raw = std.mem.trim(u8, inner[start..i], " \t");
            if (raw.len > 0) try items.append(allocator, try allocator.dupe(u8, raw));
        }
    }
    return items.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: carapace-tiny _carapace [bash] | <name> (bash|run|export) [<name> <args...>]\n", .{});
        return 1;
    }

    // carapace-tiny _carapace [bash|zsh|fish|powershell] → init script
    if (std.mem.eql(u8, std.mem.span(argv[1]), "_carapace")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const specs = try spec.discoverSpecs(init.io, init.environ_map, arena.allocator());
        if (specs.len == 0) return 0;

        const shell_name = if (argv.len >= 3) std.mem.span(argv[2]) else "bash";
        const init_shells = comptime [_]struct { name: []const u8, mod: type }{
            .{ .name = "bash", .mod = bash },
            .{ .name = "zsh", .mod = zsh },
            .{ .name = "fish", .mod = fish },
            .{ .name = "powershell", .mod = powershell },
        };
        inline for (init_shells) |s| {
            if (std.mem.eql(u8, shell_name, s.name)) {
                const script = try s.mod.generateInitScript(arena.allocator(), specs);
                std.Io.File.stdout().writeStreamingAll(init.io, script) catch {};
                return 0;
            }
        }
        std.debug.print("error: unknown shell: {s}\n", .{shell_name});
        return 1;
    }

    const name = std.mem.span(argv[1]);

    // carapace-tiny <name> export [<args...>]
    if (argv.len >= 3 and std.mem.eql(u8, std.mem.span(argv[2]), "export")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var cmdline_args: std.ArrayList([]const u8) = .empty;
        if (argv.len > 3) {
            for (argv[3..]) |a| {
                try cmdline_args.append(arena.allocator(), std.mem.span(a));
            }
        }

        const candidates = try completeWithFallback(arena.allocator(), init.io, name, cmdline_args.items, init.environ_map);
        const out = try export_shell.formatOutput(arena.allocator(), candidates);
        std.Io.File.stdout().writeStreamingAll(init.io, out) catch {};
        return 0;
    }

    // carapace-tiny <name> (bash|zsh|fish|powershell) [<name> <args...>]
    const shells = comptime [_]struct { name: []const u8, mod: type }{
        .{ .name = "bash", .mod = bash },
        .{ .name = "zsh", .mod = zsh },
        .{ .name = "fish", .mod = fish },
        .{ .name = "powershell", .mod = powershell },
    };

    inline for (shells) |shell| {
        if (argv.len >= 3 and std.mem.eql(u8, std.mem.span(argv[2]), shell.name)) {
            if (argv.len == 3) {
                // carapace-tiny <name> <shell> → snippet for single command
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const snippet = try shell.mod.generateSnippet(arena.allocator(), name);
                std.Io.File.stdout().writeStreamingAll(init.io, snippet) catch {};
                return 0;
            }

            // carapace-tiny <name> <shell> <name> <args...> → completions
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var cmdline_args: std.ArrayList([]const u8) = .empty;
            if (argv.len > 3) {
                for (argv[3..]) |a| {
                    try cmdline_args.append(arena.allocator(), std.mem.span(a));
                }
            }

            const specs = try spec.discoverSpecs(init.io, init.environ_map, arena.allocator());
            const spec_info = spec.findSpec(specs, name) orelse {
                std.debug.print("error: unknown command: {s}\n", .{name});
                return 1;
            };

            const content = std.Io.Dir.cwd().readFileAlloc(init.io, spec_info.path, allocator, .limited(1024 * 1024)) catch {
                std.debug.print("error: cannot read spec file: {s}\n", .{spec_info.path});
                return 1;
            };
            defer allocator.free(content);

            const cmd = spec.loadSpec(arena.allocator(), content) catch |err| {
                std.debug.print("error: cannot parse spec: {s}\n", .{@errorName(err)});
                return 1;
            };

            const candidates = try traverse.completeWithEnv(arena.allocator(), init.io, cmd, cmdline_args.items, init.environ_map);
            const comp_type = init.environ_map.get("COMP_TYPE");
            const out = try shell.mod.formatOutput(arena.allocator(), candidates, comp_type);
            std.Io.File.stdout().writeStreamingAll(init.io, out) catch {};
            return 0;
        }
    }

    // carapace-tiny <name> run [<args...>]
    if (argv.len >= 3 and std.mem.eql(u8, std.mem.span(argv[2]), "run")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const specs = try spec.discoverSpecs(init.io, init.environ_map, arena.allocator());
        const spec_info = spec.findSpec(specs, name) orelse {
            std.debug.print("error: unknown command: {s}\n", .{name});
            return 1;
        };

        const content = std.Io.Dir.cwd().readFileAlloc(init.io, spec_info.path, allocator, .limited(1024 * 1024)) catch {
            std.debug.print("error: cannot read spec file: {s}\n", .{spec_info.path});
            return 1;
        };
        defer allocator.free(content);

        const cmd = spec.loadSpec(arena.allocator(), content) catch |err| {
            std.debug.print("error: cannot parse spec: {s}\n", .{@errorName(err)});
            return 1;
        };

        if (cmd.run.len == 0) {
            std.debug.print("error: no run field in spec\n", .{});
            return 1;
        }

        // Collect extra args from command line
        var extra_args: std.ArrayList([]const u8) = .empty;
        if (argv.len > 3) {
            for (argv[3..]) |a| {
                try extra_args.append(arena.allocator(), std.mem.span(a));
            }
        }

        return try runCommand(arena.allocator(), init.io, cmd, &extra_args, init.environ_map);
    }

    std.debug.print("error: unknown command: {s}\n", .{name});
    return 1;
}

test {
    _ = @import("yaml.zig");
    _ = @import("spec.zig");
    _ = @import("flag.zig");
    _ = @import("traverse.zig");
    _ = @import("resolve.zig");
    _ = @import("action.zig");
    _ = @import("style.zig");
    _ = @import("builtins.zig");
    _ = @import("bridge.zig");
    _ = @import("shell/bash.zig");
    _ = @import("shell/zsh.zig");
    _ = @import("shell/fish.zig");
    _ = @import("shell/powershell.zig");
    _ = @import("shell/export.zig");
}

test "parse run args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseRunArgs(arena.allocator(), "[tail, --lines, '${NUM:-1}']");
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("tail", args[0]);
    try std.testing.expectEqualStrings("--lines", args[1]);
    try std.testing.expectEqualStrings("${NUM:-1}", args[2]);
}

test "parse run args empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseRunArgs(arena.allocator(), "[]");
    try std.testing.expectEqual(@as(usize, 0), args.len);
}