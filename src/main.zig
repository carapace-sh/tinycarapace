const std = @import("std");
const spec = @import("spec.zig");
const traverse = @import("traverse.zig");
const bash = @import("shell/bash.zig");
const action = @import("action.zig");

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: tinycarapace <spec.yaml> [_complete <shell> <args...>]\n", .{});
        return 1;
    }

    const spec_path = std.mem.span(argv[1]);

    const content = std.Io.Dir.cwd().readFileAlloc(init.io, spec_path, allocator, .limited(1024 * 1024)) catch {
        std.debug.print("error: cannot read spec file: {s}\n", .{spec_path});
        return 1;
    };
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cmd = spec.loadSpec(arena.allocator(), content) catch |err| {
        std.debug.print("error: cannot parse spec: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (argv.len >= 4 and std.mem.eql(u8, std.mem.span(argv[2]), "_complete")) {
        const shell = std.mem.span(argv[3]);

        var cmdline_args: std.ArrayList([]const u8) = .empty;
        if (argv.len > 4) {
            for (argv[4..]) |a| {
                try cmdline_args.append(arena.allocator(), std.mem.span(a));
            }
        }

        const candidates = try traverse.complete(arena.allocator(), cmd, cmdline_args.items);

        var out_buf: std.ArrayList(u8) = .empty;

        if (std.mem.eql(u8, shell, "bash")) {
            const comp_type = init.environ_map.get("COMP_TYPE");
            const out = try bash.formatOutput(arena.allocator(), candidates, comp_type);
            try out_buf.appendSlice(arena.allocator(), out);
        } else {
            for (candidates) |c| {
                if (c.description.len > 0) {
                    try out_buf.print(arena.allocator(), "{s}\t{s}\n", .{ c.value, c.description });
                } else {
                    try out_buf.print(arena.allocator(), "{s}\n", .{c.value});
                }
            }
        }

        std.Io.File.stdout().writeStreamingAll(init.io, out_buf.items) catch {};
    } else {
        const snippet = try bash.generateSnippet(arena.allocator(), cmd, spec_path);
        std.Io.File.stdout().writeStreamingAll(init.io, snippet) catch {};
    }

    return 0;
}

test {
    _ = @import("yaml.zig");
    _ = @import("spec.zig");
    _ = @import("flag.zig");
    _ = @import("traverse.zig");
    _ = @import("action.zig");
    _ = @import("shell/bash.zig");
}
