# Vigil

A clean, fast build watcher for Zig, inspired by [Bacon](https://github.com/Canop/bacon) for Rust.

Example in Terse Mode:

<img width="700" alt="Vigil in Terse Mode" src="https://github.com/user-attachments/assets/41b3b4b9-17c9-48af-9dd5-8999d12a5679" />


Example in Full Mode:

<img width="700" alt="Vigil in Full Mode" src="https://github.com/user-attachments/assets/30f6a821-d7af-4e59-8234-c811543de487" />



## Why not just use `zig build --watch`?

Good question. Zig's built-in watch mode is solid and you should try it. Vigil offers a few extras if you want them:

- **Terse Mode**: Shows errors with source context, collapses verbose diagnostics
- **Full Mode**: Toggle to see complete compiler output when needed
- **File Watching**: Auto-rebuild on source changes (pause with `p`)
- **Build & Test**: Switch between build (`b`) and test (`t`) with a keypress
- **Search**: Find text in output with `/`, navigate with `n`/`N`

If you just want "rebuild on save," `zig build --watch` has you covered. Vigil is for when you want a bit more control over the output.

A fun little side aspect is that I've found `vigil` works very well while going through [ziglings](https://codeberg.org/ziglings/exercises), especially when in `full` mode, but `zig build --watch` does not work correctly. Just don't try to switch to test (`t`) mode or things get funky.


This project is also a learning exercise in [Data-Oriented Design](https://www.dataorienteddesign.com/dodbook/), [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md), and Zig patterns. I have learned a ton and had a lot of fun doing it. See [ARCHITECTURE.md](ARCHITECTURE.md) for some of the details.

## Installation

```bash
git clone https://github.com/chase-lambert/vigil
cd vigil
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/vigil /usr/local/bin/  # or wherever you keep programs on your PATH
```

**Why ReleaseSafe?** Part of my goal with this project was to practice TigerStyle, so I use a lot of assertions throughout the codebase. These remain active in `ReleaseSafe`. You'd lose them with `ReleaseFast`, but the codebase should be considered safe without them too.

**Platform support:** I develop on Linux, and a friend confirmed it works on his Mac. Curious if it works out of the box on Windows, let me know!

**Colors not showing?** Vigil uses 256-color mode. If you see plain text instead of colored badges, try `export TERM=xterm-256color` before running. iTerm2 works great; macOS Terminal.app may need this setting.

## Usage

```bash
vigil                           # Start in build mode first
vigil test                      # Start in test mode first
vigil -Doptimize=ReleaseFast    # Pass options to zig build
vigil test -Dtest-filter=foo    # Filter tests (if your build.zig supports it)
```

All options are passed through to `zig build`. Use `-h` for help.

> **Note**: `-D` options are project-specific. Options like `-Dtest-filter` only work if your `build.zig` exposes them via `b.option()`.

## Keybindings

| Key | Action |
|-----|--------|
| `h`/`?` | Help |
| `b`/`t` | Switch to build/test job |
| `p` | Pause/resume watching |
| `Space` | Toggle terse/full view |
| `w` | Toggle line wrap |
| `j`/`k` | Scroll down/up |
| `g`/`G` | Jump to top/bottom |
| `/` | Search |
| `n`/`N` | Next/previous match |
| `q` | Quit |

## What Gets Filtered

**Shown in terse mode**: Errors, notes, source snippets, pointer lines

**Hidden**: Build tree (`└─ compile...`), `referenced by:` traces, command dumps, build summaries

## Limits & Behavior

Vigil uses fixed-size buffers (~740KB for parsed output). Total memory usage is typically 2-5MB depending on terminal size (libvaxis scales with screen dimensions). I'm genuinely curious about if these limits hold up to real world usage from others.

| Limit | Value | What happens when exceeded |
|-------|-------|---------------------------|
| Output lines | 8,192 | Additional lines dropped |
| Text buffer | 512 KB | Parsing stops |
| Line length | 512 chars | Truncated |
| Numbered errors | 255 | Capped at `[255]` badges |
| Test failures | 255 | Structured display stops |
| Watch depth | 16 levels | Deeper directories not watched |

**File watching:** Vigil watches the entire project directory. Hidden dirs, `zig-out`, `zig-cache`, `node_modules`, `vendor`, and `third_party` are ignored.

**Debounce:** File changes within 100ms are batched into a single rebuild.

**Large output:** If your build produces more than 8K lines, the output may be truncated. Try running `zig build 2>&1 | wc -l` to check, then address the root cause of excessive output.

## Architecture

One dependency: [libvaxis](https://github.com/rockorager/libvaxis), a great Zig TUI library.

See [ARCHITECTURE.md](ARCHITECTURE.md) for module details, patterns, and lessons learned.

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
