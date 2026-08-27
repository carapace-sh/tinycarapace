const std = @import("std");

pub const Flag = struct {
    longhand: []const u8 = "",
    shorthand: []const u8 = "",
    description: []const u8 = "",
    takes_value: bool = false,
    optarg: bool = false,
    repeatable: bool = false,
    hidden: bool = false,
    required: bool = false,
    name_as_shorthand: bool = false,
    nargs: i32 = 0,
    default: []const u8 = "",

    pub fn name(self: Flag) []const u8 {
        if (self.longhand.len > 0) return self.longhand;
        return self.shorthand;
    }

    pub fn matches(self: Flag, arg: []const u8) bool {
        if (self.longhand.len > 0 and std.mem.eql(u8, arg, self.longhand)) return true;
        if (self.shorthand.len > 0 and std.mem.eql(u8, arg, self.shorthand)) return true;
        return false;
    }

    pub fn isNonPosix(self: Flag) bool {
        return self.name_as_shorthand or self.shorthand.len > 1;
    }

    pub fn display(self: Flag, buf: []u8) []const u8 {
        var pos: usize = 0;
        if (self.shorthand.len > 0) {
            buf[pos] = '-';
            pos += 1;
            @memcpy(buf[pos .. pos + self.shorthand.len], self.shorthand);
            pos += self.shorthand.len;
            if (self.longhand.len > 0) {
                buf[pos] = ',';
                pos += 1;
                buf[pos] = ' ';
                pos += 1;
            }
        }
        if (self.longhand.len > 0) {
            if (self.name_as_shorthand) {
                buf[pos] = '-';
                pos += 1;
            } else {
                buf[pos] = '-';
                pos += 1;
                buf[pos] = '-';
                pos += 1;
            }
            @memcpy(buf[pos .. pos + self.longhand.len], self.longhand);
            pos += self.longhand.len;
        }
        if (self.optarg) {
            buf[pos] = '?';
            pos += 1;
        } else if (self.takes_value) {
            buf[pos] = '=';
            pos += 1;
        }
        if (self.repeatable) {
            buf[pos] = '*';
            pos += 1;
        }
        if (self.required) {
            buf[pos] = '!';
            pos += 1;
        }
        if (self.hidden) {
            buf[pos] = '&';
            pos += 1;
        }
        return buf[0..pos];
    }
};

pub fn parseFlag(key: []const u8, description: []const u8) Flag {
    var f = Flag{ .description = description };

    // Split into [shorthand, longhand, modifiers] parts
    // carapace-spec regex: ^(shorthand)?(, )?(longhand)?(modifiers)$
    // shorthand: -[^-][^ =*?&!]*  (single dash, not double-dash)
    // longhand:  -[-]?[^ =*?&!]*  (single or double dash)
    // modifiers: [=*?&!]*          (any combination)

    // First, extract modifiers from the end of the string
    var modifiers_len: usize = 0;
    while (modifiers_len < key.len) {
        const c = key[key.len - 1 - modifiers_len];
        switch (c) {
            '=', '*', '?', '&', '!' => modifiers_len += 1,
            else => break,
        }
    }
    const modifiers = key[key.len - modifiers_len ..];
    const body = key[0 .. key.len - modifiers_len];

    // Parse modifiers (order-independent, like carapace-spec)
    for (modifiers) |c| {
        switch (c) {
            '*' => f.repeatable = true,
            '?' => {
                f.optarg = true;
                f.takes_value = true;
            },
            '=' => f.takes_value = true,
            '&' => f.hidden = true,
            '!' => f.required = true,
            else => {},
        }
    }

    // Split body on ", " to get shorthand and longhand parts
    if (std.mem.indexOf(u8, body, ", ")) |sep| {
        const left = body[0..sep];
        const right = body[sep + 2 ..];
        // Left is always shorthand (single dash)
        if (left.len > 1 and left[0] == '-' and left[1] != '-') {
            f.shorthand = left[1..];
        }
        // Right can be --longhand (POSIX) or -longhand (non-POSIX)
        if (right.len > 2 and right[0] == '-' and right[1] == '-') {
            f.longhand = right[2..];
        } else if (right.len > 1 and right[0] == '-') {
            f.longhand = right[1..];
            f.name_as_shorthand = true;
        }
    } else {
        // Single part: either shorthand or longhand
        if (body.len > 2 and body[0] == '-' and body[1] == '-') {
            f.longhand = body[2..];
        } else if (body.len > 1 and body[0] == '-') {
            // Could be shorthand-only or non-posix longhand-only
            // carapace-spec treats single-dash, single-char as shorthand
            // and single-dash, multi-char as non-posix shorthand
            f.shorthand = body[1..];
        }
    }

    return f;
}

test "parse --verbose" {
    const f = parseFlag("--verbose", "verbose");
    try std.testing.expectEqualStrings("verbose", f.longhand);
    try std.testing.expect(!f.takes_value);
    try std.testing.expect(!f.name_as_shorthand);
}

test "parse -o, --output=" {
    const f = parseFlag("-o, --output=", "output file");
    try std.testing.expectEqualStrings("o", f.shorthand);
    try std.testing.expectEqualStrings("output", f.longhand);
    try std.testing.expect(f.takes_value);
    try std.testing.expect(!f.name_as_shorthand);
}

test "parse --optarg?=" {
    const f = parseFlag("--optarg?=", "optarg");
    try std.testing.expectEqualStrings("optarg", f.longhand);
    try std.testing.expect(f.optarg);
    try std.testing.expect(f.takes_value);
}

