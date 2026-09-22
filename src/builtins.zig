const std = @import("std");
const traverse = @import("traverse.zig");

/// Parse "$files" or "$files([.go, .md])" and list files in the current directory.
pub fn resolveFiles(allocator: std.mem.Allocator, io: std.Io, macro: []const u8) ![]traverse.Candidate {
    var suffixes: []const []const u8 = &.{};
    if (macro.len > 7 and macro[6] == '(') {
        if (macro[macro.len - 1] == ')') {
            const args = macro[7 .. macro.len - 1];
            if (args.len > 0) {
                suffixes = try parseFlowList(allocator, args);
            }
        }
    }
    defer if (suffixes.len > 0) allocator.free(suffixes);

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (suffixes.len > 0) {
            var matches = false;
            for (suffixes) |suf| {
                if (std.mem.endsWith(u8, name, suf)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, name) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$directories" and list directories in the current directory.
pub fn resolveDirectories(allocator: std.mem.Allocator, io: std.Io) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const name = entry.name;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, name) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$executables" and list executables in PATH.
pub fn resolveExecutables(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    const path_env = if (environ_map) |env| env.get("PATH") else null;
    const path = path_env orelse return &.{};

    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var dir_it = dir.iterate();
        while (try dir_it.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            const name = entry.name;
            var already_added = false;
            for (candidates.items) |c| {
                if (std.mem.eql(u8, c.value, name)) {
                    already_added = true;
                    break;
                }
            }
            if (already_added) continue;
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, name) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$message(msg)" and return a single candidate with the message as description.
pub fn resolveMessage(allocator: std.mem.Allocator, macro: []const u8) ![]traverse.Candidate {
    if (macro.len > 9 and macro[8] == '(' and macro[macro.len - 1] == ')') {
        const msg = macro[9 .. macro.len - 1];
        if (msg.len > 0) {
            var candidates = std.ArrayList(traverse.Candidate).empty;
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, ""),
                .description = try allocator.dupe(u8, msg),
            });
            return candidates.toOwnedSlice(allocator);
        }
    }
    return &.{};
}

/// Parse "$list(delim)" or "$uniquelist(delim)" — complete the last segment of the current value.
/// "$uniquelist" suppresses the segment when it already appears earlier in the current value.
pub fn resolveList(allocator: std.mem.Allocator, macro: []const u8, prefix: []const u8, unique: bool) ![]traverse.Candidate {
    var delim: []const u8 = ",";
    if (macro.len > 0 and macro[macro.len - 1] == ')') {
        if (std.mem.indexOfScalar(u8, macro, '(')) |o| {
            const args = macro[o + 1 .. macro.len - 1];
            if (args.len > 0) delim = args;
        }
    }
    const last_seg = if (std.mem.lastIndexOf(u8, prefix, delim)) |last| prefix[last + delim.len ..] else prefix;
    var candidates = std.ArrayList(traverse.Candidate).empty;
    if (last_seg.len > 0) {
        if (unique and lastSegmentUsed(prefix, delim, last_seg)) {
            return candidates.toOwnedSlice(allocator);
        }
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, last_seg), .nospace = true });
    }
    return candidates.toOwnedSlice(allocator);
}

fn lastSegmentUsed(prefix: []const u8, delim: []const u8, last_seg: []const u8) bool {
    var it = std.mem.splitSequence(u8, prefix, delim);
    var i: usize = 0;
    var last_index: usize = 0;
    var found_last = false;
    while (it.next()) |seg| : (i += 1) {
        if (std.mem.eql(u8, seg, last_seg)) {
            last_index = i;
            found_last = true;
        }
    }
    if (!found_last) return false;
    // Any occurrence of the segment before its last occurrence means it's used
    it = std.mem.splitSequence(u8, prefix, delim);
    i = 0;
    while (it.next()) |seg| : (i += 1) {
        if (i >= last_index) break;
        if (std.mem.eql(u8, seg, last_seg)) return true;
    }
    return false;
}

