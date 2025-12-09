# Vigil Development Notes

## Core Philosophy

**Simplicity, Elegance, and Craftsmanship**

Every line of code should be simple, elegant, and intentional. We follow Zig's philosophy of explicit, predictable, transparent behavior. When in doubt, choose the boring solution.

**Three Pillars:**
1. **Simplicity & Elegance** - Delete ruthlessly. The best code is code that doesn't exist.
2. **Data-Oriented Design** - Structure data for how it's accessed. Cache locality matters.
3. **TigerStyle** - Fixed limits, static allocation, no regex, explicit bounds.

## Architecture Overview

```
main.zig          Entry point, CLI args
    │
    ▼
app.zig           Coordination hub
    │
    ├──► types.zig      Data structures (Report, Line, Stats, etc.)
    ├──► parse.zig      Output classification (no regex)
    ├──► process.zig    Command execution
    ├──► watch.zig      File system watching
    ├──► render.zig     TUI drawing (libvaxis)
    └──► input.zig      Keyboard handling
```

## Module Responsibilities

| Module | Purpose | Status |
|--------|---------|--------|
| `types.zig` | Core data structures with fixed limits | ✅ Done |
| `parse.zig` | Line classification, location parsing | ✅ Done |
| `process.zig` | Run zig build, capture output | ✅ Done |
| `watch.zig` | File watching (polling, nested dirs) | ✅ Done |
| `render.zig` | TUI rendering | ✅ Basic |
| `input.zig` | Key handling | ✅ Done |
| `app.zig` | Main loop, state coordination | ✅ Basic |
| `main.zig` | Entry point, arg parsing | ✅ Done |

## TigerStyle Compliance

### ✅ Applied

- **Fixed limits on everything**: `MAX_LINES`, `MAX_ITEMS`, `MAX_TEXT_SIZE`, etc.
- **Static arrays** with explicit `_buf`/`_len` patterns (no BoundedArray)
- **No regex**: Hand-written pattern matching
- **Comptime assertions**: Size checks in types.zig
- **Small functions**: Most under 40 lines
- **Global static allocation**: Report lives in `.bss` segment, no heap for core data
- **Data-oriented design**: Shared text buffer for cache locality

### 🔄 TODO

- [ ] Assertion density (2+ per function)
- [ ] Paired assertions for all boundaries

## Implementation Status

### MVP (Current)

- [x] Run `zig build` and capture output
- [x] Parse and classify lines
- [x] Display in TUI with libvaxis
- [x] Terse/full view toggle
- [x] Scrolling
- [x] Manual rebuild with `r`
- [x] Quit with `q`

### Phase 2 (In Progress)

- [x] File watching (polling-based)
- [ ] Error navigation (n/N) - structure exists, needs scroll-to
- [ ] Open in editor - basic implementation exists

### Phase 3 (Planned)

- [ ] Multiple jobs (check, test, run)
- [ ] Job switching
- [ ] Search within output
- [ ] Configuration file (vigil.zon)

### Phase 4 (Future)

- [ ] inotify/kqueue native watching
- [ ] Debounced rebuilds
- [ ] Test result parsing
- [ ] Streaming output (show as it runs)

## Known Issues

1. **libvaxis API**: The code was written against expected API patterns.
   You'll likely need to adjust based on actual libvaxis version.
   Check: https://github.com/rockorager/libvaxis/tree/main/examples

2. **Open in editor**: Current implementation is simplified. Should
   exit alt screen, run editor, then re-enter.

3. **Build args**: Currently rebuilds allocate output each time.
   Could be optimized with ring buffer.

## Testing

```bash
# Run unit tests
zig build test

# Test manually
cd /some/zig/project/with/errors
/path/to/vigil
```

## Useful Commands During Development

```bash
# Rebuild and run
zig build run

# Build with optimizations
zig build -Doptimize=ReleaseFast

# Check a specific module
zig build-exe src/types.zig --watch

# See what libvaxis exports
zig build-lib $(HOME)/.cache/zig/p/vaxis-*/src/main.zig --verbose-llvm-ir
```

## Design Decisions

### Why polling for file watching?

Simple, works everywhere, adequate for this use case. The watcher now
traverses nested subdirectories using an iterative stack-based approach
(up to 8 levels deep). Native watchers (inotify, FSEvents) can be added
later as an optimization.

### Why no regex?

- Zero dependencies
- Faster (no regex engine)
- More explicit (see exactly what patterns match)
- TigerStyle principle: minimize abstractions

### Why fixed-size arrays?

- No heap allocation after init
- Predictable memory usage
- Bounds are asserted at compile time
- TigerStyle: "put a limit on everything"

### Why a shared text buffer?

The original design stored text inline in each `Line` struct (512 bytes per line).
With 8192 lines, this made the `Report` struct ~4.4MB - too large for the stack.

The solution uses data-oriented design:
- One shared `text_buf: [512KB]u8` holds all line text contiguously
- Each `Line` stores just `(text_offset: u32, text_len: u16)` - a reference into the buffer
- Line shrinks from ~536 bytes to 28 bytes
- Report shrinks from ~4.4MB to ~738KB
- Better cache locality since text is contiguous

```zig
// Before: 536 bytes per Line, 4.4MB total
const Line = struct {
    content: [512]u8,  // Inline text
    len: u16,
    // ... other fields
};

// After: 28 bytes per Line, 738KB total
const Line = struct {
    text_offset: u32,  // Offset into shared buffer
    text_len: u16,
    // ... other fields
};

const Report = struct {
    text_buf: [512 * 1024]u8,  // Shared text storage
    text_len: u32,
    lines_buf: [8192]Line,     // Just metadata
    // ...
};
```

### Why global static for Report?

Even at 738KB, the Report is too large for typical stack frames. Options:
1. **Heap allocation** - Runtime `malloc`, not TigerStyle
2. **Global static** - Goes in `.bss` segment, determined at compile time

We use option 2 (like TigerBeetle does). The `global_report` variable in `app.zig`
is allocated in the `.bss` segment - it's static memory, not heap. The App struct
itself is small and lives on the stack.

## Resources

- [libvaxis](https://github.com/rockorager/libvaxis)
- [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [Bacon (Rust reference)](https://github.com/Canop/bacon)
