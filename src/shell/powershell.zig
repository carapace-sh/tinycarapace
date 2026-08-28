const std = @import("std");
const spec = @import("../spec.zig");
const traverse = @import("../traverse.zig");

fn sanitize(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        if (c == '-') {
            try buf.append(allocator, '_');
            try buf.append(allocator, '_');
        } else {
            try buf.append(allocator, c);
        }
    }
    return buf.toOwnedSlice(allocator);
}

pub fn generateInitScript(allocator: std.mem.Allocator, specs: []const spec.SpecInfo) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";

    try buf.print(allocator,
        \\using namespace System.Management.Automation
        \\using namespace System.Management.Automation.Language
        \\Function _carapace_completer {{
        \\    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingInvokeExpression", "", Scope="Function", Target="*")]
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\    $commandElements = $commandAst.CommandElements
        \\
        \\    $elems = @()
        \\    foreach ($_ in $commandElements) {{
        \\      if ($_.Extent.StartOffset -gt $cursorPosition) {{
        \\          break
        \\      }}
        \\      $t = $_.Extent.Text
        \\      if ($_.Extent.EndOffset -gt $cursorPosition) {{
        \\          $t = $t.Substring(0, $_.Extent.Text.get_Length() - ($_.Extent.EndOffset - $cursorPosition))
        \\      }}
        \\      if ($t.Substring(0,1) -eq "'"){{
        \\        $t = $t.Substring(1)
        \\      }}
        \\      if ($t.get_Length() -gt 0 -and $t.Substring($t.get_Length()-1) -eq "'"){{
        \\        $t = $t.Substring(0,$t.get_Length()-1)
        \\      }}
        \\      if ($t.get_Length() -eq 0){{
        \\        $t = '""'
        \\      }}
        \\      $elems += $t.replace(',', ',')
        \\    }}
        \\
        \\    $completions = @(
        \\      if (!$wordToComplete) {{
        \\        {s} ($elems[0] -replace ('\\.exe$', '')) _carapace powershell $($elems| ForEach-Object {{$_}}) '' | ConvertFrom-Json | ForEach-Object {{ [CompletionResult]::new($_.CompletionText, $_.ListItemText.replace('`e[', "`e["), [CompletionResultType]::ParameterValue, $_.ToolTip.replace('`e[', "`e[")) }}
        \\      }} else {{
        \\        {s} ($elems[0] -replace ('\\.exe$', '')) _carapace powershell $($elems| ForEach-Object {{$_}}) | ConvertFrom-Json | ForEach-Object {{ [CompletionResult]::new($_.CompletionText, $_.ListItemText.replace('`e[', "`e["), [CompletionResultType]::ParameterValue, $_.ToolTip.replace('`e[', "`e[")) }}
        \\      }}
        \\    )
        \\
        \\    if ($completions.count -eq 0) {{
        \\      return ""
        \\    }}
        \\    $completions
        \\}}
        \\
    , .{ exe, exe });

    for (specs) |s| {
        try buf.print(allocator,
            \\Register-ArgumentCompleter -Native -ScriptBlock (Get-Item "Function:_carapace_completer").ScriptBlock -CommandName '{s}' # ,'{s}.exe'
            \\
        , .{ s.name, s.name });
    }

    return buf.toOwnedSlice(allocator);
}

pub fn generateSnippet(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const exe = "carapace-tiny";
    const cmd_sanitized = try sanitize(allocator, name);
    defer allocator.free(cmd_sanitized);

    try buf.print(allocator,
        \\using namespace System.Management.Automation
        \\using namespace System.Management.Automation.Language
        \\Function _{s}_completion {{
        \\    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingInvokeExpression", "", Scope="Function", Target="*")]
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\    $commandElements = $commandAst.CommandElements
        \\
        \\    $elems = @()
        \\    foreach ($_ in $commandElements) {{
        \\      if ($_.Extent.StartOffset -gt $cursorPosition) {{
        \\          break
        \\      }}
        \\      $t = $_.Extent.Text
        \\      if ($_.Extent.EndOffset -gt $cursorPosition) {{
        \\          $t = $t.Substring(0, $_.Extent.Text.get_Length() - ($_.Extent.EndOffset - $cursorPosition))
        \\      }}
        \\      if ($t.Substring(0,1) -eq "'"){{
        \\        $t = $t.Substring(1)
        \\      }}
        \\      if ($t.get_Length() -gt 0 -and $t.Substring($t.get_Length()-1) -eq "'"){{
        \\        $t = $t.Substring(0,$t.get_Length()-1)
        \\      }}
        \\      if ($t.get_Length() -eq 0){{
        \\        $t = '""'
        \\      }}
        \\      $elems += $t.replace(',', ',')
        \\    }}
        \\
        \\    $completions = @(
        \\      if (!$wordToComplete) {{
        \\        {s} '{s}' powershell $($elems| ForEach-Object {{$_}}) '' | ConvertFrom-Json | ForEach-Object {{ [CompletionResult]::new($_.CompletionText, $_.ListItemText.replace('`e[', "`e["), [CompletionResultType]::ParameterValue, $_.ToolTip.replace('`e[', "`e[")) }}
        \\      }} else {{
        \\        {s} '{s}' powershell $($elems| ForEach-Object {{$_}}) | ConvertFrom-Json | ForEach-Object {{ [CompletionResult]::new($_.CompletionText, $_.ListItemText.replace('`e[', "`e["), [CompletionResultType]::ParameterValue, $_.ToolTip.replace('`e[', "`e[")) }}
        \\      }}
        \\    )
        \\
        \\    if ($completions.count -eq 0) {{
        \\      return ""
        \\    }}
        \\    $completions
        \\}}
        \\
        \\Register-ArgumentCompleter -Native -ScriptBlock (Get-Item "Function:_{s}_completion").ScriptBlock -CommandName '{s}' # ,'{s}.exe'
        \\
    , .{ cmd_sanitized, exe, name, exe, name, cmd_sanitized, name, name });

    return buf.toOwnedSlice(allocator);
}

pub fn formatOutput(allocator: std.mem.Allocator, candidates: []traverse.Candidate, _: ?[]const u8) ![]const u8 {
    return @import("export.zig").formatOutput(allocator, candidates);
}

test "powershell init script" {
    const specs = [_]spec.SpecInfo{
        .{ .name = "mycmd", .path = "/tmp/mycmd.yaml" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try generateInitScript(arena.allocator(), specs[0..]);
    try std.testing.expect(std.mem.indexOf(u8, script, "Register-ArgumentCompleter") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "CompletionResult") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "commandAst") != null);
}

test "powershell snippet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snippet = try generateSnippet(arena.allocator(), "mycmd");
    try std.testing.expect(std.mem.indexOf(u8, snippet, "Register-ArgumentCompleter") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "CompletionResult") != null);
}

test "powershell format output" {
    const candidates = [_]traverse.Candidate{
        .{ .value = "json", .description = "JSON format" },
        .{ .value = "yaml", .description = "" },
    };
    const out = try formatOutput(std.testing.allocator, @constCast(&candidates), null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"value\": \"json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"description\": \"JSON format\"") != null);
}