# Vigil Architecture

A **build watcher for Zig** — like Bacon for Rust. Runs `zig build`, parses output, displays errors in a TUI, auto-rebuilds on file changes.

---

## Design Philosophy

### Memory Strategy: Static First, Heap Rarely

Vigil uses **static allocation** wherever possible. This means predictable memory usage, no allocator pressure during runtime, and simpler reasoning about ownership.

**Three memory zones in Zig:**

| Zone | Lifetime | Cleanup | Vigil Usage |
|------|----------|---------|-------------|
| **Static/Global** | Program lifetime | None needed | `global_report` (~740KB in .bss) |
| **Stack** | Function scope | Automatic | `App` struct fields, temp buffers |
| **Heap** | Manual | YOU free it | Only vaxis internals + build output |

**The rule:** If you see an `Allocator` being passed, that function might heap-allocate. Think about cleanup.

### TigerStyle: Explicit Limits on Everything

Inspired by [TigerBeetle's style guide](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md). Every buffer has an explicit maximum:

```zig
pub const MAX_LINES: usize = 8192;
pub const MAX_TEXT_SIZE: usize = 512 * 1024;  // 512KB
pub const MAX_ERRORS: u8 = 255;
```

This eliminates unbounded growth, makes memory usage predictable, and catches edge cases at compile time via `comptime` assertions.

### Data-Oriented Design

Structures are designed for cache efficiency:
- **Shared text buffer**: All line text lives in one contiguous 512KB buffer; `Line` structs store offsets (reduced Report from 4.4MB to 740KB)
- **Small structs**: `Line` is ≤32 bytes (fits in cache line)
- **Separation of data and logic**: Pure functions operate on data passed in, no hidden state

### Resource Cleanup Pattern

The few heap resources follow **paired init/deinit**:

```zig
// In App.init():
app.tty = try vaxis.Tty.init(&app.tty_buf);
errdefer app.tty.deinit();

app.vx = try vaxis.Vaxis.init(alloc, .{});
errdefer app.vx.deinit(alloc, app.tty.writer());

// In App.deinit():
self.vx.deinit(self.alloc, self.tty.writer());
self.tty.deinit();
```

Temporary allocations (like build output) use `defer`:

```zig
var result = try runBuildCmd(self.alloc, args);
defer result.deinit(self.alloc);  // Always freed
```

---

## Architecture Overview

```
User runs: vigil
        │
        ▼
┌────────────────────────────────────────────────────────┐
│  main.zig                                              │
│  - Parse CLI args (test/build)                         │
│  - Create App, configure it                            │
│  - Run initial build, start event loop                 │
└────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────┐
│  app.zig - The "hub" (imperative shell)                │
│  - Owns App struct (vaxis, tty, view state, watcher)   │
│  - Main event loop (keyboard, file changes, render)    │
│  - Coordinates modules + runs zig build                │
└────────────────────────────────────────────────────────┘
        │
        ├────────────┬────────────┬────────────┬────────────┐
        ▼            ▼            ▼            ▼            ▼
┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐
│ types.zig │ │ parse.zig │ │ watch.zig │ │render.zig │ │ input.zig │
│           │ │           │ │           │ │           │ │           │
│ Data      │ │ Line      │ │ Poll file │ │ Render-   │ │ Key →     │
│ structs   │ │ classify  │ │ mtimes    │ │ Context   │ │ Action    │
│           │ │           │ │           │ │ libvaxis  │ │ (pure)    │
└───────────┘ └───────────┘ └───────────┘ └───────────┘ └───────────┘
```

---

## Pure Functions (Functional Core)

```
parse.parseLocation()      []u8 → ?Location
parse.classify()           []u8 → LineKind
input.handleNormalMode()   Key → Action
render.getLineColor()      LineKind → Color
LineKind.shownInTerse()    LineKind → bool
```

**One global**: `global_report` in `app.zig` (~740KB, lives in .bss segment). Only `app.zig` knows about it — other modules receive `*const Report` as parameter.

---

## Module Details

### `types.zig` — Core Data Structures

**Constants (TigerStyle — explicit limits on everything):**
```zig
pub const MAX_LINES: usize = 8192; // Total output lines
pub const MAX_LINE_LEN: usize = 512; // Single line truncation
pub const MAX_TEXT_SIZE: usize = 512 * 1024; // 512KB shared text buffer
pub const MAX_ERRORS: u8 = 255; // Numbered error badges
pub const MAX_TEST_FAILURES: u8 = 255; // Structured test failure tracking
pub const MAX_WATCH_PATHS: usize = 64; // Root directories to watch
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
    build_error,         // "error: ..." without location
    blank,

    // Hidden in terse mode:
    test_pass,
    test_internal_frame, // std.testing.zig frames
    build_tree,          // "└─ compile exe..."
    referenced_by,
    command_dump,
    build_summary,
    final_error,
    other,
};
```

**Other types:**
- `Line` — Parsed line with offset into shared text buffer
- `Report` — Lines + stats + shared 512KB text buffer
- `ViewState` — UI state (scroll, mode)
- `Stats` — Error/test counts

**App state (in `app.zig`):**
- `state: RunState` — FSM with states: `idle`, `building`, `quitting`
- `spawn_failed: bool` — True if build command failed to spawn (not "build had errors")

**Comptime assertions:**
```zig
comptime {
    assert(@sizeOf(Line) <= 32);           // Fits in cache line
    assert(@sizeOf(Report) < 1024 * 1024); // Under 1MB
}
```

### `parse.zig` — Output Classification

Hand-written matchers classify each line of `zig build` output.

- `classify()` — Determines LineKind using `std.mem.indexOf`, `std.mem.startsWith`
- `parseLocation()` — Extracts `path:line:col` from error messages
- `extractTestName()` — Pulls test name from failure headers
- Tracks parser state for context-sensitive classification (note/error context lines)

### `watch.zig` — File Watching

Polling-based watcher with debouncing. Uses iterative stack-based traversal (not recursion) to find newest mtime in directories up to 8 levels deep.

### `render.zig` — TUI Drawing

Uses libvaxis for terminal rendering.

- **RenderContext**: Bundles render-time state (report, view, watching status, names)
- **VisibleLineIterator**: Separates "which lines to show" from "how to draw them"
  - Terse/expanded visibility filtering
  - Consecutive blank line collapsing
  - Scroll position handling

Components: Header (badges) → Content (lines) → Footer (help hints)

### `input.zig` — Key Handling

Pure functions mapping `vaxis.Key` → `Action`. Different handlers for normal, help, and search modes.

### Search Implementation

Search uses a simple case-insensitive substring match across visible lines:

```
User types '/' → view.mode = .searching
     │
     ▼
handleSearchMode() captures keystrokes into view.search buffer
     │
     ├─→ Characters: appends to buffer, returns .none (triggers redraw)
     ├─→ Backspace: removes last char
     ├─→ Enter: returns .confirm → findNextMatch() scrolls to first match
     └─→ Escape: returns .cancel → exits search mode

After confirm, 'n'/'N' in normal mode:
     │
     ▼
findNextMatch()/findPrevMatch() in app.zig
     │
     └─→ Iterates visible lines, checks containsIgnoreCase()
```

**State**: `ViewState.search` (64-byte buffer) + `search_len` (u8)

---

## Key Patterns

### Static Arrays

```zig
lines_buf: [MAX_LINES]Line,
lines_len: u16,

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

Lines store offsets, not inline text (4.4MB → 738KB):

```zig
const Line = struct {
    text_offset: u32,  // Index into shared buffer
    text_len: u16,
    kind: LineKind,

    pub fn getText(self: *const Line, text_buf: []const u8) []const u8 {
        return text_buf[self.text_offset..][0..self.text_len];
    }
};

const Report = struct {
    text_buf: [512 * 1024]u8,  // All text here (contiguous)
    text_len: u32,
    lines_buf: [8192]Line,     // Just metadata
    lines_len: u16,
};
```

### Global Static for Large Structs

```zig
// In app.zig - goes in .bss segment, not heap
var global_report: types.Report = types.Report.init();

pub const App = struct {
    view: types.ViewState,  // Small, lives on stack

    pub fn report(_: *const App) *types.Report {
        return &global_report;
    }
};
```

### Pure Input Handling

```zig
// input.zig - pure function: Key → Action
pub fn handleNormalMode(key: vaxis.Key) Action {
    if (key.matches('q', .{})) return .quit;
    if (key.matches('j', .{})) return .scroll_down;
    if (key.matches('b', .{})) return .{ .select_job = 0 };
    return .none;
}
```

App's main loop interprets Actions and performs mutations.

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
     ├─→ state = .building
     ├─→ renderView() + flush (shows "building" badge immediately)
     │
     ├─→ runBuildCmd() spawns "zig build", blocks until complete
     │
     ├─→ state = .idle
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

## Main Event Loop

```zig
pub fn run(self: *App) !void {
    var loop: vaxis.Loop(Event) = .{ .tty = &self.tty, .vaxis = &self.vx };
    try loop.init();
    try loop.start();

    try self.vx.enterAltScreen(writer);
    try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);

    while (self.state != .quitting) {
        while (loop.tryEvent()) |event| {
            self.handleEvent(event);
        }

        if (self.watcher.checkForChanges()) {
            self.runBuild();
        }

        if (self.needs_redraw) {
            self.renderView();
            self.vx.render(writer);
        }

        std.Thread.sleep(16 * std.time.ns_per_ms);  // ~60fps
    }
}
```

---

## Color Palette

### Header Badges

| Element | Hex | Purpose |
|---------|-----|---------|
| Project | `#667788` | Neutral identity |
| Job | `#5588aa` | Active context |
| Building | `#cc9944` | In-progress (amber) |
| Error/Fail | `#dd6666` | Alert (warm red) |
| OK/Pass | `#66bb66` | Success (calm green) |
| Terse | `#555566` | De-emphasized |
| Full | `#886688` | Distinct purple |
| Watching | `#448844` | Active green |
| Paused | `#aa5555` | Warning (saturated) |

