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

    pub fn name(self: Flag) []const u8 {
        if (self.longhand.len > 0) return self.longhand;
        return self.shorthand;
    }

    pub fn matches(self: Flag, arg: []const u8) bool {
        if (self.longhand.len > 0 and std.mem.eql(u8, arg, self.longhand)) return true;
        if (self.shorthand.len > 0 and std.mem.eql(u8, arg, self.shorthand)) return true;
        return false;
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
            buf[pos] = '-';
            pos += 1;
            buf[pos] = '-';
            pos += 1;
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
    var s = key;

    if (std.mem.indexOf(u8, s, ", ")) |sep| {
        const left = s[0..sep];
        const right = s[sep + 2 ..];
        if (left.len > 0 and left[0] == '-') {
            if (left.len > 1 and left[1] == '-') {
                f.longhand = left[2..];
            } else {
                f.shorthand = left[1..];
            }
        }
        s = right;
    }

    if (s.len > 0 and s[0] == '-') {
        if (s.len > 1 and s[1] == '-') {
            f.longhand = s[2..];
        } else {
            if (f.longhand.len == 0 and f.shorthand.len == 0) {
                f.shorthand = s[1..];
            } else if (f.shorthand.len == 0) {
                f.shorthand = s[1..];
            } else {
                f.longhand = s[1..];
            }
        }
    }

    var rest = if (f.longhand.len > 0) f.longhand else f.shorthand;
    while (rest.len > 0) {
        switch (rest[rest.len - 1]) {
            '*' => {
                f.repeatable = true;
                rest = rest[0 .. rest.len - 1];
            },
            '!' => {
                f.required = true;
                rest = rest[0 .. rest.len - 1];
            },
            '&' => {
                f.hidden = true;
                rest = rest[0 .. rest.len - 1];
            },
            '?' => {
                f.optarg = true;
                f.takes_value = true;
                rest = rest[0 .. rest.len - 1];
            },
            '=' => {
                f.takes_value = true;
                rest = rest[0 .. rest.len - 1];
            },
            else => break,
        }
    }

    if (f.longhand.len > 0) {
        f.longhand = stripSuffixes(f.longhand);
    }
    if (f.shorthand.len > 0) {
        f.shorthand = stripSuffixes(f.shorthand);
    }

    return f;
}

fn stripSuffixes(s: []const u8) []const u8 {
    var r = s;
    while (r.len > 0) {
        switch (r[r.len - 1]) {
            '*', '!', '&', '?', '=' => r = r[0 .. r.len - 1],
            else => break,
        }
    }
    return r;
}

test "parse --verbose" {
    const f = parseFlag("--verbose", "verbose");
    try std.testing.expectEqualStrings("verbose", f.longhand);
    try std.testing.expect(!f.takes_value);
}

test "parse -o, --output=" {
    const f = parseFlag("-o, --output=", "output file");
    try std.testing.expectEqualStrings("o", f.shorthand);
    try std.testing.expectEqualStrings("output", f.longhand);
    try std.testing.expect(f.takes_value);
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
