const std = @import("std");
const spec = @import("spec.zig");
const Flag = @import("flag.zig").Flag;
const action = @import("action.zig");

pub const Candidate = struct {
    value: []const u8,
    description: []const u8 = "",
    style: []const u8 = "",
    nospace: bool = false,
    tag: []const u8 = "",
};

/// Split a raw value string into (value, description, style) using tab separators.
/// Format: `value\tdescription\tstyle` or `value\tdescription` or just `value`.
pub fn splitValue(raw: []const u8) struct { value: []const u8, description: []const u8, style: []const u8 } {
    var it = std.mem.splitScalar(u8, raw, '\t');
    const val = it.first();
    const desc = if (it.next()) |d| d else "";
    const style = if (it.next()) |s| s else "";
    return .{ .value = val, .description = desc, .style = style };
}

/// Expand variables in a string: ${C_ARG0}, ${C_FLAG_NAME}, ${C_VALUE}
/// Supports ${VAR:-default} syntax.
pub fn expandVariables(allocator: std.mem.Allocator, template: []const u8, flag_values: *const std.StringHashMap([]const u8), positional_args: []const []const u8, current_value: []const u8) ![]const u8 {
    // Simple variable expansion: find ${...} patterns and replace
    var result = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$' and i + 1 < template.len and template[i + 1] == '{') {
            const start = i + 2;
            const end = std.mem.indexOfScalar(u8, template[start..], '}') orelse {
                // No closing brace, treat as literal
                try result.append(allocator, template[i]);
                i += 1;
                continue;
            };
            const var_expr = template[start .. start + end];
            i = start + end + 1;

            // Check for default value: ${VAR:-default}
            var var_name: []const u8 = undefined;
            var default_value: []const u8 = "";
            if (std.mem.indexOf(u8, var_expr, ":-")) |colon| {
                var_name = var_expr[0..colon];
                default_value = var_expr[colon + 2 ..];
            } else {
                var_name = var_expr;
            }

            // Resolve variable
            if (std.mem.eql(u8, var_name, "C_VALUE")) {
                try result.appendSlice(allocator, current_value);
            } else if (std.mem.startsWith(u8, var_name, "C_ARG")) {
                const idx_str = var_name[5..];
                const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                    try result.appendSlice(allocator, default_value);
                    continue;
                };
                if (idx < positional_args.len) {
                    try result.appendSlice(allocator, positional_args[idx]);
                } else {
                    try result.appendSlice(allocator, default_value);
                }
            } else if (std.mem.startsWith(u8, var_name, "C_FLAG_")) {
                const flag_name = var_name[7..];
                // Convert to lowercase for lookup (flag names are lowercase)
                const lower_key = try allocator.alloc(u8, flag_name.len);
                for (flag_name, 0..) |c, j| {
                    lower_key[j] = std.ascii.toLower(c);
                }
                defer allocator.free(lower_key);
                if (flag_values.get(lower_key)) |val| {
                    try result.appendSlice(allocator, val);
                } else {
                    try result.appendSlice(allocator, default_value);
                }
            } else {
                // Unknown variable, use default
                try result.appendSlice(allocator, default_value);
            }
        } else {
            try result.append(allocator, template[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn complete(allocator: std.mem.Allocator, io: std.Io, root: spec.Command, cmdline: []const []const u8) ![]Candidate {
    return completeWithEnv(allocator, io, root, cmdline, null);
}

pub fn completeWithEnv(allocator: std.mem.Allocator, io: std.Io, root: spec.Command, cmdline: []const []const u8, environ_map: ?*const std.process.Environ.Map) ![]Candidate {
    if (cmdline.len == 0) return &.{};

    // First arg is the command name itself — skip it
    const cmdline_args = if (cmdline.len > 1) cmdline[1..] else cmdline[0..0];
    if (cmdline_args.len == 0) return &.{};

    const args = cmdline_args[0 .. cmdline_args.len - 1];
    const value = cmdline_args[cmdline_args.len - 1];

    var current = root;
    var in_flag: ?Flag = null;
    var positional_count: usize = 0;
    var dash = false;
    var flag_parsing = true;
    var flag_values = std.StringHashMap([]const u8).init(allocator);
    var consumed_flag_names = std.StringHashMap(void).init(allocator); // for exclusiveflags

    // Track positional args for variable expansion
    var positional_args = std.ArrayList([]const u8).empty;

    // Parse CARAPACE_BRIDGES for implicit bridge fallback
    var bridge_names: []const []const u8 = &.{};
    if (environ_map) |env| {
        if (env.get("CARAPACE_BRIDGES")) |be| {
            var list = std.ArrayList([]const u8).empty;
            var it = std.mem.splitScalar(u8, be, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " \t");
                if (trimmed.len > 0) try list.append(allocator, trimmed);
            }
            bridge_names = try list.toOwnedSlice(allocator);
        }
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (in_flag) |f| {
            in_flag = null;
            try flag_values.put(f.name(), arg);
            // Handle nargs: consume additional positional args as flag values
            if (f.nargs > 0) {
                var n: i32 = 1;
                while (n < f.nargs and i + 1 < args.len) : (n += 1) {
                    i += 1;
                    try flag_values.put(f.name(), args[i]);
                }
            } else if (f.nargs < 0) {
                // nargs = -1 consumes all remaining args
                while (i + 1 < args.len) {
                    i += 1;
                    try flag_values.put(f.name(), args[i]);
                }
            }
            try consumed_flag_names.put(f.name(), {});
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            dash = true;
            flag_parsing = false;
            continue;
        }

        if (flag_parsing and arg.len > 0 and arg[0] == '-') {
            if (arg.len > 1 and arg[1] == '-') {
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                    const flag_name = arg[2..eq];
                    const flag_value = arg[eq + 1 ..];
                    if (current.findFlag(flag_name)) |_| {
                        try flag_values.put(flag_name, flag_value);
                        try consumed_flag_names.put(flag_name, {});
                    }
                    continue;
                }
                const name = arg[2..];
                if (current.findFlag(name)) |f| {
                    try consumed_flag_names.put(f.name(), {});
                    if (f.takes_value and !f.optarg) {
                        in_flag = f;
                    } else if (f.optarg) {
                        // Check if next arg exists and doesn't start with -
                        if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') {
                            i += 1;
                            try flag_values.put(f.name(), args[i]);
                        }
                    }
                }
            } else {
                const name = arg[1..];
                // Try whole-name match first (non-POSIX flags like -short)
                if (current.findFlag(name)) |f| {
                    try consumed_flag_names.put(f.name(), {});
                    if (f.takes_value and !f.optarg) {
                        in_flag = f;
                    }
                } else if (name.len > 1) {
                    // POSIX shorthand series: walk each char
                    var j: usize = 0;
                    while (j < name.len) : (j += 1) {
                        const ch = name[j .. j + 1];
                        if (current.findFlag(ch)) |f| {
                            try consumed_flag_names.put(f.name(), {});
                            if (f.takes_value and !f.optarg) {
                                if (j < name.len - 1) {
                                    // Rest of string is attached value
                                    const attached = name[j + 1 ..];
                                    try flag_values.put(f.name(), attached);
                                } else {
                                    in_flag = f;
                                }
                                break;
                            } else if (f.optarg) {
                                // Optarg - rest is optional value, stop chaining
                                break;
                            }
                            // Bool - continue to next char
                        } else {
                            // Unknown shorthand char
                            break;
                        }
                    }
                }
            }
            continue;
        }

        if (!dash) {
            if (current.findSubcommand(arg)) |sub| {
                current = sub;
                positional_count = 0;
                if (current.parsing == .disabled) flag_parsing = false;
                continue;
            }
        }

        positional_count += 1;
        try positional_args.append(allocator, arg);
        // Non-interspersed: after first positional, stop flag parsing
        if (current.parsing == .non_interspersed) {
            flag_parsing = false;
        }
    }

    if (in_flag) |f| {
        return completeFlagValueFull(allocator, io, current, f, value, environ_map, &flag_values, positional_args.items);
    }

    if (value.len > 0 and value[0] == '-' and flag_parsing) {
        if (value.len > 1 and value[1] == '-') {
            if (std.mem.indexOfScalar(u8, value, '=')) |eq| {
                const flag_name = value[2..eq];
                const prefix = value[eq + 1 ..];
                return completeFlagValueWithPrefixFull(allocator, io, current, flag_name, prefix, environ_map, &flag_values, positional_args.items);
            }
            return completeFlagsWithExclusive(allocator, current, value, &consumed_flag_names);
        }
        // Shorthand series: value is like "-v" or "-vf"
        // If only "-", complete all flags (longhand + shorthand)
        if (value.len == 1) {
            return completeFlagsWithExclusive(allocator, current, value, &consumed_flag_names);
        }
        // Check for = delimiter (non-POSIX -flag=value or POSIX -f=value)
        if (std.mem.indexOfScalar(u8, value, '=')) |eq| {
            const flag_name = value[1..eq];
            const prefix = value[eq + 1 ..];
            if (current.findFlag(flag_name)) |_| {
                return completeFlagValueWithPrefixFull(allocator, io, current, flag_name, prefix, environ_map, &flag_values, positional_args.items);
            }
        }
        // Multi-char single-dash: could be non-POSIX flag or shorthand series.
        const shorthand_part = value[1..];
        if (shorthand_part.len > 1 and current.findFlag(shorthand_part) != null) {
            return completeFlagsWithExclusive(allocator, current, value, &consumed_flag_names);
        }
        // Check if any flag has a multi-char shorthand (non-POSIX mode).
        if (hasNonPosixFlags(current)) {
            return completeFlagsWithExclusive(allocator, current, value, &consumed_flag_names);
        }
        return completeShorthandSeriesWithEnv(allocator, io, current, shorthand_part, environ_map);
    }

    if (dash) {
        if (positional_count < current.completion.dash.len) {
            const pos = current.completion.dash[positional_count];
            return resolveValuesWithEnv(allocator, io, pos, value, environ_map, &flag_values, positional_args.items);
        }
        if (current.completion.dashany.len > 0) {
            return resolveValuesWithEnv(allocator, io, current.completion.dashany, value, environ_map, &flag_values, positional_args.items);
        }
        // Fall through to positional/positionalany if no dash completions defined
    }

    if (!dash and current.commands.len > 0 and positional_count == 0) {
        var candidates = std.ArrayList(Candidate).empty;
        for (current.commands) |cmd| {
            if (!cmd.hidden and std.mem.startsWith(u8, cmd.name, value)) {
                try candidates.append(allocator, .{ .value = cmd.name, .description = cmd.description, .tag = cmd.group });
            }
        }
        if (current.completion.positional.len > 0) {
            const pos = current.completion.positional[0];
            const resolved = try resolveValuesWithEnv(allocator, io, pos, value, environ_map, &flag_values, positional_args.items);
            try candidates.appendSlice(allocator, resolved);
            allocator.free(resolved);
        }
        return candidates.toOwnedSlice(allocator);
    }

    if (positional_count < current.completion.positional.len) {
        const pos = current.completion.positional[positional_count];
        return resolveValuesWithEnv(allocator, io, pos, value, environ_map, &flag_values, positional_args.items);
    }

    if (current.completion.positionalany.len > 0) {
        return resolveValuesWithEnv(allocator, io, current.completion.positionalany, value, environ_map, &flag_values, positional_args.items);
    }

    // Bridge fallback: if no completions found and command has a run field,
    // try implicit bridges from CARAPACE_BRIDGES
    if (current.run.len > 0 and bridge_names.len > 0) {
        const bridge_candidates = try resolveBridgeFallback(allocator, io, current.run, args, value, bridge_names, environ_map);
        if (bridge_candidates.len > 0) return bridge_candidates;
    }

    return &.{};
}

