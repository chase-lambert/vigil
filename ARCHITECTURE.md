# Vigil Architecture

## What is Vigil?

A **build watcher for Zig** — like Bacon for Rust. It runs `zig build`, parses output, displays errors in a clean TUI, and auto-rebuilds on file changes.

## Design Philosophy

**Simplicity, Elegance, Craftsmanship**

- **Simple**: Boring solutions beat clever ones. Future-you will thank present-you.
- **Delete ruthlessly**: Dead code, "maybe someday" features—they all go.
- **Explicit**: No hidden allocations, no magic. Zig's philosophy, embodied.

## Three Pillars

### 1. TigerStyle (adapted)

From [TigerBeetle's style guide](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md):

- **Fixed limits**: `MAX_LINES = 8192`, `MAX_TEXT_SIZE = 512KB`, etc.
- **Static arrays**: `_buf`/`_len` pattern instead of dynamic containers
- **Explicit types**: Use `u16`, `u32` etc. instead of `usize` for determinism
- **No regex**: Hand-written matchers for speed and clarity
- **Assertions**: Pre/post conditions, defensive programming
- **Static allocation**: Large structs in `.bss` segment, not heap

### 2. Data-Oriented Design

Structure data for how it's accessed:

- **Shared text buffer**: All line text in one contiguous 512KB buffer
- **Lines store offsets**: `(text_offset, text_len)` not inline `[512]u8`
- **Result**: Report shrunk from 4.4MB → 738KB, better cache locality

### 3. Functional Core, Imperative Shell

Most functions are **pure** (deterministic, no side effects):

```
Pure Functions (data in → data out)
─────────────────────────────────────
parse.parseLocation()      []u8 → ?Location
parse.classify()           []u8 → LineKind
input.handleNormalMode()   Key → Action
render.getLineColor()      LineKind → Color
LineKind.shownInTerse()    LineKind → bool
```

**One piece of global mutable state**: `global_report` in `app.zig`

Why: Report is ~740KB (too large for stack). Lives in `.bss` segment (compile-time static), not heap. We isolate it:
- Only `app.zig` knows about the global
- Other modules receive `*const Report` as a parameter
- Pure functions don't reach for global state

---

## Architecture Overview

```
User runs: vigil
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  main.zig                                                   │
│  - Parse CLI args (test/build)                              │
│  - Create App, configure it                                 │
│  - Run initial build, start event loop                      │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  app.zig - The "hub" (imperative shell)                     │
│  - Owns App struct (vaxis, tty, view state, watcher)        │
│  - Main event loop (keyboard, file changes, render)         │
│  - Coordinates modules + runs zig build                     │
└─────────────────────────────────────────────────────────────┘
           │
    ┌──────┼──────┬────────────┬────────────┐
    ▼      ▼      ▼            ▼            ▼
┌───────┐┌───────┐┌──────────┐┌────────────────┐┌─────────┐
│types  ││parse  ││watch     ││render          ││input    │
│.zig   ││.zig   ││.zig      ││.zig            ││.zig     │
│       ││       ││          ││                ││         │
│Data   ││Line   ││Poll file ││RenderContext   ││Key→     │
│structs││class- ││mtimes,   ││VisibleLineIter││Action   │
│       ││ifier  ││detect    ││TUI w/ libvaxis ││(pure)   │
│       ││       ││changes   ││                ││         │
└───────┘└───────┘└──────────┘└────────────────┘└─────────┘
```

---

## Module Details

### `types.zig` — Core Data Structures

The foundation. Defines all limits, enums, and structs.

**Constants (TigerStyle: "put a limit on everything"):**
```zig
pub const MAX_LINES: usize = 8192;           // Max lines in a report
pub const MAX_LINE_LEN: usize = 512;         // Max chars per line
pub const MAX_TEXT_SIZE: usize = 512 * 1024; // 512KB shared text buffer
pub const MAX_ITEMS: usize = 1024;           // Max navigable errors
pub const MAX_TEST_FAILURES: usize = 64;     // Max test failures tracked
```

**`LineKind` — Classification enum:**
```zig
pub const LineKind = enum(u8) {
    // Shown in terse mode:
    error_location,      // "src/main.zig:42:13: error: ..."
    note_location,
    source_line,         // "    const x = 5;"
    pointer_line,        // "    ~~~^~~~"
    test_fail,
    test_fail_header,    // "error: 'test_name' failed:"
    test_expected_value, // "expected X, found Y"
    test_summary,
    build_error,         // "error: ..." without location (e.g., cache failures)
    blank,

    // Hidden in terse mode:
    test_pass,           // Clean Bacon-style display
    test_internal_frame, // std.testing.zig frames
    build_tree,          // "└─ compile exe..."
    referenced_by,       // "referenced by: ..."
    command_dump,        // The massive zig command
    build_summary,       // "Build Summary: ..."
    final_error,
    other,
};
```

**Other key types:**
- `Line` — Parsed line with offset into shared text buffer
- `Report` — Collection of lines + stats + shared 512KB text buffer
- `ViewState` — UI state (scroll, mode, selected item)
- `WatchConfig` — Paths to watch, debounce settings
- `Stats` — Error/test counts

**Comptime assertions validate invariants:**
```zig
comptime {
    assert(@sizeOf(Line) <= 32);           // Fits in cache line
    assert(@sizeOf(Report) < 1024 * 1024); // Under 1MB
}
```

### `parse.zig` — Output Classification

Hand-written matchers classify each line of `zig build` output. No regex.

- `classify()` — Determines LineKind using `std.mem.indexOf`, `std.mem.startsWith`
- `parseLocation()` — Extracts `path:line:col` from error messages
- `extractTestName()` — Pulls test name from failure headers
- Tracks parser state for context-sensitive classification (e.g., note context lines)

### `watch.zig` — File Watching

Polling-based watcher with debouncing. Uses **iterative stack-based traversal** (not recursion) to find newest mtime in directories up to 8 levels deep.

### `render.zig` — TUI Drawing

Uses libvaxis for terminal rendering. Key abstractions:

- **RenderContext**: Bundles all render-time state (report, view, watching status, names) to avoid long parameter lists
- **VisibleLineIterator**: Separates "which lines to show" from "how to draw them". Handles:
  - Terse/expanded visibility filtering
  - Consecutive blank line collapsing
  - Scroll position handling

Components:
- Header: project name, job, status badge, mode indicator, watch status
- Content: uses VisibleLineIterator for clean iteration over lines
- Footer: help hints, line counts

### `input.zig` — Key Handling

Pure functions that map `vaxis.Key` → `Action`. Different handlers for normal, help, and search modes.

---

## Main Event Loop

```zig
pub fn run(self: *App) !void {
    // 1. Initialize libvaxis loop (handles terminal resize signals)
    var loop: vaxis.Loop(Event) = .{ .tty = &self.tty, .vaxis = &self.vx };
    try loop.init();
    try loop.start();

    // 2. Enter alternate screen (like vim does)
    try self.vx.enterAltScreen(writer);

    // 3. Query terminal capabilities
    try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);

    // 4. Main loop
    while (self.running) {
        // Process keyboard events
        while (loop.tryEvent()) |event| {
            self.handleEvent(event);
        }

        // Check for file changes
        if (self.watcher.checkForChanges()) {
            self.runBuild();
        }

        // Render if needed
        if (self.needs_redraw) {
            self.renderView();
            self.vx.render(writer);
        }

        // Sleep ~16ms (60fps)
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
}
```

---

## Key Patterns

### Static Arrays

```zig
// Instead of ArrayList or BoundedArray:
lines_buf: [MAX_LINES]Line,
lines_len: u16,  // Explicit type, not usize

pub fn lines(self: *const Report) []const Line {
    return self.lines_buf[0..self.lines_len];
}

pub fn appendLine(self: *Report, line: Line) !void {
    if (self.lines_len >= MAX_LINES) return error.ReportFull;
    self.lines_buf[self.lines_len] = line;
    self.lines_len += 1;
}
```

### Shared Text Buffer

The core memory optimization. Instead of inline text storage:

```zig
// OLD: 536 bytes per Line, 4.4MB total for 8192 lines
const Line = struct {
    content: [512]u8,  // Text stored inline
    len: u16,
    kind: LineKind,
    // ...
};

// NEW: 28 bytes per Line, 738KB total
const Line = struct {
    text_offset: u32,  // Index into shared buffer
    text_len: u16,
    kind: LineKind,
    // ...

    pub fn getText(self: *const Line, text_buf: []const u8) []const u8 {
        return text_buf[self.text_offset..][0..self.text_len];
    }
};

// Report owns the shared buffer
const Report = struct {
    text_buf: [512 * 1024]u8,  // All text here (contiguous)
    text_len: u32,
    lines_buf: [8192]Line,     // Just metadata
    lines_len: u16,
};
```

**Benefits:**
- 6x memory reduction (4.4MB → 738KB)
- Better cache locality (text is contiguous)
- No heap allocation for text storage

### Global Static for Large Structs

```zig
// In app.zig - goes in .bss segment, not heap
var global_report: types.Report = types.Report.init();

pub const App = struct {
    view: types.ViewState,  // Small, lives on stack

    pub fn report(_: *const App) *types.Report {
        return &global_report;  // Accessor isolates the global
    }
};
```

### Pure Input Handling

```zig
// input.zig - pure function: Key → Action
pub fn handleNormalMode(key: vaxis.Key) Action {
    if (key.matches('q', .{})) return .quit;
    if (key.matches('j', .{})) return .scroll_down;
    if (key.matches('b', .{})) return .{ .select_job = 0 };  // build
    // ...
    return .none;
}
```

The App's main loop interprets Actions and performs actual mutations.

---

## Data Flow

```
User types 'b' (switch to build job)
     │
     ▼
input.handleKey() → Action.select_job(0)
     │
     ▼
app.handleKey() matches .select_job
     │
     ▼
app.switchJob() → app.runBuild()
     │
     ├─→ runBuildCmd() spawns "zig build", waits, returns output
     │
     ▼
parse.parseOutput(output, &global_report)
     │
     ├─→ For each line: classify, store text, update stats
     │
     ▼
app.needs_redraw = true
     │
     ▼
Next loop iteration: render.render() draws new state
```

---

## Design Decisions

### Why polling for file watching?

Simple, works everywhere. Traverses nested directories (up to 8 levels). Native watchers (inotify/kqueue) can be added later.

### Why no regex?

- Zero dependencies
- Faster (no regex engine overhead)
- More explicit (patterns are visible in code)
- TigerStyle principle

### Why fixed-size arrays?

- No heap allocation after init
- Predictable memory usage
- Bounds checked at compile time
- "Put a limit on everything"

### Why one global?

Trade-off between TigerStyle (no heap) and pure functional (no globals). We chose:
- Static allocation for the large Report struct
- Isolate access through a method
- Keep everything else pure

This is "functional core, imperative shell"—decision-making is pure, mutation is centralized.

### Why separate LineKind classification from visual rendering?

The parser classifies each line into a specific `LineKind` (error_location, note_location, source_line, etc.) based purely on content. The renderer then applies visual rules (badges, spacing, colors) based on those kinds.

This separation allows:
- Adding visual treatments (blank lines, badges) without touching the parser
- Different visual modes (terse/full) by filtering on `LineKind.shownInTerse()`
- Easy incremental improvements to display

**Example**: Adding a blank line before `note_location` lines was a 3-line change in render.zig. The parser already knew what notes were—we just needed to tell the renderer how to space them.

---

## Test Failure Display

Test failures use structured parsing to extract useful information:

### Data Flow
```
Zig output: "error: 'test.name' failed: expected 42, found 4"
                    ↓ parse.zig
TestFailure struct: { name, expected_offset, actual_offset, ... }
                    ↓ render.zig
Display:    [1] failed: test.name
            expected: 42
               found: 4
```

### Stack Trace Filtering

Zig test failures produce verbose stack traces with internal std.testing frames:

```
/home/user/.zvm/0.15.2/lib/std/testing.zig:110:17: 0x... in expectEqualInner
                return error.TestExpectedEqual;
                ^
/home/user/project/src/main.zig:26:5: 0x... in test.simple test
    try std.testing.expectEqual(@as(i32, 42), list.pop());
    ^
```

**Terse mode** shows only user code, hiding std library frames:
- Detects `/lib/std/` in path → classifies as `test_internal_frame`
- Tracks `in_std_frame_context` state so context lines (source + pointer) are also hidden
- Strips project root from paths, removes memory addresses (`0x...`)

**Full mode** shows everything (full paths, all frames).

### Project Detection

Project name comes from `build.zig.zon`:
```zig
.name = .myproject,  // Zig 0.15 enum literal format
```

Parsed at startup in `app.detectProject()`. Falls back to directory name if no build.zig.zon.

---

## Known Limitations

1. **Search mode incomplete** — `/` enters search mode but filtering not yet implemented
2. **File watcher is polling-only** — Could add inotify/FSEvents for efficiency
3. **Tests only in types.zig and parse.zig** — Other modules lack unit tests

---

## Summary

Vigil is a ~2500 line Zig project following TigerStyle principles:
- Fixed limits on everything
- Static allocation where possible
- No regex (hand-written parsers)
- Single external dependency (libvaxis)

The core innovation is the **shared text buffer** pattern that reduced memory from 4.4MB to 738KB by storing line text contiguously and having `Line` structs store offsets instead of inline arrays.