### Content

| Element | Hex |
|---------|-----|
| Error text | `#ff6666` |
| Note text | `#66ccff` |
| Expected | `#88cc88` |
| Actual | `#ff8888` |

---

## Test Failure Display

```
Zig output: "error: 'test.name' failed: expected 42, found 4"
                    ↓ parse.zig
TestFailure struct: { name, expected_offset, actual_offset, ... }
                    ↓ render.zig
Display:    [1] failed: test.name
            expected: 42
               found: 4
```

**Terse mode** hides std library frames:
- Detects `/lib/std/` in path → `test_internal_frame`
- Tracks context state so source/pointer lines after std frames are also hidden
- Strips project root from paths, removes `0x...` addresses

**Project detection**: Parsed from `build.zig.zon` (`.name = .myproject`), falls back to directory name.

---

## libvaxis Gotchas

**Critical**: Cell graphemes must point to **static/comptime strings**, not stack buffers.

libvaxis uses **deferred rendering** — it stores cell references in a screen buffer, then renders to terminal later. If grapheme pointers reference stack memory, that memory may be corrupted by subsequent code before render time.

```zig
// BAD: Corruption in ReleaseSafe
var buf: [8]u8 = undefined;
cell.grapheme = std.fmt.bufPrint(&buf, "{d}", .{n});

// GOOD: Use charToStaticGrapheme() for dynamic characters
win.writeCell(col, row, .{
    .char = .{ .grapheme = charToStaticGrapheme(byte), .width = 1 },
    .style = style,
});
```

