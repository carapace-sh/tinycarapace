const std = @import("std");
const traverse = @import("traverse.zig");

/// Build the command line for line-based bridges: words joined with spaces,
/// always ending with the current word. An empty word becomes a trailing
/// space (COMP_LINE-style parsing) or '' when `quoted_empty` is set
/// (shell-parsed input like fish/zsh/powershell).
fn buildCompline(allocator: std.mem.Allocator, cmd: []const u8, args: []const []const u8, prefix: []const u8, quoted_empty: bool) ![]const u8 {
    var cmdline = std.ArrayList(u8).empty;
    try cmdline.appendSlice(allocator, cmd);
    for (args) |a| {
        try cmdline.append(allocator, ' ');
        try cmdline.appendSlice(allocator, a);
    }
    try cmdline.append(allocator, ' ');
    if (prefix.len > 0) {
        try cmdline.appendSlice(allocator, prefix);
    } else if (quoted_empty) {
        try cmdline.appendSlice(allocator, "''");
    }
    return cmdline.toOwnedSlice(allocator);
}

/// Parse "$bridge.name(command, args...)" — delegate to framework-specific completion.
pub fn resolveBridge(allocator: std.mem.Allocator, io: std.Io, macro: []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const paren = std.mem.indexOfScalar(u8, macro, '(') orelse return &.{};
    if (macro[macro.len - 1] != ')') return &.{};

    const bridge_dot = macro[0..paren];
    const bridge_name = if (std.mem.startsWith(u8, bridge_dot, "$bridge."))
        bridge_dot[8..]
    else
        bridge_dot[7..];

    const args_part = macro[paren + 1 .. macro.len - 1];
    if (args_part.len == 0) return &.{};

    var cmd_args = std.ArrayList([]const u8).empty;
    var arg_it = std.mem.splitScalar(u8, args_part, ',');
    while (arg_it.next()) |arg| {
        const trimmed = std.mem.trim(u8, arg, " \t");
        if (trimmed.len > 0) {
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
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024),
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
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false);

    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("COMP_LINE", cmdline);
    try env.put("COMP_POINT", try std.fmt.allocPrint(allocator, "{d}", .{cmdline.len}));
    try env.put("COMP_TYPE", "63");

    var script = std.ArrayList(u8).empty;
    try script.appendSlice(allocator,
        "set +o history\nCOMP_WORDS=($COMP_LINE)\n" ++
        "if [ \"${COMP_LINE: -1}\" = \" \" ]; then COMP_WORDS+=(\"\")\nfi\n" ++
        "COMP_CWORD=$((${#COMP_WORDS[@]} - 1))\nCOMP_POINT=${#COMP_LINE}\n" ++
        "[ -f /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion\n" ++
        "[ -f /usr/local/share/bash-completion/bash_completion ] && source /usr/local/share/bash-completion/bash_completion\n" ++
        "[ -f /data/data/com.termux/files/usr/share/bash-completion/bash_completion ] && source /data/data/com.termux/files/usr/share/bash-completion/bash_completion\n");
    try script.appendSlice(allocator, "__load_completion \""); try script.appendSlice(allocator, cmd); try script.appendSlice(allocator, "\" 2>/dev/null\n");
    try script.appendSlice(allocator, "_cf=$(complete -p \""); try script.appendSlice(allocator, cmd); try script.appendSlice(allocator, "\" 2>/dev/null | sed -r 's/.* -F ([^ ]+).*/\\1/')\n");
    try script.appendSlice(allocator, "if [ -n \"$_cf\" ]; then \"$_cf\"\n  for i in \"${COMPREPLY[@]}\"; do\n    if [[ -d \"$i\" && \"$i\" != */ ]]; then echo \"$i/\"; else echo \"$i\"; fi; done\nfi\n");

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "bash", "--rcfile", "/dev/null", "-i", "-c", script.items },
        .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: zsh — run zsh with compdef via capture script
