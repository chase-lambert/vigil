//! Core data structures for Vigil.
//!
//! Design principles (TigerStyle):
//! - Fixed-size structures, no heap allocation after init
//! - Explicit limits on everything
//! - Pack related data for cache efficiency
//! - Shared text buffer: all line text in one contiguous buffer (cache-friendly)

const std = @import("std");

// =============================================================================
// Limits (TigerStyle: put a limit on everything)
// =============================================================================

pub const MAX_LINES: usize = 8192;
pub const MAX_LINE_LEN: usize = 512; // Max single line length
pub const MAX_PATH_LEN: usize = 256;
pub const MAX_ITEMS: usize = 1024;
pub const MAX_JOBS: usize = 16;
pub const MAX_WATCH_PATHS: usize = 64;
pub const MAX_TEXT_SIZE: usize = 512 * 1024; // 512KB shared text buffer
pub const MAX_OUTPUT_SIZE: usize = MAX_TEXT_SIZE; // Alias for backwards compat
pub const MAX_SEARCH_LEN: usize = 64;
pub const MAX_CMD_ARGS: usize = 32;

// =============================================================================
// Line Classification
// =============================================================================

/// Classification of a single line of build output.
/// Determines display behavior in terse vs full mode.
pub const LineKind = enum(u8) {
    // === Kept in terse mode ===
    error_location, // "path:line:col: error: message"
    warning_location, // "path:line:col: warning: message"
    note_location, // "path:line:col: note: message"
    source_line, // indented source code snippet
    pointer_line, // "    ~~~^~~~" error indicator
    test_pass, // "test_name... OK"
    test_fail, // "test_name... FAIL"

    // === Hidden in terse mode ===
    build_tree, // "└─ compile exe..."
    referenced_by, // "referenced by:" section
    command_dump, // the massive zig build-exe command
    build_summary, // "Build Summary:" section
    final_error, // "error: the following build command failed"
    blank, // empty lines
    other, // unknown - hide in terse to be safe

    /// Returns true if this line should be shown in terse (summary) mode.
    pub fn shownInTerse(self: LineKind) bool {
        return switch (self) {
            .error_location,
            .warning_location,
            .note_location,
            .source_line,
            .pointer_line,
            .test_pass,
            .test_fail,
            .blank,
            => true,

            .build_tree,
            .referenced_by,
            .command_dump,
            .build_summary,
            .final_error,
            .other,
            => false,
        };
    }

    /// Returns true if this is an "item header" (starts a new logical item).
    pub fn isItemStart(self: LineKind) bool {
        return switch (self) {
            .error_location, .warning_location, .test_fail => true,
            else => false,
        };
    }
};

/// Origin of a line (which stream it came from).
pub const Stream = enum(u1) {
    stdout,
    stderr,
};

// =============================================================================
// Location (parsed file:line:col reference)
// =============================================================================

/// A parsed source location from an error message.
pub const Location = struct {
    /// Byte offset into line content where path starts
    path_start: u16,
    /// Length of path
    path_len: u16,
    /// Line number (1-based)
    line: u32,
    /// Column number (1-based)
    col: u16,

    pub fn getPath(self: Location, line_content: []const u8) []const u8 {
        const end = @min(self.path_start + self.path_len, line_content.len);
        return line_content[self.path_start..end];
    }
};

// =============================================================================
// Line Storage (Data-Oriented Design)
// =============================================================================

/// A single stored line of build output.
/// Text is NOT stored inline - it lives in the Report's shared text buffer.
/// This reduces Line from ~536 bytes to ~16 bytes, making Report ~130KB instead of 4.4MB.
pub const Line = struct {
    /// Offset into the shared text buffer where this line's content starts
    text_offset: u32,
    /// Length of this line's text
    text_len: u16,
    /// Classification of this line
    kind: LineKind,
    /// Which stream this came from
    stream: Stream,
    /// Which item this line belongs to (for navigation)
    item_index: u16,
    /// Parsed location if applicable
    location: ?Location,

    /// Get the text content of this line.
    /// Requires the Report's text buffer since text is stored there, not inline.
    pub fn getText(self: *const Line, text_buf: []const u8) []const u8 {
        const end = @min(self.text_offset + self.text_len, text_buf.len);
        return text_buf[self.text_offset..end];
    }

    pub fn init() Line {
        return .{
            .text_offset = 0,
            .text_len = 0,
            .kind = .other,
            .stream = .stderr,
            .item_index = 0,
            .location = null,
        };
    }
};

// =============================================================================
// Report (collection of parsed lines)
// =============================================================================

/// Statistics about the build output.
pub const Stats = struct {
    errors: u16 = 0,
    warnings: u16 = 0,
    notes: u16 = 0,
    tests_passed: u16 = 0,
    tests_failed: u16 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    pub fn hasErrors(self: Stats) bool {
        return self.errors > 0 or self.tests_failed > 0;
    }

    pub fn hasWarnings(self: Stats) bool {
        return self.warnings > 0;
    }

    pub fn isSuccess(self: Stats) bool {
        return !self.hasErrors() and !self.hasWarnings();
    }
};

