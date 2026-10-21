const std = @import("std");
const traverse = @import("traverse.zig");
const builtins = @import("builtins.zig");

const WordQuote = enum { posix, fish, pwsh };

fn needsQuoting(word: []const u8) bool {
    if (word.len == 0) return true;
    for (word) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r', '\'', '"', '\\', '$', '`', '&', '|', ';', '<', '>', '(', ')', '*', '?', '[', ']', '{', '}', '#', '~', '!' => return true,
            else => {},
        }
    }
    return false;
}

fn appendShellWord(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), word: []const u8, mode: WordQuote) !void {
    if (!needsQuoting(word)) {
        try buf.appendSlice(allocator, word);
        return;
    }
    try buf.append(allocator, '\'');
    for (word) |c| {
        switch (mode) {
            .posix => {
                if (c == '\'') {
                    try buf.appendSlice(allocator, "'\\''");
                    continue;
                }
            },
            .fish => {
                if (c == '\'') {
                    try buf.appendSlice(allocator, "\\'");
                    continue;
                }
                if (c == '\\') {
                    try buf.appendSlice(allocator, "\\\\");
                    continue;
                }
            },
            .pwsh => {
                if (c == '\'') {
                    try buf.appendSlice(allocator, "''");
                    continue;
                }
            },
        }
        try buf.append(allocator, c);
    }
    try buf.append(allocator, '\'');
}

/// Build the command line for line-based bridges: words joined with spaces,
/// always ending with the current word. An empty word becomes a trailing
/// space (COMP_LINE-style parsing) or '' when `quoted_empty` is set
/// (shell-parsed input like fish/zsh/powershell). Words are quoted for the
/// shell that will re-parse the line.
fn buildCompline(allocator: std.mem.Allocator, cmd: []const u8, args: []const []const u8, prefix: []const u8, quoted_empty: bool, mode: WordQuote) ![]const u8 {
    var cmdline = std.ArrayList(u8).empty;
    try appendShellWord(allocator, &cmdline, cmd, mode);
    for (args) |a| {
        try cmdline.append(allocator, ' ');
        try appendShellWord(allocator, &cmdline, a, mode);
    }
    try cmdline.append(allocator, ' ');
    if (prefix.len > 0) {
        try appendShellWord(allocator, &cmdline, prefix, mode);
    } else if (quoted_empty) {
        try cmdline.appendSlice(allocator, "''");
    }
    return cmdline.toOwnedSlice(allocator);
}

/// Escape for embedding into a POSIX double-quoted shell string.
fn escapeShDouble(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        switch (c) {
            '\\', '"', '$', '`' => {
                try buf.append(allocator, '\\');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Escape for embedding into a fish double-quoted string.
fn escapeFishDouble(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        switch (c) {
            '\\', '"', '$' => {
                try buf.append(allocator, '\\');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Escape for embedding into a PowerShell double-quoted string.
fn escapePwshDouble(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        switch (c) {
            '`', '"', '$' => {
                try buf.append(allocator, '`');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Escape for embedding into a single-quoted string (fish, powershell).
fn escapeSingleQuote(allocator: std.mem.Allocator, s: []const u8, esc: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c == '\'') try buf.appendSlice(allocator, esc) else try buf.append(allocator, c);
    }
    return buf.toOwnedSlice(allocator);
}

/// Clone the environment map into a new owned map.
fn cloneEnv(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| {
        var it = em.iterator();
        while (it.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return env;
}

/// Parse stdout lines into candidates (value only, no descriptions).
fn parseSimpleLines(allocator: std.mem.Allocator, stdout: []const u8) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse stdout lines into candidates with tab-separated value/description.
fn parseTabLines(allocator: std.mem.Allocator, stdout: []const u8) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '\t')) |tab| {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed[0..tab]), .description = try allocator.dupe(u8, trimmed[tab + 1 ..]) });
        } else {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Parse stdout lines into candidates with colon-separated value:description.
fn parseColonLines(allocator: std.mem.Allocator, stdout: []const u8) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed[0..colon]), .description = try allocator.dupe(u8, trimmed[colon + 1 ..]) });
        } else {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Split macro arguments on commas, honoring single/double quotes, backslash
/// escapes and nested brackets. Used for `$bridge.<name>(cmd, args...)`.
fn splitMacroArgs(allocator: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    var items = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == ',')) : (i += 1) {}
        if (i >= src.len) break;

        var buf = std.ArrayList(u8).empty;
        var parsed = false;
        if (src[i] == '\'' or src[i] == '"') {
            const quote = src[i];
            i += 1;
            while (i < src.len and src[i] != quote) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1;
                    try buf.append(allocator, src[i]);
                    i += 1;
                } else {
                    try buf.append(allocator, src[i]);
                    i += 1;
                }
            }
            if (i < src.len) i += 1;
            parsed = true;
        } else {
            const start = i;
            var depth: usize = 0;
            while (i < src.len) : (i += 1) {
                const c = src[i];
                if (c == '[' or c == '{' or c == '(') {
                    depth += 1;
                    continue;
                }
                if ((c == ']' or c == '}' or c == ')') and depth > 0) {
                    depth -= 1;
                    continue;
                }
                if (c == ',' and depth == 0) break;
            }
            const arg = std.mem.trim(u8, src[start..i], " \t");
            if (arg.len > 0) {
                try buf.appendSlice(allocator, arg);
                parsed = true;
            }
        }
        if (parsed) try items.append(allocator, try buf.toOwnedSlice(allocator));
    }
    return items.toOwnedSlice(allocator);
}