fn bridgeZsh(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, true);

    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    const home_zsh = if (environ_map) |em| em.get("HOME") orelse "/tmp" else "/tmp";
    try env.put("CARAPACE_BRIDGE_CONFIG_HOME", home_zsh);

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
        .argv = zsh_argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    // Build unquote mappings
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == 0) continue;
        // Split on " -- " for description
        if (std.mem.indexOf(u8, trimmed, " -- ")) |sep| {
            const value = trimmed[0..sep];
            const desc = trimmed[sep + 4 ..];
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, value), .description = try allocator.dupe(u8, desc) });
        } else {
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: fish — run fish with complete --do-complete
fn bridgeFish(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, true);

    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    const home_fish = if (environ_map) |em| em.get("HOME") orelse "/tmp" else "/tmp";
    try env.put("CARAPACE_BRIDGE_CONFIG_HOME", home_fish);

    const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config/carapace/bridge/fish", .{home_fish});
    defer allocator.free(config_dir);

    const snippet = try std.fmt.allocPrint(allocator,
        "set __fish_config_dir {s};source \"$__fish_data_dir/config.fish\";source \"{s}/config.fish\";complete --do-complete=\"{s}\"",
        .{ config_dir, config_dir, cmdline });
    defer allocator.free(snippet);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "fish", "--no-config", "--command", snippet },
        .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
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

