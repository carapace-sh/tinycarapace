const std = @import("std");
const traverse = @import("traverse.zig");
const builtins = @import("builtins.zig");
const bridge = @import("bridge.zig");

/// Resolve a macro string into candidates.
/// Handles exec macros, built-in macros, bridges, modifiers (||| chaining), and static values.
pub fn resolveMacro(allocator: std.mem.Allocator, io: std.Io, macro: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Check for modifier chaining: "base ||| mod1 ||| mod2"
    if (std.mem.indexOf(u8, macro, " ||| ")) |_| {
        var parts = std.ArrayList([]const u8).empty;
        var rest = macro;
        while (std.mem.indexOf(u8, rest, " ||| ")) |sep| {
            try parts.append(allocator, std.mem.trim(u8, rest[0..sep], " \t"));
            rest = rest[sep + 5 ..];
        }
        try parts.append(allocator, std.mem.trim(u8, rest, " \t"));
        defer allocator.free(parts.items);

        var candidates = try resolveMacro(allocator, io, parts.items[0], prefix, environ_map);
        var i: usize = 1;
        while (i < parts.items.len) : (i += 1) {
            const mod = applyModifierWithPrefix(allocator, candidates, parts.items[i], prefix) catch |err| {
                allocator.free(candidates);
                return err;
            };
            allocator.free(candidates);
            candidates = mod;
        }
        return candidates;
    }

    // Built-in macros
    if (std.mem.startsWith(u8, macro, "$files")) return try builtins.resolveFiles(allocator, io, macro);
    if (std.mem.startsWith(u8, macro, "$directories")) return try builtins.resolveDirectories(allocator, io);
    if (std.mem.startsWith(u8, macro, "$executables")) return try builtins.resolveExecutables(allocator, io, environ_map);
    if (std.mem.startsWith(u8, macro, "$message")) return try builtins.resolveMessage(allocator, macro);
    if (std.mem.startsWith(u8, macro, "$list")) return try builtins.resolveList(allocator, macro, prefix, false);
    if (std.mem.startsWith(u8, macro, "$uniquelist")) return try builtins.resolveList(allocator, macro, prefix, true);
    if (std.mem.startsWith(u8, macro, "$multiparts")) return try builtins.resolveMultiparts(allocator, macro, prefix);
    if (std.mem.startsWith(u8, macro, "$chdir")) return try builtins.resolveChdir(allocator, io, macro, prefix, environ_map);
    if (std.mem.eql(u8, macro, "$split") or std.mem.startsWith(u8, macro, "$split(")) return try builtins.resolveSplit(allocator, macro, prefix);
    if (std.mem.eql(u8, macro, "$splitp") or std.mem.startsWith(u8, macro, "$splitp(")) return try builtins.resolveSplitp(allocator, macro, prefix);

    // Bridge macros
    if (std.mem.startsWith(u8, macro, "$bridge.") or std.mem.startsWith(u8, macro, "$bridge(")) {
        return try bridge.resolveBridge(allocator, io, macro, prefix, environ_map);
    }

    // $spec(path) — delegate to another spec file
    if (std.mem.startsWith(u8, macro, "$spec")) {
        const candidates = @import("traverse.zig").resolveSpec(allocator, io, macro, prefix, environ_map);
        defer allocator.free(candidates);
        var result = std.ArrayList(traverse.Candidate).empty;
        for (candidates) |c| {
            try result.append(allocator, .{
                .value = try allocator.dupe(u8, c.value),
                .description = try allocator.dupe(u8, c.description),
                .style = try allocator.dupe(u8, c.style),
                .nospace = c.nospace,
                .tag = try allocator.dupe(u8, c.tag),
            });
        }
        return result.toOwnedSlice(allocator);
    }

    // Bare dollar shorthand: $(cmd) → $sh(cmd)
    if (macro.len >= 3 and macro[0] == '$' and macro[1] == '(' and macro[macro.len - 1] == ')') {
        const command = macro[2 .. macro.len - 1];
        if (command.len > 0) return try bridge.execCommand(allocator, io, "sh", command);
        return &.{};
    }

    // Shell exec macros: $sh(cmd), $bash(cmd), $pwsh(cmd), etc.
    const exec_macro = comptime [_]struct { prefix: []const u8, shell: []const u8 }{
        .{ .prefix = "$sh(", .shell = "sh" },
        .{ .prefix = "$bash(", .shell = "bash" },
        .{ .prefix = "$pwsh(", .shell = "pwsh" },
        .{ .prefix = "$zsh(", .shell = "zsh" },
        .{ .prefix = "$fish(", .shell = "fish" },
        .{ .prefix = "$elvish(", .shell = "elvish" },
        .{ .prefix = "$nu(", .shell = "nu" },
        .{ .prefix = "$osh(", .shell = "osh" },
        .{ .prefix = "$xonsh(", .shell = "xonsh" },
        .{ .prefix = "$cmd(", .shell = "cmd" },
    };
    inline for (exec_macro) |em| {
        if (macro.len >= em.prefix.len + 1 and std.mem.startsWith(u8, macro, em.prefix) and macro[macro.len - 1] == ')') {
            const command = macro[em.prefix.len .. macro.len - 1];
            if (command.len > 0) return try bridge.execCommand(allocator, io, em.shell, command);
            return &.{};
        }
    }

    // Flow list base: "[a, b] ||| $mod(...)" — parse the list, then apply modifiers
    if (macro.len > 1 and macro[0] == '[' and macro[macro.len - 1] == ']') {
        const items = try builtins.parseFlowList(allocator, macro);
        var candidates = std.ArrayList(traverse.Candidate).empty;
        for (items) |item| {
            const parsed = traverse.splitValue(item);
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, parsed.value),
                .description = try allocator.dupe(u8, parsed.description),
                .style = try allocator.dupe(u8, parsed.style),
            });
        }
        return candidates.toOwnedSlice(allocator);
    }

    // Plain static value
    const val = std.mem.trim(u8, macro, " \t");
    if (val.len > 0) {
        const parsed = traverse.splitValue(val);
        var candidates = std.ArrayList(traverse.Candidate).empty;
        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, parsed.value),
            .description = try allocator.dupe(u8, parsed.description),
            .style = try allocator.dupe(u8, parsed.style),
        });
        return candidates.toOwnedSlice(allocator);
    }
    return &.{};
}

