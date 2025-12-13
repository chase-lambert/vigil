# Vigil

A clean, fast build watcher for Zig, inspired by [Bacon](https://github.com/Canop/bacon) for Rust.

Shows you the errors that matter, hides the noise.

## Features

- **Terse Mode**: Filters build noise, shows only errors and context
- **Full Mode**: Toggle to see complete output when needed
- **File Watching**: Auto-rebuild on source changes (pause with `p`)
- **Build & Test**: Switch between build (`b`) and test (`t`) with a keypress

## Installation

```bash
git clone https://github.com/yourname/vigil
cd vigil
zig build -Doptimize=ReleaseFast
cp zig-out/bin/vigil ~/.local/bin/
```

## Usage

```bash
vigil                           # Default: zig build
vigil test                      # Run tests
vigil -w exercises              # Watch custom directory (e.g., Ziglings)
vigil -w src -w lib             # Watch multiple directories
vigil -Doptimize=ReleaseFast    # Pass options to zig build
vigil test -Dtest-filter=foo    # Filter tests (if your build.zig supports it)
```

### Options

| Option | Description |
|--------|-------------|
| `-w`, `--watch <path>` | Directory to watch (repeatable; default: `src`, `build.zig`) |
| `-h`, `--help` | Show help |
| `-v`, `--version` | Show version |

All other options are passed through to `zig build`.

> **Note**: `-D` options are project-specific. Options like `-Dtest-filter` only work if your `build.zig` exposes them via `b.option()`.

## Keybindings

| Key | Action |
|-----|--------|
| `j`/`k` | Scroll down/up |
| `g`/`G` | Jump to top/bottom |
| `Space` | Toggle terse/full view |
| `w` | Toggle line wrap |
| `b`/`t` | Switch to build/test job |
| `p` | Pause/resume watching |
| `?` | Help |
| `q` | Quit |

## What Gets Filtered

**Shown in terse mode**: Errors, notes, source snippets, pointer lines

**Hidden**: Build tree (`└─ compile...`), `referenced by:` traces, command dumps, build summaries

## Limits

Vigil uses fixed-size buffers (no heap allocation after startup):

| Limit | Value | Overflow behavior |
|-------|-------|-------------------|
| Output lines | 8,192 | Stops parsing |
| Numbered errors | 255 | Capped at `[255]` |
| Test failures | 255 | Structured display stops |
| Line length | 512 chars | Truncated |

**Watch paths**: 64 root directories (e.g., `src`, `build.zig`). Subdirectories are traversed automatically to depth 8.

## Project Status

### Implemented
- [x] Basic TUI with libvaxis
- [x] Run zig build, capture output
- [x] Line classification (error/note/noise)
- [x] Terse/full view toggle
- [x] Scrolling (`j`/`k`, `g`/`G`)
- [x] Line wrap toggle (`w`)
- [x] File watching with pause/resume (`p`)
- [x] Help overlay (`?`)
- [x] Job switching (`b`/`t` for build/test)
- [x] Test output parsing (Zig 0.15 format)
- [x] Bacon-style test failure display (`expected:`/`found:` values)
- [x] Numbered error badges with visual grouping
- [x] Project name detection from `build.zig.zon`
- [x] Clean stack traces (strips std library frames in terse mode)

### Planned
- [ ] Search within output (`/`)
- [ ] Configuration file (vigil.zon)

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for design philosophy (TigerStyle, data-oriented design, functional core).

```
src/
├── main.zig      # Entry point, arg parsing
├── app.zig       # Application state, main loop, command execution
├── types.zig     # Core data structures
├── parse.zig     # Output classification
├── watch.zig     # File system watching
├── render.zig    # TUI rendering
└── input.zig     # Keyboard handling
```

## License

MIT