/// A complete parsed build report.
/// Uses static allocation - no heap after init (TigerStyle).
///
/// Memory layout (data-oriented design):
/// - text_buf: shared buffer for all line text (~512KB)
/// - lines_buf: array of Line structs (8192 * ~24 bytes = ~196KB)
/// - Total: ~700KB instead of 4.4MB with inline text
pub const Report = struct {
    /// Shared text buffer for all line content (contiguous, cache-friendly)
    text_buf: [MAX_TEXT_SIZE]u8,
    text_len: u32,
    /// All parsed lines (fixed-size buffer)
    lines_buf: [MAX_LINES]Line,
    lines_len: usize,
    /// Item start indices for navigation between errors (fixed-size buffer)
    item_starts_buf: [MAX_ITEMS]u16,
    item_starts_len: usize,
    /// Statistics
    stats: Stats,
    /// Exit code from the build command
    exit_code: ?u8,
    /// Whether the build was killed/interrupted
    was_killed: bool,
    /// Cached terse line count (avoids O(n) iteration on every scroll/render)
    cached_terse_count: usize,

    pub fn init() Report {
        return .{
            .text_buf = undefined,
            .text_len = 0,
            .lines_buf = undefined,
            .lines_len = 0,
            .item_starts_buf = undefined,
            .item_starts_len = 0,
            .stats = .{},
            .exit_code = null,
            .was_killed = false,
            .cached_terse_count = 0,
        };
    }

    pub fn clear(self: *Report) void {
        self.text_len = 0;
        self.lines_len = 0;
        self.item_starts_len = 0;
        self.stats.reset();
        self.exit_code = null;
        self.was_killed = false;
        self.cached_terse_count = 0;
    }

    /// Get the shared text buffer slice (for Line.getText)
    pub fn textBuf(self: *const Report) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    /// Get the slice of active lines
    pub fn lines(self: *const Report) []const Line {
        return self.lines_buf[0..self.lines_len];
    }

    /// Get mutable slice of active lines
    pub fn linesMut(self: *Report) []Line {
        return self.lines_buf[0..self.lines_len];
    }

    /// Append text to the shared buffer, returns the offset where it was stored.
    /// Text is truncated to MAX_LINE_LEN if too long.
    pub fn appendText(self: *Report, text: []const u8) !struct { offset: u32, len: u16 } {
        const copy_len = @min(text.len, MAX_LINE_LEN);
        if (self.text_len + copy_len > MAX_TEXT_SIZE) return error.TextBufferFull;

        const offset = self.text_len;
        @memcpy(self.text_buf[offset .. offset + copy_len], text[0..copy_len]);
        self.text_len += @intCast(copy_len);

        return .{ .offset = offset, .len = @intCast(copy_len) };
    }

    /// Append a line, returns error if full
    pub fn appendLine(self: *Report, line: Line) !void {
        if (self.lines_len >= MAX_LINES) return error.ReportFull;
        self.lines_buf[self.lines_len] = line;
        self.lines_len += 1;
    }

    /// Get the slice of item start indices
    pub fn itemStarts(self: *const Report) []const u16 {
        return self.item_starts_buf[0..self.item_starts_len];
    }

    /// Append an item start index
    pub fn appendItemStart(self: *Report, idx: u16) !void {
        if (self.item_starts_len >= MAX_ITEMS) return error.TooManyItems;
        self.item_starts_buf[self.item_starts_len] = idx;
        self.item_starts_len += 1;
    }

    /// Get visible line count based on view mode.
    /// Uses cached value for terse mode to avoid O(n) iteration on every call.
    pub fn getVisibleCount(self: *const Report, expanded: bool) usize {
        if (expanded) return self.lines_len;
        return self.cached_terse_count;
    }

    /// Compute and cache the terse line count.
    /// Call this after parsing is complete.
    pub fn computeTerseCount(self: *Report) void {
        var count: usize = 0;
        var prev_blank = false;

        for (self.lines()) |line| {
            if (line.kind.shownInTerse()) {
                // Collapse consecutive blanks
                if (line.kind == .blank) {
                    if (!prev_blank) {
                        count += 1;
                        prev_blank = true;
                    }
                } else {
                    count += 1;
                    prev_blank = false;
                }
            }
        }
        self.cached_terse_count = count;
    }
};

// =============================================================================
// Job Configuration
// =============================================================================