/// Strip ANSI escape sequences from bridge output.
fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, 0x1b) == null) return s;
    var buf = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) : (i += 1) {}
            if (i < s.len) i += 1;
            continue;
        }
        try buf.append(allocator, s[i]);
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

/// Remove zsh escaping from captured completion values.
fn unquoteZsh(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                '\\', '&', '<', '>', '`', '\'', '"', '{', '}', '$', '#', '|', '?', '(', ')', ';', ' ', '[', ']', '*', '~' => {
                    try buf.append(allocator, s[i + 1]);
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try buf.append(allocator, s[i]);
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

/// Mark values ending in one of the given characters as nospace.
fn markNoSpace(candidates: []traverse.Candidate, suffixes: []const u8) void {
    for (candidates) |*c| {
        if (c.value.len == 0) continue;
        if (std.mem.indexOfScalar(u8, suffixes, c.value[c.value.len - 1]) != null) c.nospace = true;
    }
}

/// Parse "$bridge.name(command, args...)" — delegate to framework-specific completion.
pub fn resolveBridge(allocator: std.mem.Allocator, io: std.Io, macro: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const paren = std.mem.indexOfScalar(u8, macro, '(') orelse return &.{};
    if (macro[macro.len - 1] != ')') return &.{};

    const bridge_dot = macro[0..paren];
    const bridge_name = if (std.mem.startsWith(u8, bridge_dot, "$bridge."))
        bridge_dot[8..]
    else if (bridge_dot.len > 7)
        bridge_dot[7..]
    else
        return &.{};

    const args_part = macro[paren + 1 .. macro.len - 1];
    if (args_part.len == 0) return &.{};

    const cmd_args = try splitMacroArgs(allocator, args_part);
    if (cmd_args.len == 0) return &.{};

    const cmd = cmd_args[0];
    const bridge_args = cmd_args[1..];

    if (std.mem.eql(u8, bridge_name, "Cobra")) {
        return try bridgeCobra(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Bash")) {
        return try bridgeBash(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Zsh")) {
        return try bridgeZsh(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Fish")) {
        return try bridgeFish(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Carapace")) {
        return try bridgeCarapace(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "CarapaceBin")) {
        return try bridgeCarapaceBin(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Argcomplete")) {
        return try bridgeArgcomplete(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "ArgcompleteV1")) {
        return try bridgeArgcompleteV1(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Aws")) {
        return try bridgeAws(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Clap")) {
        return try bridgeClap(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Click")) {
        return try bridgeClick(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Complete")) {
        return try bridgeComplete(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Gcloud")) {
        return try bridgeGcloud(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Inshellisense")) {
        return try bridgeInshellisense(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "JJ")) {
        return try bridgeJJ(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Kingpin")) {
        return try bridgeKingpin(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Kitten")) {
        return try bridgeKitten(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Powershell")) {
        return try bridgePowershell(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Urfavecli")) {
        return try bridgeUrfavecli(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "UrfavecliV1")) {
        return try bridgeUrfavecliV1(allocator, io, cmd, bridge_args, prefix, environ_map);
    } else if (std.mem.eql(u8, bridge_name, "Yargs")) {
        return try bridgeYargs(allocator, io, cmd, bridge_args, prefix, environ_map);
    }
    return &.{};
}

pub fn execCommand(allocator: std.mem.Allocator, io: std.Io, shell: []const u8, command: []const u8) ![]traverse.Candidate {
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

/// Bridge: cobra — run `cmd __complete <args>`
fn bridgeCobra(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "__complete");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
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
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == ':') continue;
        const parsed = traverse.splitValue(trimmed);
        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, parsed.value),
            .description = try allocator.dupe(u8, parsed.description),
        });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: bash — run bash completion with COMP_LINE
fn bridgeBash(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false, .posix);

    var env = try cloneEnv(allocator, environ_map);
    try env.put("COMP_LINE", cmdline);
    try env.put("COMP_POINT", try std.fmt.allocPrint(allocator, "{d}", .{cmdline.len}));
    try env.put("COMP_TYPE", "63");

    var script = std.ArrayList(u8).empty;
    try script.appendSlice(allocator, "set +o history\nCOMP_WORDS=($COMP_LINE)\n" ++
        "if [ \"${COMP_LINE: -1}\" = \" \" ]; then COMP_WORDS+=(\"\")\nfi\n" ++
        "COMP_CWORD=$((${#COMP_WORDS[@]} - 1))\nCOMP_POINT=${#COMP_LINE}\n" ++
        "[ -f /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion\n" ++
        "[ -f /usr/local/share/bash-completion/bash_completion ] && source /usr/local/share/bash-completion/bash_completion\n" ++
        "[ -f /data/data/com.termux/files/usr/share/bash-completion/bash_completion ] && source /data/data/com.termux/files/usr/share/bash-completion/bash_completion\n");
    const cmd_escaped = try escapeShDouble(allocator, cmd);
    try script.appendSlice(allocator, "__load_completion \"");
    try script.appendSlice(allocator, cmd_escaped);
    try script.appendSlice(allocator, "\" 2>/dev/null\n");
    try script.appendSlice(allocator, "_cf=$(complete -p \"");
    try script.appendSlice(allocator, cmd_escaped);
    try script.appendSlice(allocator, "\" 2>/dev/null | sed -r 's/.* -F ([^ ]+).*/\\1/')\n");
    try script.appendSlice(allocator, "if [ -n \"$_cf\" ]; then \"$_cf\"\n  for i in \"${COMPREPLY[@]}\"; do\n    if [[ -d \"$i\" && \"$i\" != */ ]]; then echo \"$i/\"; else echo \"$i\"; fi; done\nfi\n");

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "bash", "--rcfile", "/dev/null", "-i", "-c", script.items },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const candidates = try parseSimpleLines(allocator, result.stdout);
    markNoSpace(candidates, "/=@:.,");
    return candidates;
}

/// Bridge: zsh — run zsh with compdef via capture script
fn bridgeZsh(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, true, .posix);

    var env = try cloneEnv(allocator, environ_map);
    const config_home = if (environ_map) |em| blk: {
        if (em.get("XDG_CONFIG_HOME")) |xdg| break :blk xdg;
        if (em.get("HOME")) |home| break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
        break :blk "/tmp";
    } else "/tmp";
    try env.put("CARAPACE_BRIDGE_CONFIG_HOME", config_home);

    // Build zsh args: --no-rcs -c <capture script> -- <cmd> <args...>
    const capture_script =
        "zmodload zsh/zpty 2>/dev/null || exit 1\n" ++
        "zpty z zsh -f -i\n" ++
        "local line\n" ++
        "setopt rcquotes\n" ++
        "() {\n" ++
        "  zpty -w z source $1\n" ++
        "  repeat 4; do\n" ++
        "    zpty -r z line\n" ++
        "    [[ $line == ok* ]] && return\n" ++
        "  done\n" ++
        "  exit 2\n" ++
        "} =( <<< '\n" ++
        "PROMPT=\n" ++
        "oldfpath=\"$fpath\"\n" ++
        "mkdir -p \"${CARAPACE_BRIDGE_CONFIG_HOME:-$HOME/.config}/carapace/bridge/zsh\"\n" ++
        "autoload -U compinit && compinit -d \"${CARAPACE_BRIDGE_CONFIG_HOME:-$HOME/.config}/carapace/bridge/zsh/.zcompdump_capture\"\n" ++
        "[ -f \"${CARAPACE_BRIDGE_CONFIG_HOME:-$HOME/.config}/carapace/bridge/zsh/.zshrc\" ] && source \"${CARAPACE_BRIDGE_CONFIG_HOME:-$HOME/.config}/carapace/bridge/zsh/.zshrc\"\n" ++
        "[[ \"$oldfpath\" != \"$fpath\" ]] && compinit\n" ++
        "bindkey ''^M'' undefined\n" ++
        "bindkey ''^J'' undefined\n" ++
        "bindkey ''^I'' complete-word\n" ++
        "null-line () { echo -E - $''\\0'' }\n" ++
        "compprefuncs=( null-line )\n" ++
        "comppostfuncs=( null-line exit )\n" ++
        "zstyle '':completion:*'' list-grouped false\n" ++
        "zstyle '':completion:*'' insert-tab false\n" ++
        "zstyle '':completion:*'' list-separator ''''\n" ++
        "zmodload zsh/zutil\n" ++
        "compadd () {\n" ++
        "  if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\\ * ]]; then builtin compadd \"$@\"; return $?; fi\n" ++
        "  typeset -a __hits __dscr __tmp\n" ++
        "  if (( $@[(I)-d] )); then\n" ++
        "    __tmp=${@[$[${@[(i)-d]}+1]]}\n" ++
        "    if [[ $__tmp == \\(* ]]; then eval \"__dscr=$__tmp\"; else __dscr=( \"${(@P)__tmp}\" ); fi\n" ++
        "  fi\n" ++
        "  builtin compadd -A __hits -D __dscr \"$@\"\n" ++
        "  setopt localoptions norcexpandparam extendedglob\n" ++
        "  typeset -A apre hpre hsuf asuf\n" ++
        "  zparseopts -E P:=apre p:=hpre S:=asuf s:=hsuf\n" ++
        "  integer dirsuf=0\n" ++
        "  if [[ -z $hsuf && \"${${@//-default-/}% -# *}\" == *-[[:alnum:]]#f* ]]; then dirsuf=1; fi\n" ++
        "  [[ -n $__hits ]] || return\n" ++
        "  local dsuf dscr\n" ++
        "  for i in {1..$#__hits}; do\n" ++
        "    (( dirsuf )) && [[ -d $__hits[$i] ]] && dsuf=/ || dsuf=\n" ++
        "    (( $#__dscr >= $i )) && dscr=\" -- ${${__dscr[$i]}##$__hits[$i] #}\" || dscr=\n" ++
        "    echo -E - $IPREFIX$apre$hpre$__hits[$i]$dsuf$hsuf$asuf$dscr\n" ++
        "  done\n" ++
        "}\n" ++
        "echo ok')\n" ++
        "zpty -w z \"$*\"$'\\t'\n" ++
        "integer tog=0\n" ++
        "while zpty -r z; do :; done | while IFS= read -r line; do\n" ++
        "  if [[ $line == *$'\\0\\r' ]]; then (( tog++ )) && return 0 || continue; fi\n" ++
        "  (( tog )) && echo -E - $line\n" ++
        "done\n" ++
        "return 0";

    var zsh_argv = std.ArrayList([]const u8).empty;
    try zsh_argv.append(allocator, "zsh");
    try zsh_argv.append(allocator, "--no-rcs");
    try zsh_argv.append(allocator, "-c");
    try zsh_argv.append(allocator, capture_script);
    try zsh_argv.append(allocator, "--");
    try zsh_argv.append(allocator, cmdline);

    const result = std.process.run(allocator, io, .{
        .argv = zsh_argv.items,
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
        if (trimmed[0] == 0) continue;
        // Split on " -- " for description
        if (std.mem.indexOf(u8, trimmed, " -- ")) |sep| {
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, try stripAnsi(allocator, try unquoteZsh(allocator, trimmed[0..sep]))),
                .description = try allocator.dupe(u8, try stripAnsi(allocator, try unquoteZsh(allocator, trimmed[sep + 4 ..]))),
            });
        } else {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, try stripAnsi(allocator, try unquoteZsh(allocator, trimmed))) });
        }
    }
    const result_values = try candidates.toOwnedSlice(allocator);
    markNoSpace(result_values, "/=@:.,");
    return result_values;
}

/// Bridge: fish — run fish with complete --do-complete
fn bridgeFish(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, true, .fish);

    var env = try cloneEnv(allocator, environ_map);
    const config_home = if (environ_map) |em| blk: {
        if (em.get("XDG_CONFIG_HOME")) |xdg| break :blk xdg;
        if (em.get("HOME")) |home| break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
        break :blk "/tmp";
    } else "/tmp";
    try env.put("CARAPACE_BRIDGE_CONFIG_HOME", config_home);

    const config_dir = try std.fmt.allocPrint(allocator, "{s}/carapace/bridge/fish", .{config_home});
    defer allocator.free(config_dir);

    const cmdline_escaped = try escapeFishDouble(allocator, cmdline);
    const snippet = try std.fmt.allocPrint(allocator, "set __fish_config_dir {s};source \"$__fish_data_dir/config.fish\";test -f \"{s}/config.fish\";and source \"{s}/config.fish\";complete --do-complete=\"{s}\"", .{ config_dir, config_dir, config_dir, cmdline_escaped });
    defer allocator.free(snippet);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "fish", "--no-config", "--command", snippet },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const candidates = try parseTabLines(allocator, result.stdout);
    markNoSpace(candidates, "/=@:.,");
    return candidates;
}

/// Bridge: carapace — run `cmd _carapace export ""`
fn bridgeCarapace(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "_carapace");
    try argv.append(allocator, "export");
    try argv.append(allocator, "");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
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
    if (result.stdout.len == 0) return &.{};
    return parseExportJson(allocator, result.stdout);
}

/// Bridge: carapace-bin — run `carapace <cmd> export ""`
fn bridgeCarapaceBin(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, "carapace");
    try argv.append(allocator, cmd);
    try argv.append(allocator, "export");
    try argv.append(allocator, "");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
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
    if (result.stdout.len == 0) return &.{};
    return parseExportJson(allocator, result.stdout);
}

/// Bridge: argcomplete — run with _ARGCOMPLETE=1 (v3)
fn bridgeArgcomplete(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false, .posix);
    var env = try cloneEnv(allocator, environ_map);
    try env.put("_ARGCOMPLETE", "1");
    try env.put("_ARGCOMPLETE_DFS", "\\t");
    try env.put("_ARGCOMPLETE_IFS", "\\n");
    try env.put("_ARGCOMPLETE_SHELL", "fish");
    try env.put("COMP_LINE", cmdline);
    try env.put("COMP_POINT", try std.fmt.allocPrint(allocator, "{d}", .{cmdline.len}));
    try env.put("_ARGCOMPLETE_SUPPRESS_SPACE", "1");
    const result = std.process.run(allocator, io, .{
        .argv = &.{cmd},
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return parseTabLines(allocator, result.stdout);
}

/// Bridge: argcomplete v1 — deprecated, uses fd 8/9
fn bridgeArgcompleteV1(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false, .posix);
    var env = try cloneEnv(allocator, environ_map);
    try env.put("_ARGCOMPLETE", "1");
    try env.put("_ARGCOMPLETE_DFS", "\\t");
    try env.put("_ARGCOMPLETE_IFS", "\\n");
    try env.put("_ARGCOMPLETE_SHELL", "fish");
    try env.put("COMP_LINE", cmdline);
    try env.put("COMP_POINT", try std.fmt.allocPrint(allocator, "{d}", .{cmdline.len}));
    try env.put("_ARGCOMPLETE_SUPPRESS_SPACE", "1");
    const shell_cmd = try std.fmt.allocPrint(allocator, "{s} 8>&1 9>&2 1>/dev/null 2>/dev/null", .{try escapeShDouble(allocator, cmd)});
    defer allocator.free(shell_cmd);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", shell_cmd },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return parseTabLines(allocator, result.stdout);
}

/// Bridge: aws — run aws_completer with COMP_LINE
fn bridgeAws(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false, .posix);
    var env = try cloneEnv(allocator, environ_map);
    try env.put("COMP_LINE", cmdline);
    const result = std.process.run(allocator, io, .{
        .argv = &.{"aws_completer"},
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
        if (trimmed.len > 0) {
            // Strip trailing space from aws v1
            const stripped = if (std.mem.endsWith(u8, trimmed, " ")) trimmed[0 .. trimmed.len - 1] else trimmed;
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, stripped) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: clap — run `cmd complete --index ...`
fn bridgeClap(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const index = 1 + args.len;
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "complete");
    try argv.append(allocator, "--index");
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
    try argv.append(allocator, "--type");
    try argv.append(allocator, "9");
    try argv.append(allocator, "--no-space");
    try argv.append(allocator, "--ifs=\n");
    try argv.append(allocator, "--");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
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
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: click — run with _<CMD>_COMPLETE=zsh_complete
fn bridgeClick(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false, .posix);
    var env = try cloneEnv(allocator, environ_map);
    try env.put("COMP_WORDS", cmdline);
    try env.put("COMP_CWORD", try std.fmt.allocPrint(allocator, "{d}", .{args.len + 1}));
    var upper = std.ArrayList(u8).empty;
    for (cmd) |c| try upper.append(allocator, std.ascii.toUpper(c));
    const env_var_name = try std.fmt.allocPrint(allocator, "_{s}_COMPLETE", .{upper.items});
    defer allocator.free(env_var_name);
    try env.put(env_var_name, "zsh_complete");
    const result = std.process.run(allocator, io, .{
        .argv = &.{cmd},
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
    while (true) {
        // click's zsh_complete emits triplets: type, value, description
        const type_line = lines.next() orelse break;
        const value_line = lines.next() orelse break;
        const desc_line = lines.next() orelse "";
        const kind = std.mem.trim(u8, type_line, " \t\r");
        if (std.mem.eql(u8, kind, "dir")) return builtins.resolveDirectories(allocator, io, prefix);
        if (std.mem.eql(u8, kind, "file")) return builtins.resolveFiles(allocator, io, "$files", prefix);
        if (!std.mem.eql(u8, kind, "plain")) continue;

        const value = std.mem.trim(u8, value_line, " \t\r");
        if (value.len == 0) continue;
        var description = std.mem.trim(u8, desc_line, " \t\r");
        if (std.mem.eql(u8, description, "_")) description = "";
        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, value),
            .description = try allocator.dupe(u8, description),
        });
    }
    const result_values = try candidates.toOwnedSlice(allocator);
    markNoSpace(result_values, "/=@:.,");
    return result_values;
}

/// Bridge: complete — run with COMP_LINE
fn bridgeComplete(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false, .posix);
    var env = try cloneEnv(allocator, environ_map);
    try env.put("COMP_LINE", cmdline);
    const result = std.process.run(allocator, io, .{
        .argv = &.{cmd},
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return parseSimpleLines(allocator, result.stdout);
}

/// Bridge: gcloud — run with argcomplete (delegates to argcomplete v1)
fn bridgeGcloud(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var env = try cloneEnv(allocator, environ_map);
    try env.put("CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK", "1");
    return bridgeArgcompleteV1(allocator, io, cmd, args, prefix, &env);
}

/// Bridge: inshellisense — run `inshellisense complete <input>`
fn bridgeInshellisense(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false, .posix);
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, "inshellisense");
    try argv.append(allocator, "complete");
    try argv.append(allocator, cmdline);
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
    var candidates = std.ArrayList(traverse.Candidate).empty;
    // Parse JSON output for inshellisense
    // Simple approach: extract values from JSON
    if (result.stdout.len > 0) {
        var json = result.stdout;
        // Find "name" fields
        var pos: usize = 0;
        while (pos < json.len) {
            const name_key = std.mem.indexOf(u8, json[pos..], "\"name\": \"") orelse break;
            const val_start = pos + name_key + 9;
            const val_end = std.mem.indexOfScalar(u8, json[val_start..], '"') orelse break;
            const value = json[val_start .. val_start + val_end];
            pos = val_start + val_end;
            // Look for description after this
            var desc: []const u8 = "";
            if (std.mem.indexOf(u8, json[pos..], "\"description\": \"")) |desc_key| {
                const d_start = pos + desc_key + 16;
                const d_end = std.mem.indexOfScalar(u8, json[d_start..], '"') orelse 0;
                if (d_end > 0) desc = json[d_start .. d_start + d_end];
            }
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, value), .description = try allocator.dupe(u8, desc) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: jj — run with COMPLETE=fish
fn bridgeJJ(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var env = try cloneEnv(allocator, environ_map);
    try env.put("COMPLETE", "fish");
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "--");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
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
    const is_flags = prefix.len > 0 and prefix[0] == '-';
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const is_line_flag = trimmed.len > 0 and trimmed[0] == '-';
        if (is_flags != is_line_flag) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '\t')) |tab| {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed[0..tab]), .description = try allocator.dupe(u8, trimmed[tab + 1 ..]) });
        } else {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: kingpin — run with --completion-bash
fn bridgeKingpin(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "--completion-bash");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
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
    return parseSimpleLines(allocator, result.stdout);
}

