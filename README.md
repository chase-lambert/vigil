# Vigil

A clean, fast build watcher for Zig. Shows you the errors that matter, hides the noise.

## Features

- **Terse Mode**: Filters out build system noise, shows only errors, warnings, and relevant context
- **Full Mode**: Toggle to see complete unfiltered output when you need it
- **File Watching**: Automatically rebuilds when source files change
- **Multiple Jobs**: Switch between build, test, run, and custom commands
- **Navigation**: Jump between errors, go to source locations
- **Search**: Find text in build output
- **Zero Config**: Works out of the box, optional config for customization

## Installation

```bash
git clone https://github.com/yourname/vigil
cd vigil
zig build -Doptimize=ReleaseFast
cp zig-out/bin/vigil ~/.local/bin/
```

## Quick Start

```bash
# In any Zig project directory
vigil

# Run a specific job
vigil test
vigil run

# Pass arguments to zig build
vigil -- -Doptimize=ReleaseFast
```

## Keybindings

| Key | Action |
|-----|--------|
| `j` / `↓` | Scroll down |
| `k` / `↑` | Scroll up |
| `g` / `G` | Go to top / bottom |
| `n` / `N` | Next / previous error |
| `Enter` | Open error location in `$EDITOR` |
| `Space` | Toggle terse / full view |
| `Tab` | Cycle through jobs |
| `/` | Search |
| `r` | Manual rebuild |
| `w` | Toggle file watching |
| `?` | Help |
| `q` | Quit |

## What Gets Filtered

**Terse mode shows:**
- Error messages with file:line:col locations
- Warning messages with locations  
- Notes attached to errors/warnings
- Source code snippets
- Pointer lines (`~~~^~~~`)

**Terse mode hides:**
- Build tree output (`└─ compile exe...`)
- `referenced by:` trace sections
- The massive `zig build-exe` command dumps
- Build summary trees
- Redundant "the following command failed" messages

## Configuration (Optional)

Create `vigil.zon` in your project root:

```zig
.{
    .default_job = "check",
    .jobs = .{
        .check = .{ .command = .{ "zig", "build" } },
        .@"test" = .{ .command = .{ "zig", "build", "test" } },
        .run = .{ .command = .{ "zig", "build", "run" } },
    },
    .watch = .{
        .paths = .{ "src", "build.zig" },
        .ignore = .{ ".zig-cache", "zig-out" },
        .debounce_ms = 100,
    },
    .keys = .{
        .{ .key = "c", .job = "check" },
        .{ .key = "t", .job = "test" },
        .{ .key = "x", .job = "run" },
    },
}
```

## Design Philosophy

Vigil follows [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) principles:

- **Single dependency**: Only libvaxis for TUI
- **Static allocation**: Fixed limits, no runtime heap growth after init
- **No regex**: Hand-written parsers for speed and clarity
- **Explicit limits**: Bounded arrays, known maximums
- **Assertions**: Pre/post conditions, defensive programming

## Project Status

### Implemented
- [x] Basic TUI with libvaxis
- [x] Run zig build, capture output
- [x] Line classification (error/warning/note/noise)
- [x] Terse/full view toggle
- [x] Scrolling
- [x] Manual rebuild (`r`)
- [x] File watching (polling-based)
- [x] Error navigation (`n`/`N`)
- [x] Open in editor (`Enter`)
- [x] Help overlay (`?`)

### Planned
- [ ] Multiple jobs (test, run, custom)
- [ ] Job switching
- [ ] Search within output
- [ ] Configuration file (vigil.zon)
- [ ] Debounced rebuilds
- [ ] Test output parsing

## Architecture

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