/// Resolve a list of raw completion values into candidates.
/// Static values (no macro) are parsed for tab-separated description/style.
/// Macro values (starting with `$`) are passed to `action.resolveMacro`.
fn resolveValues(allocator: std.mem.Allocator, io: std.Io, values: []const []const u8, prefix: []const u8) ![]Candidate {
    return resolveValuesWithEnv(allocator, io, values, prefix, null, null, &.{});
}

fn resolveValuesWithEnv(allocator: std.mem.Allocator, io: std.Io, values: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: ?*const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]Candidate {
    var candidates = std.ArrayList(Candidate).empty;
    for (values) |v| {
        if (flag_values) |fv| {
            const expanded = try expandVariables(allocator, v, fv, positional_args, prefix);
            defer allocator.free(expanded);
            if (expanded.len > 0 and expanded[0] == '$') {
                const macro_candidates = try action.resolveMacro(allocator, io, expanded, prefix, environ_map);
                for (macro_candidates) |c| {
                    if (std.mem.startsWith(u8, c.value, prefix)) {
                        try candidates.append(allocator, .{
                            .value = try allocator.dupe(u8, c.value),
                            .description = try allocator.dupe(u8, c.description),
                            .style = try allocator.dupe(u8, c.style),
                            .nospace = c.nospace,
                            .tag = try allocator.dupe(u8, c.tag),
                        });
                    }
                }
            } else {
                const parsed = splitValue(expanded);
                if (std.mem.startsWith(u8, parsed.value, prefix)) {
                    try candidates.append(allocator, .{
                        .value = try allocator.dupe(u8, parsed.value),
                        .description = try allocator.dupe(u8, parsed.description),
                        .style = try allocator.dupe(u8, parsed.style),
                    });
                }
            }
        } else {
            if (v.len > 0 and v[0] == '$') {
                const macro_candidates = try action.resolveMacro(allocator, io, v, prefix, environ_map);
                for (macro_candidates) |c| {
                    if (std.mem.startsWith(u8, c.value, prefix)) {
                        try candidates.append(allocator, c);
                    }
                }
            } else {
                const parsed = splitValue(v);
                if (std.mem.startsWith(u8, parsed.value, prefix)) {
                    try candidates.append(allocator, .{ .value = parsed.value, .description = parsed.description, .style = parsed.style });
                }
            }
        }
    }
    return candidates.toOwnedSlice(allocator);
}

