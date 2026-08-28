const std = @import("std");
const traverse = @import("traverse.zig");

/// Resolve a macro string into candidates.
/// Handles exec macros ($sh, $bash, $pwsh), modifiers (||| chaining), and static values.
/// `prefix` is the current partial word being completed (for list/multiparts/split).
pub fn resolveMacro(allocator: std.mem.Allocator, io: std.Io, macro: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Check for modifier chaining: "base ||| mod1 ||| mod2"
    // Split on " ||| " and resolve the chain: base → modifier1 → modifier2
    // Modifiers are applied right-to-left (outermost runs first).
    if (std.mem.indexOf(u8, macro, " ||| ")) |_| {
        var parts = std.ArrayList([]const u8).empty;
        var rest = macro;
        while (std.mem.indexOf(u8, rest, " ||| ")) |sep| {
            try parts.append(allocator, std.mem.trim(u8, rest[0..sep], " \t"));
            rest = rest[sep + 5 ..];
        }
        try parts.append(allocator, std.mem.trim(u8, rest, " \t"));
        defer allocator.free(parts.items);

        // First part is the base action — resolve recursively
        var candidates = try resolveMacro(allocator, io, parts.items[0], prefix, environ_map);

        // Remaining parts are modifiers, applied right-to-left
        var i: usize = parts.items.len - 1;
        while (i >= 1) : (i -= 1) {
            const mod = applyModifier(allocator, candidates, parts.items[i]) catch |err| {
                allocator.free(candidates);
                return err;
            };
            allocator.free(candidates);
            candidates = mod;
        }

        return candidates;
    }

    // Handle built-in macros: $files, $directories, $executables
    if (std.mem.startsWith(u8, macro, "$files")) {
        return try resolveFiles(allocator, io, macro);
    }
    if (std.mem.startsWith(u8, macro, "$directories")) {
        return try resolveDirectories(allocator, io);
    }
    if (std.mem.startsWith(u8, macro, "$executables")) {
        return try resolveExecutables(allocator, io, environ_map);
    }
    if (std.mem.startsWith(u8, macro, "$message")) {
        return try resolveMessage(allocator, macro);
    }

    // $list(delim) — split the current value by delimiter, complete last segment
    if (std.mem.startsWith(u8, macro, "$list")) {
        return try resolveList(allocator, macro, prefix, false);
    }
    if (std.mem.startsWith(u8, macro, "$uniquelist")) {
        return try resolveList(allocator, macro, prefix, true);
    }

    // $multiparts([delim]) — like list but with nospace semantics
    if (std.mem.startsWith(u8, macro, "$multiparts")) {
        return try resolveMultiparts(allocator, macro, prefix);
    }

    // $chdir(dir) — change directory before completing
    if (std.mem.startsWith(u8, macro, "$chdir")) {
        return try resolveChdir(allocator, io, macro, prefix, environ_map);
    }

    // $split — split current value lexicographically
    if (std.mem.eql(u8, macro, "$split") or std.mem.startsWith(u8, macro, "$split(")) {
        return try resolveSplit(allocator, macro, prefix);
    }
    if (std.mem.eql(u8, macro, "$splitp") or std.mem.startsWith(u8, macro, "$splitp(")) {
        return try resolveSplitp(allocator, macro, prefix);
    }

    // Handle bridge macros: $bridge(name, command) or $bridge.name(command)
    if (std.mem.startsWith(u8, macro, "$bridge.") or std.mem.startsWith(u8, macro, "$bridge(")) {
        return try resolveBridge(allocator, io, macro, prefix, environ_map);
    }

    // Handle bare dollar shorthand: $(cmd) → $sh(cmd)
    if (macro.len >= 3 and macro[0] == '$' and macro[1] == '(' and macro[macro.len - 1] == ')') {
        const command = macro[2 .. macro.len - 1];
        if (command.len > 0) {
            return try execCommand(allocator, io, "sh", command);
        }
        return &.{};
    }

    // Handle exec macros: $sh(command), $bash(command), $pwsh(command), etc.
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
            if (command.len > 0) {
                return try execCommand(allocator, io, em.shell, command);
            }
            return &.{};
        }
    }

    // Plain static value (no macro prefix)
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

