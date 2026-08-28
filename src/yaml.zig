const std = @import("std");

pub const Value = union(enum) {
    scalar: []const u8,
    list: []Value,
    map: []KV,

    pub const KV = struct {
        key: []const u8,
        value: Value,
    };

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .map => |m| blk: {
                for (m) |kv| {
                    if (std.mem.eql(u8, kv.key, key)) break :blk kv.value;
                }
                break :blk null;
            },
            else => null,
        };
    }

    pub fn getList(self: Value, key: []const u8) ?[]Value {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .list => |l| l,
            else => null,
        };
    }

    pub fn getMap(self: Value, key: []const u8) ?[]KV {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .map => |m| m,
            else => null,
        };
    }

    pub fn getScalar(self: Value, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .scalar => |s| s,
            else => null,
        };
    }
};

/// Helper to get a scalar value from a raw KV slice (map entries).
pub fn getScalarFromMap(map: []const Value.KV, key: []const u8) ?[]const u8 {
    for (map) |kv| {
        if (std.mem.eql(u8, kv.key, key)) {
            return switch (kv.value) {
                .scalar => |s| s,
                else => null,
            };
        }
    }
    return null;
}

const Parser = struct {
    arena: std.heap.ArenaAllocator,
    src: []const u8,
    pos: usize = 0,

    fn init(a: std.mem.Allocator, src: []const u8) Parser {
        return .{ .arena = std.heap.ArenaAllocator.init(a), .src = src };
    }

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn dup(self: *Parser, s: []const u8) []const u8 {
        return self.alloc().dupe(u8, s) catch unreachable;
    }

    fn skipBlanks(self: *Parser) void {
        while (self.pos < self.src.len) {
            // Skip newline
            if (self.src[self.pos] == '\n') {
                self.pos += 1;
                continue;
            }
            if (self.src[self.pos] == '\r') {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '\n') self.pos += 1;
                continue;
            }
            // Skip whitespace, check if rest of line is blank or comment
            if (self.src[self.pos] == ' ' or self.src[self.pos] == '\t') {
                const save = self.pos;
                while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '\n') {
                    self.pos += 1;
                    continue;
                }
                if (self.pos < self.src.len and self.src[self.pos] == '#') {
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                    continue;
                }
                self.pos = save;
                return;
            }
            // Comment line
            if (self.src[self.pos] == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            return;
        }
    }

    fn countIndent(self: *Parser) usize {
        var n: usize = 0;
        while (self.pos < self.src.len and self.src[self.pos] == ' ') {
            n += 1;
            self.pos += 1;
        }
        return n;
    }

    fn atSeqEntry(self: *Parser) bool {
        if (self.pos >= self.src.len) return false;
        if (self.src[self.pos] != '-') return false;
        if (self.pos + 1 >= self.src.len) return true;
        const next = self.src[self.pos + 1];
        return next == ' ' or next == '\n';
    }

    fn findColon(self: *Parser, from: usize) ?usize {
        var i = from;
        while (i < self.src.len and self.src[i] != '\n') {
            if (self.src[i] == ':' and (i + 1 >= self.src.len or self.src[i + 1] == ' ' or self.src[i + 1] == '\n')) {
                return i;
            }
            i += 1;
        }
        return null;
    }

    fn skipToEOL(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
        if (self.pos < self.src.len) self.pos += 1;
    }

    fn readInline(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
        const end = self.pos;
        if (self.pos < self.src.len) self.pos += 1;
        var s = std.mem.trim(u8, self.src[start..end], " \t\r");
        // strip trailing comment
        if (std.mem.indexOfScalar(u8, s, '#')) |hash_pos| {
            if (hash_pos > 0 and s[hash_pos - 1] == ' ') {
                s = std.mem.trim(u8, s[0..hash_pos], " \t");
            }
        }
        return s;
    }

    fn parse(self: *Parser) anyerror!Value {
        self.skipBlanks();
        if (self.pos >= self.src.len) return .{ .scalar = "" };

        const indent = self.countIndent();
        if (self.atSeqEntry()) return self.parseList(indent);
        if (self.src[self.pos] == '[') return self.parseFlowSeq();
        if (self.src[self.pos] == '{') return self.parseFlowMap();

        if (self.findColon(self.pos) != null) return self.parseMap(indent);
        return .{ .scalar = self.dup(self.readInline()) };
    }

    fn parseMap(self: *Parser, indent: usize) anyerror!Value {
        var entries: std.ArrayList(Value.KV) = .empty;

        while (true) {
            self.skipBlanks();
            if (self.pos >= self.src.len) break;

            const save = self.pos;
            const line_indent = self.countIndent();
            if (line_indent < indent) {
                self.pos = save;
                break;
            }
            if (self.pos >= self.src.len or self.src[self.pos] == '\n' or self.src[self.pos] == '#') {
                self.pos = save;
                break;
            }
            if (self.atSeqEntry()) {
                self.pos = save;
                break;
            }

            const colon = self.findColon(self.pos) orelse {
                self.pos = save;
                break;
            };

            const key = std.mem.trim(u8, self.src[self.pos..colon], " \t");
            self.pos = colon + 1;
            while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;

            // Empty value on this line → check for block content on next line
            if (self.pos >= self.src.len or self.src[self.pos] == '\n' or self.src[self.pos] == '#') {
                self.skipToEOL();
                const block_pos = self.pos;
                self.skipBlanks();
                if (self.pos >= self.src.len) {
                    self.pos = block_pos;
                    try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = "" } });
                    continue;
                }
                const block_indent = self.countIndent();
                if (block_indent > indent) {
                    self.pos = block_pos;
                    const val = try self.parseBlock(block_indent);
                    try entries.append(self.alloc(), .{ .key = self.dup(key), .value = val });
                } else {
                    self.pos = block_pos;
                    try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = "" } });
                }
                continue;
            }

            // Inline value
            const c = self.src[self.pos];
            if (c == '|') {
                // Literal block scalar: run: |
                //   #!/bin/bash
                //   echo hello
                const val = try self.parseLiteralBlock(indent);
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = self.dup(val) } });
            } else if (c == '[') {
                const val = try self.parseFlowSeq();
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = val });
                self.skipToEOL();
            } else if (c == '{') {
                const val = try self.parseFlowMap();
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = val });
                self.skipToEOL();
            } else {
                const val = self.readInline();
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = self.dup(val) } });
            }
        }

        return .{ .map = try entries.toOwnedSlice(self.alloc()) };
    }

    fn parseList(self: *Parser, indent: usize) anyerror!Value {
        var items: std.ArrayList(Value) = .empty;

        while (true) {
            self.skipBlanks();
            if (self.pos >= self.src.len) break;

            const save = self.pos;
            const line_indent = self.countIndent();
            if (line_indent < indent) {
                self.pos = save;
                break;
            }
            if (!self.atSeqEntry()) {
                self.pos = save;
                break;
            }

            // Consume '- '
            self.pos += 1;
            if (self.pos < self.src.len and self.src[self.pos] == ' ') self.pos += 1;

            // Empty after dash → check for block content
            if (self.pos >= self.src.len or self.src[self.pos] == '\n') {
                self.skipToEOL();
                const block_pos = self.pos;
                self.skipBlanks();
                if (self.pos >= self.src.len) {
                    self.pos = block_pos;
                    try items.append(self.alloc(), .{ .scalar = "" });
                    continue;
                }
                const block_indent = self.countIndent();
                if (block_indent > indent) {
                    self.pos = block_pos;
                    const val = try self.parseBlock(block_indent);
                    try items.append(self.alloc(), val);
                } else {
                    self.pos = block_pos;
                    try items.append(self.alloc(), .{ .scalar = "" });
                }
                continue;
            }

            // Inline content after dash
            const c = self.src[self.pos];
            if (c == '[') {
                const val = try self.parseFlowSeq();
                try items.append(self.alloc(), val);
                self.skipToEOL();
            } else if (c == '{') {
                const val = try self.parseFlowMap();
                try items.append(self.alloc(), val);
                self.skipToEOL();
            } else if (self.findColon(self.pos) != null) {
                // Map item: key starts on same line as dash
                const item_indent = indent + 2;
                const val = try self.parseInlineMap(item_indent);
                try items.append(self.alloc(), val);
            } else {
                const val = self.readInline();
                try items.append(self.alloc(), .{ .scalar = self.dup(val) });
            }
        }

        return .{ .list = try items.toOwnedSlice(self.alloc()) };
    }

    fn parseBlock(self: *Parser, _: usize) anyerror!Value {
        self.skipBlanks();
        const li = self.countIndent();
        if (self.atSeqEntry()) {
            self.pos -= li;
            return self.parseList(li);
        }
        if (self.pos < self.src.len and self.src[self.pos] == '[') return self.parseFlowSeq();
        if (self.pos < self.src.len and self.src[self.pos] == '{') return self.parseFlowMap();
        if (self.pos < self.src.len and self.src[self.pos] == '|') return .{ .scalar = self.dup(try self.parseLiteralBlock(li)) };
        if (self.findColon(self.pos) != null) {
            self.pos -= li;
            return self.parseMap(li);
        }
        return .{ .scalar = self.dup(self.readInline()) };
    }

    /// Parse a literal block scalar: `|` followed by indented lines.
    fn parseLiteralBlock(self: *Parser, indent: usize) ![]const u8 {
        // The `|` has been consumed, skip to end of line
        self.skipToEOL();
        const block_start = self.pos;
        // Read all lines indented deeper than `indent`
        while (self.pos < self.src.len) {
            const save = self.pos;
            const line_indent = self.countIndent();
            if (line_indent <= indent) {
                self.pos = save;
                break;
            }
            if (self.pos >= self.src.len or self.src[self.pos] == '\n' or self.src[self.pos] == '#') {
                self.skipToEOL();
                continue;
            }
            // Skip indentation and read the rest of the line
            while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            if (self.pos < self.src.len) self.pos += 1;
        }
        const block_end = self.pos;
        return self.dup(self.src[block_start..block_end]);
    }

    fn parseInlineMap(self: *Parser, indent: usize) anyerror!Value {
        var entries: std.ArrayList(Value.KV) = .empty;

        // First key is on the same line as '- '
        const colon = self.findColon(self.pos) orelse {
            const val = self.readInline();
            return .{ .scalar = self.dup(val) };
        };

        const key = std.mem.trim(u8, self.src[self.pos..colon], " \t");
        self.pos = colon + 1;
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;

        if (self.pos >= self.src.len or self.src[self.pos] == '\n' or self.src[self.pos] == '#') {
            self.skipToEOL();
            const block_pos = self.pos;
            self.skipBlanks();
            if (self.pos >= self.src.len) {
                self.pos = block_pos;
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = "" } });
            } else {
                const block_indent = self.countIndent();
                if (block_indent > indent) {
                    self.pos = block_pos;
                    const val = try self.parseBlock(block_indent);
                    try entries.append(self.alloc(), .{ .key = self.dup(key), .value = val });
                } else {
                    self.pos = block_pos;
                    try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = "" } });
                }
            }
        } else {
            const c = self.src[self.pos];
            if (c == '[') {
                const val = try self.parseFlowSeq();
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = val });
                self.skipToEOL();
            } else if (c == '{') {
                const val = try self.parseFlowMap();
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = val });
                self.skipToEOL();
            } else {
                const val = self.readInline();
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = self.dup(val) } });
            }
        }

        // Subsequent keys are on indented lines
        while (true) {
            self.skipBlanks();
            if (self.pos >= self.src.len) break;

            const save = self.pos;
            const line_indent = self.countIndent();
            if (line_indent < indent) {
                self.pos = save;
                break;
            }
            if (self.pos >= self.src.len or self.src[self.pos] == '\n' or self.src[self.pos] == '#') {
                self.pos = save;
                break;
            }
            if (self.atSeqEntry()) {
                self.pos = save;
                break;
            }

            const colon2 = self.findColon(self.pos) orelse {
                self.pos = save;
                break;
            };

            const key2 = std.mem.trim(u8, self.src[self.pos..colon2], " \t");
            self.pos = colon2 + 1;
            while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;

            if (self.pos >= self.src.len or self.src[self.pos] == '\n' or self.src[self.pos] == '#') {
                self.skipToEOL();
                const block_pos = self.pos;
                self.skipBlanks();
                if (self.pos >= self.src.len) {
                    self.pos = block_pos;
                    try entries.append(self.alloc(), .{ .key = self.dup(key2), .value = .{ .scalar = "" } });
                    continue;
                }
                const block_indent = self.countIndent();
                if (block_indent > indent) {
                    self.pos = block_pos;
                    const val = try self.parseBlock(block_indent);
                    try entries.append(self.alloc(), .{ .key = self.dup(key2), .value = val });
                } else {
                    self.pos = block_pos;
                    try entries.append(self.alloc(), .{ .key = self.dup(key2), .value = .{ .scalar = "" } });
                }
                continue;
            }

            const c = self.src[self.pos];
            if (c == '[') {
                const val = try self.parseFlowSeq();
                try entries.append(self.alloc(), .{ .key = self.dup(key2), .value = val });
                self.skipToEOL();
            } else if (c == '{') {
                const val = try self.parseFlowMap();
                try entries.append(self.alloc(), .{ .key = self.dup(key2), .value = val });
                self.skipToEOL();
            } else {
                const val = self.readInline();
                try entries.append(self.alloc(), .{ .key = self.dup(key2), .value = .{ .scalar = self.dup(val) } });
            }
        }

        return .{ .map = try entries.toOwnedSlice(self.alloc()) };
    }

    fn parseFlowSeq(self: *Parser) anyerror!Value {
        std.debug.assert(self.src[self.pos] == '[');
        self.pos += 1;
        var items: std.ArrayList(Value) = .empty;

        while (true) {
            self.skipFlowWs();
            if (self.pos >= self.src.len) break;
            const c = self.src[self.pos];
            if (c == ']') {
                self.pos += 1;
                break;
            }
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            if (c == '[') {
                try items.append(self.alloc(), try self.parseFlowSeq());
            } else if (c == '{') {
                try items.append(self.alloc(), try self.parseFlowMap());
            } else {
                const s = try self.readFlowScalar();
                try items.append(self.alloc(), .{ .scalar = self.dup(s) });
            }
        }
        return .{ .list = try items.toOwnedSlice(self.alloc()) };
    }

    fn parseFlowMap(self: *Parser) anyerror!Value {
        std.debug.assert(self.src[self.pos] == '{');
        self.pos += 1;
        var entries: std.ArrayList(Value.KV) = .empty;

        while (true) {
            self.skipFlowWs();
            if (self.pos >= self.src.len) break;
            const c = self.src[self.pos];
            if (c == '}') {
                self.pos += 1;
                break;
            }
            if (c == ',') {
                self.pos += 1;
                continue;
            }

            const key = try self.readFlowScalar();
            self.skipFlowWs();
            if (self.pos < self.src.len and self.src[self.pos] == ':') {
                self.pos += 1;
                self.skipFlowWs();
            }

            if (self.pos >= self.src.len or self.src[self.pos] == ',' or self.src[self.pos] == '}') {
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = "" } });
                continue;
            }

            const vc = self.src[self.pos];
            if (vc == '[') {
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = try self.parseFlowSeq() });
            } else if (vc == '{') {
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = try self.parseFlowMap() });
            } else {
                const s = try self.readFlowScalar();
                try entries.append(self.alloc(), .{ .key = self.dup(key), .value = .{ .scalar = self.dup(s) } });
            }
        }
        return .{ .map = try entries.toOwnedSlice(self.alloc()) };
    }

    fn skipFlowWs(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                return;
            }
        }
    }

    fn readFlowScalar(self: *Parser) ![]const u8 {
        self.skipFlowWs();
        if (self.pos >= self.src.len) return "";

        if (self.src[self.pos] == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '"') {
                if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
            }
            const end = self.pos;
            if (self.pos < self.src.len) self.pos += 1;
            return self.src[start..end];
        }

        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ',' or c == ']' or c == '}' or c == ':' or c == '\n') break;
            self.pos += 1;
        }
        return std.mem.trim(u8, self.src[start..self.pos], " \t\r");
    }
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Value {
    var parser = Parser.init(allocator, src);
    return parser.parse();
}