/// Bridge: kitten — run `kitten __complete__ json` with words piped via stdin
fn bridgeKitten(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    // kitten __complete__ json reads newline-separated words from stdin
    var input = std.ArrayList(u8).empty;
    try input.appendSlice(allocator, cmd);
    try input.append(allocator, '\n');
    for (args) |a| {
        try input.appendSlice(allocator, a);
        try input.append(allocator, '\n');
    }
    try input.appendSlice(allocator, prefix);
    try input.append(allocator, '\n');

    // Use sh to pipe input to kitten since std.process.run has no stdin field.
    // Single quotes are safe: `'` is escaped as `'\''`.
    var escaped = std.ArrayList(u8).empty;
    for (input.items) |c| {
        if (c == '\'') try escaped.appendSlice(allocator, "'\\''") else try escaped.append(allocator, c);
    }
    const shell_cmd = try std.fmt.allocPrint(allocator, "printf %s '{s}' | kitten __complete__ json", .{escaped.items});
    defer allocator.free(shell_cmd);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", shell_cmd },
        .stdout_limit = .limited(1024 * 64),
        .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len == 0) return &.{};

    // Parse JSON: [{"groups":[{"matches":[{"word":"...","description":"..."}]}]}]
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var pos: usize = 0;
    while (pos < result.stdout.len) {
        const word_key = std.mem.indexOf(u8, result.stdout[pos..], "\"word\": \"") orelse break;
        const val_start = pos + word_key + 9;
        const val_end_rel = jsonStringEnd(result.stdout[val_start..]) orelse break;
        const value = result.stdout[val_start .. val_start + val_end_rel];
        pos = val_start + val_end_rel;

        // Scope description lookup to the current match object (closing brace)
        const obj_end = std.mem.indexOfScalarPos(u8, result.stdout, pos, '}') orelse result.stdout.len;
        var desc: []const u8 = "";
        if (std.mem.indexOf(u8, result.stdout[pos..obj_end], "\"description\": \"")) |desc_key| {
            const d_start = pos + desc_key + 16;
            if (jsonStringEnd(result.stdout[d_start..])) |d_end| {
                desc = result.stdout[d_start .. d_start + d_end];
            }
        }

        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, try jsonDecode(allocator, value)),
            .description = try allocator.dupe(u8, try jsonDecode(allocator, desc)),
        });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: powershell — run pwsh with CommandCompletion::CompleteInput