/// Parse a modifier string like "$prefix(text)" and apply it to candidates.
fn applyModifier(allocator: std.mem.Allocator, candidates: []traverse.Candidate, modifier: []const u8) ![]traverse.Candidate {
    const trimmed = std.mem.trim(u8, modifier, " \t");

    // All modifiers start with $ and may have (args)
    if (trimmed.len < 2 or trimmed[0] != '$') return error.InvalidModifier;
    const paren = std.mem.indexOfScalar(u8, trimmed, '(');
    const name = if (paren) |p| trimmed[1..p] else trimmed[1..];
    const args = if (paren) |p| (if (trimmed[trimmed.len - 1] == ')') trimmed[p + 1 .. trimmed.len - 1] else "") else "";

    if (std.mem.eql(u8, name, "prefix")) {
        return try modPrefix(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "suffix")) {
        return try modSuffix(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "nospace")) {
        return try modNospace(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "noprefix")) {
        return try modNoprefix(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "style")) {
        return try modStyle(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "tag")) {
        return try modTag(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "filter")) {
        return try modFilter(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "filterargs")) {
        return try modFilterargs(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "retain")) {
        return try modRetain(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "shift")) {
        return try modShift(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "suppress")) {
        return try modSuppress(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "usage")) {
        return try modUsage(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "uid")) {
        return try modUid(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "split")) {
        return try modSplit(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "splitp")) {
        return try modSplitp(allocator, candidates, args);
    }
    // Unknown modifier — pass through unchanged
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = c;
    }
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
        };
    }
    return result;
}

fn modNospace(allocator: std.mem.Allocator, candidates: []traverse.Candidate, chars: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        var has_char = false;
        for (chars) |ch| {
            if (std.mem.indexOfScalar(u8, c.value, ch) != null) {
                has_char = true;
                break;
            }
        }
        result[i] = .{
            .value = try allocator.dupe(u8, c.value),
            .description = try allocator.dupe(u8, c.description),
            .style = try allocator.dupe(u8, c.style),
            .nospace = has_char,
            .tag = try allocator.dupe(u8, c.tag),
        };
    }
    return result;
}

fn modNoprefix(allocator: std.mem.Allocator, candidates: []traverse.Candidate, chars: []const u8) ![]traverse.Candidate {
    // Delegate to nospace — same semantics (don't add common prefix for values containing given chars)
    return modNospace(allocator, candidates, chars);
}

fn modStyle(allocator: std.mem.Allocator, candidates: []traverse.Candidate, style: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = .{
            .value = try allocator.dupe(u8, c.value),
            .description = try allocator.dupe(u8, c.description),
            .style = try allocator.dupe(u8, style),
            .nospace = c.nospace,
            .tag = try allocator.dupe(u8, c.tag),
        };
    }
    return result;
}

fn modTag(allocator: std.mem.Allocator, candidates: []traverse.Candidate, tag: []const u8) ![]traverse.Candidate {
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = .{
            .value = try allocator.dupe(u8, c.value),
            .description = try allocator.dupe(u8, c.description),
            .style = try allocator.dupe(u8, c.style),
            .nospace = c.nospace,
            .tag = try allocator.dupe(u8, tag),
        };
    }
    return result;
}

fn modFilter(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    const filter_values = try parseFlowList(allocator, args);
    defer allocator.free(filter_values);

    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        var should_remove = false;
        for (filter_values) |fv| {
            if (std.mem.indexOf(u8, c.value, fv) != null) {
                should_remove = true;
                break;
            }
        }
        if (!should_remove) {
            try result.append(allocator, c);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn modFilterargs(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: []const u8) ![]traverse.Candidate {
    // Filter out candidates whose values match already-completed positional args.
    // This is a simplified version — in full carapace-spec it uses the context's
    // consumed positional args. Here we just pass through unchanged.
    // The actual filtering happens in traverse.zig when the context is available.
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = c;
    }
    return result;
}

fn modRetain(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    const retain_values = try parseFlowList(allocator, args);
    defer allocator.free(retain_values);

    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        for (retain_values) |rv| {
            if (std.mem.indexOf(u8, c.value, rv) != null) {
                try result.append(allocator, c);
                break;
            }
        }
    }
    return result.toOwnedSlice(allocator);
}

fn modShift(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    // Shift positional arguments left by n.
    // This is a no-op in the modifier chain — it's handled by the traversal engine.
    // But we parse the argument to validate it.
    const trimmed = std.mem.trim(u8, args, " \t");
    _ = std.fmt.parseInt(usize, trimmed, 10) catch return error.InvalidModifier;
    // Pass through unchanged
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = c;
    }
    return result;
}

fn modSuppress(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: []const u8) ![]traverse.Candidate {
    // Suppress error messages matching a regex. Since we don't have error messages
    // in the candidate stream, this is a no-op pass-through.
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = c;
    }
    return result;
}

fn modUsage(allocator: std.mem.Allocator, candidates: []traverse.Candidate, usage: []const u8) ![]traverse.Candidate {
    // Set usage message on first candidate (or all — carapace-spec sets it on the batch)
    // Since we don't have a batch-level usage field, we set it as the description of the first candidate.
    if (candidates.len == 0) return &.{};
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = if (i == 0) .{
            .value = try allocator.dupe(u8, c.value),
            .description = try allocator.dupe(u8, usage),
            .style = try allocator.dupe(u8, c.style),
            .nospace = c.nospace,
            .tag = try allocator.dupe(u8, c.tag),
        } else c;
    }
    return result;
}

