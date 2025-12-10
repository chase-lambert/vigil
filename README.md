# Vigil

A clean, fast build watcher for Zig, inspired by [Bacon](https://github.com/Canop/bacon) for Rust.

Shows you the errors that matter, hides the noise.

## Features

- **Terse Mode**: Filters build noise, shows only errors, warnings, and context
- **Full Mode**: Toggle to see complete output when needed
- **File Watching**: Auto-rebuild on source changes
- **Multiple Jobs**: Switch between build (`b`), test (`t`), run (`x`)
- **Navigation**: Jump between errors, open in `$EDITOR`

## Installation

```bash
git clone https://github.com/yourname/vigil
cd vigil
zig build -Doptimize=ReleaseFast
cp zig-out/bin/vigil ~/.local/bin/
```

## Usage

```bash
vigil           # Default: zig build
vigil test      # Run tests
vigil run       # Run the project
vigil -- -Doptimize=ReleaseFast  # Pass args to zig
```

## Keybindings

| Key | Action |
|-----|--------|
| `j`/`k` | Scroll down/up |
| `g`/`G` | Top/bottom |
| `n`/`N` | Next/prev error |
| `Enter` | Open in `$EDITOR` |
| `Space` | Toggle terse/full |
| `b`/`t`/`x` | Build/test/run |
| `r` | Rebuild |
| `w` | Toggle watching |
| `?` | Help |
| `q` | Quit |

## What Gets Filtered

**Shown in terse mode**: Errors, warnings, notes, source snippets, pointer lines

**Hidden**: Build tree (`└─ compile...`), `referenced by:` traces, command dumps, build summaries

## Project Status

### Implemented
- [x] Basic TUI with libvaxis
- [x] Run zig build, capture output
- [x] Line classification (error/warning/note/noise)
- [x] Terse/full view toggle
- [x] Scrolling and error navigation (`n`/`N`)
- [x] Manual rebuild (`r`)
- [x] File watching (polling-based)
- [x] Open in editor (`Enter`)
- [x] Help overlay (`?`)
- [x] Job switching (`b`/`t`/`x` for build/test/run)
- [x] Test output parsing (Zig 0.15 format)
- [x] Bacon-style test failure display (`expected:`/`found:` values)
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
├── app.zig       # Application state, main loop
├── types.zig     # Core data structures
├── parse.zig     # Output classification
├── process.zig   # Command execution
├── watch.zig     # File system watching
├── render.zig    # TUI rendering
└── input.zig     # Keyboard handling
```

## License

MIT