/// Apply a modifier (e.g. "$prefix(text)") to a list of candidates.
fn applyModifier(allocator: std.mem.Allocator, candidates: []traverse.Candidate, modifier: []const u8) ![]traverse.Candidate {
    return applyModifierWithPrefix(allocator, candidates, modifier, "");
}

fn applyModifierWithPrefix(allocator: std.mem.Allocator, candidates: []traverse.Candidate, modifier: []const u8, prefix: []const u8) ![]traverse.Candidate {
    const trimmed = std.mem.trim(u8, modifier, " \t");
    if (trimmed.len < 2 or trimmed[0] != '$') return error.InvalidModifier;
    const paren = std.mem.indexOfScalar(u8, trimmed, '(');
    const name = if (paren) |p| trimmed[1..p] else trimmed[1..];
    const args = if (paren) |p| (if (trimmed[trimmed.len - 1] == ')') trimmed[p + 1 .. trimmed.len - 1] else "") else "";

    if (std.mem.eql(u8, name, "prefix")) return modPrefix(allocator, candidates, args);
    if (std.mem.eql(u8, name, "suffix")) return modSuffix(allocator, candidates, args);
    if (std.mem.eql(u8, name, "nospace")) return modNospace(allocator, candidates, args);
    if (std.mem.eql(u8, name, "noprefix")) return modNoprefix(allocator, candidates, args);
    if (std.mem.eql(u8, name, "style")) return modStyle(allocator, candidates, args);
    if (std.mem.eql(u8, name, "tag")) return modTag(allocator, candidates, args);
    if (std.mem.eql(u8, name, "filter")) return modFilter(allocator, candidates, args);
    if (std.mem.eql(u8, name, "filterargs")) return modFilterargs(allocator, candidates, args);
    if (std.mem.eql(u8, name, "retain")) return modRetain(allocator, candidates, args);
    if (std.mem.eql(u8, name, "shift")) return modShift(allocator, candidates, args);
    if (std.mem.eql(u8, name, "suppress")) return modSuppress(allocator, candidates, args);
    if (std.mem.eql(u8, name, "usage")) return modUsage(allocator, candidates, args);
    if (std.mem.eql(u8, name, "uid")) return modUid(allocator, candidates, args);
    if (std.mem.eql(u8, name, "split")) return modSplit(allocator, candidates, args);
    if (std.mem.eql(u8, name, "splitp")) return modSplitp(allocator, candidates, args);
    if (std.mem.eql(u8, name, "list")) return modList(allocator, candidates, args, prefix, false);
    if (std.mem.eql(u8, name, "uniquelist")) return modList(allocator, candidates, args, prefix, true);
    if (std.mem.eql(u8, name, "multiparts")) return modList(allocator, candidates, args, prefix, false);

    // Unknown modifier — pass through
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| result[i] = c;
    return result;
}