fn modUid(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: []const u8) ![]traverse.Candidate {
    // Set UID for deduplication. Since we don't have a dedup cache, this is a no-op.
    var result = try allocator.alloc(traverse.Candidate, candidates.len);
    for (candidates, 0..) |c, i| {
        result[i] = c;
    }
    return result;
}

fn modSplit(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    // Split candidates by delimiter (default: whitespace), return last segment of each
    var delim: []const u8 = " \t\n\r";
    if (args.len > 0) delim = args;
    var result = std.ArrayList(traverse.Candidate).empty;
    for (candidates) |c| {
        // Find the last delimiter in the value
        var last_pos: i64 = -1;
        for (delim) |d| {
            if (std.mem.lastIndexOfScalar(u8, c.value, d)) |pos| {
                if (@as(i64, @intCast(pos)) > last_pos) last_pos = @as(i64, @intCast(pos));
            }
        }
        if (last_pos >= 0) {
            try result.append(allocator, .{
                .value = try allocator.dupe(u8, c.value[@as(usize, @intCast(last_pos)) + 1 ..]),
                .description = try allocator.dupe(u8, c.description),
                .style = try allocator.dupe(u8, c.style),
                .nospace = c.nospace,
                .tag = try allocator.dupe(u8, c.tag),
            });
        } else {
            try result.append(allocator, c);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn modSplitp(allocator: std.mem.Allocator, candidates: []traverse.Candidate, args: []const u8) ![]traverse.Candidate {
    // Same as split but with pipeline delimiter `|` by default
    var delim: []const u8 = "|";
    if (args.len > 0) delim = args;
    return modSplit(allocator, candidates, delim);
}

/// Parse a simple YAML flow sequence: [val1, val2, val3]
/// Handles quoted strings (single and double) and unquoted values.
fn parseFlowList(allocator: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, src, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return &.{};
    }
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return &.{};

    var items = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < inner.len) {
        // Skip whitespace
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i >= inner.len) break;

        // Parse value (quoted or unquoted)
        const start = i;
        if (inner[i] == '"') {
            i += 1;
            while (i < inner.len and inner[i] != '"') {
                if (inner[i] == '\\' and i + 1 < inner.len) i += 2 else i += 1;
            }
            if (i < inner.len) i += 1; // skip closing quote
            const raw = inner[start + 1 .. i - 1];
            try items.append(allocator, try allocator.dupe(u8, raw));
        } else if (inner[i] == '\'') {
            i += 1;
            while (i < inner.len and inner[i] != '\'') {
                if (inner[i] == '\\' and i + 1 < inner.len) i += 2 else i += 1;
            }
            if (i < inner.len) i += 1;
            const raw = inner[start + 1 .. i - 1];
            try items.append(allocator, try allocator.dupe(u8, raw));
        } else {
            while (i < inner.len and inner[i] != ',' and inner[i] != ']') : (i += 1) {}
            const raw = std.mem.trim(u8, inner[start..i], " \t");
            if (raw.len > 0) {
                try items.append(allocator, try allocator.dupe(u8, raw));
            }
        }

        // Skip comma
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == ',')) : (i += 1) {}
    }

    return items.toOwnedSlice(allocator);
}