fn hasNonPosixFlags(cmd: spec.Command) bool {
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
        } else {
            break;
        }
    }
    return false;
}

fn completeFlags(allocator: std.mem.Allocator, cmd: spec.Command, prefix: []const u8) ![]Candidate {
    return completeFlagsWithExclusive(allocator, cmd, prefix, null);
}

fn completeFlagsWithExclusive(allocator: std.mem.Allocator, cmd: spec.Command, prefix: []const u8, consumed_flags: ?*const std.StringHashMap(void)) ![]Candidate {
    var candidates = std.ArrayList(Candidate).empty;

    var current = cmd;
    while (true) {
        for (current.flags) |f| {
            if (f.hidden) continue;
            // Skip flags in exclusive groups that already have a consumed member
            if (consumed_flags) |cf| {
                if (isFlagExcluded(current, f, cf)) continue;
            }
            try addFlagCandidate(allocator, &candidates, f, prefix);
        }
        for (current.persistent_flags) |f| {
            if (f.hidden) continue;
            if (consumed_flags) |cf| {
                if (isFlagExcluded(current, f, cf)) continue;
            }
            try addFlagCandidate(allocator, &candidates, f, prefix);
        }
        if (current.parent) |p| {
            current = p.*;
        } else {
            break;
        }
    }

    return candidates.toOwnedSlice(allocator);
}