test "simple map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml = "name: mycmd\ndescription: my command\n";
    const val = try parse(arena.allocator(), yaml);
    try std.testing.expectEqualStrings("mycmd", val.getScalar("name").?);
    try std.testing.expectEqualStrings("my command", val.getScalar("description").?);
}

test "flow sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml = "aliases: [a, b, c]\n";
    const val = try parse(arena.allocator(), yaml);
    const list = val.getList("aliases").?;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("a", list[0].scalar);
    try std.testing.expectEqualStrings("b", list[1].scalar);
    try std.testing.expectEqualStrings("c", list[2].scalar);
}

test "block list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\commands:
        \\  - name: sub1
        \\    description: first
        \\  - name: sub2
        \\    description: second
    ;
    const val = try parse(arena.allocator(), yaml);
    const cmds = val.getList("commands").?;
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("sub1", cmds[0].getScalar("name").?);
    try std.testing.expectEqualStrings("first", cmds[0].getScalar("description").?);
    try std.testing.expectEqualStrings("sub2", cmds[1].getScalar("name").?);
}

test "nested map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\completion:
        \\  flag:
        \\    verbose: ["one", "two"]
        \\  positional:
        \\    - [a, b]
        \\    - [c, d]
    ;
    const val = try parse(arena.allocator(), yaml);
    const comp = val.get("completion").?;
    const flag = comp.getMap("flag").?;
    try std.testing.expectEqualStrings("one", flag[0].value.list[0].scalar);
}