/// Parse "$files" or "$files([.go, .md])" and list files in the current directory.
fn resolveFiles(allocator: std.mem.Allocator, io: std.Io, macro: []const u8) ![]traverse.Candidate {
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
fn resolveDirectories(allocator: std.mem.Allocator, io: std.Io) ![]traverse.Candidate {
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
fn resolveExecutables(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
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
fn resolveMessage(allocator: std.mem.Allocator, macro: []const u8) ![]traverse.Candidate {
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

/// Parse "$list(delim)" or "$uniquelist(delim)" and complete the last segment of the current value.
/// `prefix` is the current partial word being completed.
fn resolveList(allocator: std.mem.Allocator, macro: []const u8, prefix: []const u8, _: bool) ![]traverse.Candidate {
    // Extract delimiter: $list(,) or $list(delim)
    var delim: []const u8 = ",";
    if (macro.len > 6 and macro[5] == '(') {
        if (macro[macro.len - 1] == ')') {
            const args = macro[6 .. macro.len - 1];
            if (args.len > 0) {
                delim = args;
            }
        }
    }

    // Split prefix by delimiter, get last segment
    const last_seg = if (std.mem.lastIndexOf(u8, prefix, delim)) |last| prefix[last + delim.len ..] else prefix;

    // Return candidates that match the last segment
    // We don't have a static list here — this is typically used with a preceding macro.
    // Return a single candidate with the prefix as value.
    var candidates = std.ArrayList(traverse.Candidate).empty;
    if (last_seg.len > 0) {
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, last_seg) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$multiparts([delim])" and complete the last segment with nospace semantics.
fn resolveMultiparts(allocator: std.mem.Allocator, macro: []const u8, prefix: []const u8) ![]traverse.Candidate {
    var delim: []const u8 = "/";
    if (macro.len > 12 and macro[11] == '(') {
        if (macro[macro.len - 1] == ')') {
            const args = macro[12 .. macro.len - 1];
            if (args.len > 0) {
                delim = args;
            }
        }
    }

    const last_seg = if (std.mem.lastIndexOf(u8, prefix, delim)) |last| prefix[last + delim.len ..] else prefix;

    var candidates = std.ArrayList(traverse.Candidate).empty;
    if (last_seg.len > 0) {
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, last_seg), .nospace = true });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$chdir(dir)" and complete in the given directory.
/// Supports special directory macros: $userhomedir, $tempdir, etc.
fn resolveChdir(allocator: std.mem.Allocator, io: std.Io, macro: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Extract the directory path from $chdir(path)
    var dir_path: []const u8 = "";
    if (macro.len > 7 and macro[6] == '(' and macro[macro.len - 1] == ')') {
        dir_path = macro[7 .. macro.len - 1];
    }
    if (dir_path.len == 0) return &.{};

    // Resolve special directory macros
    const resolved = try resolveChdirPath(allocator, dir_path, environ_map, io);
    defer allocator.free(resolved);

    // If resolved exists, list files/directories in that directory
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

/// Resolve a chdir path, handling special directory macros.
fn resolveChdirPath(allocator: std.mem.Allocator, path: []const u8, environ_map: ?*const std.process.Environ.Map, io: std.Io) ![]const u8 {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, path, " \t");

    // $userhomedir → HOME
    if (std.mem.eql(u8, trimmed, "$userhomedir") or std.mem.eql(u8, trimmed, "$HOME")) {
        if (environ_map) |env| {
            if (env.get("HOME")) |home| return try allocator.dupe(u8, home);
        }
        return try allocator.dupe(u8, "/root");
    }

    // $tempdir → TMPDIR or /tmp
    if (std.mem.eql(u8, trimmed, "$tempdir") or std.mem.eql(u8, trimmed, "$TMPDIR")) {
        if (environ_map) |env| {
            if (env.get("TMPDIR")) |td| return try allocator.dupe(u8, td);
        }
        return try allocator.dupe(u8, "/tmp");
    }

    // $xdgconfighome → XDG_CONFIG_HOME or ~/.config
    if (std.mem.eql(u8, trimmed, "$xdgconfighome") or std.mem.eql(u8, trimmed, "$XDG_CONFIG_HOME")) {
        if (environ_map) |env| {
            if (env.get("XDG_CONFIG_HOME")) |xdg| return try allocator.dupe(u8, xdg);
        }
        if (environ_map) |env| {
            if (env.get("HOME")) |home| return try std.fs.path.join(allocator, &.{ home, ".config" });
        }
        return try allocator.dupe(u8, "/root/.config");
    }

    // $xdgcachehome → XDG_CACHE_HOME or ~/.cache
    if (std.mem.eql(u8, trimmed, "$xdgcachehome") or std.mem.eql(u8, trimmed, "$XDG_CACHE_HOME")) {
        if (environ_map) |env| {
            if (env.get("XDG_CACHE_HOME")) |xdg| return try allocator.dupe(u8, xdg);
        }
        if (environ_map) |env| {
            if (env.get("HOME")) |home| return try std.fs.path.join(allocator, &.{ home, ".cache" });
        }
        return try allocator.dupe(u8, "/root/.cache");
    }

    // $usercachedir → same as $xdgcachehome
    if (std.mem.eql(u8, trimmed, "$usercachedir")) {
        return resolveChdirPath(allocator, "$xdgcachehome", environ_map, io);
    }

    // $userconfigdir → same as $xdgconfighome
    if (std.mem.eql(u8, trimmed, "$userconfigdir")) {
        return resolveChdirPath(allocator, "$xdgconfighome", environ_map, io);
    }

    // $nixprofile → ~/.nix-profile
    if (std.mem.eql(u8, trimmed, "$nixprofile")) {
        if (environ_map) |env| {
            if (env.get("HOME")) |home| return try std.fs.path.join(allocator, &.{ home, ".nix-profile" });
        }
        return try allocator.dupe(u8, "/root/.nix-profile");
    }

    // $gitdir — .git folder of current directory
    if (std.mem.eql(u8, trimmed, "$gitdir")) {
        return try allocator.dupe(u8, ".git");
    }

    // $gitworktree — root of working directory for non-bare repos
    if (std.mem.eql(u8, trimmed, "$gitworktree")) {
        return try allocator.dupe(u8, ".");
    }

    // $parent([file, dir]) — walk up to first parent containing given names
    if (std.mem.startsWith(u8, trimmed, "$parent(")) {
        return resolveChdirParent(allocator, trimmed, io);
    }

    // Plain path — use as-is
    return try allocator.dupe(u8, trimmed);
}

/// Resolve $parent([file, dir]) — walk up to the first parent directory containing one of the given names.
fn resolveChdirParent(allocator: std.mem.Allocator, macro: []const u8, io: std.Io) ![]const u8 {
    if (macro.len < 10 or macro[macro.len - 1] != ')') return try allocator.dupe(u8, ".");
    const args = macro[8 .. macro.len - 1];
    const names = parseFlowList(allocator, args) catch return try allocator.dupe(u8, ".");
    defer allocator.free(names);

    if (names.len == 0) return try allocator.dupe(u8, ".");

    // Walk up from current directory by checking each parent
    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return try allocator.dupe(u8, ".");
    defer dir.close(io);

    // Check current directory first
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        for (names) |name| {
            if (std.mem.eql(u8, entry.name, name)) {
                return try allocator.dupe(u8, ".");
            }
        }
    }

    // Walk up using ".." relative paths
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
            for (names) |name| {
                if (std.mem.eql(u8, entry.name, name)) {
                    return try allocator.dupe(u8, up_str);
                }
            }
        }
    }

    return try allocator.dupe(u8, ".");
}

/// Parse "$split" and split the current value lexicographically.
/// Each segment of the current value is completed independently.
fn resolveSplit(allocator: std.mem.Allocator, macro: []const u8, prefix: []const u8) ![]traverse.Candidate {
    // $split optionally takes a delimiter: $split(,)
    var delim: []const u8 = " \t\n\r";
    if (macro.len > 7 and macro[6] == '(' and macro[macro.len - 1] == ')') {
        const args = macro[7 .. macro.len - 1];
        if (args.len > 0) {
            delim = args;
        }
    }

    // Split the prefix by the delimiter
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var last_seg = prefix;
    var i: usize = 0;
    while (i < prefix.len) {
        // Find next delimiter
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

    if (last_seg.len > 0) {
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, last_seg) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$splitp" — same as split but with pipeline support.
/// Pipeline delimiter is `|`.
fn resolveSplitp(allocator: std.mem.Allocator, macro: []const u8, prefix: []const u8) ![]traverse.Candidate {
    // $splitp can take a custom delimiter too
    var delim: []const u8 = "|";
    if (macro.len > 8 and macro[7] == '(' and macro[macro.len - 1] == ')') {
        const args = macro[8 .. macro.len - 1];
        if (args.len > 0) {
            delim = args;
        }
    }

    // Split by delimiter, complete last segment
    var candidates = std.ArrayList(traverse.Candidate).empty;
    const last_seg = if (std.mem.lastIndexOf(u8, prefix, delim)) |last| prefix[last + delim.len ..] else prefix;

    if (last_seg.len > 0) {
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, last_seg) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse "$bridge.name(command)" or "$bridge(name, command)" — delegate to framework-specific completion.
/// Supported bridges: cobra, bash, zsh, fish, carapace, carapace-bin, argcomplete, click, powershell, yargs
fn resolveBridge(allocator: std.mem.Allocator, io: std.Io, macro: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Parse $bridge.name(command) or $bridge(name, command)
    const paren = std.mem.indexOfScalar(u8, macro, '(') orelse return &.{};
    if (macro[macro.len - 1] != ')') return &.{};

    // Extract bridge name and command args
    const bridge_dot = macro[0..paren];
    const bridge_name = if (std.mem.startsWith(u8, bridge_dot, "$bridge."))
        bridge_dot[8..]
    else
        bridge_dot[7..];

    const args_part = macro[paren + 1 .. macro.len - 1];
    if (args_part.len == 0) return &.{};

    // Split command args by comma (simple split, not YAML flow list)
    var cmd_args = std.ArrayList([]const u8).empty;
    var arg_it = std.mem.splitScalar(u8, args_part, ',');
    while (arg_it.next()) |arg| {
        const trimmed = std.mem.trim(u8, arg, " \t");
        if (trimmed.len > 0) {
            // Strip surrounding quotes if present
            const unquoted = if (trimmed.len >= 2 and (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'' or trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"'))
                trimmed[1 .. trimmed.len - 1]
            else
                trimmed;
            try cmd_args.append(allocator, try allocator.dupe(u8, unquoted));
        }
    }

    if (cmd_args.items.len == 0) return &.{};

    const cmd = cmd_args.items[0];
    const bridge_args = cmd_args.items[1..];

    // Dispatch to the appropriate bridge handler
    if (std.mem.eql(u8, bridge_name, "cobra")) {
        return try bridgeCobra(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "bash")) {
        return try bridgeBash(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "zsh")) {
        return try bridgeZsh(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "fish")) {
        return try bridgeFish(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "carapace") or std.mem.eql(u8, bridge_name, "carapace-bin")) {
        return try bridgeCarapace(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "argcomplete")) {
        return try bridgeArgcomplete(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "click")) {
        return try bridgeClick(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "powershell")) {
        return try bridgePowershell(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "yargs")) {
        return try bridgeYargs(allocator, io, cmd, bridge_args, prefix, environ_map);
    }

    return &.{};
}

/// Bridge: cobra — run `cmd __complete <args>`
fn bridgeCobra(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Build argv: cmd __complete <args...> <prefix>
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "__complete");
    for (args) |a| try argv.append(allocator, a);
    if (prefix.len > 0) try argv.append(allocator, prefix);

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Cobra output: lines of "value\tdescription", last line is ":directive"
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == ':') continue; // directive line
        const parsed = traverse.splitValue(trimmed);
        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, parsed.value),
            .description = try allocator.dupe(u8, parsed.description),
            .style = try allocator.dupe(u8, parsed.style),
        });
    }

    return candidates.toOwnedSlice(allocator);
}