/// Check if a flag is in an exclusive group where another member has been consumed.
fn isFlagExcluded(cmd: spec.Command, f: Flag, consumed_flags: *const std.StringHashMap(void)) bool {
    for (cmd.exclusive_flags) |group| {
        for (group) |member| {
            if (std.mem.eql(u8, member, f.name())) {
                // This flag is in an exclusive group — check if another member was consumed
                for (group) |other| {
                    if (!std.mem.eql(u8, other, f.name()) and consumed_flags.contains(other)) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

fn addFlagCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList(Candidate), f: Flag, prefix: []const u8) !void {
    if (f.longhand.len > 0) {
        const dash = if (f.name_as_shorthand) "-" else "--";
        const form = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dash, f.longhand });
        if (std.mem.startsWith(u8, form, prefix)) {
            try candidates.append(allocator, .{ .value = form, .description = f.description });
        } else {
            allocator.free(form);
        }
    }
    if (f.shorthand.len > 0) {
        const form = try std.fmt.allocPrint(allocator, "-{s}", .{f.shorthand});
        if (std.mem.startsWith(u8, form, prefix)) {
            try candidates.append(allocator, .{ .value = form, .description = f.description });
        } else {
            allocator.free(form);
        }
    }
}

fn completeShorthandSeries(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, shorthand_part: []const u8) ![]Candidate {
    return completeShorthandSeriesWithEnv(allocator, io, cmd, shorthand_part, null);
}

fn completeShorthandSeriesWithEnv(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, shorthand_part: []const u8, environ_map: ?*const std.process.Environ.Map) ![]Candidate {
    // Walk the already-typed shorthand chars. All must be valid bool/optarg shorthands.
    // If any is a non-optarg value flag, the rest would be consumed as its attached value,
    // so we can't chain further — fall back to completing that flag's value.
    var j: usize = 0;
    while (j < shorthand_part.len) : (j += 1) {
        const ch = shorthand_part[j .. j + 1];
        if (cmd.findFlag(ch)) |f| {
            if (f.takes_value and !f.optarg) {
                // This flag consumes the rest as attached value.
                // If we're at the last char, complete flag value for this flag.
                // Otherwise, the rest is the attached value prefix.
                if (j == shorthand_part.len - 1) {
                    // Last char is a value flag expecting next arg — complete its value
                    return completeFlagValue(allocator, io, cmd, f, "", environ_map);
                }
                // Rest after this char is the attached value prefix
                const attached = shorthand_part[j + 1 ..];
                return completeFlagValueWithPrefix(allocator, io, cmd, f.name(), attached, environ_map);
            } else if (f.optarg) {
                // Optarg flag: rest after this char is optional value
                if (j == shorthand_part.len - 1) {
                    // At the end — could complete optarg value or more shorthands
                    break;
                }
                // Has more chars after optarg — those are the optarg's value
                break;
            }
            // Bool flag — continue to next char
        } else {
            // Unknown shorthand char — no valid completions
            return &.{};
        }
    }

    // All typed chars are valid bool/optarg shorthands.
    // Offer remaining valid shorthand flags as chaining candidates.
    // Candidate value is the full typed prefix + new shorthand char.
    var candidates = std.ArrayList(Candidate).empty;

    var current = cmd;
    while (true) {
        for (current.flags) |f| {
            if (f.hidden or f.shorthand.len == 0) continue;
            // Skip shorthands already used in the series
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
        } else {
            break;
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Try implicit bridge fallback for commands with a `run` field but no completions.
/// Parses the run field to extract the aliased command, then tries each bridge
/// from CARAPACE_BRIDGES in order.
fn resolveBridgeFallback(allocator: std.mem.Allocator, io: std.Io, run: []const u8, args: []const []const u8, value: []const u8, bridge_names: []const []const u8, environ_map: ?*const std.process.Environ.Map) ![]Candidate {
    // Extract the command name from the run field
    const cmd_name = extractAliasedCommand(run) orelse return &.{};

    // Try each bridge from CARAPACE_BRIDGES
    for (bridge_names) |bridge_name| {
        const trimmed = std.mem.trim(u8, bridge_name, " \t");
        if (trimmed.len == 0) continue;

        // Build the macro string: $bridge.name(cmd, arg1, arg2, value)
        var macro = std.ArrayList(u8).empty;
        try macro.appendSlice(allocator, "$bridge.");
        try macro.appendSlice(allocator, trimmed);
        try macro.append(allocator, '(');
        try macro.appendSlice(allocator, cmd_name);
        for (args) |a| {
            try macro.appendSlice(allocator, ", ");
            try macro.appendSlice(allocator, a);
        }
        if (value.len > 0) {
            try macro.appendSlice(allocator, ", ");
            try macro.appendSlice(allocator, value);
        }
        try macro.append(allocator, ')');

        // Try to resolve via the bridge
        const candidates = action.resolveMacro(allocator, io, macro.items, value, environ_map) catch continue;
        if (candidates.len > 0) return candidates;
    }

    return &.{};
}

/// Extract the aliased command name from a run field.
/// Supports: "[kubectl, ...]", "kubectl ...", "$(kubectl ...)"
fn extractAliasedCommand(run: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, run, " \t");
    if (trimmed.len == 0) return null;

    // JSON array: [cmd, ...]
    if (trimmed[0] == '[') {
        const inner = std.mem.trim(u8, trimmed[1..], " \t");
        if (inner.len > 0) {
            var i: usize = 0;
            // Skip whitespace
            while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == ',')) : (i += 1) {}
            if (i >= inner.len) return null;
            // Skip opening quote if present
            if (inner[i] == '"' or inner[i] == '\'') i += 1;
            const start = i;
            while (i < inner.len and inner[i] != ',' and inner[i] != ']' and inner[i] != '"' and inner[i] != '\'') : (i += 1) {}
            if (i > start) return inner[start..i];
        }
        return null;
    }

    // Macro: $(cmd ...)
    if (trimmed[0] == '$' and trimmed.len > 2 and trimmed[1] == '(') {
        const inner = trimmed[2..];
        var i: usize = 0;
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        const start = i;
        while (i < inner.len and inner[i] != ' ' and inner[i] != '\t' and inner[i] != ')') : (i += 1) {}
        if (i > start) return inner[start..i];
        return null;
    }

    // Plain string: "kubectl ..."
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] != ' ' and trimmed[i] != '\t') : (i += 1) {}
    if (i > 0) return trimmed[0..i];
    return null;
}