fn bridgePowershell(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, true, .pwsh);
    var env = try cloneEnv(allocator, environ_map);
    const config_home = if (environ_map) |em| blk: {
        if (em.get("XDG_CONFIG_HOME")) |xdg| break :blk xdg;
        if (em.get("HOME")) |home| break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
        break :blk "/tmp";
    } else "/tmp";
    const config_dir = try std.fmt.allocPrint(allocator, "{s}/carapace/bridge/powershell", .{config_home});
    defer allocator.free(config_dir);
    const cmdline_escaped = try escapePwshDouble(allocator, cmdline);
    const config_escaped = try escapePwshDouble(allocator, config_dir);
    const snippet = try std.fmt.allocPrint(allocator, "Get-Content \"{s}/Microsoft.PowerShell_profile.ps1\" | Out-String | Invoke-Expression;[System.Management.Automation.CommandCompletion]::CompleteInput(\"{s}\", {d}, $null).CompletionMatches | ConvertTo-Json", .{ config_escaped, cmdline_escaped, cmdline.len });
    defer allocator.free(snippet);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "pwsh", "-Command", snippet },
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
    // Parse JSON from powershell: [{"CompletionText":"...","ListItemText":"...","ToolTip":"..."}]
    if (result.stdout.len > 0) {
        var pos: usize = 0;
        while (pos < result.stdout.len) {
            const ct_key = std.mem.indexOf(u8, result.stdout[pos..], "\"CompletionText\": \"") orelse break;
            const val_start = pos + ct_key + 19;
            const val_end_rel = jsonStringEnd(result.stdout[val_start..]) orelse break;
            var value = result.stdout[val_start .. val_start + val_end_rel];
            // Strip trailing space (nospace indicator)
            if (value.len > 0 and value[value.len - 1] == ' ') value = value[0 .. value.len - 1];
            pos = val_start + val_end_rel;
            // Scope ToolTip lookup to the current JSON object
            const obj_end = std.mem.indexOfScalarPos(u8, result.stdout, pos, '}') orelse result.stdout.len;
            var desc: []const u8 = "";
            if (std.mem.indexOf(u8, result.stdout[pos..obj_end], "\"ToolTip\": \"")) |tt_key| {
                const d_start = pos + tt_key + 12;
                if (jsonStringEnd(result.stdout[d_start..])) |d_end| {
                    desc = result.stdout[d_start .. d_start + d_end];
                }
            }
            // Skip if CompletionText == ToolTip
            if (std.mem.eql(u8, value, desc)) desc = "";
            try candidates.append(allocator, .{
                .value = try allocator.dupe(u8, try jsonDecode(allocator, value)),
                .description = try allocator.dupe(u8, try jsonDecode(allocator, desc)),
            });
        }
    }
    const result_values = try candidates.toOwnedSlice(allocator);
    markNoSpace(result_values, "/=@:.,");
    return result_values;
}