/// Bridge: bash — run bash completion script with COMP_LINE
/// Sources bash-completion framework and calls the registered completion function.
fn bridgeBash(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Build the command line
    var cmdline = std.ArrayList(u8).empty;
    try cmdline.appendSlice(allocator, cmd);
    for (args) |a| {
        try cmdline.append(allocator, ' ');
        try cmdline.appendSlice(allocator, a);
    }
    if (prefix.len > 0) {
        try cmdline.append(allocator, ' ');
        try cmdline.appendSlice(allocator, prefix);
    }

    // Set COMP_* env vars
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| {
        var it = em.iterator();
        while (it.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try env.put("COMP_LINE", cmdline.items);
    try env.put("COMP_POINT", try std.fmt.allocPrint(allocator, "{d}", .{cmdline.items.len}));
    try env.put("COMP_TYPE", "63");

    // Build the bash script that discovers and runs the actual completion
    // Uses bash-completion framework's __load_completion and the registered -F function
    const script = try std.fmt.allocPrint(allocator,
        \\set +o history
        \\COMP_WORDS=($COMP_LINE)
        \\if [ "${{COMP_LINE: -1}}" = " " ]; then
        \\  COMP_WORDS+=("")
        \\fi
        \\COMP_CWORD=$((${{#COMP_WORDS[@]}} - 1))
        \\COMP_POINT=${{#COMP_LINE}}
        \\[ -f /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion
        \\[ -f /usr/local/share/bash-completion/bash_completion ] && source /usr/local/share/bash-completion/bash_completion
        \\[ -f /data/data/com.termux/files/usr/share/bash-completion/bash_completion ] && source /data/data/com.termux/files/usr/share/bash-completion/bash_completion
        \\__load_completion "{s}" 2>/dev/null
        \\_cf=$(complete -p "{s}" 2>/dev/null | sed -r 's/.* -F ([^ ]+).*/\\1/')
        \\if [ -n "$_cf" ]; then
        \\  "$_cf"
        \\  for i in "${{COMPREPLY[@]}}"; do
        \\    if [[ -d "$i" && "$i" != */ ]]; then echo "$i/"
        \\    else echo "$i"
        \\    fi
        \\  done
        \\fi
    , .{ cmd, cmd });
    defer allocator.free(script);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "bash", "-i", "-c", script },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
    }

    return candidates.toOwnedSlice(allocator);
}

/// Bridge: zsh — run zsh completion with compdef
fn bridgeZsh(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Build words array for zsh completion
    var words = std.ArrayList(u8).empty;
    try words.appendSlice(allocator, cmd);
    for (args) |a| {
        try words.append(allocator, ' ');
        try words.appendSlice(allocator, a);
    }
    if (prefix.len > 0) {
        try words.append(allocator, ' ');
        try words.appendSlice(allocator, prefix);
    }

    // Use zsh's compdef via a script
    const zsh_script = try std.fmt.allocPrint(allocator,
        \\autoload -U compinit; compinit -D
        \\_zsh_completion() {{
        \\  local -a completions
        \\  completions=("$@")
        \\  _describe '' completions
        \\}}
        \\compdef _zsh_completion {s}
        \\_zsh_completion "$@"
    , .{cmd});
    defer allocator.free(zsh_script);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zsh", "-f", "-c", zsh_script },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse zsh output
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // zsh format: value:description
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, trimmed[0..colon]),
                .description = try allocator.dupe(u8, trimmed[colon + 1 ..]),
            });
        } else {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
        }
    }

    return candidates.toOwnedSlice(allocator);
}

/// Bridge: fish — run fish completion with complete --do-complete
fn bridgeFish(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    _ = cmd;
    _ = args;
    _ = environ_map;
    // Fish bridge: run the command with fish's complete --do-complete
    const fish_script = try std.fmt.allocPrint(allocator, "complete -C '{s}'", .{prefix});
    defer allocator.free(fish_script);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "fish", "-c", fish_script },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = traverse.splitValue(trimmed);
        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, parsed.value),
            .description = try allocator.dupe(u8, parsed.description),
        });
    }

    return candidates.toOwnedSlice(allocator);
}

