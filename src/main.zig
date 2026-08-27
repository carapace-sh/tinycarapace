const std = @import("std");
const spec = @import("spec.zig");
const traverse = @import("traverse.zig");
const bash = @import("shell/bash.zig");
const action = @import("action.zig");

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: carapace-tiny _carapace [bash] | <name> bash [<name> <args...>]\n", .{});
        return 1;
    }

    // carapace-tiny _carapace [bash] → init script
    if (std.mem.eql(u8, std.mem.span(argv[1]), "_carapace")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const specs = try spec.discoverSpecs(init.io, init.environ_map, arena.allocator());
        if (specs.len == 0) return 0;
        const script = try bash.generateInitScript(arena.allocator(), specs);
        std.Io.File.stdout().writeStreamingAll(init.io, script) catch {};
        return 0;
    }

    const name = std.mem.span(argv[1]);

    // carapace-tiny <name> bash [<name> <args...>]
    if (argv.len >= 3 and std.mem.eql(u8, std.mem.span(argv[2]), "bash")) {
        if (argv.len == 3) {
            // carapace-tiny <name> bash → snippet for single command
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const snippet = try bash.generateSnippet(arena.allocator(), name);
            std.Io.File.stdout().writeStreamingAll(init.io, snippet) catch {};
            return 0;
        }

        // carapace-tiny <name> bash <name> <args...> → completions
        // argv[3] is the command name again (from xargs input in the snippet)
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var cmdline_args: std.ArrayList([]const u8) = .empty;
        if (argv.len > 3) {
            for (argv[3..]) |a| {
                try cmdline_args.append(arena.allocator(), std.mem.span(a));
            }
        }

        // Look up spec from env var, user dirs, or system dirs
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

        const candidates = try traverse.complete(arena.allocator(), cmd, cmdline_args.items);
        const comp_type = init.environ_map.get("COMP_TYPE");
        const out = try bash.formatOutput(arena.allocator(), candidates, comp_type);
        std.Io.File.stdout().writeStreamingAll(init.io, out) catch {};
        return 0;
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
}