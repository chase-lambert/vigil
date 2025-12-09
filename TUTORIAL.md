# Vigil Codebase Tutorial

A comprehensive guide to understanding the Vigil codebase.

## What is Vigil?

Vigil is a **build watcher for Zig** - similar to Bacon for Rust. It:
1. Runs `zig build`
2. Captures and parses the output
3. Displays errors/warnings in a TUI (terminal UI)
4. Filters out noisy build system output
5. Watches files and auto-rebuilds on changes

## Architecture Overview

```
User runs: vigil
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  main.zig                                                   │
│  - Parse CLI args (test/run/build)                          │
│  - Create App, configure it                                 │
│  - Run initial build, start event loop                      │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│  app.zig - The "hub"                                        │
│  - Owns App struct (vaxis, tty, view state, watcher)        │
│  - Main event loop (keyboard, file changes, render)         │
│  - Coordinates all other modules                            │
└─────────────────────────────────────────────────────────────┘
           │
    ┌──────┼──────┬──────────┬────────────┐
    ▼      ▼      ▼          ▼            ▼
┌───────┐┌───────┐┌────────┐┌──────────┐┌────────┐
│types  ││parse  ││process ││watch     ││render  │
│.zig   ││.zig   ││.zig    ││.zig      ││.zig    │
│       ││       ││        ││          ││        │
│Data   ││Line   ││Run zig ││Poll file ││Draw    │
│structs││class- ││build,  ││mtimes,   ││TUI w/  │
│       ││ifier  ││capture ││detect    ││libvaxis│
│       ││       ││output  ││changes   ││        │
└───────┘└───────┘└────────┘└──────────┘└────────┘
                                         │
                                   ┌─────┴─────┐
                                   │ input.zig │
                                   │           │
                                   │ Key→Action│
                                   │ mapping   │
                                   └───────────┘
```

---

## File-by-File Breakdown

### 1. `build.zig.zon` - Package Manifest

```zig
.{
    .name = .vigil,              // Enum literal (Zig 0.15+ syntax)
    .version = "0.1.0",
    .fingerprint = 0x4b3d7ac3b82dd494,  // Auto-generated hash
    .dependencies = .{
        .vaxis = .{...},         // Only dependency: libvaxis for TUI
    },
}
```

**Key point**: Only ONE external dependency. TigerStyle principle.

---

### 2. `build.zig` - Build Configuration

Sets up:
- Main executable from `src/main.zig`
- Imports libvaxis as "vaxis" module
- Test step that runs tests from `types.zig` and `parse.zig`

---

### 3. `types.zig` - Core Data Structures (~485 lines)

This is the **foundation** of the codebase. Everything else depends on these types.

#### Constants (TigerStyle: "put a limit on everything")

```zig
pub const MAX_LINES: usize = 8192;      // Max lines in a build report
pub const MAX_LINE_LEN: usize = 512;    // Max chars per line
pub const MAX_TEXT_SIZE: usize = 512 * 1024;  // 512KB shared text buffer
pub const MAX_ITEMS: usize = 1024;      // Max navigable errors/warnings
```

#### `LineKind` - Classification enum

Every line of build output is classified:
```zig
pub const LineKind = enum(u8) {
    // Shown in terse mode:
    error_location,    // "src/main.zig:42:13: error: ..."
    warning_location,
    note_location,
    source_line,       // "    const x = 5;"
    pointer_line,      // "    ~~~^~~~"
    test_pass,
    test_fail,
    blank,

    // Hidden in terse mode:
    build_tree,        // "└─ compile exe..."
    referenced_by,     // "referenced by: ..."
    command_dump,      // The massive zig command
    build_summary,     // "Build Summary: ..."
    final_error,
    other,
};
```

The `shownInTerse()` method determines what appears in terse vs full mode.

#### `Line` - A single parsed line

**This is the key data-oriented design decision:**

```zig
pub const Line = struct {
    text_offset: u32,    // Where in shared buffer
    text_len: u16,       // How long
    kind: LineKind,      // Classification
    stream: Stream,      // stdout or stderr
    item_index: u16,     // Which error group
    location: ?Location, // Parsed file:line:col
};
```

Text is NOT stored inline. Instead, all text lives in a shared buffer in `Report`, and `Line` just stores an offset. This reduces `Line` from ~536 bytes to 28 bytes.

To get text: `line.getText(report.textBuf())`

#### `Report` - Collection of parsed build output

```zig
pub const Report = struct {
    text_buf: [512KB]u8,        // Shared text storage
    text_len: u32,
    lines_buf: [8192]Line,      // Line metadata
    lines_len: usize,
    item_starts_buf: [1024]u16, // Indices of error headers (for n/N nav)
    item_starts_len: usize,
    stats: Stats,               // Error/warning counts
    exit_code: ?u8,
    was_killed: bool,
    cached_terse_count: usize,  // Cached for O(1) getVisibleCount()
};
```