/// Decode JSON string escapes (", \\, \/, \n, \r, \t, \uXXXX).
fn jsonDecode(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var buf = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try buf.append(allocator, s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => try buf.append(allocator, '\n'),
            'r' => try buf.append(allocator, '\r'),
            't' => try buf.append(allocator, '\t'),
            'u' => {
                if (i + 4 < s.len) {
                    const cp = std.fmt.parseInt(u21, s[i + 1 .. i + 5], 16) catch {
                        try buf.append(allocator, s[i]);
                        continue;
                    };
                    i += 4;
                    var utf8_buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                    try buf.appendSlice(allocator, utf8_buf[0..n]);
                } else {
                    try buf.append(allocator, s[i]);
                }
            },
            else => try buf.append(allocator, s[i]),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Index of the closing quote of a JSON string value (honors backslash escapes).
fn jsonStringEnd(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
        } else if (s[i] == '"') {
            return i;
        }
    }
    return null;
}

/// Bridge: urfavecli — run with --generate-shell-completion
fn bridgeUrfavecli(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
    try argv.append(allocator, "--generate-shell-completion");
    var env = try cloneEnv(allocator, environ_map);
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
    return parseColonLines(allocator, result.stdout);
}

/// Bridge: urfavecli v1 — run with --generate-bash-completion
fn bridgeUrfavecliV1(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
    try argv.append(allocator, "--generate-bash-completion");
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
    return parseSimpleLines(allocator, result.stdout);
}