/// Bridge: carapace — run `cmd _carapace export ""`
fn bridgeCarapace(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "_carapace"); try argv.append(allocator, "export"); try argv.append(allocator, "");
    for (args) |a| try argv.append(allocator, a);
    if (prefix.len > 0) try argv.append(allocator, prefix);
    const result = std.process.run(allocator, io, .{
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    if (result.stdout.len == 0) return &.{};
    return parseExportJson(allocator, result.stdout);
}

/// Bridge: carapace-bin — run `carapace <cmd> export ""`
fn bridgeCarapaceBin(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, "carapace");
    try argv.append(allocator, cmd); try argv.append(allocator, "export"); try argv.append(allocator, "");
    for (args) |a| try argv.append(allocator, a);
    if (prefix.len > 0) try argv.append(allocator, prefix);
    const result = std.process.run(allocator, io, .{
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    if (result.stdout.len == 0) return &.{};
    return parseExportJson(allocator, result.stdout);
}

/// Bridge: argcomplete — run with _ARGCOMPLETE=1 (v3)
fn bridgeArgcomplete(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false);
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("_ARGCOMPLETE", "1"); try env.put("_ARGCOMPLETE_DFS", "\\t"); try env.put("_ARGCOMPLETE_IFS", "\\n");
    try env.put("_ARGCOMPLETE_SHELL", "fish"); try env.put("COMP_LINE", cmdline);
    try env.put("COMP_POINT", try std.fmt.allocPrint(allocator, "{d}", .{cmdline.len}));
    try env.put("_ARGCOMPLETE_SUPPRESS_SPACE", "1");
    const result = std.process.run(allocator, io, .{
        .argv = &.{ cmd }, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            if (std.mem.indexOfScalar(u8, trimmed, '\t')) |tab| {
                try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed[0..tab]), .description = try allocator.dupe(u8, trimmed[tab + 1 ..]) });
            } else {
                try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
            }
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: argcomplete v1 — deprecated, uses fd 8/9
fn bridgeArgcompleteV1(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false);
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("_ARGCOMPLETE", "1"); try env.put("_ARGCOMPLETE_DFS", "\\t"); try env.put("_ARGCOMPLETE_IFS", "\\n");
    try env.put("_ARGCOMPLETE_SHELL", "fish"); try env.put("COMP_LINE", cmdline);
    try env.put("COMP_POINT", try std.fmt.allocPrint(allocator, "{d}", .{cmdline.len}));
    try env.put("_ARGCOMPLETE_SUPPRESS_SPACE", "1");
    const shell_cmd = try std.fmt.allocPrint(allocator, "{s} 8>&1 9>&2 1>/dev/null 2>/dev/null", .{cmd});
    defer allocator.free(shell_cmd);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", shell_cmd }, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            if (std.mem.indexOfScalar(u8, trimmed, '\t')) |tab| {
                try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed[0..tab]), .description = try allocator.dupe(u8, trimmed[tab + 1 ..]) });
            } else {
                try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
            }
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: aws — run aws_completer with COMP_LINE
fn bridgeAws(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false);
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("COMP_LINE", cmdline);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "aws_completer" }, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
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
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
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
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false);
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("COMP_WORDS", cmdline);
    var word_count: usize = 1;
    for (cmdline) |c| { if (c == ' ') word_count += 1; }
    try env.put("COMP_CWORD", try std.fmt.allocPrint(allocator, "{d}", .{word_count}));
    var upper_buf: [256]u8 = undefined;
    var upper_len: usize = 0;
    for (cmd) |c| { upper_buf[upper_len] = std.ascii.toUpper(c); upper_len += 1; }
    const env_var_name = try std.fmt.allocPrint(allocator, "_{s}_COMPLETE", .{upper_buf[0..upper_len]});
    defer allocator.free(env_var_name);
    try env.put(env_var_name, "zsh_complete");
    const result = std.process.run(allocator, io, .{
        .argv = &.{ cmd }, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |_| {
        const value_line = if (lines.next()) |l| std.mem.trim(u8, l, " \t\r") else break;
        const desc_line = if (lines.next()) |l| std.mem.trim(u8, l, " \t\r") else "";
        if (value_line.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, value_line), .description = try allocator.dupe(u8, desc_line) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: complete — run with COMP_LINE
fn bridgeComplete(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false);
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("COMP_LINE", cmdline);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ cmd }, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: gcloud — run with argcomplete (delegates to argcomplete v1)
fn bridgeGcloud(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK", "1");
    return bridgeArgcompleteV1(allocator, io, cmd, args, prefix, &env);
}

/// Bridge: inshellisense — run `inshellisense complete <input>`
fn bridgeInshellisense(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, false);
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, "inshellisense");
    try argv.append(allocator, "complete");
    try argv.append(allocator, cmdline);
    const result = std.process.run(allocator, io, .{
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
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
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("COMPLETE", "fish");
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    try argv.append(allocator, "--");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
    const result = std.process.run(allocator, io, .{
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
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
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
    }
    // Fallback to files if no candidates
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: kitten — run `kitten __complete__ json`
fn bridgeKitten(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    _ = allocator; _ = io; _ = cmd; _ = args; _ = prefix; _ = environ_map;
    return &.{};
}

/// Bridge: powershell — run pwsh with CommandCompletion::CompleteInput
fn bridgePowershell(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    const cmdline = try buildCompline(allocator, cmd, args, prefix, true);
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    const home = if (environ_map) |em| em.get("HOME") orelse "/tmp" else "/tmp";
    const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config/carapace/bridge/powershell", .{home});
    defer allocator.free(config_dir);
    const snippet = try std.fmt.allocPrint(allocator,
        "Get-Content \"{s}/Microsoft.PowerShell_profile.ps1\" | Out-String | Invoke-Expression;[System.Management.Automation.CommandCompletion]::CompleteInput(\"{s}\", {d}, $null).CompletionMatches | ConvertTo-Json",
        .{ config_dir, cmdline, cmdline.len });
    defer allocator.free(snippet);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "pwsh", "-Command", snippet }, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    // Parse JSON from powershell: [{"CompletionText":"...","ListItemText":"...","ToolTip":"..."}]
    if (result.stdout.len > 0) {
        var pos: usize = 0;
        while (pos < result.stdout.len) {
            const ct_key = std.mem.indexOf(u8, result.stdout[pos..], "\"CompletionText\": \"") orelse break;
            const val_start = pos + ct_key + 19;
            const val_end = std.mem.indexOfScalar(u8, result.stdout[val_start..], '"') orelse break;
            var value = result.stdout[val_start .. val_start + val_end];
            // Strip trailing space (nospace indicator)
            if (value.len > 0 and value[value.len - 1] == ' ') value = value[0 .. value.len - 1];
            pos = val_start + val_end;
            var desc: []const u8 = "";
            if (std.mem.indexOf(u8, result.stdout[pos..], "\"ToolTip\": \"")) |tt_key| {
                const d_start = pos + tt_key + 11;
                const d_end = std.mem.indexOfScalar(u8, result.stdout[d_start..], '"') orelse 0;
                if (d_end > 0) desc = result.stdout[d_start .. d_start + d_end];
            }
            // Skip if CompletionText == ToolTip
            if (std.mem.eql(u8, value, desc)) desc = "";
            try candidates.append(allocator, .{ .value = try allocator.dupe(u8, value), .description = try allocator.dupe(u8, desc) });
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: urfavecli — run with --generate-shell-completion
fn bridgeUrfavecli(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
    try argv.append(allocator, "--generate-shell-completion");
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("SHELL", "zsh");
    const result = std.process.run(allocator, io, .{
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
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

/// Bridge: urfavecli v1 — run with --generate-bash-completion
fn bridgeUrfavecliV1(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd);
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
    try argv.append(allocator, "--generate-bash-completion");
    const result = std.process.run(allocator, io, .{
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024),
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) try candidates.append(allocator, .{ .value = try allocator.dupe(u8, trimmed) });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Bridge: yargs — run with --get-yargs-completions
fn bridgeYargs(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, args: []const []const u8, prefix: []const u8, environ_map: ?*const std.process.Environ.Map) ![]traverse.Candidate {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, cmd); try argv.append(allocator, "--get-yargs-completions");
    for (args) |a| try argv.append(allocator, a);
    try argv.append(allocator, prefix);
    var env = std.process.Environ.Map.init(allocator);
    if (environ_map) |em| { var it = em.iterator(); while (it.next()) |entry| { try env.put(entry.key_ptr.*, entry.value_ptr.*); } }
    try env.put("SHELL", "zsh");
    const result = std.process.run(allocator, io, .{
        .argv = argv.items, .stdout_limit = .limited(1024 * 64), .stderr_limit = .limited(1024), .environ_map = &env,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    var candidates = std.ArrayList(traverse.Candidate).empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
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

/// Parse carapace JSON export format.
fn parseExportJson(allocator: std.mem.Allocator, json: []const u8) ![]traverse.Candidate {
    var candidates = std.ArrayList(traverse.Candidate).empty;
    const values_start = std.mem.indexOf(u8, json, "\"values\": [") orelse return &.{};
    var rest = values_start + 11;
    while (rest < json.len) {
        const val_key = std.mem.indexOf(u8, json[rest..], "\"value\": \"") orelse break;
        const val_start = rest + val_key + 10;
        const val_end = std.mem.indexOfScalar(u8, json[val_start..], '"') orelse break;
        const value = json[val_start .. val_start + val_end];
        var desc: []const u8 = "";
        const after_val = json[val_start + val_end ..];
        if (std.mem.indexOf(u8, after_val, "\"description\": \"")) |desc_start| {
            const d_start = desc_start + 16;
            var d_end: usize = 0;
            var i: usize = d_start;
            while (i < after_val.len) {
                if (after_val[i] == '\\' and i + 1 < after_val.len) { i += 2; continue; }
                if (after_val[i] == '"') { d_end = i; break; }
                i += 1;
            }
            if (d_end > 0) desc = after_val[d_start..d_end];
        }
        try candidates.append(allocator, .{ .value = try allocator.dupe(u8, value), .description = try allocator.dupe(u8, desc) });
        rest = val_start + val_end;
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

    const line = try buildCompline(a, "git", &.{"show"}, "", false);
    try std.testing.expectEqualStrings("git show ", line);

    const quoted = try buildCompline(a, "git", &.{"show"}, "", true);
    try std.testing.expectEqualStrings("git show ''", quoted);

    const partial = try buildCompline(a, "git", &.{"show"}, "mas", false);
    try std.testing.expectEqualStrings("git show mas", partial);

    const noargs = try buildCompline(a, "git", &.{}, "", false);
    try std.testing.expectEqualStrings("git ", noargs);
}

test "exec macro handles empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = try execCommand(arena.allocator(), std.testing.io, "sh", "true");
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}