test "flags map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\flags:
        \\  --verbose: verbose flag
        \\  -o, --output=: output file
    ;
    const val = try parse(arena.allocator(), yaml);
    const flags = val.getMap("flags").?;
    try std.testing.expectEqual(@as(usize, 2), flags.len);
    try std.testing.expectEqualStrings("--verbose", flags[0].key);
    try std.testing.expectEqualStrings("verbose flag", flags[0].value.scalar);
    try std.testing.expectEqualStrings("-o, --output=", flags[1].key);
}

test "empty value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\name: cmd
        \\flags:
        \\  --verbose:
    ;
    const val = try parse(arena.allocator(), yaml);
    try std.testing.expectEqualStrings("cmd", val.getScalar("name").?);
    const flags = val.getMap("flags").?;
    try std.testing.expectEqualStrings("", flags[0].value.scalar);
}

test "list of strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml = "positionalany: [one, two, three]\n";
    const val = try parse(arena.allocator(), yaml);
    const list = val.getList("positionalany").?;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("two", list[1].scalar);
}

test "list of lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\positional:
        \\  - [a, b]
        \\  - [c, d]
    ;
    const val = try parse(arena.allocator(), yaml);
    const pos = val.getList("positional").?;
    try std.testing.expectEqual(@as(usize, 2), pos.len);
    try std.testing.expectEqual(@as(usize, 2), pos[0].list.len);
    try std.testing.expectEqualStrings("a", pos[0].list[0].scalar);
    try std.testing.expectEqualStrings("d", pos[1].list[1].scalar);
}

