const std = @import("std");

/// Minimal port of carapace's style system (pkg/style + elvish ui subset).
/// SGR output contains bare numeric codes ("1;31") suitable for zsh
/// list-colors; callers wrap with ESC sequences where needed.

const Color = union(enum) {
    ansi: u8,
    ansi_bright: u8,
    xterm256: u8,
    truecolor: [3]u8,
};

const State = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underlined: bool = false,
    blink: bool = false,
    inverse: bool = false,
};

const basic_names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

fn parseColor(name: []const u8) ?Color {
    for (basic_names, 0..) |n, i| {
        if (std.mem.eql(u8, name, n)) return .{ .ansi = @intCast(i) };
    }
    if (std.mem.startsWith(u8, name, "bright-")) {
        for (basic_names, 0..) |n, i| {
            if (std.mem.eql(u8, name[7..], n)) return .{ .ansi_bright = @intCast(i) };
        }
        return null;
    }
    if (std.fmt.parseInt(u8, name, 10)) |v| {
        return .{ .xterm256 = v };
    } else |_| {}
    if (name.len > 1 and name[0] == '#') {
        const hex = name[1..];
        var rgb: [3]u8 = undefined;
        if (hex.len == 3) {
            inline for (0..3) |i| {
                const v = std.fmt.parseInt(u8, hex[i .. i + 1], 16) catch return null;
                rgb[i] = v * 17;
            }
            return .{ .truecolor = rgb };
        }
        if (hex.len == 6) {
            inline for (0..3) |i| {
                rgb[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return null;
            }
            return .{ .truecolor = rgb };
        }
    }
    return null;
}

fn parseOneStyling(state: *State, name: []const u8) bool {
    if (std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "fg-default")) {
        state.fg = null;
        return true;
    }
    if (std.mem.startsWith(u8, name, "fg-")) {
        if (parseColor(name[3..])) |c| {
            state.fg = c;
            return true;
        }
        return false;
    }
    if (std.mem.eql(u8, name, "bg-default")) {
        state.bg = null;
        return true;
    }
    if (std.mem.startsWith(u8, name, "bg-")) {
        if (parseColor(name[3..])) |c| {
            state.bg = c;
            return true;
        }
        return false;
    }
    if (std.mem.startsWith(u8, name, "no-")) {
        const rest = name[3..];
        if (std.mem.eql(u8, rest, "bold")) { state.bold = false; return true; }
        if (std.mem.eql(u8, rest, "dim")) { state.dim = false; return true; }
        if (std.mem.eql(u8, rest, "italic")) { state.italic = false; return true; }
        if (std.mem.eql(u8, rest, "underlined")) { state.underlined = false; return true; }
        if (std.mem.eql(u8, rest, "blink")) { state.blink = false; return true; }
        if (std.mem.eql(u8, rest, "inverse")) { state.inverse = false; return true; }
        return false;
    }
    if (std.mem.startsWith(u8, name, "toggle-")) {
        const rest = name[7..];
        if (std.mem.eql(u8, rest, "bold")) { state.bold = !state.bold; return true; }
        if (std.mem.eql(u8, rest, "dim")) { state.dim = !state.dim; return true; }
        if (std.mem.eql(u8, rest, "italic")) { state.italic = !state.italic; return true; }
        if (std.mem.eql(u8, rest, "underlined")) { state.underlined = !state.underlined; return true; }
        if (std.mem.eql(u8, rest, "blink")) { state.blink = !state.blink; return true; }
        if (std.mem.eql(u8, rest, "inverse")) { state.inverse = !state.inverse; return true; }
        return false;
    }
    if (std.mem.eql(u8, name, "bold")) { state.bold = true; return true; }
    if (std.mem.eql(u8, name, "dim")) { state.dim = true; return true; }
    if (std.mem.eql(u8, name, "italic")) { state.italic = true; return true; }
    if (std.mem.eql(u8, name, "underlined")) { state.underlined = true; return true; }
    if (std.mem.eql(u8, name, "blink")) { state.blink = true; return true; }
    if (std.mem.eql(u8, name, "inverse")) { state.inverse = true; return true; }
    if (parseColor(name)) |c| {
        state.fg = c;
        return true;
    }
    return false;
}

/// Validate a style string (all tokens must be recognized).
pub fn isValid(style_str: []const u8) bool {
    var state = State{};
    var it = std.mem.splitScalar(u8, style_str, ' ');
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (!parseOneStyling(&state, token)) return false;
    }
    return true;
}

fn appendColorCodes(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, c: Color, bg: bool) !void {
    const fg_base: u8 = 30;
    const bg_base: u8 = 40;
    const fg_bright_base: u8 = 90;
    const bg_bright_base: u8 = 100;
    switch (c) {
        .ansi => |v| try buf.print(allocator, "{d};", .{(if (bg) bg_base else fg_base) + v}),
        .ansi_bright => |v| try buf.print(allocator, "{d};", .{(if (bg) bg_bright_base else fg_bright_base) + v}),
        .xterm256 => |v| try buf.print(allocator, "{s}5;{d};", .{ if (bg) "48;" else "38;", v }),
        .truecolor => |rgb| try buf.print(allocator, "{s}2;{d};{d};{d};", .{ if (bg) "48;" else "38;", rgb[0], rgb[1], rgb[2] }),
    }
}

/// SGR numeric codes for a style string (e.g. "1;31"), or "" if unset.
/// Invalid tokens are skipped like upstream's style.Parse.
pub fn sgr(allocator: std.mem.Allocator, style_str: []const u8) ![]const u8 {
    var state = State{};
    var it = std.mem.splitScalar(u8, style_str, ' ');
    while (it.next()) |token| {
        if (token.len == 0) continue;
        _ = parseOneStyling(&state, token);
    }

    var buf = std.ArrayList(u8).empty;
    if (state.bold) try buf.appendSlice(allocator, "1;");
    if (state.dim) try buf.appendSlice(allocator, "2;");
    if (state.italic) try buf.appendSlice(allocator, "3;");
    if (state.underlined) try buf.appendSlice(allocator, "4;");
    if (state.blink) try buf.appendSlice(allocator, "5;");
    if (state.inverse) try buf.appendSlice(allocator, "7;");
    if (state.fg) |c| try appendColorCodes(&buf, allocator, c, false);
    if (state.bg) |c| try appendColorCodes(&buf, allocator, c, true);
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ';') {
        _ = buf.pop();
    }
    return buf.toOwnedSlice(allocator);
}

test "sgr basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("", try sgr(a, ""));
    try std.testing.expectEqualStrings("1;31", try sgr(a, "bold red"));
    try std.testing.expectEqualStrings("94", try sgr(a, "fg-bright-blue"));
    try std.testing.expectEqualStrings("42", try sgr(a, "bg-green"));
    try std.testing.expectEqualStrings("4;38;5;128", try sgr(a, "underlined 128"));
    try std.testing.expectEqualStrings("38;2;255;0;0", try sgr(a, "#ff0000"));
    try std.testing.expectEqualStrings("38;2;255;0;0", try sgr(a, "#f00"));
    try std.testing.expectEqualStrings("", try sgr(a, "not-a-color"));
    try std.testing.expectEqualStrings("31", try sgr(a, "bogus red"));
}

test "isValid" {
    try std.testing.expect(isValid("bold red"));
    try std.testing.expect(isValid(""));
    try std.testing.expect(isValid("fg-default bg-default"));
    try std.testing.expect(!isValid("bogus red"));
}