fn modPrefix(allocator: std.mem.Allocator, candidates: []traverse.Candidate, prefix: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = .{
            .value = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, c.value }),
            .description = try allocator.dupe(u8, c.description),
            .style = try allocator.dupe(u8, c.style),
            .nospace = c.nospace,
            .tag = try allocator.dupe(u8, c.tag),
            .uid = try allocator.dupe(u8, c.uid),
        };
    }
    return result;
}

fn modSuffix(allocator: std.mem.Allocator, candidates: []traverse.Candidate, suffix: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = .{
            .value = try std.fmt.allocPrint(allocator, "{s}{s}", .{ c.value, suffix }),
            .description = try allocator.dupe(u8, c.description),
            .style = try allocator.dupe(u8, c.style),
            .nospace = c.nospace,
            .tag = try allocator.dupe(u8, c.tag),
            .uid = try allocator.dupe(u8, c.uid),
        };
    }
    return result;
}

fn modNospace(allocator: std.mem.Allocator, candidates: []traverse.Candidate, chars: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        var has_char = false;
        for (chars) |ch| { if (std.mem.indexOfScalar(u8, c.value, ch) != null) { has_char = true; break; } }
        result[i] = .{ .value = try allocator.dupe(u8, c.value), .description = try allocator.dupe(u8, c.description), .style = try allocator.dupe(u8, c.style), .nospace = has_char, .tag = try allocator.dupe(u8, c.tag), .uid = try allocator.dupe(u8, c.uid) };
    }
    return result;
}

fn modNoprefix(allocator: std.mem.Allocator, candidates: []traverse.Candidate, chars: []const u8) ![]traverse.Candidate {
    // Upstream NoPrefix: values containing one of the chars are matched and
    // inserted as the segment after the last occurrence of any char.
    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        var last_pos: ?usize = null;
        for (chars) |ch| {
            if (std.mem.lastIndexOfScalar(u8, c.value, ch)) |pos| {
                if (last_pos == null or pos > last_pos.?) last_pos = pos;
            }
        }
        if (last_pos) |pos| {
            try result.append(allocator, .{
                .value = try allocator.dupe(u8, c.value[pos + 1 ..]),
                .description = try allocator.dupe(u8, c.description),
                .style = try allocator.dupe(u8, c.style),
                .nospace = true,
                .tag = try allocator.dupe(u8, c.tag),
                .uid = try allocator.dupe(u8, c.uid),
            });
        } else {
            try result.append(allocator, .{
                .value = try allocator.dupe(u8, c.value),
                .description = try allocator.dupe(u8, c.description),
                .style = try allocator.dupe(u8, c.style),
                .nospace = c.nospace,
                .tag = try allocator.dupe(u8, c.tag),
                .uid = try allocator.dupe(u8, c.uid),
            });
        }
    }
    return result.toOwnedSlice(allocator);
}

/// $list(delim)/$uniquelist(delim)/$multiparts([delim]) — complete the segment
/// of each candidate value at the position indicated by the current prefix.
fn modList(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8, prefix: []const u8, unique: bool) ![]traverse.Candidate {
    var delim: []const u8 = if (args.len > 0) args else ",";
    if (std.mem.startsWith(u8, delim, "[") and std.mem.endsWith(u8, delim, "]")) {
        delim = delim[1 .. delim.len - 1];
        if (delim.len == 0) delim = "/";
    }

    // The segment being completed is determined by the delimiter count in the prefix
    const part_index = blk: {
        var n: usize = 0;
        var rest = prefix;
        while (std.mem.indexOf(u8, rest, delim)) |pos| {
            n += 1;
            rest = rest[pos + delim.len ..];
        }
        break :blk n;
    };

    // Segments of the prefix before the one being completed (for uniquelist dedup)
    var used = std.ArrayList([]const u8).empty;
    if (unique) {
        var it = std.mem.splitSequence(u8, prefix, delim);
        var idx: usize = 0;
        while (it.next()) |seg| : (idx += 1) {
            if (idx >= part_index) break;
            try used.append(allocator, seg);
        }
    }

    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        var it = std.mem.splitSequence(u8, c.value, delim);
        var idx: usize = 0;
        var joined = std.ArrayList(u8).empty;
        var matched = false;
        while (it.next()) |seg| : (idx += 1) {
            if (idx > part_index) break;
            if (idx > 0) try joined.appendSlice(allocator, delim);
            try joined.appendSlice(allocator, seg);
            if (idx == part_index) {
                if (seg.len == 0) break;
                if (unique) {
                    var dup_used = false;
                    for (used.items) |u| {
                        if (std.mem.eql(u8, u, seg)) {
                            dup_used = true;
                            break;
                        }
                    }
                    if (dup_used) break;
                }
                matched = true;
                break;
            }
        }
        if (matched) {
            try result.append(allocator, .{
                .value = try joined.toOwnedSlice(allocator),
                .description = try allocator.dupe(u8, c.description),
                .style = try allocator.dupe(u8, c.style),
                .nospace = true,
                .tag = try allocator.dupe(u8, c.tag),
                .uid = try allocator.dupe(u8, c.uid),
            });
        }
    }
    return result.toOwnedSlice(allocator);
}