**Memory**: ~738KB total (was 4.4MB before optimization)

#### Other types

- `ViewState` - UI state (scroll position, selected item, mode)
- `WatchConfig` - Paths to watch, debounce settings
- `Job` - Configured build job (not fully used yet)
- `Stats` - Error/warning/test counts

#### Comptime assertions

```zig
comptime {
    std.debug.assert(@sizeOf(Line) <= 32);
    std.debug.assert(@sizeOf(Report) < 1024 * 1024);
}
```

---

### 4. `main.zig` - Entry Point (~113 lines)

Simple flow:
1. Set up allocator (GeneralPurposeAllocator)
2. Parse CLI args into a static array (TigerStyle: no heap for arg building)
3. Build command array: `["zig", "build"]` or `["zig", "build", "test"]` etc.
4. Create App, configure, run initial build, start event loop

---

### 5. `app.zig` - Application Hub (~389 lines)

The central coordinator.

#### Global Static Report

```zig
var global_report: types.Report = types.Report.init();
```

This goes in the `.bss` segment (static memory), not heap. TigerStyle approach for large static data.

#### App struct

```zig
pub const App = struct {
    alloc: std.mem.Allocator,     // For vaxis internals
    view: types.ViewState,        // UI state
    watcher: watch_mod.Watcher,   // File watcher
    build_args_buf: [...],        // Command to run
    vx: vaxis.Vaxis,              // TUI library
    tty: vaxis.Tty,               // Terminal handle
    needs_redraw: bool,
    running: bool,
};
```

#### Main event loop (`run()`)

```zig
pub fn run(self: *App) !void {
    // 1. Initialize libvaxis loop (handles terminal resize signals)
    var loop: vaxis.Loop(Event) = .{...};
    try loop.init();
    try loop.start();

    // 2. Enter alternate screen (like vim does)
    try self.vx.enterAltScreen(writer);

    // 3. Query terminal capabilities
    try self.vx.queryTerminal(writer, 1_000_000_000);  // 1 sec timeout

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
        std.Thread.sleep(16_000_000);
    }
}
```

---

### 6. `parse.zig` - Output Classification (~376 lines)

This is where the **magic** happens. It takes raw `zig build` output and classifies each line.

#### Parser state machine

```zig
pub const Parser = struct {
    current_item: u16,          // Which error group we're in
    state: State,               // Context for classification
    in_reference_block: bool,   // Inside "referenced by:" section
};
```

#### `parseLine()` - Core function

```zig
pub fn parseLine(self: *Parser, raw: []const u8, stream: Stream, report: *Report) !void {
    // 1. Store text in shared buffer
    const text_info = try report.appendText(raw);

    // 2. Classify the line
    line.kind = self.classify(raw);

    // 3. Parse location for errors/warnings
    if (line.kind == .error_location) {
        line.location = parseLocation(raw);
    }

    // 4. Update stats and item tracking
    // 5. Append to report
}
```

#### Classification logic (`classify()`)

Hand-written pattern matching (no regex):

```zig
fn classify(self: *Parser, line: []const u8) LineKind {
    if (line.len == 0) return .blank;

    // Check for ": error:", ": warning:", ": note:"
    if (std.mem.indexOf(u8, line, ": error:")) |_| return .error_location;
    if (std.mem.indexOf(u8, line, ": warning:")) |_| return .warning_location;

    // Check for build tree (unicode box drawing)
    if (std.mem.startsWith(u8, trimmed, "└─")) return .build_tree;

    // Check for command dump
    if (std.mem.indexOf(u8, line, "zig build-exe")) return .command_dump;

    // ... etc

    return .other;
}
```

#### `parseLocation()` - Extract file:line:col

Parses `"src/main.zig:42:13: error: message"` backwards to find the two rightmost colons before the error marker.

---

### 7. `process.zig` - Command Execution (~107 lines)

Simple wrapper around `std.process.Child.run`:

```zig
pub fn runBuild(alloc: Allocator, args: []const []const u8) !BuildResult {
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = args,
        .max_output_bytes = 512KB,
    });

    // Prefer stderr (where errors go)
    return BuildResult{
        .output = result.stderr.len > 0 ? result.stderr : result.stdout,
        .exit_code = ...,
    };
}
```

---

### 8. `watch.zig` - File Watching (~170 lines)

Polling-based watcher with nested directory support:

```zig
pub fn checkForChanges(self: *Watcher) bool {
    // Debounce check
    if (now - self.last_check < debounce_ns) return false;

    // Check each watched path's mtime
    for (paths) |path| {
        if (getPathMtime(path) > self.mtimes[i]) {
            changed = true;
        }
    }
    return changed;
}
```

