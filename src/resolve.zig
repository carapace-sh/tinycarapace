const std = @import("std");
const spec = @import("spec.zig");
const Flag = @import("flag.zig").Flag;
const action = @import("action.zig");
const traverse = @import("traverse.zig");

/// Append candidates that match prefix, duplicating strings into the output list.
fn appendMatching(allocator: std.mem.Allocator, candidates: *std.ArrayList(traverse.Candidate), resolved: []const traverse.Candidate, prefix: []const u8) !void {
    for (resolved) |c| {
        // messages have an empty value and are not filtered by the current word
        if (c.value.len == 0 or std.mem.startsWith(u8, c.value, prefix)) {
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, c.value),
                .description = try allocator.dupe(u8, c.description),
                .style = try allocator.dupe(u8, c.style),
                .nospace = c.nospace,
                .noprefix = c.noprefix,
                .tag = try allocator.dupe(u8, c.tag),
                .uid = try allocator.dupe(u8, c.uid),
            });
        }
    }
}

/// Resolve a single raw value string, append duplicated candidates that match prefix.
/// Handles modifier chains, including context modifiers that affect how the base
/// action is resolved: $shift(n) drops the first n consumed positional args,
/// $filterargs removes candidates matching a consumed positional arg and
/// $usage sets the action usage.
fn resolveSingleValue(allocator: std.mem.Allocator, io: std.Io, candidates: *std.ArrayList(traverse.Candidate), raw: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: ?*const std.StringHashMap([]const u8), positional_args: []const []const u8, meta: ?*traverse.Meta) !void {
    // Split modifier chain: "base ||| mod1 ||| mod2"
    var base_raw = raw;
    var mods = std.ArrayList([]const u8).empty;
    var args = positional_args;
    var filterargs = false;

    if (std.mem.indexOf(u8, raw, " ||| ")) |first_sep| {
        base_raw = std.mem.trim(u8, raw[0..first_sep], " \t");
        var rest = raw[first_sep + 5 ..];
        while (std.mem.indexOf(u8, rest, " ||| ")) |sep| {
            try mods.append(allocator, std.mem.trim(u8, rest[0..sep], " \t"));
            rest = rest[sep + 5 ..];
        }
        try mods.append(allocator, std.mem.trim(u8, rest, " \t"));

        // Extract context modifiers (they modify resolution, not candidates)
        var kept = std.ArrayList([]const u8).empty;
        for (mods.items) |m| {
            if (std.mem.eql(u8, m, "$filterargs")) {
                filterargs = true;
            } else if (std.mem.startsWith(u8, m, "$shift(") and std.mem.endsWith(u8, m, ")")) {
                const n = std.fmt.parseInt(usize, m[7 .. m.len - 1], 10) catch 0;
                args = if (n >= args.len) args[args.len..] else args[n..];
            } else if (std.mem.startsWith(u8, m, "$usage(") and std.mem.endsWith(u8, m, ")")) {
                if (meta) |result_meta| result_meta.usage = m[7 .. m.len - 1];
            } else {
                try kept.append(allocator, m);
            }
        }
        mods.deinit(allocator);
        mods = kept;
    }

    // Expand variables in the base and modifiers with the (shifted) context
    const expanded_base = if (flag_values) |fv|
        try traverse.expandVariables(allocator, base_raw, fv, args, prefix)
    else
        try allocator.dupe(u8, base_raw);
    defer allocator.free(expanded_base);

    // Resolve base ($spec / macro / flow list / static value)
    const is_flow_list = expanded_base.len > 1 and expanded_base[0] == '[' and expanded_base[expanded_base.len - 1] == ']';
    var resolved = blk: {
        if (expanded_base.len > 0 and (expanded_base[0] == '$' or is_flow_list)) {
            if (std.mem.startsWith(u8, expanded_base, "$spec")) {
                break :blk try allocator.dupe(traverse.Candidate, traverse.resolveSpec(allocator, io, expanded_base, prefix, environ_map));
            }
            break :blk try action.resolveMacro(allocator, io, expanded_base, prefix, environ_map);
        }
        const parsed = traverse.splitValue(expanded_base);
        var one = try allocator.alloc(traverse.Candidate, 1);
        one[0] = .{
            .value = try allocator.dupe(u8, parsed.value),
            .description = try allocator.dupe(u8, parsed.description),
            .style = try allocator.dupe(u8, parsed.style),
        };
        break :blk one;
    };
    errdefer allocator.free(resolved);

    // Apply candidate modifiers in order
    for (mods.items) |m| {
        const expanded_mod = if (flag_values) |fv|
            try traverse.expandVariables(allocator, m, fv, args, prefix)
        else
            try allocator.dupe(u8, m);
        defer allocator.free(expanded_mod);

        resolved = try action.applyModifierWithPrefix(allocator, resolved, expanded_mod, prefix);
    }

    // $filterargs: remove candidates whose value equals a consumed positional arg
    if (filterargs) {
        var filtered = std.ArrayList(traverse.Candidate).empty;
        for (resolved) |c| {
            var excluded = false;
            for (args) |a| {
                if (std.mem.eql(u8, c.value, a)) {
                    excluded = true;
                    break;
                }
            }
            if (!excluded) try filtered.append(allocator, c);
        }
        allocator.free(resolved);
        resolved = try filtered.toOwnedSlice(allocator);
    }

    try appendMatching(allocator, candidates, resolved, prefix);
    allocator.free(resolved);
}