fn completeFlagValue(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, f: Flag, value: []const u8, environ_map: ?*const std.process.Environ.Map) ![]Candidate {
    const values = cmd.findFlagCompletion(f.name()) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, value, environ_map, null, &.{});
}

fn completeFlagValueWithPrefix(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, flag_name: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]Candidate {
    const values = cmd.findFlagCompletion(flag_name) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, prefix, environ_map, null, &.{});
}

fn completeFlagValueFull(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, f: Flag, value: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: *const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]Candidate {
    const values = cmd.findFlagCompletion(f.name()) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, value, environ_map, flag_values, positional_args);
}

fn completeFlagValueWithPrefixFull(allocator: std.mem.Allocator, io: std.Io, cmd: spec.Command, flag_name: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map, flag_values: *const std.StringHashMap([]const u8), positional_args: []const []const u8) ![]Candidate {
    const values = cmd.findFlagCompletion(flag_name) orelse return &.{};
    return resolveValuesWithEnv(allocator, io, values, prefix, environ_map, flag_values, positional_args);
}

test "complete flag names" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --verbose: verbose
        \\  -o, --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--verbose", result[0].value);
    try std.testing.expectEqualStrings("--output", result[1].value);
}

test "complete flag names with shorthand prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --verbose: verbose
        \\  -o, --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("--verbose", result[0].value);
    try std.testing.expectEqualStrings("--output", result[1].value);
    try std.testing.expectEqualStrings("-o", result[2].value);
}

test "complete flag names filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --verbose: verbose
        \\  --version: show version
        \\  --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--ver" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--verbose", result[0].value);
    try std.testing.expectEqualStrings("--version", result[1].value);
}

test "complete flag names excludes hidden flags" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --visible: visible flag
        \\  --hidden&: hidden flag
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("--visible", result[0].value);
}

test "complete flag value after space" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -o, --output=: output file
        \\completion:
        \\  flag:
        \\    output: [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-o", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("file1", result[0].value);
    try std.testing.expectEqualStrings("file2", result[1].value);
}

test "complete flag value with --flag= prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --output=: output file
        \\completion:
        \\  flag:
        \\    output: [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--output=fi" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("file1", result[0].value);
    try std.testing.expectEqualStrings("file2", result[1].value);
}

test "complete flag value with longhand" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -o, --output=: output file
        \\completion:
        \\  flag:
        \\    output: [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--output", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("file1", result[0].value);
}

test "complete flag value with description" {
    const yaml_src =
        "name: mycmd\n" ++
        "flags:\n" ++
        "  --format=: output format\n" ++
        "completion:\n" ++
        "  flag:\n" ++
        "    format: [json\tJSON, yaml\tYAML, toml\tTOML]\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--format", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("json", result[0].value);
    try std.testing.expectEqualStrings("JSON", result[0].description);
    try std.testing.expectEqualStrings("yaml", result[1].value);
    try std.testing.expectEqualStrings("YAML", result[1].description);
    try std.testing.expectEqualStrings("toml", result[2].value);
    try std.testing.expectEqualStrings("TOML", result[2].description);
}

test "complete subcommands" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub1
        \\    description: first
        \\  - name: sub2
        \\    description: second
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("sub1", result[0].value);
    try std.testing.expectEqualStrings("first", result[0].description);
    try std.testing.expectEqualStrings("sub2", result[1].value);
    try std.testing.expectEqualStrings("second", result[1].description);
}

test "complete subcommands filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    description: build the project
        \\  - name: run
        \\    description: run the project
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "b" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("build", result[0].value);
}

test "complete subcommands excludes hidden" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: visible
        \\    description: visible subcommand
        \\  - name: hidden
        \\    hidden: true
        \\    description: hidden subcommand
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("visible", result[0].value);
}

test "complete nested subcommand" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub
        \\    commands:
        \\      - name: subsub1
        \\        description: first nested
        \\      - name: subsub2
        \\        description: second nested
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "sub", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("subsub1", result[0].value);
    try std.testing.expectEqualStrings("subsub2", result[1].value);
}

test "complete positional" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positional:
        \\    - [a, b, c]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "complete positionalany" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positionalany: [unit, integration, e2e]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("unit", result[0].value);
    try std.testing.expectEqualStrings("integration", result[1].value);
    try std.testing.expectEqualStrings("e2e", result[2].value);
}

test "complete positionalany after positional consumed" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positional:
        \\    - [first, second]
        \\  positionalany: [any1, any2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "first", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("any1", result[0].value);
    try std.testing.expectEqualStrings("any2", result[1].value);
}

test "complete subcommand and positional batch" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    description: build it
        \\completion:
        \\  positional:
        \\    - [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("build", result[0].value);
    try std.testing.expectEqualStrings("file1", result[1].value);
    try std.testing.expectEqualStrings("file2", result[2].value);
}

