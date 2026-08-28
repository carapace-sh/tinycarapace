# tinycarapace

A minimal [carapace-spec](https://github.com/carapace-sh/carapace-spec) interpreter
in Zig. Reads standard YAML spec files and generates shell completion for bash,
zsh, fish, and powershell — no dependencies, tiny static binary, instant startup.

Designed for resource-constrained environments (containers, alpine, scratch images)
where the full carapace-bin (~30 MB Go binary) is too heavy.

## Quick start

```bash
# Drop a spec file into the user directory
mkdir -p ~/.config/carapace/specs
cp myapp.yaml ~/.config/carapace/specs/

# Source the init script to register all completers
source <(tinycarapace _carapace bash)

# Or source a single completer
source <(tinycarapace myapp bash)
```

For commands without a spec file, set `CARAPACE_BRIDGES` to fall back to
shell-native completions (bash, fish, zsh, inshellisense):

```bash
export CARAPACE_BRIDGES=bash
tinycarapace git export ""               # uses bash's git completion
```

## Build

Requires [Zig 0.15+](https://ziglang.org/download/).

```bash
zig build                                     # Debug build
zig build -Doptimize=ReleaseFast && strip zig-out/bin/tinycarapace  # 779 KB
zig build -Doptimize=ReleaseSmall && strip zig-out/bin/tinycarapace  # 270 KB
zig build -Dtarget=x86_64-linux-musl          # Cross-compile (no extra toolchain)
zig build -Dtarget=aarch64-linux-musl         # Cross-compile for ARM64
```

## Usage

```
tinycarapace _carapace [bash|zsh|fish|powershell]     # Init script for all specs
tinycarapace <name> [bash|zsh|fish|powershell]          # Snippet for one command
tinycarapace <name> [bash|zsh|fish|powershell] <name> <args...>  # Completion callback
tinycarapace <name> export [<args...>]                  # JSON export (carapace format)
tinycarapace <name> run [<args...>]                     # Execute spec's run field
tinycarapace <name> --dash-repl                         # Interactive REPL with completion
```

Specs are discovered from these directories (in order of precedence):

1. `$CARAPACE_SPECS` — colon-separated `name=path` pairs (override)
2. `$XDG_CONFIG_HOME/carapace/specs/` or `~/.config/carapace/specs/` — user specs
3. `/etc/carapace/specs/` — system-wide specs

Just drop `.yaml` files into one of the directories and they'll be picked up
automatically.

## How it works

1. Specs are YAML files following the
   [carapace-spec](https://github.com/carapace-sh/carapace-spec) format
2. `tinycarapace _carapace bash` generates a `complete -F` function that
   registers all your commands
3. On TAB press, the function calls `tinycarapace <name> bash <name> <args...>`
   which traverses the parsed spec tree and returns matching candidates
4. If no spec is found, `CARAPACE_BRIDGES` provides shell-native fallback

## Status

Everything is implemented. See [plan.md](plan.md) and [AGENTS.md](AGENTS.md) for
full details.

| Feature | Status |
|---------|--------|
| YAML parsing, spec decoding, flag parsing | ✅ |
| Argument traversal (subcommands, flags, positionals, dash) | ✅ |
| All shell snippets (bash, zsh, fish, powershell) | ✅ |
| Macro system (`$sh`, `$files`, `$directories`, `$executables`, `$message`, `$chdir`, `$list`, `$multiparts`, `$split`, `$bridge.*`) | ✅ |
| Modifier chains (`$prefix`, `$suffix`, `$nospace`, `$style`, `$tag`, `$filter`, `$retain`, `$shift`, `$split`, `$usage`, `$uid`, `$suppress`) | ✅ |
| Variable expansion (`${C_ARG0}`, `${C_FLAG_NAME}`, `${C_VALUE}`, `${VAR:-default}`) | ✅ |
| Run mode (alias, macro, script) | ✅ |
| Dash readline REPL | ✅ |
| Bridge fallback (`CARAPACE_BRIDGES`) | ✅ |
| Persistent flags, exclusive flags, group, nargs | ✅ |
| Binary size (ReleaseSmall, stripped) | **270 KB** |

## Spec format

See [carapace-spec](https://github.com/carapace-sh/carapace-spec) for the full format.
Example:

```yaml
name: myapp
description: my application
flags:
  --verbose: verbose output
  --output=: output file
  --color=: {description: color output, nargs: 1}
persistentflags:
  --config=: config file
exclusiveflags:
  - [verbose, format]
commands:
  - name: build
    description: build the project
    group: actions
    flags:
      --target=: target triple
    completion:
      flag:
        target: [x86_64-linux, aarch64-linux]
  - name: run
    description: run the project
    completion:
      positional:
        - [start, stop, restart]
```