/// Bridge: yargs — run with --get-yargs-completions
fn bridgeYargs(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "--get-yargs-completions");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
    var env = try cloneEnv(allocator, environ_map);
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
    return parseColonLines(allocator, result.stdout);
}

/// Parse carapace JSON export format.
fn parseExportJson(allocator: std.mem.Allocator, json: []const u8) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    const values_start = std.mem.indexOf(u8, json, "\"values\": [") orelse return &.{};
    var rest = values_start + 11;
    while (rest < json.len) {
        const val_key = std.mem.indexOf(u8, json[rest..], "\"value\": \"") orelse break;
        const val_start = rest + val_key + 10;
        const val_end_rel = jsonStringEnd(json[val_start..]) orelse break;
        const value = json[val_start .. val_start + val_end_rel];
        var desc: []const u8 = "";
        const after_val = json[val_start + val_end_rel ..];
        // Scope the description lookup to the current JSON object
        const obj_end = std.mem.indexOfScalar(u8, after_val, '}') orelse after_val.len;
        if (std.mem.indexOf(u8, after_val[0..obj_end], "\"description\": \"")) |desc_start| {
            const d_start = desc_start + 16;
            if (jsonStringEnd(after_val[d_start..])) |d_end| {
                desc = after_val[d_start .. d_start + d_end];
            }
        }
        try candidates.append(allocator, .{
            .value = try allocator.dupe(u8, try jsonDecode(allocator, value)),
            .description = try allocator.dupe(u8, try jsonDecode(allocator, desc)),
        });
        rest = val_start + val_end_rel;
    }
    return candidates.toOwnedSlice(allocator);
}