/// Resolve a list of raw completion values into candidates.
/// Macro values (starting with `$`) are passed to `action.resolveMacro`.
pub fn resolveValues(allocator: std.mem.Allocator, io: std.Io, values: []const []const u8, prefix: []const u8) ![]traverse.Candidate {
    return resolveValuesWithEnv(allocator, io, values, prefix, null, null, &.{});
}

pub fn resolveValuesWithEnv(allocator: std.mem.Allocator, io: std.Io, values: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: ?*const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]traverse.Candidate {
    return resolveValuesWithEnvMeta(allocator, io, values, prefix, environ_map, flag_values, positional_args, null);
}

pub fn resolveValuesWithEnvMeta(allocator: std.mem.Allocator, io: std.Io, values: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: ?*const std.StringHashMap([]const u8), positional_args: []const []const u8, meta: ?*traverse.Meta) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    for (values) |v| {
        try resolveSingleValue(allocator, io, &candidates, v, prefix, environ_map, flag_values, positional_args, meta);
    }
    return candidates.toOwnedSlice(allocator);
}

pub fn hasNonPosixFlags(cmd: spec.Command) bool {
    var current = cmd;
    while (true) {
        for (current.flags) |f| {
            if (f.isNonPosix()) return true;
        }
        for (current.persistent_flags) |f| {
            if (f.isNonPosix()) return true;
        }
        if (current.parent) |p| {
            current = p.*;
        } else break;
    }
    return false;
}

pub fn completeFlags(allocator: std.mem.Allocator, cmd: spec.Command, prefix: []const u8) ![]traverse.Candidate {
    return completeFlagsWithExclusive(allocator, cmd, prefix, null, cmd.name, &.{});
}

pub fn completeFlagsWithExclusive(allocator: std.mem.Allocator, cmd: spec.Command, prefix: []const u8, consumed_flags: ?*const std.StringHashMap(void), root_name: []const u8, cmd_path: []const []const u8) ![]traverse.Candidate {
    const uid_base = try commandUid(allocator, root_name, cmd_path);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    // Own local + persistent flags
    for (cmd.flags) |f| {
        if (f.hidden) continue;
        if (consumed_flags) |cf| {
            if (isFlagExcluded(cmd, f, cf)) continue;
        }
        try addFlagCandidate(allocator, &candidates, f, prefix, uid_base);
    }
    for (cmd.persistent_flags) |f| {
        if (f.hidden) continue;
        if (consumed_flags) |cf| {
            if (isFlagExcluded(cmd, f, cf)) continue;
        }
        try addFlagCandidate(allocator, &candidates, f, prefix, uid_base);
    }
    // Ancestors: only persistent flags are inherited
    var current = cmd.parent;
    while (current) |p| {
        for (p.persistent_flags) |f| {
            if (f.hidden) continue;
            if (consumed_flags) |cf| {
                if (isFlagExcluded(p.*, f, cf)) continue;
            }
            try addFlagCandidate(allocator, &candidates, f, prefix, uid_base);
        }
        current = p.parent;
    }
    return candidates.toOwnedSlice(allocator);
}

