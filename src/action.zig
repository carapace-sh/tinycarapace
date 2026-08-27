const std = @import("std");
const traverse = @import("traverse.zig");

/// Resolve a macro string into candidates.
/// Handles exec macros ($sh, $bash, $pwsh), modifiers (||| chaining), and static values.
pub fn resolveMacro(allocator: std.mem.Allocator, io: std.Io, macro: []const u8) ![]traverse.Candidate {
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
        var candidates = try resolveMacro(allocator, io, parts.items[0]);

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

    // Handle exec macros: $sh(command), $bash(command), $pwsh(command)
    const exec_macro = comptime [_]struct { prefix: []const u8, shell: []const u8 }{
        .{ .prefix = "$sh(", .shell = "sh" },
        .{ .prefix = "$bash(", .shell = "bash" },
        .{ .prefix = "$pwsh(", .shell = "pwsh" },
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

    // All modifiers start with $ and have (args)
    if (trimmed.len < 4 or trimmed[0] != '$') return error.InvalidModifier;
    const paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.InvalidModifier;
    if (trimmed[trimmed.len - 1] != ')') return error.InvalidModifier;
    const name = trimmed[1..paren];
    const args = trimmed[paren + 1 .. trimmed.len - 1];

    if (std.mem.eql(u8, name, "prefix")) {
        return try modPrefix(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "suffix")) {
        return try modSuffix(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "nospace")) {
        return try modNospace(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "style")) {
        return try modStyle(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "tag")) {
        return try modTag(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "filter")) {
        return try modFilter(allocator, candidates, args);
    } else if (std.mem.eql(u8, name, "retain")) {
        return try modRetain(allocator, candidates, args);
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
    // args is a YAML flow sequence like [val1, val2]
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
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo one; echo two)");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}

test "exec macro handles empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(true)");
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "static value returns itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "hello");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("hello", candidates[0].value);
}

test "static value with description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "hello\tgreeting");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("hello", candidates[0].value);
    try std.testing.expectEqualStrings("greeting", candidates[0].description);
}

test "exec macro with tab-separated descriptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(printf 'one\tfirst\\ntwo\tsecond')");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("first", candidates[0].description);
    try std.testing.expectEqualStrings("two", candidates[1].value);
    try std.testing.expectEqualStrings("second", candidates[1].description);
}

test "modifier prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $prefix(p/)");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("p/a", candidates[0].value);
}

test "modifier suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a ||| $suffix(/suf)");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("a/suf", candidates[0].value);
}

test "modifier nospace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "a/b ||| $nospace(/)");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expect(candidates[0].nospace);
}

test "modifier nospace no match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "abc ||| $nospace(/)");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expect(!candidates[0].nospace);
}

test "modifier style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "val ||| $style(bold)");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("bold", candidates[0].style);
}

test "modifier tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "val ||| $tag(mytag)");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("mytag", candidates[0].tag);
}

test "modifier filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo one; echo two; echo three) ||| $filter([two])");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("three", candidates[1].value);
}

test "modifier retain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo one; echo two; echo three) ||| $retain([one, two])");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}

test "modifier chaining prefix then filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Rightmost runs first: $prefix adds p/, then $filter removes p/x
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo a; echo b; echo x) ||| $filter([x]) ||| $prefix(p/)");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("p/a", candidates[0].value);
    try std.testing.expectEqualStrings("p/b", candidates[1].value);
}

test "modifier chaining filter then prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Rightmost runs first: $filter removes x, then $prefix adds p/ to remaining
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo a; echo b; echo x) ||| $prefix(p/) ||| $filter([x])");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("p/a", candidates[0].value);
    try std.testing.expectEqualStrings("p/b", candidates[1].value);
}

test "modifier on static value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "hello ||| $prefix(--) ||| $suffix(=)");
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("--hello=", candidates[0].value);
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

test "parse flow list empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseFlowList(arena.allocator(), "[]");
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse flow list single" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = try parseFlowList(arena.allocator(), "[only]");
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("only", items[0]);
}

test "modifier with exec macro as base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try resolveMacro(arena.allocator(), std.testing.io, "$sh(echo foo; echo bar) ||| $prefix(/usr/)");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("/usr/foo", candidates[0].value);
    try std.testing.expectEqualStrings("/usr/bar", candidates[1].value);
}