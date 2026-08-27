# carapace-tiny

A minimal [carapace-spec](https://github.com/carapace-sh/carapace-spec) interpreter in Zig. Reads standard YAML spec files and generates bash completion — no dependencies, tiny static binary, instant startup.

Designed for resource-constrained environments (containers, alpine, scratch images) where the full carapace-bin (~30 MB Go binary) is too heavy.

## Quick start

```bash
# Drop a spec file into the user directory
mkdir -p ~/.config/carapace/specs
cp myapp.yaml ~/.config/carapace/specs/

# Source the init script to register all completers
source <(carapace-tiny _carapace bash)

# Or source a single completer
source <(carapace-tiny myapp bash)
```

## Build

Requires [Zig 0.15+](https://ziglang.org/download/).

```bash
zig build                        # Debug build → zig-out/bin/carapace-tiny
zig build -Doptimize=ReleaseFast # Release build (~1 MB stripped)
zig build -Dtarget=x86_64-linux-musl  # Cross-compile (no extra toolchain)
```

## Usage

```
carapace-tiny _carapace [bash]                   # Init script for all specs
carapace-tiny <name> bash                        # Snippet for one command
carapace-tiny <name> bash <name> <args...>       # Completion callback (internal)
```

Specs are discovered from these directories (in order of precedence):

1. `$CARAPACE_SPECS` — colon-separated `name=path` pairs (override)
2. `$XDG_CONFIG_HOME/carapace/specs/` or `~/.config/carapace/specs/` — user specs
3. `/etc/carapace/specs/` — system-wide specs

So you can just drop `.yaml` files into one of the directories and they'll be picked up automatically.

## How it works

1. Specs are YAML files following the [carapace-spec](https://github.com/carapace-sh/carapace-spec) format
2. `carapace-tiny _carapace bash` generates a bash `complete -F` function that registers all your commands
3. On TAB press, the function calls `carapace-tiny <name> bash <name> <args...>` which traverses the parsed spec tree and returns matching candidates

## Status

- **Core**: YAML parsing, spec decoding, flag parsing, argument traversal, bash snippet generation — complete
- **Macros**: `$sh(...)`, `$files(...)`, `$directories(...)`, `$executables(...)` — not yet implemented
- **Shells**: bash only (no zsh/fish yet)
- **Size**: ~1 MB release binary (vs ~30 MB for carapace-bin)

## Spec format

See [carapace-spec](https://github.com/carapace-sh/carapace-spec) for the full format. Example:

```yaml
name: myapp
description: my application
flags:
  --verbose: verbose output
  --output=: output file
commands:
  - name: build
    description: build the project
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