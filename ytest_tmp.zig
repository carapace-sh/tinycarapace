const std = @import("std");
const spec = @import("spec.zig");
test "optarg spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "/tmp/opt.yaml", arena.allocator(), .limited(1024*1024));
    const cmd = try spec.loadSpec(arena.allocator(), content);
    for (cmd.flags) |f| std.debug.print("flag: {s} optarg={} takes={}\n", .{ f.name(), f.optarg, f.takes_value });
}