test "comment handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\# top comment
        \\name: cmd  # inline comment
        \\# another
        \\description: hi
    ;
    const val = try parse(arena.allocator(), yaml);
    try std.testing.expectEqualStrings("cmd", val.getScalar("name").?);
    try std.testing.expectEqualStrings("hi", val.getScalar("description").?);
}

test "literal block scalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\run: |
        \\  #!/usr/bin/env bash
        \\  echo "hello"
        \\  for arg in "$@"; do
        \\    echo "$arg"
        \\  done
    ;
    const val = try parse(arena.allocator(), yaml);
    const run = val.getScalar("run").?;
    try std.testing.expect(std.mem.indexOf(u8, run, "#!/usr/bin/env bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "echo \"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "for arg in") != null);
}

test "flow map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml = "nested: {key: value, num: 42}\n";
    const val = try parse(arena.allocator(), yaml);
    const nested = val.getMap("nested").?;
    try std.testing.expectEqualStrings("value", getScalarFromMap(nested, "key").?);
    try std.testing.expectEqualStrings("42", getScalarFromMap(nested, "num").?);
}

test "extended flag notation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\flags:
        \\  --nargs-two=: {description: consumes two args, nargs: 2}
        \\  --default-val=: {description: has default, default: /tmp/out.txt}
    ;
    const val = try parse(arena.allocator(), yaml);
    const flags = val.getMap("flags").?;
    try std.testing.expectEqual(@as(usize, 2), flags.len);
    try std.testing.expectEqualStrings("--nargs-two=", flags[0].key);
    try std.testing.expectEqualStrings("--default-val=", flags[1].key);
}