**Safe pattern for text rendering**: Use `writeCell` character-by-character with `charToStaticGrapheme()` (maps bytes to static string literals). See `renderHeader`, `renderFooter`, and `printContentLine` in `render.zig`.

**Unsafe pattern**: `win.print()` with stack-allocated format buffers — the text pointer escapes into the cell buffer but stack is reused before render.

**Startup order**: Call `loop.start()` BEFORE `queryTerminal()`.

---

## Test Fixtures Pattern

Golden tests in `parse.zig` use fixture files from `testdata/`. Zig's `@embedFile` cannot access files outside the package boundary, so we use a **fixtures module pattern**:

```
testdata/
├── fixtures.zig          # Exports fixtures via @embedFile
├── compile_error.txt     # Sample compiler error output
├── test_failure.txt      # Sample test failure output
└── success.txt           # Empty (successful build)
```

**`testdata/fixtures.zig`:**
```zig
pub const compile_error = @embedFile("compile_error.txt");
pub const test_failure = @embedFile("test_failure.txt");
pub const success = @embedFile("success.txt");
```

**`build.zig`** imports the fixtures module for tests:
```zig
const fixtures_mod = b.createModule(.{
    .root_source_file = b.path("testdata/fixtures.zig"),
});
// Added to test module imports
```

**Usage in tests:**
```zig
test "golden fixture - compile error" {
    const fixtures = @import("fixtures");
    var report = Report.init();
    parseOutput(fixtures.compile_error, &report);
    // assertions...
}
```

**Why this works**: By placing `fixtures.zig` inside `testdata/`, the `@embedFile` paths are within that module's package boundary. The build system imports this module, giving tests access without violating Zig's security constraints.

**Benefits**: Hermetic (no CWD dependency), fast (compile-time embedding), portable.

---

## Known Limitations

1. **Polling-only watcher** — no inotify/FSEvents (simple, portable, works everywhere)
