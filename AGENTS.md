# carapace-tiny — Agent Guide

A minimal [carapace-spec](https://github.com/carapace-sh/carapace-spec) interpreter in Zig for resource-constrained environments (docker containers, alpine, scratch images). It reads the standard YAML spec format and generates shell completion — primarily bash.

**Language**: Zig 0.16.0 (min 0.15.0) — all tests pass with `zig build test`

## Essential Commands

```bash
zig build              # Build (outputs to zig-out/bin/carapace-tiny)
zig build test         # Run all tests (no output = success)
zig build -Doptimize=ReleaseFast  # Release build (strip with zig build && strip zig-out/bin/carapace-tiny)
```

Cross-compile (no extra toolchain needed):
```bash
zig build -Dtarget=x86_64-linux-musl
zig build -Dtarget=aarch64-linux-musl
```

## Source Layout (~1511 LOC)

```
src/
├── main.zig       # CLI entry: `_carapace` (init) or `<name> bash` (snippet/completions)
├── spec.zig       # Command/Flag/Completion types + YAML → struct decode + SpecInfo/discovery
├── yaml.zig       # ~676 LOC hand-written YAML subset parser (recursive descent, no deps)
├── flag.zig       # Flag string parser (compact syntax: --optarg?=, --repeatable*, --hidden&)
├── traverse.zig   # Argument traversal state machine (the core completion engine)
├── action.zig     # Macro resolution stub (currently only returns static values, no macros)
└── shell/
    ├── bash.zig   # Init script, snippet generation + output formatting
    └── export.zig # JSON export format (carapace-compatible)
```

## Architecture

1. **YAML parsing** (`yaml.zig`) → tagged union tree (`Value.{scalar, list, map}`)
2. **Spec decoding** (`spec.zig`) → typed `Command` structs with `Flag`, `Completion`
3. **Traversal** (`traverse.zig`) → walk CLI args, classify tokens, decide what to complete
4. **Output** (`shell/bash.zig`, `shell/export.zig`) → format candidates or generate bash `complete -F` snippet

```
CARAPACE_SPECS / ~/.config/carapace/specs/ /etc/carapace/specs/
    → spec.zig (discover) → bash.zig (init snippet) → bash compgen
                       ↓
                    yaml.zig (parse) → spec.zig (decode) → traverse.zig (complete) → bash.zig (format)
                                                                                  └→ export.zig (JSON)
```

## CLI Interface

```bash
# Generate bash init script for all specs in CARAPACE_SPECS env var
# (source this to register all completers)
carapace-tiny _carapace [bash]

# Generate bash completion snippet for a single command
# (source this to register one completer)
carapace-tiny <name> bash

# Completion callback — invoked by the bash snippet
# Provides completions for the given command's spec
carapace-tiny <name> bash <name> <args...>

# Export completions as JSON (carapace export format)
# Useful for debugging or external tooling
carapace-tiny <name> export [<name> <args...>]
```

The `CARAPACE_SPECS` environment variable is a colon-separated list of `name=path` pairs that overrides directory-based discovery. By default, specs are loaded from:

- `$XDG_CONFIG_HOME/carapace/specs/` or `~/.config/carapace/specs/`
- `/etc/carapace/specs/`

## Key Patterns & Gotchas

### Zig 0.16.x APIs

This codebase uses the **new Zig 0.16 I/O API** (`std.process.Init`, `std.Io`, `init.minimal.args.vector`, `init.environ_map.get`, `init.io`, `std.Io.Dir.readFileAlloc`, `std.Io.File.stdout().writeStreamingAll`). These are **not** the Zig 0.11-0.13 allocator/fs APIs. If you see `std.io`, `std.fs.cwd()`, or `args.processAlloc` — those are the wrong version.

### Memory Management

- **Arena per completion invocation** in `main.zig` (line 62-63)
- Inside `loadSpec()`, a **second ArenaAllocator** is created (line 75) — the caller's arena is only used indirectly. This is a nested arena pattern: the inner arena is freed by `defer arena.deinit()` in `loadSpec`, but the returned `Command` struct borrows from it. The caller's arena keeps the result alive.
- `std.ArrayList(T).empty` is used instead of `std.ArrayList(T).init(allocator)` — this is `@TypeOf(.empty)` pattern where the allocator is passed separately to `append()`.

### YAML Parser Limitations

- Only handles the carapace-spec subset: maps, block lists, flow sequences (`[a, b]`), flow maps (`{k: v}`)
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

### Traversal Engine (`traverse.zig:complete()`)

- Skips first arg (command name)
- Classifies each arg: flag value → dash → flag → subcommand → positional
- `--` disables flag parsing for remaining args
- `parsing: disabled` on a subcommand also disables flag parsing
- **Persistent flags are NOT inherited from ancestors** — only searched on the current command via `cmd.findFlag()`. The `findFlag` method checks both `cmd.flags` and `cmd.persistent_flags`, but there's no walk up the tree.
- When a subcommand is entered, `positional_count` resets to 0 (line 81-82)
- Completion candidates are filtered by `std.mem.startsWith(u8, candidate, value)` — prefix matching only

### Completion Decision Tree (last arg)

| Context | Completes |
|---|---|
| `in_flag` is set | `completion.flag[flag.name]` |
| Last arg is `--flag=value` | `completion.flag[flag.name]`, filtered by prefix after `=` |
| Last arg starts with `-` | All non-hidden flags of current command (+ persistent flags) |
| Has subcommands + no positionals consumed | Subcommand names **+** `completion.positional[0]` (batch) |
| `positional_count < positional.len` | `completion.positional[positional_count]` |
| Otherwise | `completion.positionalany` |

### Action/Macro System (`action.zig`)

**Currently a stub** — `resolveMacro()` only handles static values (no `$sh(...)`, `$files(...)`, etc.). The traverse engine does NOT call `resolveMacro` at all — it only uses static completion values from the spec. Macro resolution is not wired up yet.

### Bash Snippet

- **Init script** (`_carapace`): function name `_carapace_completer`, registers all specs from `CARAPACE_SPECS` via `complete -o noquote -F _carapace_completer <name>...`
- **Single spec** (`<name> bash`): function name `_carapace_tiny_<name>_completion`, registers one command
- Both use `xargs --` to pass the command line safely
- Three-stage open-quote retry (single quotes, then double quotes, then none)
- `complete -o noquote -F` — no `-o nospace` (POC always appends space)
- Descriptions shown only when `COMP_TYPE` is `63` (successive tab)
- Uses `while read` loop (portable, works in bash 3.x)

### Testing

- All tests are inline in source files using `std.testing.*`
- Arena allocator pattern: `var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();`
- Tests call completion functions directly with parsed specs (no subprocess)
- Tests are in: `yaml.zig` (10 tests), `flag.zig` (6 tests), `spec.zig` (1 test), `traverse.zig` (4 tests), `bash.zig` (4 tests), `main.zig` (1 test — just imports)
- `zig build test` exits with code 0 on success, errors on failure

### Non-Obvious

- **`@constCast`** is used in `bash.zig:formatOutput` test (line 69) to pass a const slice to a function expecting a mutable parameter — this is a test-only pattern
- **No `std.log` or debug logging** — uses `std.debug.print` for error messages only
- **No `COMP_WORDBREAKS` handling** — unlike full carapace, there's no re-lexing of the command line
- **No nospace support** — all candidates get a trailing space from bash
- **No `mapfile`** in the bash snippet — uses portable `while read` loop instead
- **`plan.md`** is the design document — contains the full spec, architecture decisions, and stretch goals (dash readline, zsh/fish support, modifiers)
- **`example/example.yaml`** is a test spec with flags, subcommands, and completion values — use it for manual testing
- The `build.zig.zon` has `minimum_zig_version = "0.15.0"` but the code uses Zig 0.16.0 APIs — update this if adding new APIs

## Phase Status

From `plan.md`:

- **Phase 1 (Core + bash)**: ✅ Complete — YAML parser, spec decode, flag parsing, traversal, bash snippet
- **Phase 2 (Dash readline)**: ❌ Not started — `src/shell/dash.zig` doesn't exist
- **Phase 3 (Polish)**: ❌ Not started — no zsh/fish, no nospace, no modifiers, no `$spec()` macro

Notable: `action.zig` (macro resolution) is listed as Phase 1 but is a stub. The `$sh(...)`, `$bash(...)`, `$files(...)`, `$directories(...)`, `$executables(...)` macros are not implemented.