fn modStyle(allocator: std.mem.Allocator, candidates: []traverse.Candidate, style: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = .{ .value = try allocator.dupe(u8, c.value), .description = try allocator.dupe(u8, c.description), .style = try allocator.dupe(u8, style), .nospace = c.nospace, .tag = try allocator.dupe(u8, c.tag), .uid = try allocator.dupe(u8, c.uid) };
    }
    return result;
}

fn modTag(allocator: std.mem.Allocator, candidates: []traverse.Candidate, tag: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = .{ .value = try allocator.dupe(u8, c.value), .description = try allocator.dupe(u8, c.description), .style = try allocator.dupe(u8, c.style), .nospace = c.nospace, .tag = try allocator.dupe(u8, tag), .uid = try allocator.dupe(u8, c.uid) };
    }
    return result;
}

fn modFilter(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    const filter_values = try builtins.parseFlowList(allocator, args);
    defer allocator.free(filter_values);
    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        var should_remove = false;
        for (filter_values) |fv| { if (std.mem.indexOf(u8, c.value, fv) != null) { should_remove = true; break; } }
        if (!should_remove) try result.append(allocator, c);
    }
    return result.toOwnedSlice(allocator);
}

fn modFilterargs(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| result[i] = c;
    return result;
}

fn modRetain(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    const retain_values = try builtins.parseFlowList(allocator, args);
    defer allocator.free(retain_values);
    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        for (retain_values) |rv| { if (std.mem.indexOf(u8, c.value, rv) != null) { try result.append(allocator, c); break; } }
    }
    return result.toOwnedSlice(allocator);
}

fn modShift(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    _ = std.fmt.parseInt(usize, std.mem.trim(u8, args, " \t"), 10) catch return error.InvalidModifier;
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| result[i] = c;
    return result;
}

fn modSuppress(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    // Upstream suppresses messages matching the regex expressions; here we
    // filter message candidates (empty value, non-empty description) whose
    // description contains any of the (substring) expressions.
    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        if (c.value.len == 0 and c.description.len > 0) {
            var suppressed = false;
            var it = std.mem.splitSequence(u8, args, ", ");
            while (it.next()) |expr| {
                const trimmed = std.mem.trim(u8, expr, " \"[]");
                if (trimmed.len > 0 and std.mem.indexOf(u8, c.description, trimmed) != null) {
                    suppressed = true;
                    break;
                }
            }
            if (suppressed) continue;
        }
        try result.append(allocator, c);
    }
    return result.toOwnedSlice(allocator);
}

fn modUsage(allocator: std.mem.Allocator, candidates: []traverse.Candidate, usage: []const u8) ![]traverse.Candidate {
    if (candidates.len == 0) return &.{};
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = if (i == 0) .{ .value = try allocator.dupe(u8, c.value), .description = try allocator.dupe(u8, usage), .style = try allocator.dupe(u8, c.style), .nospace = c.nospace, .tag = try allocator.dupe(u8, c.tag), .uid = try allocator.dupe(u8, c.uid) } else c;
    }
    return result;
}

fn modUid(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    // $uid([scheme, host, opts...]) — build scheme://host/<path>?query per value
    const parts = try builtins.parseFlowList(allocator, args);
    if (parts.len < 2) return error.InvalidModifier;
    const scheme = parts[0];
    const host = parts[1];

    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        var buf = std.ArrayList(u8).empty;
        try buf.print(allocator, "{s}://{s}/{s}", .{ scheme, try pathEscape(allocator, host), try pathEscape(allocator, c.value) });
        var j: usize = 2;
        var first = true;
        while (j + 1 < parts.len) : (j += 2) {
            if (parts[j + 1].len == 0) continue; // implicitly skip empty values
            try buf.appendSlice(allocator, if (first) "?" else "&");
            first = false;
            try buf.print(allocator, "{s}={s}", .{ try pathEscape(allocator, parts[j]), try pathEscape(allocator, parts[j + 1]) });
        }
        result[i] = .{
            .value = try allocator.dupe(u8, c.value),
            .description = try allocator.dupe(u8, c.description),
            .style = try allocator.dupe(u8, c.style),
            .nospace = c.nospace,
            .tag = try allocator.dupe(u8, c.tag),
            .uid = try buf.toOwnedSlice(allocator),
        };
    }
    return result;
}