/// Upstream flag styles: no-arg=default, optarg=yellow, multi-arg=magenta, arg=blue.
fn flagStyle(f: Flag) []const u8 {
    if (!f.takes_value) return "";
    if (f.optarg) return "yellow";
    if (f.nargs != 0) return "magenta";
    return "blue";
}

/// Implicit command uid: "cmd://<root>[/<path>...]".
fn commandUid(allocator: std.mem.Allocator, root_name: []const u8, cmd_path: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.print(allocator, "cmd://{s}", .{root_name});
    for (cmd_path) |p| try buf.print(allocator, "/{s}", .{p});
    return buf.toOwnedSlice(allocator);
}

pub fn isFlagExcluded(cmd: spec.Command, f: Flag, consumed_flags: *const std.StringHashMap(void)) bool {
    for (cmd.exclusive_flags) |group| {
        for (group) |member| {
            if (std.mem.eql(u8, member, f.name())) {
                for (group) |other| {
                    if (!std.mem.eql(u8, other, f.name()) and consumed_flags.contains(other)) return true;
                }
            }
        }
    }
    return false;
}

pub fn addFlagCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList(traverse.Candidate), f: Flag, prefix: []const u8, uid_base: []const u8) !void {
    const uid = try std.fmt.allocPrint(allocator, "{s}?flag={s}", .{ uid_base, f.name() });
    const style = flagStyle(f);
    if (f.longhand.len > 0) {
        const dash = if (f.name_as_shorthand) "-" else "--";
        const form = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dash, f.longhand });
        if (std.mem.startsWith(u8, form, prefix)) {
            try candidates.append(allocator, .{ .value = form, .description = f.description, .style = style, .uid = uid });
        } else allocator.free(form);
    }
    if (f.shorthand.len > 0) {
        const form = try std.fmt.allocPrint(allocator, "-{s}", .{f.shorthand});
        if (std.mem.startsWith(u8, form, prefix)) {
            try candidates.append(allocator, .{ .value = form, .description = f.description, .style = style, .uid = uid });
        } else allocator.free(form);
    }
}

pub fn completeShorthandSeries(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, shorthand_part: []const u8) ![]traverse.Candidate {
    return completeShorthandSeriesWithEnv(allocator, io, cmd, shorthand_part, null);
}

pub fn completeShorthandSeriesWithEnv(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, shorthand_part: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    return completeShorthandSeriesFull(allocator, io, cmd, shorthand_part, environ_map, null, &.{});
}

pub fn completeShorthandSeriesFull(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, shorthand_part: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: ?*const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]traverse.Candidate {
    var j: usize = 0;
    while (j < shorthand_part.len) : (j += 1) {
        const ch = shorthand_part[j .. j + 1];
        if (cmd.findFlag(ch)) |f| {
            if (f.takes_value and !f.optarg) {
                if (j == shorthand_part.len - 1) return completeFlagValueFull(allocator, io, cmd, f, "", environ_map, flag_values, positional_args);
                const attached = shorthand_part[j + 1 ..];
                return completeFlagValueWithPrefixFull(allocator, io, cmd, f.name(), attached, environ_map, flag_values, positional_args);
            } else if (f.optarg) {
                if (j == shorthand_part.len - 1) break;
                break;
            }
        } else return &.{};
    }

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var current = cmd;
    while (true) {
        for (current.flags) |f| {
            if (f.hidden or f.shorthand.len == 0) continue;
            var already_used = false;
            for (shorthand_part) |c| {
                if (f.shorthand.len > 0 and f.shorthand[0] == c) {
                    already_used = true;
                    break;
                }
            }
            if (already_used) continue;
            const form = try std.fmt.allocPrint(allocator, "-{s}{s}", .{ shorthand_part, f.shorthand });
            try candidates.append(allocator, .{ .value = form, .description = f.description });
        }
        for (current.persistent_flags) |f| {
            if (f.hidden or f.shorthand.len == 0) continue;
            var already_used = false;
            for (shorthand_part) |c| {
                if (f.shorthand.len > 0 and f.shorthand[0] == c) {
                    already_used = true;
                    break;
                }
            }
            if (already_used) continue;
            const form = try std.fmt.allocPrint(allocator, "-{s}{s}", .{ shorthand_part, f.shorthand });
            try candidates.append(allocator, .{ .value = form, .description = f.description });
        }
        if (current.parent) |p| {
            current = p.*;
        } else break;
    }
    return candidates.toOwnedSlice(allocator);
}