test "dash and dashany completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\completion:
        \\  dash:
        \\    - [d1, d2]
        \\    - [d3]
        \\  dashany: [extra]
    ;
    const val = try parse(arena.allocator(), yaml);
    const comp = val.get("completion").?;
    const dash = comp.getList("dash").?;
    try std.testing.expectEqual(@as(usize, 2), dash.len);
    try std.testing.expectEqualStrings("d1", dash[0].list[0].scalar);
    try std.testing.expectEqualStrings("d3", dash[1].list[0].scalar);
    const dashany = comp.getList("dashany").?;
    try std.testing.expectEqualStrings("extra", dashany[0].scalar);
}

test "exclusive flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\exclusiveflags:
        \\  - [add, delete]
        \\  - [create, remove]
    ;
    const val = try parse(arena.allocator(), yaml);
    const excl = val.getList("exclusiveflags").?;
    try std.testing.expectEqual(@as(usize, 2), excl.len);
    try std.testing.expectEqualStrings("add", excl[0].list[0].scalar);
    try std.testing.expectEqualStrings("delete", excl[0].list[1].scalar);
}

test "empty string in flow sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml = "items: [a, , b]\n";
    const val = try parse(arena.allocator(), yaml);
    const items = val.getList("items").?;
    // Empty entries between commas are skipped
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("a", items[0].scalar);
    try std.testing.expectEqualStrings("b", items[1].scalar);
}