/// Percent-encode a URL path segment (escape everything but unreserved chars).
fn pathEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else {
            try buf.print(allocator, "%{X:0>2}", .{c});
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn modSplit(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    var delim: []const u8 = " \t\n\r";
    if (args.len > 0) delim = args;
    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        var last_pos: i64 = -1;
        for (delim) |d| {
            if (std.mem.lastIndexOfScalar(u8, c.value, d)) |pos| { if (@as(i64, @intCast(pos)) > last_pos) last_pos = @as(i64, @intCast(pos)); }
        }
        if (last_pos >= 0) {
            try result.append(allocator, .{ .value = try allocator.dupe(u8, c.value[@as(usize, @intCast(last_pos)) + 1 ..]), .description = try allocator.dupe(u8, c.description), .style = try allocator.dupe(u8, c.style), .nospace = c.nospace, .tag = try allocator.dupe(u8, c.tag), .uid = try allocator.dupe(u8, c.uid) });
        } else {
            try result.append(allocator, c);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn modSplitp(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    var delim: []const u8 = "|";
    if (args.len > 0) delim = args;
    return modSplit(allocator, candidates, delim);
}

test "exec macro returns command output lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo one; echo two)", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}

test "exec macro handles empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(true)", "", null);
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "static value returns itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "hello", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("hello", candidates[0].value);
}

test "static value with description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "hello\tgreeting", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("hello", candidates[0].value);
    try std.testing.expectEqualStrings("greeting", candidates[0].description);
}

test "exec macro with tab-separated descriptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(printf 'one\tfirst\\ntwo\tsecond')", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("first", candidates[0].description);
    try std.testing.expectEqualStrings("two", candidates[1].value);
    try std.testing.expectEqualStrings("second", candidates[1].description);
}

test "uid modifier builds scheme://host/path urls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "one\tfirst ||| $uid([rails, rake])", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("rails://rake/one", candidates[0].uid);
}

test "uid modifier with options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "my file ||| $uid([file, fs, type, task])", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("file://fs/my%20file?type=task", candidates[0].uid);
}

test "modifier prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $prefix(p/)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("p/a", candidates[0].value);
}

test "modifier suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $suffix(/suf)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("a/suf", candidates[0].value);
}

test "modifier nospace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a/b ||| $nospace(/)", "", null);
    try std.testing.expect(candidates[0].nospace);
}

test "modifier style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "val ||| $style(bold)", "", null);
    try std.testing.expectEqualStrings("bold", candidates[0].style);
}

test "modifier tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "val ||| $tag(mytag)", "", null);
    try std.testing.expectEqualStrings("mytag", candidates[0].tag);
}

test "modifier filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo one; echo two; echo three) ||| $filter([two])", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("three", candidates[1].value);
}

test "modifier retain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo one; echo two; echo three) ||| $retain([one, two])", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}

test "modifier chaining prefix then filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo a; echo b; echo x) ||| $filter([x]) ||| $prefix(p/)", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("p/a", candidates[0].value);
    try std.testing.expectEqualStrings("p/b", candidates[1].value);
}

test "modifier on static value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "hello ||| $prefix(--) ||| $suffix(=)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("--hello=", candidates[0].value);
}

test "split modifier returns last segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a/b/c ||| $split(/)" , "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("c", candidates[0].value);
}

test "bare dollar shorthand $(cmd) matches $sh(cmd)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$(echo one; echo two)", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}
test "uniquelist suppresses segments already used in the prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // values a/b and a/a: completing the second segment of "a/" — "a" is
    // already used as the first segment, so only a/b remains.
    const c1 = try resolveMacro(arena.allocator(), std.testing.io, "[a/b, a/a] ||| $uniquelist(/)", "a/", null);
    try std.testing.expectEqual(@as(usize, 1), c1.len);
    try std.testing.expectEqualStrings("a/b", c1[0].value);
    const c2 = try resolveMacro(arena.allocator(), std.testing.io, "[a/b, a/a] ||| $list(/)", "a/", null);
    try std.testing.expectEqual(@as(usize, 2), c2.len);
}