test "complete flag value in subcommand" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    flags:
        \\      --target=: target triple
        \\    completion:
        \\      flag:
        \\        target: [x86_64-linux, aarch64-linux]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "build", "--target", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("x86_64-linux", result[0].value);
    try std.testing.expectEqualStrings("aarch64-linux", result[1].value);
}

test "complete flags in subcommand inherits parent persistent flags" {
    const yaml_src =
        \\name: mycmd
        \\persistentflags:
        \\  -v, --verbose: verbose
        \\commands:
        \\  - name: build
        \\    flags:
        \\      --target=: target triple
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "build", "--" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--target", result[0].value);
    try std.testing.expectEqualStrings("--verbose", result[1].value);
}

test "complete flags after consuming persistent flag value" {
    const yaml_src =
        \\name: mycmd
        \\persistentflags:
        \\  --config=: config file
        \\commands:
        \\  - name: build
        \\    flags:
        \\      --target=: target triple
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--config", "/etc/app.conf", "build", "--" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--target", result[0].value);
    try std.testing.expectEqualStrings("--config", result[1].value);
}

test "complete positional after flag" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --bool: bool flag
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--bool", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
    try std.testing.expectEqualStrings("three", result[2].value);
}

test "complete positional after flag with value" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--format", "json", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
}

test "flag value population from space-separated flag" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    // --format json should store format=json in flag_values
    // We can't directly inspect flag_values from outside, but we can verify
    // that the flag value is consumed (no flag value completion offered)
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--format", "json", "" });
    // After consuming --format json, "" should be positional, not flag value
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "flag value population from --flag=value" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    // --format=json should store format=json, then "" is positional
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--format=json", "" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete after dash disables flag parsing" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --bool: bool flag
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--", "-" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete positional after dash" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --bool: bool flag
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
    try std.testing.expectEqualStrings("three", result[2].value);
}

test "complete dash positional" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  dash:
        \\    - [d1, d2]
        \\    - [d3, d4]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("d1", result[0].value);
    try std.testing.expectEqualStrings("d2", result[1].value);
}

test "complete dash positional second position" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  dash:
        \\    - [d1, d2]
        \\    - [d3, d4]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--", "d1", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("d3", result[0].value);
    try std.testing.expectEqualStrings("d4", result[1].value);
}

test "complete dashany fallback" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  dash:
        \\    - [d1, d2]
        \\  dashany: [any]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--", "d1", "d2", "" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("any", result[0].value);
}

test "complete subcommand with disabled parsing" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub
        \\    parsing: disabled
        \\    flags:
        \\      --flag: a flag
        \\    completion:
        \\      positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "sub", "--" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete subcommand with disabled parsing shows positionals for empty string" {
    // With parsing disabled, flag_parsing is false, so -- is not treated as a flag prefix.
    // It becomes a positional value prefix, but no positional values start with --.
    // Use empty string to verify positionals still work with disabled parsing.
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub
        \\    parsing: disabled
        \\    completion:
        \\      positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "sub", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
    try std.testing.expectEqualStrings("three", result[2].value);
}

test "complete flags with mixed shorthand/longhand" {
    const yaml_src =
        \\name: tinycarapace
        \\flags:
        \\  -h, --help: show help
        \\  -v, --verbose: verbose
        \\completion:
        \\  positional:
        \\   - ["one", "two", "three"]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);

    // -<TAB> should show all 4 flag forms
    const result1 = try complete(arena.allocator(), std.testing.io, cmd, &.{ "tinycarapace", "-" });
    try std.testing.expectEqual(@as(usize, 4), result1.len);
    try std.testing.expectEqualStrings("--help", result1[0].value);
    try std.testing.expectEqualStrings("-h", result1[1].value);
    try std.testing.expectEqualStrings("--verbose", result1[2].value);
    try std.testing.expectEqualStrings("-v", result1[3].value);

    // <TAB> should show all 3 positional values
    const result2 = try complete(arena.allocator(), std.testing.io, cmd, &.{ "tinycarapace", "" });
    try std.testing.expectEqual(@as(usize, 3), result2.len);
    try std.testing.expectEqualStrings("one", result2[0].value);
    try std.testing.expectEqualStrings("two", result2[1].value);
    try std.testing.expectEqualStrings("three", result2[2].value);
}

test "complete repeatable flag shown again" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --repeatable*: repeatable flag
        \\  --other: other flag
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--repeatable", "--" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--repeatable", result[0].value);
    try std.testing.expectEqualStrings("--other", result[1].value);
}

test "complete optarg flag as bare name" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --optarg?: optional argument flag
        \\  --normal: normal flag
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--optarg", result[0].value);
    try std.testing.expectEqualStrings("--normal", result[1].value);
}

test "complete flag value via attached equals" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--format=" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("json", result[0].value);
    try std.testing.expectEqualStrings("yaml", result[1].value);
}

test "complete flag value via attached equals with prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--format=ya" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("yaml", result[0].value);
}