/// Bridge: carapace/carapace-bin — run `cmd _carapace export`
fn bridgeCarapace(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Build argv: cmd _carapace export <args...> <prefix>
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "_carapace");
    try argv.append(allocator, "export");
    for (args) |a| try argv.append(allocator, a);
    if (prefix.len > 0) try argv.append(allocator, prefix);

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse JSON export format
    // Simple parsing: extract "value" fields from JSON
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var rest = result.stdout;
    while (std.mem.indexOf(u8, rest, "\"value\": \"")) |start| {
        const val_start = start + 10;
        const val_end = std.mem.indexOfScalar(u8, rest[val_start..], '"') orelse break;
        const value = rest[val_start .. val_start + val_end];

        // Check for description
        var desc: []const u8 = "";
        const after_val = rest[val_start + val_end ..];
        if (std.mem.indexOf(u8, after_val, "\"description\": \"")) |desc_start| {
            const d_start = desc_start + 16;
            const d_end = std.mem.indexOfScalar(u8, after_val[d_start..], '"') orelse 0;
            if (d_end > 0) desc = after_val[d_start .. d_start + d_end];
        }

        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, value),
            .description = try allocator.dupe(u8, desc),
        });

        rest = rest[val_start + val_end ..];
    }

    return candidates.toOwnedSlice(allocator);
}

