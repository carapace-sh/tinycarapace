const std = @import("std");
const spec = @import("spec.zig");
const traverse = @import("traverse.zig");
const bash = @import("shell/bash.zig");
const zsh = @import("shell/zsh.zig");
const fish = @import("shell/fish.zig");
const powershell = @import("shell/powershell.zig");
const export_shell = @import("shell/export.zig");
const action = @import("action.zig");

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: carapace-tiny _carapace [bash] | <name> (bash|export) [<name> <args...>]\n", .{});
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

    std.debug.print("error: unknown command: {s}\n", .{name});
    return 1;
}

test {
    _ = @import("yaml.zig");
    _ = @import("spec.zig");
    _ = @import("flag.zig");
    _ = @import("traverse.zig");
    _ = @import("action.zig");
    _ = @import("shell/bash.zig");
    _ = @import("shell/zsh.zig");
    _ = @import("shell/fish.zig");
    _ = @import("shell/powershell.zig");
    _ = @import("shell/export.zig");
}