test "exec macro returns command output lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try execCommand(arena.allocator(), std.testing.io, "sh", "echo one; echo two");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("one", candidates[0].value);
    try std.testing.expectEqualStrings("two", candidates[1].value);
}

test "buildCompline keeps empty word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = try buildCompline(a, "git", &.{"show"}, "", false, .posix);
    try std.testing.expectEqualStrings("git show ", line);

    const quoted = try buildCompline(a, "git", &.{"show"}, "", true, .posix);
    try std.testing.expectEqualStrings("git show ''", quoted);

    const partial = try buildCompline(a, "git", &.{"show"}, "mas", false, .posix);
    try std.testing.expectEqualStrings("git show mas", partial);

    const noargs = try buildCompline(a, "git", &.{}, "", false, .posix);
    try std.testing.expectEqualStrings("git ", noargs);
}

test "exec macro handles empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try execCommand(arena.allocator(), std.testing.io, "sh", "true");
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "buildCompline quotes words for the target shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const posix = try buildCompline(a, "git", &.{ "commit", "-m", "two words", "it's" }, "", false, .posix);
    try std.testing.expectEqualStrings("git commit -m 'two words' 'it'\\''s' ", posix);

    const fish = try buildCompline(a, "git", &.{"two words"}, "", false, .fish);
    try std.testing.expectEqualStrings("git 'two words' ", fish);

    const pwsh = try buildCompline(a, "git", &.{"it's"}, "", false, .pwsh);
    try std.testing.expectEqualStrings("git 'it''s' ", pwsh);
}

test "splitMacroArgs handles quoted commas and brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try splitMacroArgs(arena.allocator(), "'a,b', c, [d, e], 'f\\'g'");
    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("a,b", args[0]);
    try std.testing.expectEqualStrings("c", args[1]);
    try std.testing.expectEqualStrings("[d, e]", args[2]);
    try std.testing.expectEqualStrings("f'g", args[3]);
}
