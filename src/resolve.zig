const std = @import("std");
const spec = @import("spec.zig");
const Flag = @import("flag.zig").Flag;
const action = @import("action.zig");
const traverse = @import("traverse.zig");

/// Resolve a single raw value string, append duplicated candidates that match prefix.
fn resolveSingleValue(allocator: std.mem.Allocator, io: std.Io, candidates: *std.ArrayList(traverse.Candidate), raw: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) !void {
    // Modifier chains also apply to static bases ("a ||| $style(...)"),
    // so anything containing a chain separator goes through resolveMacro.
    if (raw.len > 0 and (raw[0] == '$' or std.mem.indexOf(u8, raw, " ||| ") != null)) {
        if (std.mem.startsWith(u8, raw, "$spec")) {
            const spec_candidates = traverse.resolveSpec(allocator, io, raw, prefix, environ_map);
            defer allocator.free(spec_candidates);
            for (spec_candidates) |c| {
                if (std.mem.startsWith(u8, c.value, prefix)) {
                    try candidates.append(allocator, .{
                        .value = try allocator.dupe(u8, c.value),
                        .description = try allocator.dupe(u8, c.description),
                        .style = try allocator.dupe(u8, c.style),
                        .nospace = c.nospace,
                        .tag = try allocator.dupe(u8, c.tag),
                        .uid = try allocator.dupe(u8, c.uid),
                    });
                }
            }
        } else {
            const macro_candidates = try action.resolveMacro(allocator, io, raw, prefix, environ_map);
            defer allocator.free(macro_candidates);
            for (macro_candidates) |c| {
                if (std.mem.startsWith(u8, c.value, prefix)) {
                    try candidates.append(allocator, .{
                        .value = try allocator.dupe(u8, c.value),
                        .description = try allocator.dupe(u8, c.description),
                        .style = try allocator.dupe(u8, c.style),
                        .nospace = c.nospace,
                        .tag = try allocator.dupe(u8, c.tag),
                        .uid = try allocator.dupe(u8, c.uid),
                    });
                }
            }
        }
    } else {
        const parsed = traverse.splitValue(raw);
        if (std.mem.startsWith(u8, parsed.value, prefix)) {
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, parsed.value),
                .description = try allocator.dupe(u8, parsed.description),
                .style = try allocator.dupe(u8, parsed.style),
            });
        }
    }
}

/// Resolve a list of raw completion values into candidates.
/// Macro values (starting with `$`) are passed to `action.resolveMacro`.
pub fn resolveValues(allocator: std.mem.Allocator, io: std.Io, values: []const []const u8, prefix: []const u8) ![]traverse.Candidate {
    return resolveValuesWithEnv(allocator, io, values, prefix, null, null, &.{});
}

pub fn resolveValuesWithEnv(allocator: std.mem.Allocator, io: std.Io, values: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: ?*const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    for (values) |v| {
        if (flag_values) |fv| {
            const expanded = try traverse.expandVariables(allocator, v, fv, positional_args, prefix);
            defer allocator.free(expanded);
            try resolveSingleValue(allocator, io, &candidates, expanded, prefix, environ_map);
        } else {
            try resolveSingleValue(allocator, io, &candidates, v, prefix, environ_map);
        }
    }
    return candidates.toOwnedSlice(allocator);
}

pub fn hasNonPosixFlags(cmd: spec.Command) bool {
    var current = cmd;
    while (true) {
        for (current.flags) |f| { if (f.isNonPosix()) return true; }
        for (current.persistent_flags) |f| { if (f.isNonPosix()) return true; }
        if (current.parent) |p| { current = p.*; } else break;
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
        if (consumed_flags) |cf| { if (isFlagExcluded(cmd, f, cf)) continue; }
        try addFlagCandidate(allocator, &candidates, f, prefix, uid_base);
    }
    for (cmd.persistent_flags) |f| {
        if (f.hidden) continue;
        if (consumed_flags) |cf| { if (isFlagExcluded(cmd, f, cf)) continue; }
        try addFlagCandidate(allocator, &candidates, f, prefix, uid_base);
    }
    // Ancestors: only persistent flags are inherited
    var current = cmd.parent;
    while (current) |p| {
        for (p.persistent_flags) |f| {
            if (f.hidden) continue;
            if (consumed_flags) |cf| { if (isFlagExcluded(p.*, f, cf)) continue; }
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
    var j: usize = 0;
    while (j < shorthand_part.len) : (j += 1) {
        const ch = shorthand_part[j .. j + 1];
        if (cmd.findFlag(ch)) |f| {
            if (f.takes_value and !f.optarg) {
                if (j == shorthand_part.len - 1) return completeFlagValue(allocator, io, cmd, f, "", environ_map);
                const attached = shorthand_part[j + 1 ..];
                return completeFlagValueWithPrefix(allocator, io, cmd, f.name(), attached, environ_map);
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
            for (shorthand_part) |c| { if (f.shorthand.len > 0 and f.shorthand[0] == c) { already_used = true; break; } }
            if (already_used) continue;
            const form = try std.fmt.allocPrint(allocator, "-{s}{s}", .{ shorthand_part, f.shorthand });
            try candidates.append(allocator, .{ .value = form, .description = f.description });
        }
        for (current.persistent_flags) |f| {
            if (f.hidden or f.shorthand.len == 0) continue;
            var already_used = false;
            for (shorthand_part) |c| { if (f.shorthand.len > 0 and f.shorthand[0] == c) { already_used = true; break; } }
            if (already_used) continue;
            const form = try std.fmt.allocPrint(allocator, "-{s}{s}", .{ shorthand_part, f.shorthand });
            try candidates.append(allocator, .{ .value = form, .description = f.description });
        }
        if (current.parent) |p| { current = p.*; } else break;
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

pub fn completeFlagValueFull(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, f: Flag, value: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: *const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]traverse.Candidate {
    const values = cmd.findFlagCompletion(f.name()) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, value, environ_map, flag_values, positional_args);
}

pub fn completeFlagValueWithPrefixFull(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, flag_name: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: *const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]traverse.Candidate {
    const values = cmd.findFlagCompletion(flag_name) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, prefix, environ_map, flag_values, positional_args);
}