/// Bridge: argcomplete — run with _ARGCOMPLETE=1
fn bridgeArgcomplete(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Build the command line
    var cmdline = std.ArrayList(u8).empty;
    try cmdline.appendSlice(allocator, cmd);
    for (args) |a| {
        try cmdline.append(allocator, ' ');
        try cmdline.appendSlice(allocator, a);
    }
    if (prefix.len > 0) {
        try cmdline.append(allocator, ' ');
        try cmdline.appendSlice(allocator, prefix);
    }

    // Set argcomplete env vars
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| {
        var it = em.iterator();
        while (it.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try env.put("_ARGCOMPLETE", "1");
    try env.put("_ARGCOMPLETE_DFS", "\\t");
    try env.put("_ARGCOMPLETE_IFS", "\\n");
    try env.put("_ARGCOMPLETE_SHELL", "fish");
    try env.put("COMP_LINE", cmdline.items);
    try env.put("COMP_POINT", try std.fmt.allocPrint(allocator, "{d}", .{cmdline.items.len}));

    const result = std.process.run(allocator, io, .{
        .argv = &.{ cmd },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = traverse.splitValue(trimmed);
        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, parsed.value),
            .description = try allocator.dupe(u8, parsed.description),
        });
    }

    return candidates.toOwnedSlice(allocator);
}

