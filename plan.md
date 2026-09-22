# tinycarapace — Plan

A minimal [carapace-spec](https://github.com/carapace-sh/carapace-spec) interpreter
for resource-constrained environments (docker containers, alpine, scratch images).
It reads the same YAML spec format and provides shell completion.

**Language**: Zig 0.16.0+. **Status**: Phase 1 complete (core + bash + modifiers).

## Why Zig

| Concern | Go (carapace-spec) | Zig (tinycarapace) |
|---------|--------------------|--------------------|
| Binary size (static, stripped) | ~15 MB | **~830 KB** |
| Runtime | Go runtime + GC | None (bare metal) |
| YAML parsing | `gopkg.in/yaml.v3` (~50k LOC transitive) | Hand-written subset parser (~700 LOC) |
| Cross-compile | `GOOS=linux GOARCH=amd64` | `zig build -Dtarget=x86_64-linux-musl` |
| Static linking | Requires CGO_ENABLED=0, still pulls runtime | Default — no dynamic linking ever |
| Allocator | GC | Explicit arena — free on every TAB press |

Cross-compile to any target from a single toolchain — no cross-compiler setup needed.

## Architecture

```
spec.yaml → yaml.zig (parse) → spec.zig (decode) → traverse.zig (complete) → shell/*.zig (format)
```

### Source layout

```
src/
├── main.zig       # CLI entry: snippet, candidates, export
├── spec.zig       # Command/Flag/Completion types + YAML → struct decode
├── yaml.zig       # Hand-written YAML subset parser (recursive descent, no deps)
├── flag.zig       # Flag string parser (compact syntax: --optarg?=, --repeatable*, --hidden&)
├── traverse.zig   # Argument traversal state machine (the core completion engine)
├── action.zig     # Static value + macro resolution (shell exec, modifier chains)
└── shell/
    ├── bash.zig   # Snippet generation + output formatting
    ├── zsh.zig    # (not yet) zsh compdef snippet
    └── fish.zig   # (not yet) fish complete snippet
```

### Memory management

- One `std.heap.ArenaAllocator` per completion invocation.
- All spec parsing, traversal, and candidate generation allocates from the arena.
- Arena freed in one call after output is written.

---

## Current State (Phase 1 — ✅ Complete)

### Spec decoding
| Field | Status |
|-------|--------|
| `name`, `description`, `aliases` | ✅ |
| `commands` (subcommand tree) | ✅ |
| `flags` / `persistentflags` | ✅ |
| `completion.flag` | ✅ |
| `completion.positional` / `positionalany` | ✅ |
| `completion.dash` / `dashany` | ✅ |
| `exclusiveflags` | ✅ |
| `group` | ✅ |
| `run` | ✅ (alias, macro, script modes) |
| `parsing` | ✅ `disabled`, `non-interspersed`, `interspersed` |
| `hidden` | ✅ |

### Flag parsing
| Feature | Status |
|---------|--------|
| `--longhand` / `-s` / `-s, --longhand` | ✅ |
| `=` (takes value) / `?` (optarg) | ✅ |
| `*` (repeatable) / `!` (required) / `&` (hidden) | ✅ |
| Non-POSIX mode (`NameAsShorthand`) | ✅ |
| `nargs` / `default` extended fields | ✅ |

### Traversal engine
| Feature | Status |
|---------|--------|
| Subcommand traversal (with alias matching) | ✅ |
| `--flag=value` splitting | ✅ |
| `--` dash disables flag parsing | ✅ |
| POSIX shorthand chaining (`-abc`) | ✅ |
| Subcommand + positional[0] batch completion | ✅ |
| Persistent flag inheritance from ancestors | ✅ |
| Flag value population (`flag_values` HashMap) | ✅ |
| Non-interspersed parsing | ✅ |
| Exclusive flags | ✅ |
| `COMP_WORDBREAKS` re-lexing | ❌ |

### Macros & actions
| Feature | Status |
|---------|--------|
| Static values (`value`, `value\tdescription`, `value\tdescription\tstyle`) | ✅ |
| `$sh(cmd)`, `$bash(cmd)`, `$pwsh(cmd)` | ✅ |
| `$zsh(cmd)`, `$fish(cmd)`, `$elvish(cmd)`, `$nu(cmd)`, `$osh(cmd)`, `$xonsh(cmd)`, `$cmd(cmd)` | ✅ |
| `$files`, `$directories`, `$executables` | ✅ |
| `$(cmd)` shorthand for `$sh(cmd)` | ✅ |
| `$spec(path)` — delegate to another spec | ❌ (circular dep) |
| `$message(msg)` | ✅ |
| `$chdir(dir)` | ✅ (with special dir macros) |
| `$list(delim)` / `$uniquelist(delim)` | ✅ |
| `$multiparts([delim])` | ✅ |
| `$split` / `$splitp` | ✅ (as modifiers) |
| Variable expansion (`${C_ARG0}`, `${C_FLAG_NAME}`, `${C_VALUE}`, `${VAR:-default}`) | ✅ |
| Bridge macros (`$bridge.name(cmd, args...)`) | ✅ (cobra, bash, zsh, fish, carapace, carapace-bin, argcomplete, click, yargs, powershell) |

### Modifier chains (` ||| ` delimiter)
| Modifier | Status |
|----------|--------|
| `$prefix(text)` | ✅ |
| `$suffix(text)` | ✅ |
| `$nospace(chars)` | ✅ |
| `$noprefix(chars)` | ✅ (segment-based, no regex) |
| `$style(name)` | ✅ |
| `$tag(name)` | ✅ |
| `$filter([vals])` | ✅ |
| `$filterargs` | ✅ (removes candidates matching a consumed positional arg) |
| `$retain([vals])` | ✅ |
| `$shift(n)` | ✅ (shifts positional-arg context before base expansion) |
| `$split` / `$splitp` | ✅ |
| `$suppress(expr)` | ✅ (substring match on message candidates, not regex) |
| `$uid([scheme, host, opts...])` | ✅ |
| `$uniquelist(delim)` | ✅ (suppresses segments already used in the prefix) |
| `$usage(usage)` | ✅ |

### Shell support
| Shell | Init script | Snippet | Candidate output |
|-------|-------------|---------|------------------|
| bash | ✅ | ✅ | ✅ |
| zsh | ✅ | ✅ | ✅ (multi-block format) |
| fish | ✅ | ✅ | ✅ |
| powershell | ✅ | ✅ | ✅ (JSON via ConvertFrom-Json) |

### CLI
| Mode | Status |
|------|--------|
| `tinycarapace _carapace bash` (init script) | ✅ |
| `tinycarapace spec.yaml <shell>` (snippet) | ✅ |
| `tinycarapace spec.yaml <shell> <name> <args...>` (candidates) | ✅ |
| `tinycarapace spec.yaml export` (shell-agnostic export) | ✅ |
| `tinycarapace spec.yaml run` (run mode) | ✅ |

### Bash snippet features
| Feature | Status |
|---------|--------|
| `complete -o noquote -F` | ✅ |
| Three-stage open-quote retry (empty, single, double) | ✅ |
| Nospace flag (`\x01` delimiter) | ✅ |
| Descriptions on `COMP_TYPE == 63` | ✅ |
| `mapfile` + `unset COMPREPLY[-1]` | ✅ |
| `COMP_WORDBREAKS` export | ✅ |

---

## Phase 2 — Core improvements

Small, focused additions to round out the core engine.

### 2a — `completion.dash` / `completion.dashany`

- Add `dash: [][]string` and `dashany: []string` fields to `Completion` struct in `spec.zig`
- Update `decodeCompletion` to parse them
- In `traverse.zig:complete()`, when `dash` flag is set, complete from `completion.dash[positional_count]` or `completion.dashany`
- Tests: add dash completion cases to `traverse.zig` tests

### 2b — Persistent flag inheritance

- In `traverse.zig`, when looking up a flag, walk up the parent chain
- Add a `parent` field to `Command` (set during spec decoding)
- `cmd.findFlag(name)` tries `cmd.flags`, then `cmd.persistent_flags`, then recurses to `cmd.parent`
- Tests: verify persistent flags from parent commands are completed

### 2c — Flag value population

- In `traverse.zig`, when a flag value is consumed (attached via `=` or as next arg), write to `Context.flag_values`
- This enables future variable expansion (`${C_FLAG_NAME}`)
- Tests: verify flag_values HashMap contains expected entries after traversal

### 2d — `$files`, `$directories`, `$executables` macros

- In `action.zig`, add `resolveFiles(dir)`, `resolveDirectories(dir)`, `resolveExecutables()` functions
- Use `std.fs.cwd().openDir`, `std.fs.Dir.iterate` to list directory contents
- `$files([".go", ".md"])` filters by extension; `$files()` lists all files
- `$directories` lists directories only
- `$executables` scans PATH directories and lists executable files
- Wire into `resolveMacro` dispatch
- Tests: create temp dirs with known contents, verify correct candidates

### 2e — `$(cmd)` shorthand

- In `resolveMacro`, detect empty macro name `$`: treat `$(cmd)` as `$sh(cmd)`
- Simple: if macro name is empty string, delegate to `$sh` handler
- Test: verify `$(echo one)` produces same result as `$sh(echo one)`

---

## Phase 3 — Extended macros

### 3a — `$message(msg)`

- Returns a single candidate with the message as a description (empty value)
- Used for error/info display in the completion menu
- In `resolveMacro`, detect `$message(msg)` and return a single candidate with empty value and the message as description

### 3b — `$list(delim)` and `$uniquelist(delim)`

- `$list(delim)` splits the current value by delimiter and completes the last segment
- `$uniquelist(delim)` same but deduplicates existing segments
- In `resolveMacro`, needs access to the current partial value (`C_VALUE`)
- Implementation: split `context.value` by delimiter, filter candidates by last segment
- For uniquelist: filter out already-used segments from candidates

### 3c — `$chdir(dir)`

- Changes directory before completing the next macro/value
- Accepts special directory macros: `$gitdir`, `$gitworktree`, `$parent([file, dir])`, `$tempdir`, `$userhomedir`, `$usercachedir`, `$userconfigdir`, `$xdgcachehome`, `$xdgconfighome`, `$nixprofile`
- Implementation: save current dir, change to target dir, resolve next macro, restore dir
- POC level: just `$chdir($userhomedir)` and `$chdir($tempdir)` — the common cases

### 3d — `$multiparts([delim])`

- Splits the current value by the delimiter and completes the last segment
- Like `$list` but uses `$nospace` semantics (no space after completion)
- Implementation: similar to `$list`, but sets `nospace=true` on candidates
- Delimiter typically `/` for path-style multipart

### 3e — `$shift(n)`

- Shifts positional arguments left by n positions
- Used when a flag consumes multiple positional args (paired with `nargs`)
- Implementation: decrements `positional_count` by n in the context
- POC: only handle `$shift(1)` for single-arg consumption

### 3f — `$noprefix(chars)`, `$suppress(regex)`, `$usage(usage)`, `$uid(...)`

- `$noprefix(chars)`: don't add common prefix for values containing given chars
- `$suppress(regex)`: filter out error messages matching regex
- `$usage(usage)`: set a usage message for the current completion
- `$uid(...)`: set UID for deduplication (no-op without dedup cache)
- All straightforward: modify candidate fields or filter results

### 3g — `$filterargs`

- Filter completion candidates by already-completed positional args
- Implementation: exclude candidates whose values match any consumed positional arg
- Simple string comparison against `context.flag_values` or positional tracking

### 3h — `$split` / `$splitp`

- `$split`: split current value lexicographically, complete each segment independently
- `$splitp`: same with pipeline support (`|` separator)
- Advanced: requires multi-word completion semantics
- POC: skip unless needed

---

## Phase 4 — Shell support (bash+, zsh, fish, powershell)

### 4a — Bash improvements

- `COMP_WORDBREAKS` re-lexing: handle `=` and `:` as word separators in the command line
- Current: `xargs` splits on spaces only — `--flag=value` is one token, but bash splits it
- Implementation: re-lex `COMP_LINE` using `COMP_WORDBREAKS` characters as delimiters (like carapace does)
- This is the main source of bugs in the current bash snippet

### 4b — zsh completion

- `src/shell/zsh.zig`: generate `compdef` + `_describe` snippet
- Output format: `_describe 'command' '(...)'` for static values, `_call_program` for macros
- Candidate output format: same newline-delimited as bash, but zsh-specific quoting
- Init script: `compdef _tinycarapace_<name> <name>`

### 4c — fish completion

- `src/shell/fish.zig`: generate `complete -c <name> -k -f -a '(...)'` snippet
- Candidate output: `value\tdescription` format, fish handles nospace via `--force-files`
- Descriptions: fish supports them natively, no `COMP_TYPE` equivalent needed
- Init script: source the generated snippet in `conf.d/`

### 4d — powershell completion

- `src/shell/powershell.zig`: generate `Register-ArgumentCompleter` script
- Uses `[CompletionResult]::new(...)` for each candidate
- Candidate output format: `value\tdescription\tcompletionText\tToolTip` (tab-separated)

---

## Phase 5 — Variable expansion & run mode

### 5a — Variable expansion

- Implement `${C_ARG0}`, `${C_ARG1}`, etc. from positional args
- Implement `${C_FLAG_NAME}` from `Context.flag_values`
- Implement `${C_VALUE}` for the current partial word
- Implement `${C_PART0}`, `${C_PART1}`, etc. for multipart segments
- Use `std.mem.replace` or a simple template engine
- Apply to completion values (for macros that use variables) and `run` commands
- Support `${VAR:-default}` and `${VAR//pattern/replacement}` via `drone/envsubst`-style parsing (or a minimal subset)

### 5b — `run` mode

- Execute the spec's `run` field when no completion args are provided
- `run` can be a string (alias: `"[tail, --lines, '${NUM:-1}']"`), a macro (`"$(tail -n${C_FLAG_LINES:-1} ${C_ARG0})"`), or a script (`"#!/usr/bin/env bash\n..."`)
- Alias mode: `std.process.execv` with the parsed args
- Macro mode: execute the shell command, stream output
- Script mode: write to temp file, make executable, exec
- Variable expansion applies to all modes

### 5c — `parsing: non-interspersed`

- When flags appear before the first positional arg, everything after the first positional is treated as positional (no more flag parsing)
- Implementation: after first positional is consumed, set `dash`-like flag to stop flag parsing
- Test: `cmd file --flag` should complete `file` as positional, not `--flag` as flag

### 5d — `exclusiveflags`

- Validate that mutually exclusive flags aren't both set
- In completion: exclude flags from the completion list if their exclusive group already has a member set
- Implementation: during traversal, track which flags from each group have been seen; during flag name completion, exclude already-seen groups

### 5e — `group` subcommand grouping

- Display subcommand groups in the completion menu (for shells that support it)
- Implementation: set tag on subcommand candidates based on their group field
- Bash doesn't support tags natively, but zsh and fish do

### 5f — `nargs` / `default` extended flag fields

- `nargs: 2` means the flag consumes 2 positional args
- `nargs: -1` means the flag consumes all remaining args
- `default: "value"` sets a default value if the flag isn't provided
- Implementation: in `traverse.zig`, when a flag with `nargs > 0` is encountered, consume that many positional args as flag values
- For `default`: store in `Context.flag_values` if not already set

---

---

## Implementation Order (Recommended)

| Step | Phase | What | Est. LOC |
|------|-------|------|----------|
| 1 | 2a | `completion.dash` / `dashany` | ~30 |
| 2 | 2b | Persistent flag inheritance | ~20 |
| 3 | 2c | Flag value population | ~15 |
| 4 | 2d | `$files`, `$directories`, `$executables` | ~80 |
| 5 | 2e | `$(cmd)` shorthand | ~5 |
| 6 | 3a | `$message(msg)` | ~10 |
| 7 | 3b | `$list`, `$uniquelist` | ~40 |
| 8 | 3c | `$chdir` | ~50 |
| 9 | 3d | `$multiparts` | ~30 |
| 10 | 3e-f | `$shift`, `$noprefix`, `$suppress`, `$usage`, `$uid` | ~60 |
| 11 | 3g | `$filterargs` | ~20 |
| 12 | 4a | Bash `COMP_WORDBREAKS` re-lexing | ~60 |
| 13 | 4b-d | zsh, fish, powershell shells | ~200 each |
| 14 | 5a | Variable expansion | ~80 |
| 15 | 5b | `run` mode | ~100 |
| 16 | 5c | `parsing: non-interspersed` | ~15 |
| 17 | 5d | `exclusiveflags` | ~30 |
| 18 | 5e | `group` subcommand grouping | ~15 |
| 19 | 5f | `nargs` / `default` | ~40 |

---

## Testing Strategy

Zig's built-in test framework. Tests call the traverse + action resolution
functions directly and compare string output.

```zig
const TestCase = struct {
    name: []const u8,
    spec_yaml: []const u8,
    args: []const []const u8,
    want: []const u8, // newline-delimited expected output
};
```

For bash snippet integration, a single smoke test that sources the
generated snippet in a bash subprocess and verifies `COMPREPLY` is
populated. Skip if bash not installed.

---

## CLI Interface

```
# Generate bash completion snippet (source this)
tinycarapace spec.yaml

# Internal completion callback (invoked by the snippet)
tinycarapace spec.yaml _complete bash <name> <args...>

# Generate init script for all discovered specs
tinycarapace _carapace bash

# Export completions in shell-agnostic format
tinycarapace spec.yaml export [<args...>]

# (Phase 5b) Run the spec as a command
tinycarapace spec.yaml run [<args...>]
```

---

## Build & Size

```bash
zig build                                # Build
zig build test                           # Run tests
zig build -Doptimize=ReleaseFast -Dstrip=true  # Release build
zig build -Dtarget=x86_64-linux-musl     # Cross-compile
zig build -Dtarget=aarch64-linux-musl    # Cross-compile
```

| Binary | Approx size |
|--------|------------|
| carapace-spec (Go) | ~15 MB |
| **tinycarapace** (Zig, ReleaseFast, stripped) | **~830 KB** |
| tinycarapace (UPX compressed) | **<200 KB** |