/// Parse "$multiparts([delim])" — like list but with nospace semantics.
pub fn resolveMultiparts(allocator: std.mem.Allocator, macro: []const u8, prefix: []const u8) ![]traverse.Candidate {
    var delim: []const u8 = "/";
    if (macro.len > 12 and macro[11] == '(') {
        if (macro[macro.len - 1] == ')') {
            const args = macro[12 .. macro.len - 1];
            if (args.len > 0) delim = args;
        }
    }
    const last_seg = if (std.mem.lastIndexOf(u8, prefix, delim)) |last| prefix[last + delim.len ..] else prefix;
    var candidates = std.ArrayList(traverse.Candidate).empty;
    if (last_seg.len > 0) {
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, last_seg), .nospace = true });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$chdir(dir)" — complete in the given directory.
pub fn resolveChdir(allocator: std.mem.Allocator, io: std.Io, macro: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var dir_path: []const u8 = "";
    if (macro.len > 7 and macro[6] == '(' and macro[macro.len - 1] == ')') {
        dir_path = macro[7 .. macro.len - 1];
    }
    if (dir_path.len == 0) return &.{};

    const resolved = try resolveChdirPath(allocator, dir_path, environ_map, io);
    defer allocator.free(resolved);

    var dir = std.Io.Dir.cwd().openDir(io, resolved, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.NotDir => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = entry.name;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (std.mem.startsWith(u8, name, prefix)) {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, name) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

fn resolveChdirPath(allocator: std.mem.Allocator, path: []const u8, environ_map: ?*const std.process.Environ.Map, io: std.Io) ![]const u8 {
    const trimmed = std.mem.trim(u8, path, " \t");

    if (std.mem.eql(u8, trimmed, "$userhomedir") or std.mem.eql(u8, trimmed, "$HOME")) {
        if (environ_map) |env| { if (env.get("HOME")) |home| return try allocator.dupe(u8, home); }
        return try allocator.dupe(u8, "/root");
    }
    if (std.mem.eql(u8, trimmed, "$tempdir") or std.mem.eql(u8, trimmed, "$TMPDIR")) {
        if (environ_map) |env| { if (env.get("TMPDIR")) |td| return try allocator.dupe(u8, td); }
        return try allocator.dupe(u8, "/tmp");
    }
    if (std.mem.eql(u8, trimmed, "$xdgconfighome") or std.mem.eql(u8, trimmed, "$XDG_CONFIG_HOME")) {
        if (environ_map) |env| { if (env.get("XDG_CONFIG_HOME")) |xdg| return try allocator.dupe(u8, xdg); }
        if (environ_map) |env| { if (env.get("HOME")) |home| return try std.fs.path.join(allocator, &.{ home, ".config" }); }
        return try allocator.dupe(u8, "/root/.config");
    }
    if (std.mem.eql(u8, trimmed, "$xdgcachehome") or std.mem.eql(u8, trimmed, "$XDG_CACHE_HOME")) {
        if (environ_map) |env| { if (env.get("XDG_CACHE_HOME")) |xdg| return try allocator.dupe(u8, xdg); }
        if (environ_map) |env| { if (env.get("HOME")) |home| return try std.fs.path.join(allocator, &.{ home, ".cache" }); }
        return try allocator.dupe(u8, "/root/.cache");
    }
    if (std.mem.eql(u8, trimmed, "$usercachedir")) return resolveChdirPath(allocator, "$xdgcachehome", environ_map, io);
    if (std.mem.eql(u8, trimmed, "$userconfigdir")) return resolveChdirPath(allocator, "$xdgconfighome", environ_map, io);
    if (std.mem.eql(u8, trimmed, "$nixprofile")) {
        if (environ_map) |env| { if (env.get("HOME")) |home| return try std.fs.path.join(allocator, &.{ home, ".nix-profile" }); }
        return try allocator.dupe(u8, "/root/.nix-profile");
    }
    if (std.mem.eql(u8, trimmed, "$gitdir")) return try allocator.dupe(u8, ".git");
    if (std.mem.eql(u8, trimmed, "$gitworktree")) return try allocator.dupe(u8, ".");
    if (std.mem.startsWith(u8, trimmed, "$parent(")) return resolveChdirParent(allocator, trimmed, io);
    return try allocator.dupe(u8, trimmed);
}

fn resolveChdirParent(allocator: std.mem.Allocator, macro: []const u8, io: std.Io) ![]const u8 {
    if (macro.len < 10 or macro[macro.len - 1] != ')') return try allocator.dupe(u8, ".");
    const args = macro[8 .. macro.len - 1];
    const names = parseFlowList(allocator, args) catch return try allocator.dupe(u8, ".");
    defer allocator.free(names);
    if (names.len == 0) return try allocator.dupe(u8, ".");

    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return try allocator.dupe(u8, ".");
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        for (names) |name| { if (std.mem.eql(u8, entry.name, name)) return try allocator.dupe(u8, "."); }
    }

    var depth: usize = 1;
    while (depth < 64) : (depth += 1) {
        var up_path = std.ArrayList(u8).empty;
        var d: usize = 0;
        while (d < depth) : (d += 1) {
            if (d > 0) try up_path.append(allocator, '/');
            try up_path.appendSlice(allocator, "..");
        }
        const up_str = try up_path.toOwnedSlice(allocator);
        defer allocator.free(up_str);
        var parent_dir = std.Io.Dir.cwd().openDir(io, up_str, .{ .iterate = true }) catch break;
        defer parent_dir.close(io);
        var parent_it = parent_dir.iterate();
        while (try parent_it.next(io)) |entry| {
            for (names) |name| { if (std.mem.eql(u8, entry.name, name)) return try allocator.dupe(u8, up_str); }
        }
    }
    return try allocator.dupe(u8, ".");
}

/// Parse "$split" — split the current value by delimiter, complete last segment.
pub fn resolveSplit(allocator: std.mem.Allocator, macro: []const u8, prefix: []const u8) ![]traverse.Candidate {
    var delim: []const u8 = " \t\n\r";
    if (macro.len > 7 and macro[6] == '(' and macro[macro.len - 1] == ')') {
        const args = macro[7 .. macro.len - 1];
        if (args.len > 0) delim = args;
    }
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var last_seg = prefix;
    var i: usize = 0;
    while (i < prefix.len) {
        var next_delim = prefix.len;
        for (delim) |d| {
            if (std.mem.indexOfScalar(u8, prefix[i..], d)) |pos| {
                const abs_pos = i + pos;
                if (abs_pos < next_delim) next_delim = abs_pos;
            }
        }
        last_seg = prefix[i..next_delim];
        i = next_delim + 1;
    }
    if (last_seg.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, last_seg) });
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$splitp" — same as split but with pipeline delimiter.
pub fn resolveSplitp(allocator: std.mem.Allocator, macro: []const u8, prefix: []const u8) ![]traverse.Candidate {
    var delim: []const u8 = "|";
    if (macro.len > 8 and macro[7] == '(' and macro[macro.len - 1] == ')') {
        const args = macro[8 .. macro.len - 1];
        if (args.len > 0) delim = args;
    }
    var candidates = std.ArrayList(traverse.Candidate).empty;
    const last_seg = if (std.mem.lastIndexOf(u8, prefix, delim)) |last| prefix[last + delim.len ..] else prefix;
    if (last_seg.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, last_seg) });
    return candidates.toOwnedSlice(allocator);
}