test "boolean values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\hidden: true
        \\visible: false
    ;
    const val = try parse(arena.allocator(), yaml);
    try std.testing.expectEqualStrings("true", val.getScalar("hidden").?);
    try std.testing.expectEqualStrings("false", val.getScalar("visible").?);
}

test "integer values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\nargs: 2
        \\negative: -1
    ;
    const val = try parse(arena.allocator(), yaml);
    try std.testing.expectEqualStrings("2", val.getScalar("nargs").?);
    try std.testing.expectEqualStrings("-1", val.getScalar("negative").?);
}

test "empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "");
    try std.testing.expectEqualStrings("", val.scalar);
}

test "trailing whitespace lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml = "name: mycmd\n\nother: val\n";
    const val = try parse(arena.allocator(), yaml);
    try std.testing.expectEqualStrings("mycmd", val.getScalar("name").?);
    try std.testing.expectEqualStrings("val", val.getScalar("other").?);
}

test "empty value with subcommand block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml =
        \\name: root
        \\commands:
        \\  - name: sub
        \\    flags:
        \\      --verbose:
    ;
    const val = try parse(arena.allocator(), yaml);
    const cmds = val.getList("commands").?;
    try std.testing.expectEqualStrings("sub", cmds[0].getScalar("name").?);
    const flags = cmds[0].getMap("flags").?;
    try std.testing.expectEqualStrings("--verbose", flags[0].key);
    try std.testing.expectEqualStrings("", flags[0].value.scalar);
}