`getPathMtime()` handles both files and directories. For directories, it uses an **iterative stack-based traversal** to find the newest mtime up to `MAX_WATCH_DEPTH` (8) levels deep. We use an explicit stack instead of function recursion because TigerStyle prohibits recursion (unbounded execution).

---

### 9. `render.zig` - TUI Drawing (~307 lines)

Uses libvaxis to render:
- Header: mode badge, watch indicator, job name, error/warning counts
- Content: the actual build output lines
- Footer: keybinding hints, line count

```zig
pub fn render(vx: *vaxis.Vaxis, report: *const Report, view: *const ViewState, ...) void {
    // Split window into header (1 line), content (rest-2), footer (1 line)
    const header_win = win.child(.{ .height = 1 });
    const content_win = win.child(.{ .y_off = 1, .height = height - 2 });
    const footer_win = win.child(.{ .y_off = height - 1, .height = 1 });

    renderHeader(header_win, ...);
    renderContent(content_win, ...);
    renderFooter(footer_win, ...);
}
```

`renderContent()` implements:
- Terse mode filtering (`line.kind.shownInTerse()`)
- Consecutive blank line collapsing
- Scroll handling
- Color coding by line type

---

### 10. `input.zig` - Key Handling (~179 lines)

Maps keyboard input to actions:

```zig
pub const Action = union(enum) {
    none,
    quit,
    rebuild,
    toggle_expanded,
    scroll_up,
    scroll_down,
    next_error,
    prev_error,
    // ...
};

pub fn handleNormalMode(key: vaxis.Key) Action {
    if (key.matches('q', .{})) return .quit;
    if (key.matches('j', .{})) return .scroll_down;
    if (key.matches('n', .{})) return .next_error;
    // ...
}
```

Different modes (normal, help, searching) have different keybindings.

---

## Data Flow

```
User types 'r' (rebuild)
     │
     ▼
input.handleKey() → Action.rebuild
     │
     ▼
app.handleKey() matches .rebuild
     │
     ▼
app.runBuild()
     │
     ├─→ process.runBuild() spawns "zig build", waits, returns output
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

## Key Design Decisions

### Shared Text Buffer

The core memory optimization. Instead of each `Line` storing 512 bytes of text inline:

```zig
// OLD: 536 bytes per Line, 4.4MB total for 8192 lines
const Line = struct {
    content: [512]u8,
    len: u16,
    // ...
};

// NEW: 28 bytes per Line, 738KB total
const Line = struct {
    text_offset: u32,  // Index into shared buffer
    text_len: u16,
    // ...
};

const Report = struct {
    text_buf: [512 * 1024]u8,  // All text here
    lines_buf: [8192]Line,      // Just metadata
};
```

Benefits:
- 6x memory reduction
- Better cache locality (text is contiguous)
- No heap allocation for text storage

### Global Static for Report

The Report is ~738KB - too big for stack. Instead of heap allocation:

```zig
var global_report: types.Report = types.Report.init();
```

This goes in `.bss` segment (static memory). No runtime allocation needed.

### No Regex

All pattern matching is hand-written using `std.mem.indexOf`, `std.mem.startsWith`, etc. This means:
- Zero dependencies for parsing
- Faster execution
- Explicit, readable matching logic

---

## Potential Improvements

### Simplifications

1. **`Parser.state` is unused** - The `after_error`, `after_warning`, `in_test_output` states are set but never read. Either remove them or use them for smarter classification.

2. **`MAX_OUTPUT_SIZE` alias** - Exists for "backwards compat" but nothing uses it differently. Could just use one name.

### Performance

1. **Fixed 16ms sleep** - Could use `select()`/`poll()` to sleep until input arrives OR timeout, reducing latency for key presses.

2. **File watcher is polling-only** - Could add inotify/FSEvents/kqueue for efficiency on long-running sessions.

3. **Build output is fully buffered** - For very large outputs, could stream and parse incrementally.

### Features (noted as TODO in code)

1. **Search** - The mode exists but `confirm` does nothing
2. **Job selection** - `select_job` action exists but does nothing
3. **Open in editor** - Works but should exit alt screen first

### Code Quality

1. **Tests only in two files** - `types.zig` and `parse.zig` have tests, others don't
2. **No error handling in some places** - `catch {}` silently swallows errors in a few spots

---

## Summary

Vigil is a well-structured ~2500 line Zig project following TigerStyle principles:
- Fixed limits on everything
- Static allocation where possible
- No regex (hand-written parsers)
- Single external dependency

The core innovation is the **shared text buffer** pattern that reduced memory from 4.4MB to 738KB by storing line text contiguously and having `Line` structs store offsets instead of inline arrays.