test "complete no candidates for unknown flag value" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--unknown", "" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete empty command returns nothing" {
    const yaml_src =
        \\name: mycmd
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete only command name returns nothing" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: sub
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{"mycmd"});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete no args returns nothing" {
    const yaml_src =
        \\name: mycmd
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete subcommand via alias enters subcommand" {
    // Aliases are used for subcommand matching during traversal but not completed.
    // Entering via alias 'b' resolves to 'build' subcommand, which has no completions.
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    aliases: [b, bu]
        \\    description: build the project
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "b", "" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "complete flag value filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --color=: color
        \\completion:
        \\  flag:
        \\    color: [red, green, blue]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--color", "b" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("blue", result[0].value);
}

test "complete positional filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positional:
        \\    - [apple, banana, cherry]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "a" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("apple", result[0].value);
}

test "complete positionalany filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positionalany: [unit, integration, e2e]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "e" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("e2e", result[0].value);
}

test "non-interspersed parsing stops flag parsing after first positional" {
    const yaml_src =
        \\name: mycmd
        \\parsing: non-interspersed
        \\flags:
        \\  --flag: a flag
        \\completion:
        \\  positionalany: [one, two]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    // After a positional arg, --flag should be treated as positional, not flag
    // With no positionalany values starting with "--", we get 0 results
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "file", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
}

test "exclusive flags exclude consumed group members" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  --add: add mode
        \\  --delete: delete mode
        \\  --list: list mode
        \\exclusiveflags:
        \\  - [add, delete]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    // After --add is consumed, --delete should be excluded from flag completion
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--add", "--" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("--add", result[0].value);
    try std.testing.expectEqualStrings("--list", result[1].value);
}

test "variable expansion uses C_VALUE in value template" {
    // Direct test of expandVariables
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fv = std.StringHashMap([]const u8).init(arena.allocator());
    const result = try expandVariables(arena.allocator(), "${C_VALUE}-suffix", &fv, &.{}, "hello");
    try std.testing.expectEqualStrings("hello-suffix", result);
}

test "group field sets tag on subcommand candidates" {
    const yaml_src =
        \\name: mycmd
        \\commands:
        \\  - name: build
        \\    description: build
        \\    group: build-group
        \\  - name: run
        \\    description: run
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("build-group", result[0].tag);
    try std.testing.expectEqualStrings("", result[1].tag);
}

test "complete second positional position" {
    const yaml_src =
        \\name: mycmd
        \\completion:
        \\  positional:
        \\    - [src, dst]
        \\    - [fast, slow]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "src", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("fast", result[0].value);
    try std.testing.expectEqualStrings("slow", result[1].value);
}

test "complete flag value via attached equals for longhand only" {
    // Shorthand attached equals (-f=value) is not handled by the traversal engine.
    // Only longhand --flag=value is supported for attached value completion.
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -f, --format=: output format
        \\completion:
        \\  flag:
        \\    format: [json, yaml]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--format=ya" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("yaml", result[0].value);
}

test "shorthand series complete single bool shorthand" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -f: force
        \\  -o, --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-v" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("-vf", result[0].value);
    try std.testing.expectEqualStrings("-vo", result[1].value);
}

test "shorthand series complete two bool shorthands" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -f: force
        \\  -o, --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-vf" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("-vfo", result[0].value);
}

test "shorthand series excludes already used shorthands" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -f: force
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-vf" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "shorthand series with value flag at end completes flag value" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -o, --output=: output file
        \\completion:
        \\  flag:
        \\    output: [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-vo" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("file1", result[0].value);
    try std.testing.expectEqualStrings("file2", result[1].value);
}

test "shorthand series with value flag and attached prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -o, --output=: output file
        \\completion:
        \\  flag:
        \\    output: [file1, file2]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    // -vofi: v is bool, o takes value, "fi" is attached value prefix
    // Both file1 and file2 start with "fi"
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-vofi" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("file1", result[0].value);
    try std.testing.expectEqualStrings("file2", result[1].value);
}

test "shorthand series traversal chains bool flags" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -f: force
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-vf", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
    try std.testing.expectEqualStrings("three", result[2].value);
}

test "shorthand series traversal with value flag consumes rest as attached" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -o, --output=: output file
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    // -vofile: v is bool, o takes value, "file" is attached value
    // Then "" is a positional
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-vofile", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
}

test "shorthand series unknown char returns nothing" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-vx" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "shorthand series excludes hidden flags" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -h&: hidden flag
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-v" });
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "shorthand series includes persistent flags" {
    const yaml_src =
        \\name: mycmd
        \\persistentflags:
        \\  -p: persistent flag
        \\flags:
        \\  -v: verbose
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-v" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("-vp", result[0].value);
}

test "shorthand series single dash completes all flags" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -v: verbose
        \\  -o, --output=: output file
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    // -v has no longhand so only shorthand; -o has both, longhand emitted first
    try std.testing.expectEqualStrings("-v", result[0].value);
    try std.testing.expectEqualStrings("--output", result[1].value);
    try std.testing.expectEqualStrings("-o", result[2].value);
}

test "nonposix flag completion shows single dash longhand" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -short, -long*: nonposix both
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    // addFlagCandidate emits longhand first, then shorthand
    try std.testing.expectEqualStrings("-long", result[0].value);
    try std.testing.expectEqualStrings("-short", result[1].value);
}

test "nonposix flag completion filters by prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -short, -long*: nonposix both
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-lo" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("-long", result[0].value);
}

test "nonposix flag completion shorthand prefix" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -short, -long*: nonposix both
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-sh" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("-short", result[0].value);
}

test "nonposix flag value completion via equals" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -styled=: nonposix shorthand
        \\completion:
        \\  flag:
        \\    styled: [green, red]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-styled=gr" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("green", result[0].value);
}

