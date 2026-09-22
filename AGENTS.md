# tinycarapace — Agent Guide

A minimal [carapace-spec](https://github.com/carapace-sh/carapace-spec) interpreter
in Zig for resource-constrained environments (docker containers, alpine, scratch
images). It reads the standard YAML spec format and provides shell completion.

**Language**: Zig 0.16.0+ (min 0.15.0). **Tests**: `zig build test`

---

## Source of Truth

**The Go-based carapace ecosystem is the source of truth.** This project is an
AI-generated port and should adapt to upstream changes. The key reference
projects are:

| Project | Role | What to verify against |
|---------|------|----------------------|
| [carapace](https://github.com/carapace-sh/carapace) | Core framework | Shell snippets, traversal engine, export format, `_carapace` protocol |
| [carapace-spec](https://github.com/carapace-sh/carapace-spec) | Spec format | `Command`/`Flag` structs, YAML fields, macro names, `run` semantics |
| [carapace-bridge](https://github.com/carapace-sh/carapace-bridge) | Bridge system | `bash.sh`, `bash.go`, `zsh.go`, `fish.go`, bridge dispatch, `CARAPACE_BRIDGES` |
| [carapace-bin](https://github.com/carapace-sh/carapace-bin) | Reference impl | `carapace _carapace export` protocol, CLI interface |

When in doubt, check the Go implementation first — it is well-tested and
represents the correct behavior. This project targets a **reduced feature set**
but must be **consistent** with upstream for the features it implements.

---

## Essential Commands

```bash
zig build                                    # Build (zig-out/bin/carapace-tiny)
zig build test                                # Run all tests (no output = success)
zig build -Doptimize=ReleaseFast && strip zig-out/bin/carapace-tiny  # Release
```

Cross-compile (no extra toolchain needed):
```bash
zig build -Dtarget=x86_64-linux-musl
zig build -Dtarget=aarch64-linux-musl
```

---

## Source Layout (~5100 LOC)

```
src/
├── main.zig       # CLI entry: _carapace, bash/zsh/fish/powershell, run, export
├── spec.zig       # Command/Flag/Completion types + YAML decode + SpecInfo discovery
├── yaml.zig       # ~676 LOC hand-written YAML subset parser (recursive descent, no deps)
├── flag.zig       # Flag string parser (compact syntax: --optarg?=, --repeatable*, --hidden&)
├── traverse.zig   # Argument traversal state machine (the core completion engine)
├── action.zig     # Macro resolution: static values, shell execs, modifiers, bridges (~800 LOC)
└── shell/
    ├── bash.zig        # Bash snippet + output formatting
    ├── zsh.zig         # Zsh snippet + output formatting (multi-block format)
    ├── fish.zig        # Fish snippet + output formatting
    ├── powershell.zig  # Powershell snippet + output formatting (JSON via ConvertFrom-Json)
    └── export.zig      # JSON export format (carapace-compatible)
```

---

## Architecture

```
spec.yaml → yaml.zig (parse) → spec.zig (decode) → traverse.zig (complete)
    → shell/*.zig (format output)
    ↕ fallback
    → action.zig (macros, bridges, $files, $sh, $chdir, $bridge.*)
```

For commands without a spec file, `CARAPACE_BRIDGES` (bash/fish/zsh/inshellisense)
provides implicit bridge fallback.

---

## CLI Interface

```
# Generate init script for all discovered specs
tinycarapace _carapace [bash|zsh|fish|powershell]

# Generate completion snippet for a single command
tinycarapace <name> <shell>

# Get completions (invoked by snippet)
tinycarapace <name> <shell> <name> <args...>

# Export completions as JSON (carapace export format)
tinycarapace <name> export [<args...>]

# Execute the spec's run field
tinycarapace <name> run [<args...>]
```

---

## Shell Snippets

All shell snippets must match the output of the corresponding Go files in `carapace/internal/shell/`.

### Bash
- Exports: `COMP_LINE`, `COMP_POINT`, `COMP_TYPE`, `COMP_WORDBREAKS`
- Output: `mapfile -t COMPREPLY < <(echo "${data}")` + `unset COMPREPLY[-1]`
- Three-stage open-quote retry (empty `''`, single `'`, double `"`)
- `[[ "${COMPREPLY[*]}" == "" ]] && COMPREPLY=()` — fix for mapfile creating non-empty array from empty output
- Function name: `_<name>_completion` (single), `_carapace_completer` (init)
- Init script: `complete -o noquote -F _carapace_completer <names...>`

### Zsh
- `#compdef <names>` header
- Multi-block output format: `\x01` (nospace/message), `\x02` (block separator), `\x03` (tag/displays/values separator), `\x04` (array terminator)
- `CARAPACE_COMPLINE` env var passed to xargs
- `compstate[insert]=menu` for nospace support
- `compquote '' 2>/dev/null && _<name>_completion` for pre-GNU compdef compat
- Blocks: `tag\x03displays\x04\x03values\x04\x02`

### Fish
- `function _<name>_completion` with `set --local data`
- `IFS='' set data (echo (commandline -cp)'' | sed "s/ $/ ''/" | xargs ...)`
- `sed "s/ $/ ''/"` — handles trailing space (empty word being completed)
- `complete -e '<name>'` — erase existing completions before registering
- `complete -c '<name>' -f -a '(_<name>_completion)' -r`

### Powershell
- Uses `$commandAst.CommandElements` and `$cursorPosition` (not `$words`)
- `$_.Extent.StartOffset` / `$_.Extent.EndOffset` for cursor position tracking
- Strips surrounding single quotes from elements
- Output via `ConvertFrom-Json` (powershell format output = JSON export format)
- `[CompletionResult]::new($_.CompletionText, $_.ListItemText, ...)`
- `Register-ArgumentCompleter -Native -ScriptBlock (Get-Item "Function:_<name>_completion").ScriptBlock`

---

## Bridges

### Supported bridge macros (`$bridge.<name>(cmd, args...)`)

| Bridge | Protocol | Invocation |
|--------|----------|------------|
| `Cobra` | `cmd __complete <args>` | Cobra's built-in `__complete` command |
| `Bash` | `COMP_LINE` + bash-completion | `bash --rcfile /dev/null -i` sourcing `bash_completion` |
| `Zsh` | `zsh --no-rcs -c <script>` | Third-party zsh-capture-completion script |
| `Fish` | `fish --no-config --command <script>` | `complete --do-complete=<input>` |
| `Carapace` | `cmd _carapace export ""` | JSON export format |
| `CarapaceBin` | `carapace <cmd> export ""` | Carapace binary's export |
| `Argcomplete` | `_ARGCOMPLETE=1` | argcomplete env vars |
| `ArgcompleteV1` | `_ARGCOMPLETE=1` (fd 8/9) | Deprecated argcomplete v1 |
| `Aws` | `aws_completer` | aws-cli completer |
| `Clap` | `cmd complete --index ...` | Clap's built-in completion |
| `Click` | `_<CMD>_COMPLETE=zsh_complete` | Click env var |
| `Complete` | `COMP_LINE` | posener/complete |
| `Gcloud` | `argcomplete` | gcloud CLI |
| `Inshellisense` | `inshellisense complete` | Microsoft inshellisense |
| `JJ` | `COMPLETE=fish` | Jujutsu VCS |
| `Kingpin` | `--completion-bash` | alecthomas/kingpin |
| `Kitten` | `kitten __complete__ json` | kitty terminal |
| `Powershell` | `CommandCompletion::CompleteInput()` | pwsh script |
| `Urfavecli` | `--generate-shell-completion` | urfave/cli v2+ |
| `UrfavecliV1` | `--generate-bash-completion` | urfave/cli v1 |
| `Yargs` | `--get-yargs-completions` | Yargs built-in |

### Implicit bridges (`CARAPACE_BRIDGES`)

Only shell bridges are auto-detectable: `bash`, `fish`, `zsh`, `inshellisense`.
Framework bridges (cobra, click, etc.) require explicit `$bridge.name()` usage.

The bash bridge script must match `carapace-bridge/pkg/actions/bridge/bash.sh`:
- `set +o history`
- Set `COMP_WORDS`, `COMP_CWORD`, `COMP_POINT` from `COMP_LINE`
- Source `bash_completion` from known paths
- Call `__load_completion` to register the completion
- Extract function name via `complete -p <cmd> | sed -r 's/.* -F ([^ ]+).*/\1/'`
- Iterate `COMPREPLY`, append `/` to directories

---

## Key Patterns & Gotchas

### Zig 0.16.x APIs

This codebase uses the **new Zig 0.16 I/O API** (`std.process.Init`, `std.Io`,
`init.minimal.args.vector`, `init.environ_map.get`, `init.io`,
`std.Io.Dir.readFileAlloc`, `std.Io.File.stdout().writeStreamingAll`). These are
**not** the Zig 0.11-0.13 allocator/fs APIs. If you see `std.io`, `std.fs.cwd()`,
or `args.processAlloc` — those are the wrong version.

### Memory Management

- **One `ArenaAllocator` per completion invocation** in `main.zig`
- Inside `loadSpec()`, a **second ArenaAllocator** is created — the caller's
  arena is only used indirectly. The inner arena is freed by `defer arena.deinit()`
  in `loadSpec`, but the returned `Command` struct borrows from it. The caller's
  arena keeps the result alive.
- `std.ArrayList(T).empty` is used instead of `std.ArrayList(T).init(allocator)`
  — allocator passed separately to `append()`.

### YAML Parser Limitations

- Only handles the carapace-spec subset: maps, block lists, flow sequences
  (`[a, b]`), flow maps (`{k: v}`)
- No anchors, aliases, multi-document, or complex tags
- Indentation-based blocks only (no tabs)
- `#` comments supported (inline and line-level)
- Silently ignores unknown fields (forward-compatible)
- Returns `.scalar = ""` for empty/absent values (not null)

### Flag String Syntax

Parsed in `flag.zig:parseFlag()`. Suffix characters on the flag name:
- `=` — takes a value
- `?` — optional argument (also sets `takes_value=true`)
- `*` — repeatable
- `!` — required
- `&` — hidden

Examples: `--output=`, `--optarg?=`, `--repeatable*`, `-v`, `-o, --output=`

Extended notation (object form) supports `nargs` and `default`:
```yaml
--nargs-two=: {description: consumes two args, nargs: 2}
--default-val=: {description: flag with default, default: /tmp/out.txt}
```

### Traversal Engine (`traverse.zig:completeWithEnv`)

- Skips first arg (command name)
- Classifies each arg: flag value → dash → flag → subcommand → positional
- `--` disables flag parsing for remaining args
- `parsing: disabled` on a subcommand also disables flag parsing
- `parsing: non-interspersed` stops flag parsing after first positional
- **Persistent flags ARE inherited from ancestors** — `findFlag()` walks up the
  parent chain via `cmd.parent`
- **Exclusive flags** — consumed flag groups exclude their members from completion
- **Variable expansion** — `${C_ARG0}`, `${C_FLAG_NAME}`, `${C_VALUE}` with
  `${VAR:-default}` syntax
- **Bridge fallback** — when a spec has a `run` field and no completions,
  `CARAPACE_BRIDGES` bridges are tried on the aliased command
- When a subcommand is entered, `positional_count` resets to 0
- Completion candidates are filtered by `std.mem.startsWith(u8, candidate, value)`
  — prefix matching only

### Completion Decision Tree (last arg)

| Context | Completes |
|---|---|
| `in_flag` is set | `completion.flag[flag.name]` |
| Last arg is `--flag=value` | `completion.flag[flag.name]`, filtered by prefix after `=` |
| Last arg starts with `-` | All non-hidden flags of current command (+ persistent flags, minus exclusive groups) |
| `dash` is true | `completion.dash[positional_count]` / `dashany` |
| Has subcommands + no positionals consumed | Subcommand names **+** `completion.positional[0]` (batch) |
| `positional_count < positional.len` | `completion.positional[positional_count]` |
| Otherwise | `completion.positionalany` |
| No completions + `run` field | Bridge fallback from `CARAPACE_BRIDGES` |

### Macro System (`action.zig`)

Supports:
- **Static values**: `value`, `value\tdescription`, `value\tdescription\tstyle`
- **Shell exec macros**: `$sh(cmd)`, `$bash(cmd)`, `$zsh(cmd)`, `$fish(cmd)`,
  `$elvish(cmd)`, `$nu(cmd)`, `$osh(cmd)`, `$xonsh(cmd)`, `$cmd(cmd)`, `$pwsh(cmd)`
- **Bare dollar shorthand**: `$(cmd)` → `$sh(cmd)`
- **Built-in macros**: `$files`, `$directories`, `$executables`, `$message(msg)`
- **List macros**: `$list(delim)`, `$uniquelist(delim)`, `$multiparts([delim])`
- **Directory macro**: `$chdir(dir)` with `$userhomedir`, `$tempdir`,
  `$xdgconfighome`, `$xdgcachehome`, `$gitdir`, `$gitworktree`, `$parent([file, dir])`
- **Split macros**: `$split(delim)`, `$splitp(delim)`
- **Bridge macros**: `$bridge.name(cmd, args...)`
- **Modifier chains**: `base ||| $prefix(...) ||| $suffix(...) ||| ...`
- **Modifiers**: `$prefix`, `$suffix`, `$nospace`, `$noprefix`, `$style`, `$tag`,
  `$filter`, `$filterargs`, `$retain`, `$shift`, `$suppress`, `$usage`, `$uid`,
  `$split`, `$splitp`

### Bash Snippet Details

- Function name: `_<name>_completion` (single), `_carapace_completer` (init)
- Uses `xargs --` to pass the command line safely
- Three-stage open-quote retry (empty `''`, single `'`, double `"`)
- `complete -o noquote -F` — no `-o nospace`
- `mapfile -t COMPREPLY < <(echo "${data}")` + `unset COMPREPLY[-1]`
- `[[ "${COMPREPLY[*]}" == "" ]] && COMPREPLY=()` — fix for mapfile
- Descriptions shown only when `COMP_TYPE` is `63` (successive tab)
- `\x01`-delimited nospace flag on first line of output

### Testing

- All tests are inline in source files using `std.testing.*`
- Arena allocator pattern: `var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();`
- Tests call completion functions directly with parsed specs (no subprocess)
- `zig build test` exits with code 0 on success, errors on failure
- Test file: `src/main.zig` imports all modules (each has inline tests)

### Non-Obvious

- **`@constCast`** is used in test code to pass a const slice to a function
  expecting a mutable parameter — test-only pattern
- **No `std.log` or debug logging** — uses `std.debug.print` for error messages
- **No `COMP_WORDBREAKS` re-lexing** — unlike full carapace, there's no re-lexing
  of the command line with `COMP_WORDBREAKS` characters
- **`plan.md`** is the design document — contains spec, architecture decisions,
  and implementation phases
- **`example/example.yaml`** is a test spec with flags, subcommands, and
  completion values — use it for manual testing
- The `build.zig.zon` has `minimum_zig_version = "0.15.0"` but the code uses
  Zig 0.16.0 APIs — update this if adding new APIs
- **`expandVariables`** in `traverse.zig` supports `${C_VALUE}`, `${C_ARG0}`,
  `${C_FLAG_NAME}`, and `${VAR:-default}` — used in `run` mode and completion
  value templates
- **`resolveBridgeFallback`** in `traverse.zig` is public — called from `main.zig`
  when no spec file is found for a command
- The `run` field supports three modes: script (`#!`), macro (`$(`), and alias
  (`[json, array]` or plain string)

---

## Phase Status

From `plan.md`:

- **Phase 1 (Core + bash)**: ✅ Complete
- **Phase 2 (Core improvements)**: ✅ dash/dashany, persistent flags, flag values, `$files/$directories/$executables`, `$(cmd)`
- **Phase 3 (Extended macros)**: ✅ All modifiers, `$message`, `$list`, `$multiparts`, `$chdir`, `$split`, `$splitp`, `$bridge.*`
- **Phase 4 (Shell support)**: ✅ Bash, zsh, fish, powershell (all with upstream-compatible output formats)
- **Phase 5 (Variable expansion & run mode)**: ✅ Variable expansion, `run` mode, `non-interspersed`, `exclusiveflags`, `group`, `nargs`

### Not implemented (deferred)

- `COMP_WORDBREAKS` re-lexing in bash snippet (upstream `bash/action.go` splits
  the line on wordbreak chars and handles common display prefixes)
- Zsh quote-state handling (`QUOTING_STATE` etc. in upstream `zsh/action.go`)
- Bash value quoting/escaping (`requiresQuoting`, `escapingQuotedReplacer`)
- elvish/shell discovery for bridges