/// Bridge: click — run with _<CMD>_COMPLETE=zsh_complete
fn bridgeClick(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Build the command line
    var cmdline = std.ArrayList(u8).empty;
    try cmdline.appendSlice(allocator, cmd);
    for (args) |a| {
        try cmdline.append(allocator, ' ');
        try cmdline.appendSlice(allocator, a);
    }
    if (prefix.len > 0) {
        try cmdline.append(allocator, ' ');
        try cmdline.appendSlice(allocator, prefix);
    }

    // Set click env vars
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| {
        var it = em.iterator();
        while (it.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try env.put("COMP_WORDS", cmdline.items);
    // COMP_CWORD: count of words
    var word_count: usize = 1;
    for (cmdline.items) |c| {
        if (c == ' ') word_count += 1;
    }
    try env.put("COMP_CWORD", try std.fmt.allocPrint(allocator, "{d}", .{word_count}));

    // Build the env var name: _<CMD>_COMPLETE (uppercased)
    var upper_name_buf: [256]u8 = undefined;
    var upper_len: usize = 0;
    for (cmd) |c| {
        upper_name_buf[upper_len] = std.ascii.toUpper(c);
        upper_len += 1;
    }
    const env_var_name = try std.fmt.allocPrint(allocator, "_{s}_COMPLETE", .{upper_name_buf[0..upper_len]});
    defer allocator.free(env_var_name);
    try env.put(env_var_name, "zsh_complete");

    const result = std.process.run(allocator, io, .{
        .argv = &.{ cmd },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Click output: groups of 3 lines: type, value, desc
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |_| {
        const value_line = if (lines.next()) |l| std.mem.trim(u8, l, " \t\r") else break;
        const desc_line = if (lines.next()) |l| std.mem.trim(u8, l, " \t\r") else "";
        if (value_line.len > 0) {
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, value_line),
                .description = try allocator.dupe(u8, desc_line),
            });
        }
    }

    return candidates.toOwnedSlice(allocator);
}

/// Bridge: powershell — run pwsh with CommandCompletion
fn bridgePowershell(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    _ = allocator;
    _ = io;
    _ = cmd;
    _ = args;
    _ = prefix;
    _ = environ_map;
    // Powershell bridge: use pwsh -Command with CommandCompletion::CompleteInput
    // Simplified: just return empty for now
    return &.{};
}

/// Bridge: yargs — run with --get-yargs-completions
fn bridgeYargs(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // Build argv: cmd --get-yargs-completions <args...> <prefix>
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "--get-yargs-completions");
    for (args) |a| try argv.append(allocator, a);
    if (prefix.len > 0) try argv.append(allocator, prefix);

    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| {
        var it = em.iterator();
        while (it.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    try env.put("SHELL", "zsh");

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // yargs format: name:description
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, trimmed[0..colon]),
                .description = try allocator.dupe(u8, trimmed[colon + 1 ..]),
            });
        } else {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
        }
    }

    return candidates.toOwnedSlice(allocator);
}

fn execCommand(allocator: std.mem.Allocator, io: std.Io, shell: []const u8, command: []const u8) ![]traverse.Candidate {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ shell, "-c", command },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
    }) catch |err| switch (err) {
        error.StreamTooLong => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            const parsed = traverse.splitValue(trimmed);
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, parsed.value),
                .description = try allocator.dupe(u8, parsed.description),
                .style = try allocator.dupe(u8, parsed.style),
            });
        }
    }

    return candidates.toOwnedSlice(allocator);
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
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expect(candidates[0].nospace);
}

test "modifier nospace no match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "abc ||| $nospace(/)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expect(!candidates[0].nospace);
}

test "modifier noprefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a/b ||| $noprefix(/)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expect(candidates[0].nospace);
}

test "modifier style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "val ||| $style(bold)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("bold", candidates[0].style);
}

test "modifier tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "val ||| $tag(mytag)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
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

test "modifier filterargs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $filterargs", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("a", candidates[0].value);
}

test "modifier retain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo one; echo two; echo three) ||| $retain([one, two])", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}

test "modifier shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $shift(1)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("a", candidates[0].value);
}

test "modifier suppress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $suppress(fail)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("a", candidates[0].value);
}

test "modifier usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $usage(custom)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("a", candidates[0].value);
    try std.testing.expectEqualStrings("custom", candidates[0].description);
}

test "modifier uid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $uid([https, example.com])", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("a", candidates[0].value);
}

test "modifier chaining prefix then filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo a; echo b; echo x) ||| $filter([x]) ||| $prefix(p/)", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("p/a", candidates[0].value);
    try std.testing.expectEqualStrings("p/b", candidates[1].value);
}

test "modifier chaining filter then prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo a; echo b; echo x) ||| $prefix(p/) ||| $filter([x])", "", null);
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

test "files macro returns files in current directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$files", "", null);
    try std.testing.expect(candidates.len > 0);
}

test "directories macro returns directories in current directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$directories", "", null);
    try std.testing.expect(candidates.len > 0);
}

test "executables macro returns empty with null env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$executables", "", null);
    try std.testing.expect(candidates.len == 0);
}

test "executables macro with PATH env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    try env_map.put("PATH", "/usr/bin:/bin");
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$executables", "", &env_map);
    try std.testing.expect(candidates.len > 0);
}

test "bare dollar shorthand $(cmd) matches $sh(cmd)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$(echo one; echo two)", "", null);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}

test "split modifier returns last segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a/b/c ||| $split(/)" , "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("c", candidates[0].value);
}

test "splitp modifier returns last pipeline segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a|b|c ||| $splitp" , "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("c", candidates[0].value);
}

test "chdir macro resolves userhomedir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try resolveMacro(arena.allocator(), std.testing.io, "$chdir($userhomedir)", "", null);
    // Just verify it doesn't crash — returns candidates from the home directory
}

test "message macro returns empty value with description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$message(no matches)", "", null);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("", candidates[0].value);
    try std.testing.expectEqualStrings("no matches", candidates[0].description);
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