/// Parse a simple YAML flow sequence: [val1, val2, val3]
pub fn parseFlowList(allocator: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, src, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return &.{};
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return &.{};
    var items = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i >= inner.len) break;
        const start = i;
        if (inner[i] == '"') {
            i += 1;
            while (i < inner.len and inner[i] != '"') { if (inner[i] == '\\' and i + 1 < inner.len) i += 2 else i += 1; }
            if (i < inner.len) i += 1;
            try items.append(allocator, try allocator.dupe(u8, inner[start + 1 .. i - 1]));
        } else if (inner[i] == '\'') {
            i += 1;
            while (i < inner.len and inner[i] != '\'') { if (inner[i] == '\\' and i + 1 < inner.len) i += 2 else i += 1; }
            if (i < inner.len) i += 1;
            try items.append(allocator, try allocator.dupe(u8, inner[start + 1 .. i - 1]));
        } else {
            while (i < inner.len and inner[i] != ',' and inner[i] != ']') : (i += 1) {}
            const raw = std.mem.trim(u8, inner[start..i], " \t");
            if (raw.len > 0) try items.append(allocator, try allocator.dupe(u8, raw));
        }
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == ',')) : (i += 1) {}
    }
    return items.toOwnedSlice(allocator);
}

test "parse flow list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseFlowList(arena.allocator(), "[a, b, c]");
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("a", items[0]);
    try std.testing.expectEqualStrings("b", items[1]);
    try std.testing.expectEqualStrings("c", items[2]);
}

test "parse flow list with quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseFlowList(arena.allocator(), "[\"hello world\", 'single']");
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("hello world", items[0]);
    try std.testing.expectEqualStrings("single", items[1]);
}

test "parse empty flow list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseFlowList(arena.allocator(), "[]");
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "files macro returns files in current directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveFiles(arena.allocator(), std.testing.io, "$files");
    try std.testing.expect(candidates.len > 0);
}

test "directories macro returns directories in current directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveDirectories(arena.allocator(), std.testing.io);
    try std.testing.expect(candidates.len > 0);
}

test "executables macro returns empty with null env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveExecutables(arena.allocator(), std.testing.io, null);
    try std.testing.expect(candidates.len == 0);
}

test "executables macro with PATH env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    try env_map.put("PATH", "/usr/bin:/bin");
    const candidates = try resolveExecutables(arena.allocator(), std.testing.io, &env_map);
    try std.testing.expect(candidates.len > 0);
}

test "message macro returns empty value with description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMessage(arena.allocator(), "$message(no matches)");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("", candidates[0].value);
    try std.testing.expectEqualStrings("no matches", candidates[0].description);
}

test "chdir macro resolves userhomedir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try resolveChdir(arena.allocator(), std.testing.io, "$chdir($userhomedir)", "", null);
}