/// A configured build job (e.g., "check", "test", "run").
pub const Job = struct {
    /// Job name for display
    name: [32]u8,
    name_len: u8,
    /// Command arguments
    args: [MAX_CMD_ARGS][MAX_PATH_LEN]u8,
    args_lens: [MAX_CMD_ARGS]u8,
    args_count: u8,
    /// Keybinding to trigger this job (0 = none)
    key: u8,

    pub fn init() Job {
        return .{
            .name = undefined,
            .name_len = 0,
            .args = undefined,
            .args_lens = undefined,
            .args_count = 0,
            .key = 0,
        };
    }

    pub fn getName(self: *const Job) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *Job, name: []const u8) void {
        const copy_len = @min(name.len, self.name.len);
        @memcpy(self.name[0..copy_len], name[0..copy_len]);
        self.name_len = @intCast(copy_len);
    }

    pub fn addArg(self: *Job, arg: []const u8) !void {
        if (self.args_count >= MAX_CMD_ARGS) return error.TooManyArgs;
        const idx = self.args_count;
        const copy_len = @min(arg.len, MAX_PATH_LEN);
        @memcpy(self.args[idx][0..copy_len], arg[0..copy_len]);
        self.args_lens[idx] = @intCast(copy_len);
        self.args_count += 1;
    }
};

// =============================================================================
// View State
// =============================================================================

/// Current view/UI state.
pub const ViewState = struct {
    /// Scroll position (line offset)
    scroll: usize,
    /// Currently selected item index (for navigation)
    selected_item: u16,
    /// Whether we're in expanded (full) view
    expanded: bool,
    /// Search query
    search: [MAX_SEARCH_LEN]u8,
    search_len: u8,
    /// Current mode
    mode: Mode,

    pub const Mode = enum {
        normal,
        searching,
        help,
        job_select,
    };

    pub fn init() ViewState {
        return .{
            .scroll = 0,
            .selected_item = 0,
            .expanded = false,
            .search = undefined,
            .search_len = 0,
            .mode = .normal,
        };
    }

    pub fn reset(self: *ViewState) void {
        self.scroll = 0;
        self.selected_item = 0;
        // Keep expanded state across rebuilds
    }

    pub fn getSearch(self: *const ViewState) []const u8 {
        return self.search[0..self.search_len];
    }
};

// =============================================================================
// Watch Configuration
// =============================================================================

/// File watching configuration.
pub const WatchConfig = struct {
    /// Paths to watch
    paths: [MAX_WATCH_PATHS][MAX_PATH_LEN]u8,
    paths_lens: [MAX_WATCH_PATHS]u8,
    paths_count: u8,
    /// Debounce time in milliseconds
    debounce_ms: u32,
    /// Whether watching is enabled
    enabled: bool,

    pub fn init() WatchConfig {
        var config = WatchConfig{
            .paths = undefined,
            .paths_lens = undefined,
            .paths_count = 0,
            .debounce_ms = 100,
            .enabled = true,
        };
        // Default: watch "src" and "build.zig"
        config.addPath("src") catch {};
        config.addPath("build.zig") catch {};
        config.addPath("build.zig.zon") catch {};
        return config;
    }

    pub fn addPath(self: *WatchConfig, path: []const u8) !void {
        if (self.paths_count >= MAX_WATCH_PATHS) return error.TooManyPaths;
        const idx = self.paths_count;
        const copy_len = @min(path.len, MAX_PATH_LEN);
        @memcpy(self.paths[idx][0..copy_len], path[0..copy_len]);
        self.paths_lens[idx] = @intCast(copy_len);
        self.paths_count += 1;
    }

    pub fn getPath(self: *const WatchConfig, idx: usize) []const u8 {
        std.debug.assert(idx < self.paths_count);
        return self.paths[idx][0..self.paths_lens[idx]];
    }
};

// =============================================================================
// Compile-time Assertions (TigerStyle: assert relationships)
// =============================================================================

comptime {
    // Line should be small now (no inline text buffer)
    // Target: fit multiple Lines in a cache line (64 bytes)
    std.debug.assert(@sizeOf(Line) <= 32);

    // Report should be reasonable size for stack allocation
    // With shared text buffer approach: ~700KB total
    // - text_buf: 512KB
    // - lines_buf: 8192 * ~24 = ~196KB
    // - item_starts_buf: 1024 * 2 = 2KB
    std.debug.assert(@sizeOf(Report) < 1024 * 1024); // < 1MB
}

// =============================================================================
// Tests
// =============================================================================

test "LineKind.shownInTerse" {
    try std.testing.expect(LineKind.error_location.shownInTerse());
    try std.testing.expect(LineKind.warning_location.shownInTerse());
    try std.testing.expect(LineKind.note_location.shownInTerse());
    try std.testing.expect(!LineKind.build_tree.shownInTerse());
    try std.testing.expect(!LineKind.command_dump.shownInTerse());
}

test "Stats" {
    var stats = Stats{};
    try std.testing.expect(stats.isSuccess());

    stats.errors = 1;
    try std.testing.expect(!stats.isSuccess());
    try std.testing.expect(stats.hasErrors());
}

test "Report.init" {
    const report = Report.init();
    try std.testing.expectEqual(@as(usize, 0), report.lines_len);
    try std.testing.expectEqual(@as(usize, 0), report.item_starts_len);
}