test "nonposix flag value completion after space" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -styled=: nonposix shorthand
        \\completion:
        \\  flag:
        \\    styled: [green, red]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-styled", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("green", result[0].value);
    try std.testing.expectEqualStrings("red", result[1].value);
}

test "nonposix flag traversal consumes value" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -styled=: nonposix shorthand
        \\completion:
        \\  positionalany: [one, two, three]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-styled", "green", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
}

test "nonposix optarg flag completion" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -opt, -optarg?: both nonposix
        \\completion:
        \\  flag:
        \\    optarg: [o1, o2, o3]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    // longhand emitted first, then shorthand
    try std.testing.expectEqualStrings("-optarg", result[0].value);
    try std.testing.expectEqualStrings("-opt", result[1].value);
}

test "nonposix mixed posix longhand" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -short, --long: nonposix mixed
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("--long", result[0].value);
}

test "nonposix mixed shorthand completion" {
    const yaml_src =
        \\name: mycmd
        \\flags:
        \\  -short, --long: nonposix mixed
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "-sh" });
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("-short", result[0].value);
}

test "splitValue extracts value only" {
    const parsed = splitValue("hello");
    try std.testing.expectEqualStrings("hello", parsed.value);
    try std.testing.expectEqualStrings("", parsed.description);
    try std.testing.expectEqualStrings("", parsed.style);
}

test "splitValue extracts value and description" {
    const parsed = splitValue("hello\tworld");
    try std.testing.expectEqualStrings("hello", parsed.value);
    try std.testing.expectEqualStrings("world", parsed.description);
    try std.testing.expectEqualStrings("", parsed.style);
}

test "splitValue extracts value, description, and style" {
    const parsed = splitValue("hello\tworld\tbold");
    try std.testing.expectEqualStrings("hello", parsed.value);
    try std.testing.expectEqualStrings("world", parsed.description);
    try std.testing.expectEqualStrings("bold", parsed.style);
}

test "complete flag value with style" {
    const yaml_src =
        "name: mycmd\n" ++
        "flags:\n" ++
        "  --format=: output format\n" ++
        "completion:\n" ++
        "  flag:\n" ++
        "    format: [json\tJSON\tbold, yaml\tYAML\titalic, toml\tTOML]\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "--format", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("json", result[0].value);
    try std.testing.expectEqualStrings("JSON", result[0].description);
    try std.testing.expectEqualStrings("bold", result[0].style);
    try std.testing.expectEqualStrings("yaml", result[1].value);
    try std.testing.expectEqualStrings("YAML", result[1].description);
    try std.testing.expectEqualStrings("italic", result[1].style);
    try std.testing.expectEqualStrings("toml", result[2].value);
    try std.testing.expectEqualStrings("TOML", result[2].description);
    try std.testing.expectEqualStrings("", result[2].style);
}

test "complete positional with description and style" {
    const yaml_src =
        "name: mycmd\n" ++
        "completion:\n" ++
        "  positional:\n" ++
        "    - [foo\tFoo\tred, bar\tBar\tblue]\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("foo", result[0].value);
    try std.testing.expectEqualStrings("Foo", result[0].description);
    try std.testing.expectEqualStrings("red", result[0].style);
    try std.testing.expectEqualStrings("bar", result[1].value);
    try std.testing.expectEqualStrings("Bar", result[1].description);
    try std.testing.expectEqualStrings("blue", result[1].style);
}

test "complete only flags at dash prefix, no subcommands" {
    const yaml_src =
        \\name: tinycarapace
        \\flags:
        \\  -h, --help: show help
        \\  -v, --verbose: verbose
        \\completion:
        \\  positional:
        \\    - ["one", "two", "three"]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);

    // tinycarapace -<TAB> → all flags (no subcommands)
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "tinycarapace", "-" });
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("--help", result[0].value);
    try std.testing.expectEqualStrings("-h", result[1].value);
    try std.testing.expectEqualStrings("--verbose", result[2].value);
    try std.testing.expectEqualStrings("-v", result[3].value);
}

test "complete only positionals at empty prefix, no subcommands" {
    const yaml_src =
        \\name: tinycarapace
        \\flags:
        \\  -h, --help: show help
        \\  -v, --verbose: verbose
        \\completion:
        \\  positional:
        \\    - ["one", "two", "three"]
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);

    // tinycarapace <TAB> → only positionals (no subcommands)
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "tinycarapace", "" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("one", result[0].value);
    try std.testing.expectEqualStrings("two", result[1].value);
    try std.testing.expectEqualStrings("three", result[2].value);
}

test "complete positionalany with description and style" {
    const yaml_src =
        "name: mycmd\n" ++
        "completion:\n" ++
        "  positionalany: [unit\tUnit\tgreen, e2e\tE2E]\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try @import("spec.zig").loadSpec(arena.allocator(), yaml_src);
    const result = try complete(arena.allocator(), std.testing.io, cmd, &.{ "mycmd", "" });
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("unit", result[0].value);
    try std.testing.expectEqualStrings("Unit", result[0].description);
    try std.testing.expectEqualStrings("green", result[0].style);
    try std.testing.expectEqualStrings("e2e", result[1].value);
    try std.testing.expectEqualStrings("E2E", result[1].description);
    try std.testing.expectEqualStrings("", result[1].style);
}