test "parse --repeatable*" {
    const f = parseFlag("--repeatable*", "repeatable");
    try std.testing.expectEqualStrings("repeatable", f.longhand);
    try std.testing.expect(f.repeatable);
}

test "parse --hidden&" {
    const f = parseFlag("--hidden&", "hidden");
    try std.testing.expect(f.hidden);
}

test "parse -b" {
    const f = parseFlag("-b", "bool");
    try std.testing.expectEqualStrings("b", f.shorthand);
    try std.testing.expect(!f.takes_value);
}

test "flag matches" {
    const f = parseFlag("-o, --output=", "output");
    try std.testing.expect(f.matches("o"));
    try std.testing.expect(f.matches("output"));
    try std.testing.expect(!f.matches("verbose"));
}

test "flag display" {
    const f = parseFlag("-o, --output=", "output");
    var buf: [64]u8 = undefined;
    const d = f.display(&buf);
    try std.testing.expectEqualStrings("-o, --output=", d);
}

test "parse shorthand-only slice" {
    const f = parseFlag("-s*", "repeatable");
    try std.testing.expectEqualStrings("s", f.shorthand);
    try std.testing.expect(f.repeatable);
}

test "parse shorthand-only slice value" {
    const f = parseFlag("-s*=", "repeatable value");
    try std.testing.expectEqualStrings("s", f.shorthand);
    try std.testing.expect(f.repeatable);
    try std.testing.expect(f.takes_value);
}

test "parse shorthand-only value" {
    const f = parseFlag("-s=", "value");
    try std.testing.expectEqualStrings("s", f.shorthand);
    try std.testing.expect(f.takes_value);
}

test "parse shorthand-only optarg" {
    const f = parseFlag("-s?", "optarg");
    try std.testing.expectEqualStrings("s", f.shorthand);
    try std.testing.expect(f.takes_value);
    try std.testing.expect(f.optarg);
}

test "parse longhand-only value" {
    const f = parseFlag("--long=", "value");
    try std.testing.expectEqualStrings("long", f.longhand);
    try std.testing.expect(f.takes_value);
}

test "parse longhand-only slice optarg" {
    const f = parseFlag("--long*?", "slice optarg");
    try std.testing.expectEqualStrings("long", f.longhand);
    try std.testing.expect(f.optarg);
    try std.testing.expect(f.repeatable);
    try std.testing.expect(f.takes_value);
}

test "parse both" {
    const f = parseFlag("-s, --long", "both");
    try std.testing.expectEqualStrings("s", f.shorthand);
    try std.testing.expectEqualStrings("long", f.longhand);
    try std.testing.expect(!f.takes_value);
    try std.testing.expect(!f.name_as_shorthand);
}

test "parse both value" {
    const f = parseFlag("-s, --long=", "both value");
    try std.testing.expectEqualStrings("s", f.shorthand);
    try std.testing.expectEqualStrings("long", f.longhand);
    try std.testing.expect(f.takes_value);
}

test "parse both optarg" {
    const f = parseFlag("-s, --long?", "both optarg");
    try std.testing.expectEqualStrings("s", f.shorthand);
    try std.testing.expectEqualStrings("long", f.longhand);
    try std.testing.expect(f.takes_value);
    try std.testing.expect(f.optarg);
}

test "parse both slice optarg" {
    const f = parseFlag("-s, --long*?", "both slice optarg");
    try std.testing.expectEqualStrings("s", f.shorthand);
    try std.testing.expectEqualStrings("long", f.longhand);
    try std.testing.expect(f.takes_value);
    try std.testing.expect(f.repeatable);
    try std.testing.expect(f.optarg);
}

test "parse nonposix shorthand" {
    const f = parseFlag("-short", "nonposix shorthand");
    try std.testing.expectEqualStrings("short", f.shorthand);
    try std.testing.expectEqualStrings("", f.longhand);
}

test "parse nonposix shorthand optarg" {
    const f = parseFlag("-short?", "nonposix optarg");
    try std.testing.expectEqualStrings("short", f.shorthand);
    try std.testing.expect(f.takes_value);
    try std.testing.expect(f.optarg);
}

test "parse nonposix both" {
    const f = parseFlag("-short, -long*", "nonposix both");
    try std.testing.expectEqualStrings("short", f.shorthand);
    try std.testing.expectEqualStrings("long", f.longhand);
    try std.testing.expect(f.repeatable);
    try std.testing.expect(f.name_as_shorthand);
}

test "parse nonposix mixed" {
    const f = parseFlag("-short, --long", "nonposix mixed");
    try std.testing.expectEqualStrings("short", f.shorthand);
    try std.testing.expectEqualStrings("long", f.longhand);
    try std.testing.expect(!f.name_as_shorthand);
}

test "nonposix flag display" {
    const f = parseFlag("-short, -long*", "nonposix");
    var buf: [64]u8 = undefined;
    const d = f.display(&buf);
    try std.testing.expectEqualStrings("-short, -long*", d);
}

test "nonposix flag matches" {
    const f = parseFlag("-short, -long*", "nonposix");
    try std.testing.expect(f.matches("short"));
    try std.testing.expect(f.matches("long"));
    try std.testing.expect(!f.matches("other"));
}

test "nonposix isNonPosix" {
    const f1 = parseFlag("-short", "nonposix");
    try std.testing.expect(f1.isNonPosix());
    const f2 = parseFlag("-s", "posix");
    try std.testing.expect(!f2.isNonPosix());
    const f3 = parseFlag("-short, -long", "nonposix both");
    try std.testing.expect(f3.isNonPosix());
    const f4 = parseFlag("-short, --long", "nonposix mixed");
    try std.testing.expect(f4.isNonPosix());
}