pub fn completeFlagValue(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, f: Flag, value: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const values = cmd.findFlagCompletion(f.name()) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, value, environ_map, null, &.{});
}

pub fn completeFlagValueWithPrefix(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, flag_name: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const values = cmd.findFlagCompletion(flag_name) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, prefix, environ_map, null, &.{});
}

pub fn completeFlagValueFull(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, f: Flag, value: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: ?*const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]traverse.Candidate {
    const values = cmd.findFlagCompletion(f.name()) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, value, environ_map, flag_values, positional_args);
}

pub fn completeFlagValueWithPrefixFull(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, flag_name: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: ?*const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]traverse.Candidate {
    const values = cmd.findFlagCompletion(flag_name) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, prefix, environ_map, flag_values, positional_args);
}
test "shift modifier drops consumed positional args for base expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var flag_values = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer flag_values.deinit();
    const args = [_][]const u8{ "first", "second" };
    // after $shift(1), ${C_ARG0} refers to "second"
    const values = [_][]const u8{"${C_ARG0} ||| $shift(1)"};
    const c = try resolveValuesWithEnv(arena.allocator(), std.testing.io, &values, "", null, &flag_values, &args);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqualStrings("second", c[0].value);
}

test "filterargs removes candidates matching consumed positional args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{"one"};
    const values = [_][]const u8{"[one, two, three] ||| $filterargs"};
    const c = try resolveValuesWithEnv(arena.allocator(), std.testing.io, &values, "", null, null, &args);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqualStrings("two", c[0].value);
    try std.testing.expectEqualStrings("three", c[1].value);
}

test "filterargs respects shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // after shift(1), the consumed arg is "second" — "first" survives
    const args = [_][]const u8{ "first", "second" };
    const values = [_][]const u8{"[first, second, third] ||| $shift(1) ||| $filterargs"};
    const c = try resolveValuesWithEnv(arena.allocator(), std.testing.io, &values, "", null, null, &args);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqualStrings("first", c[0].value);
    try std.testing.expectEqualStrings("third", c[1].value);
}

test "noprefix preserves values and sets the flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_][]const u8{"[a/b] ||| $noprefix(/)"};
    const c = try resolveValuesWithEnv(arena.allocator(), std.testing.io, &values, "a", null, null, &.{});
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqualStrings("a/b", c[0].value);
    try std.testing.expect(c[0].noprefix);
    try std.testing.expect(!c[0].nospace);
}

test "usage modifier sets meta usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var meta = traverse.Meta{};
    const values = [_][]const u8{"[a] ||| $usage(mycmd <file>)"};
    const c = try resolveValuesWithEnvMeta(arena.allocator(), std.testing.io, &values, "", null, null, &.{}, &meta);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqualStrings("a", c[0].value);
    try std.testing.expectEqualStrings("mycmd <file>", meta.usage);
}

test "messages are not filtered by the current word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_][]const u8{"$message(nothing to see)"};
    const c = try resolveValuesWithEnv(arena.allocator(), std.testing.io, &values, "zzz", null, null, &.{});
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqualStrings("", c[0].value);
    try std.testing.expectEqualStrings("nothing to see", c[0].description);
}
