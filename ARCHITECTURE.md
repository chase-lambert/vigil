# Vigil Architecture

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

## Module Overview

```
main.zig          Entry point, CLI args
    │
    ▼
app.zig           Coordination hub (imperative shell)
    │
    ├──► types.zig      Data structures, limits, assertions
    ├──► parse.zig      Line classification (pure functions)
    ├──► process.zig    Command execution
    ├──► watch.zig      File watching (polling)
    ├──► render.zig     TUI drawing (takes Report as param)
    └──► input.zig      Key → Action (pure)
```

## Key Patterns

### Static Arrays

```zig
// Instead of ArrayList or BoundedArray:
lines_buf: [MAX_LINES]Line,
lines_len: usize,

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

```zig
// Line doesn't store text inline—just a reference
const Line = struct {
    text_offset: u32,  // Offset into Report.text_buf
    text_len: u16,
    kind: LineKind,

    pub fn getText(self: *const Line, text_buf: []const u8) []const u8 {
        return text_buf[self.text_offset..][0..self.text_len];
    }
};

// Report owns the shared buffer
const Report = struct {
    text_buf: [512 * 1024]u8,  // All text here
    text_len: u32,
    lines_buf: [8192]Line,     // Just metadata
    lines_len: usize,
};
```

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
    if (key.matches('n', .{})) return .next_error;
    // ...
    return .none;
}
```

The App's main loop interprets Actions and performs actual mutations.

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
