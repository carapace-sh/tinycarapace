# tinycarapace — Plan

A minimal carapace-spec interpreter for resource-constrained environments
(docker containers, alpine, scratch images, embedded shells). It reads the same
YAML spec format as [carapace-spec](https://github.com/carapace-sh/carapace-spec)
and provides shell completion — primarily **bash**, with a stretch goal of a
**minimal custom readline menu for dash** (which lacks programmable completion).

**Implemented in [Zig](https://ziglang.org).**

## Goals

- **Small**: single static binary, no external dependencies. Zig produces
  tiny static binaries with no runtime — ideal for containers and scratch
  images. The whole point is to shed the ~30 MB transitive dependency graph
  of carapace/carapace-spec (Go + cobra + pflag + yaml.v3 + carapace).
- **Spec-compatible**: accepts the subset of the carapace-spec YAML format
  needed for static and dynamic flag/subcommand/positional completion.
- **Bash first**: generates a `complete -F` snippet just like carapace does,
  but vastly simplified (no COMP_WORDBREAKS re-lexing, no redirect patching,
  no partial-completion workaround — those are nice-to-haves for later).
- **POC scope**: static values, dynamic shell macros (`$sh(...)`, `$bash(...)`),
  flag completion, subcommand traversal, positional/positionalany completion.
  No styles, no multipart, no modifiers, no codegen, no run mode, no bridges.

## Non-Goals (for the POC)

- cobra/pflag integration — we do our own arg parsing.
- carapace-pflag fork features (non-POSIX flags, nargs, longhand shorthands).
- Styles/colors (bash doesn't support per-candidate styling anyway).
- Modifier chains (` ||| ` delimiter).
- Multipart completion, caching, UIDs, tags.
- Codegen (converting specs to source code).
- Run mode (executing the spec as a command).
- Shells other than bash for the POC (zsh/fish later).

---

## Why Zig

| Concern | Go (carapace-spec) | Zig (tinycarapace) |
|---------|--------------------|--------------------|
| Binary size (static, stripped) | ~15 MB | **<500 KB** |
| Runtime | Go runtime + GC | None (bare metal) |
| YAML parsing | `gopkg.in/yaml.v3` (pure Go, ~50k LOC transitive) | Hand-written subset parser (~300 lines) |
| Cross-compile | `GOOS=linux GOARCH=amd64` | `zig build -Dtarget=x86_64-linux-musl` |
| Static linking | Requires CGO_ENABLED=0, still pulls runtime | Default — no dynamic linking ever |
| Syscalls (for dash readline) | `syscall` package, indirect | Direct `linux.v*` stdlib wrappers |
- Zig's `comptime` and tagged unions map cleanly to the spec's optional/sum-type fields.
- Zig has no hidden allocations — the allocator is explicit, so we can use an arena for the whole completion invocation and free everything in one call. This matters for a tool invoked on every TAB press.
- Zig cross-compiles to any target from a single toolchain — no cross-compiler setup needed. `zig build -Dtarget=aarch64-linux-musl` just works.

---

## YAML Parsing

Zig stdlib has **no YAML parser**. Options:

| Approach | Pros | Cons | Decision |
|----------|------|------|----------|
| Hand-written subset parser | Zero deps, ~300 LOC, parse only what we need | We maintain it | **✅ Chosen** |
| Use a Zig YAML library (e.g. `zig-yaml`) | Full YAML support | External dep, overkill for our subset, may be unmaintained | ❌ |
| Convert spec to JSON at build time | Trivial parsing | Changes the user workflow | ❌ |

The carapace-spec YAML subset is simple: maps, lists, scalars, flow-style
sequences (`[a, b, c]`), and block-style. No anchors, no multi-document, no
complex tags. A recursive-descent parser handling indentation-based blocks
and flow collections is straightforward in Zig with a small tokenizer.

### Parser structure

```
Tokenizer → Token stream → Parser → Spec struct (arena-allocated)
```

Token types: `scalar`, `map_key`, `seq_entry`, `flow_seq_start`, `flow_seq_end`,
`flow_map_start`, `flow_map_end`, `flow_sep`, `newline`, `eof`.

The parser produces a tagged union tree (like `std.json.Value` but for our
subset), then we decode it into typed `Spec` / `Command` / `Flag` structs
with a small `decode` helper that mirrors `yaml.v3`'s `Unmarshal` for our
field set.

---

## Architecture

```
┌────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  spec.yaml     │────▶│  tinycarapace     │────▶│  completion      │
│ (carapace-spec │     │  - parse YAML     │     │  candidates      │
│  subset)       │     │  - traverse tree  │     │  (newline-       │
└────────────────┘     │  - resolve macros │     │   delimited)     │
                       │  - format output  │     └──────────────────┘
                       └──────────────────┘
```

### Source layout

```
tinycarapace/
├── plan.md                  ← this file
├── build.zig                ← build script (cross-compile targets)
├── build.zig.zon            ← dependency manifest (empty — no deps)
├── src/
│   ├── main.zig             ← CLI entry point
│   ├── spec.zig             ← Spec/Command/Flag types + decode
│   ├── yaml.zig             ← hand-written YAML subset parser
│   ├── flag.zig             ← flag string parsing (regex-equivalent)
│   ├── traverse.zig         ← argument traversal state machine
│   ├── action.zig           ← static value + macro resolution
│   └── shell/
│       ├── bash.zig         ← bash snippet + output formatting
│       └── dash.zig         ← (stretch) dash readline menu
├── example/
│   └── example.yaml         ← test spec
└── test/
    └── traverse_test.zig    ← table-driven completion tests
```

### Memory management

- One `std.heap.ArenaAllocator` per completion invocation.
- All spec parsing, traversal, and candidate generation allocates from the arena.
- Arena freed in one call after output is written.
- The binary itself uses the system allocator (or page allocator on bare targets).

---

## Spec Format Subset

We support the fields needed for the POC. Anything not listed is ignored
(not errored — forward-compatible).

### Supported top-level / command fields

| Field | Status | Notes |
|-------|--------|-------|
| `name` | ✅ | Command name (first token split on space for usage strings) |
| `description` | ✅ | Short description |
| `aliases` | ⚠️ | Parsed, used for subcommand matching but not completed |
| `commands` | ✅ | Subcommand tree |
| `flags` | ✅ | Local flags (compact string syntax) |
| `persistentflags` | ✅ | Inherited by subcommands |
| `completion.flag` | ✅ | `map[string][]string` — flag value completion |
| `completion.positional` | ✅ | `[][]string` — per-position completion |
| `completion.positionalany` | ✅ | `[]string` — fallback positional |
| `completion.dash` | ❌ | Ignored in POC |
| `completion.dashany` | ❌ | Ignored in POC |
| `exclusiveflags` | ❌ | Ignored (no validation in completion) |
| `run` | ❌ | Ignored (no run mode) |
| `parsing` | ⚠️ | Only `disabled` honored (skip flag parsing) |
| `hidden` | ✅ | Hidden subcommands/flags skipped in completion |
| `group` | ❌ | Ignored |

### Flag syntax (reuse carapace-spec's regex)

```
--longhand
-s, --longhand
--optarg?=
--repeatable*
--required!
--hidden&
```

We parse these into a simple `Flag` struct. We do **not** need pflag — we only
need to know: name, shorthand, whether it takes a value, whether it's an
optarg, whether it's hidden. We don't actually parse flag *values* from the
command line into typed storage; we just need to classify tokens during
traversal.

### Completion value format

Same as carapace-spec:
- Plain string → `ActionValues(s)`
- `value\tdescription` → value with description
- `$macroname(args)` → dynamic completion (shell macro)

### Supported macros (POC)

| Macro | Behavior |
|-------|----------|
| `$files` / `$files([.go])` | List files in current dir, optionally filtered by extension |
| `$directories` | List directories in current dir |
| `$executables` | List executables in PATH |
| `$sh(cmd)` | Run `sh -c 'cmd'` with args appended; parse newline output |
| `$bash(cmd)` | Same with bash |
| `$(cmd)` | Shorthand for `$sh(cmd)` |

Modifiers (` ||| $chdir(...)` etc.) are **not** supported in the POC.

---

## Traversal Engine

A simplified version of carapace's `traverse()`. We walk the command tree
classifying each argument:

```
state:
  currentCmd    *Command   // resolved command (descends into subcommands)
  inFlag        *Flag       // flag expecting a value (nil if none)
  positionals   int         // count of positionals consumed
  dash          bool        // "--" encountered
```

### Classification (per arg, left to right)

1. **Flag argument** — if `inFlag != null`, consume arg as flag value, clear `inFlag`.
2. **Dash** — if arg == `"--"`, set `dash = true`, skip flag parsing for rest.
3. **Flag** — if arg starts with `-` and flag parsing not disabled:
   - `--longhand` or `--longhand=value` → lookup longhand
   - `-s` or `-svalue` or `-s value` → lookup shorthand
   - If found and takes value: set `inFlag` (unless value attached via `=`)
   - If not found: treat as positional (lenient)
4. **Subcommand** — if arg matches a subcommand name (or alias) of `currentCmd`,
   recurse: `currentCmd = subcommand`, reset positionals.
5. **Positional** — increment `positionals`.

### Completion decision (after traversal, on the last partial word)

| Context | Complete |
|---------|----------|
| `inFlag` is set | `completion.flag[inFlag.name]` |
| Last arg is `--flag=` (attached) | `completion.flag[flag.name]`, filtered by prefix after `=` |
| Last arg starts with `-` | All non-hidden flags of `currentCmd` (+ persistent flags from ancestors) |
| `dash` is true | `completion.dash[positionals]` or `dashany` (not in POC) |
| `currentCmd` has subcommands and no positionals consumed | Subcommand names **+** `completion.positional[0]` (batch) |
| Otherwise | `completion.positional[positionals]` or `positionalany` |

This mirrors carapace's behavior where subcommands and the first positional
are offered together.

---

## Bash Shell Integration

### Snippet

Generated when invoked as `tinycarapace spec.yaml` (no extra args):

```bash
_tinycarapace_<name>_completion() {
  local compline="${COMP_LINE:0:${COMP_POINT}}"
  local data
  data=$(echo "${compline}''" | xargs -- tinycarapace '<specpath>' _complete bash 2>/dev/null)
  [ $? -ne 0 ] && data=$(echo "${compline}'" | xargs -- tinycarapace '<specpath>' _complete bash 2>/dev/null)
  [ $? -ne 0 ] && data=$(echo "${compline}\"" | xargs -- tinycarapace '<specpath>' _complete bash 2>/dev/null)
  COMPREPLY=()
  while IFS= read -r line; do
    [ -n "$line" ] && COMPREPLY+=("$line")
  done <<< "$data"
}
complete -o noquote -F _tinycarapace_<name>_completion <name>
```

Differences from carapace's snippet:
- No `\001`-delimited nospace flag (POC always appends space).
- No `mapfile` (use portable `while read` loop — works in bash 3.x).
- Three-stage open-quote retry (kept — it's cheap and fixes the common case).
- `xargs --` to handle the spec path safely.

### Output format

Plain newline-delimited values, one per line. Descriptions are appended
with a tab when `COMP_TYPE` indicates successive tabs (63) — same heuristic
as carapace, but without the partial-completion prefix-collapse logic.

```
--verbose
--output
file1
file2
```

For described values in successive-tab mode:
```
--verbose	Verbose output
--output	Output file
```

### Quoting

Minimal: backslash-escape spaces, quotes, and backslashes. No double-quote
mode, no tilde handling in the POC. This covers the 90% case.

---

## Dash Shell: Minimal Readline Completion Menu (Stretch Goal — Discussion)

### The problem

[dash](https://en.wikipedia.org/wiki/Almquist_shell#dash) is Debian's
`/bin/sh`. It has **no programmable completion** — no `complete` builtin,
no `COMP_LINE`, no `COMPREPLY`. It uses a bare-bones readline (actually
libedit on some systems, or a minimal built-in line editor). There is no
hook to inject custom candidates.

### Why this matters for containers

Docker containers often run dash as `/bin/sh`. If you `apt-get install` a
tool and want completion in an interactive dash session, you're stuck.
Bash isn't always available (alpine uses busybox ash, distroless images
have no shell at all). A tiny completion menu that works in dash would be
unique.

### Approaches considered

#### Option A: `set -o vi` / line editor hook — ❌ Not viable
Dash's line editor doesn't expose hooks. There's no way to intercept TAB.

#### Option B: Pre-read wrapper function — ✅ Feasible (POC-level)
Replace the command with a shell function that:
1. Reads the entire line with `read -e -p` (dash supports `read -e` for
   line editing on systems with libedit).
2. On TAB, calls `tinycarapace` with the partial line, gets candidates.
3. Displays candidates and re-prompts.

```sh
mycmd() {
  while true; do
    printf '> ' >&2
    IFS= read -r line || return $?
    # Check if last char was TAB — but read -e consumes it...
    # This is the hard part.
    break
  done
  # ... execute the command
}
```

**Problem**: `read -e` doesn't expose raw keypresses. TAB triggers
libedit's own completion (file completion by default). We can't intercept it.

#### Option C: Raw mode read loop (the "tiny readline" approach) — ✅ Most promising

Write a small interactive line reader that:
1. Puts the terminal in raw mode. In Zig this is trivial — `std.os.linux`
   provides `ioctl` with `TCGETS` / `TCSETS` directly, no external
   terminal library needed, no libc:
   ```zig
   const linux = std.os.linux;
   var termios: linux.termios = undefined;
   _ = linux.ioctl(stdin_fd, linux.T.CGETS, @intFromPtr(&termios));
   // disable ECHO, ICANON, ISIG
   termios.lflag &= ~(@as(u32, linux.ECHO | linux.ICANON | linux.ISIG));
   _ = linux.ioctl(stdin_fd, linux.T.CSETS, @intFromPtr(&termios));
   ```
2. Reads keystrokes one at a time via `std.posix.read`.
3. Maintains a line buffer + cursor position.
4. On TAB (`\t`), calls the completion engine, displays candidates in a menu
   below the prompt, and lets the user pick (arrow keys / number / type to
   filter).
5. On Enter (`\r` or `\n`), restores terminal, executes the command via
   `std.process.execv`.

This is essentially a **~150-line minimal readline** embedded in tinycarapace,
invoked as:

```sh
# In dash:
eval "$(tinycarapace spec.yaml --dash-shell)"
# This defines a function `mycmd` that calls tinycarapace's interactive reader
```

Or run as a wrapper:
```sh
alias mycmd='tinycarapace spec.yaml --dash-run mycmd'
```

Zig makes this particularly clean because:
- Direct syscalls, no libc needed (works on musl and glibc-less targets)
- `std.posix` and `std.os.linux` cover all the ioctl/termios/exec primitives
- Explicit allocators mean we can use a fixed buffer for the line — no heap
  fragmentation on every keystroke
- No signal handler runtime to fight with — we install our own SIGINT handler
  directly via `std.os.linux.sigaction`

#### Option D: FZF-style external picker — ❌ Requires fzf installed
Defeats the "small environment" purpose.

### Recommendation

**Option C is the right stretch goal**, and Zig is the ideal language for it
(direct syscalls, no runtime, tiny binary). For the POC I recommend:

1. **Phase 1**: bash completion only. Get the spec interpreter + bash
   snippet working. This proves the core value.
2. **Phase 2**: Add the dash minimal readline as a separate subcommand
   (`tinycarapace spec.yaml --dash-repl`). Start with a dead-simple
   implementation: TAB cycles through candidates inline (like bash
   `menu-complete`), no multi-column display. ~150 lines of Zig.
3. **Phase 3**: If dash readline proves useful, add a proper menu with
   arrow-key navigation and filtering.

The dash readline would be **opt-in** and **self-contained** — it doesn't
affect the bash path at all, and it adds no dependencies (raw mode via
`std.os.linux.ioctl` on Linux, no libc needed).

### Dash readline design sketch (Phase 2)

```
tinycarapace <spec> --dash-repl
  → enter raw mode (ioctl TCSETS, disable ICANON|ECHO|ISIG)
  → install SIGINT handler → restore terminal on signal
  → loop:
      read byte (std.posix.read stdin)
      if \t → invoke completion engine with current line
         → if single match: insert it
         → if multiple: print them on next line, redisplay prompt + line
      if \r or \n → break, execute line via std.process.execv
      if \x03 (Ctrl-C) → restore terminal, exit
      if \x7f (Backspace) → delete char before cursor
      if printable → insert at cursor, shift rest
  → restore terminal (ioctl TCSETS, original termios)
  → exec the command
```

No history, no multi-line editing, no vi mode. Just: type, TAB to complete,
Enter to run. This is genuinely useful in a container.

---

## Implementation Phases

### Phase 1 — Core interpreter + bash (the POC)

- [ ] `build.zig` with no dependencies, cross-compile targets
- [ ] `src/yaml.zig`: Hand-written YAML subset parser (tokenizer + recursive descent)
- [ ] `src/spec.zig`: Spec/Command/Flag types + decode from YAML value tree
- [ ] `src/flag.zig`: Flag string parser (port carapace-spec's regex logic)
- [ ] `src/traverse.zig`: Argument classification state machine
- [ ] `src/action.zig`: Static values + shell macros (`$sh`, `$bash`, `$files`, `$directories`)
- [ ] `src/shell/bash.zig`: Snippet generation + output formatting
- [ ] `src/main.zig`: CLI — `tinycarapace <spec.yaml>` → snippet, `tinycarapace <spec.yaml> _complete bash <args...>` → candidates
- [ ] `example/example.yaml`: Test spec with flags, subcommands, static + dynamic completion
- [ ] `test/traverse_test.zig`: Table-driven tests using `std.testing`

### Phase 2 — Dash minimal readline (stretch)

- [ ] `src/shell/dash.zig`: Raw-mode line reader (termios via `std.os.linux`)
- [ ] `src/main.zig`: `--dash-repl` subcommand
- [ ] Terminal restore on signal (SIGINT via `std.os.linux.sigaction`)
- [ ] TAB-completion inline (single match) + list (multiple matches)

### Phase 3 — Polish (later)

- [ ] Persistent flag inheritance verification
- [ ] `COMP_TYPE` successive-tab descriptions
- [ ] zsh snippet (`compdef` + `_describe`)
- [ ] fish snippet (`complete -c ... -a '(...)'`)
- [ ] Nospace support (per-candidate for zsh/fish, global for bash)
- [ ] Basic modifiers: `$chdir`, `$filter`, `$list`
- [ ] `$spec()` macro (load another spec as a subcommand's completion)

---

## Testing Strategy

Zig's built-in test framework. Tests call the traverse + action resolution
functions directly and compare string output.

```zig
const std = @import("std");
const expectEqualStrings = std.testing.expectEqualStrings;

const TestCase = struct {
    name: []const u8,
    spec_yaml: []const u8,
    args: []const []const u8,
    want: []const u8, // newline-delimited expected output
};

test "static flags" {
    const tc = TestCase{
        .name = "static flags",
        .spec_yaml =
            \\name: mycmd
            \\flags:
            \\  --verbose: verbose
            \\  --output=: output file
        ,
        .args = &.{"--"},
        .want = "--verbose\n--output=",
    };
    // ... parse, traverse, compare
}
```

For bash snippet integration, a single smoke test that sources the
generated snippet in a bash subprocess and verifies `COMPREPLY` is
populated. This requires bash to be installed (skip if not, using
`std.process.getChild` to check).

---

## CLI Interface

```
# Generate bash completion snippet (source this)
tinycarapace spec.yaml
# → prints bash snippet to stdout

# Internal completion callback (invoked by the snippet)
tinycarapace spec.yaml _complete bash <args...>
# → prints newline-delimited candidates

# (Phase 2) Interactive dash REPL with completion
tinycarapace spec.yaml --dash-repl
```

The `_complete` subcommand is the internal protocol — users never call it
directly. The snippet handles it.

---

## Build

```bash
# Native build
zig build

# Cross-compile (no extra toolchain needed)
zig build -Dtarget=x86_64-linux-musl
zig build -Dtarget=aarch64-linux-musl
zig build -Dtarget=x86_64-linux-gnu.2.27  # old glibc for older containers

# Release (optimized, stripped)
zig build -Doptimize=ReleaseFast -Dstrip=true

# Run tests
zig build test
```

---

## Size Comparison (Target)

| Binary | Approx size |
|--------|------------|
| carapace-bin (Go) | ~30 MB (static, with all completers) |
| carapace-spec (Go) | ~15 MB |
| **tinycarapace** (Zig, ReleaseFast, stripped) | **<500 KB** |
| tinycarapace (UPX compressed) | **<200 KB** |

Zig has no runtime, no GC, no garbage collector metadata — the binary is
just our code + the YAML parser + libc stubs (or fully static with musl).

---

## Open Questions

1. **Spec path resolution**: The bash snippet hardcodes the spec path. If
   the spec moves, the snippet breaks. Carapace-spec has the same issue.
   Acceptable for POC.

2. **Macro execution environment**: We set `C_ARG<n>`, `C_FLAG_<NAME>`,
   `C_VALUE` like carapace-spec. But since we don't use pflag, we track
   flag values ourselves during traversal (simple `std.StringHashMap`).

3. **`xargs` in the snippet**: The bash snippet uses `xargs` to split the
   command line. On some minimal systems `xargs` behaves differently
   (busybox). We may need a fallback that passes the raw `COMP_LINE` as a
   single arg. Defer to testing.

4. **Dash readline terminal compatibility**: Raw mode via ioctl is
   Linux-specific. For macOS/other BSDs we'd need the equivalent
   POSIX terminal control calls (which Zig stdlib partially provides via
   `std.posix.tcgetattr`/`tcsetattr` on non-Linux POSIX targets). Decision:
   Linux-only for Phase 2, since the target is containers.

5. **YAML parser robustness**: The hand-written parser only needs to handle
   the spec subset. But users may copy-paste specs from carapace-spec that
   use unsupported features. Decision: silently ignore unknown fields
   (forward-compatible), warn on malformed YAML (stderr, not fatal).
