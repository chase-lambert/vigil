//! Core data structures for Vigil.
//!
//! Design principles:
//! - Fixed-size structures, no heap allocation after init
//! - Explicit limits on everything
//! - Pack related data for cache efficiency
//! - Shared text buffer: all line text in one contiguous buffer (cache-friendly)

const std = @import("std");
const assert = std.debug.assert;

// =============================================================================
// Limits
// =============================================================================

pub const MAX_LINES: usize = 8192;
pub const MAX_LINE_LEN: usize = 512;
pub const MAX_PATH_LEN: usize = 256;
pub const MAX_WATCH_PATHS: usize = 64;
pub const MAX_TEXT_SIZE: usize = 512 * 1024; // 512KB shared text buffer
pub const MAX_SEARCH_LEN: usize = 64;
pub const MAX_CMD_ARGS: usize = 32;
pub const MAX_ERRORS: u8 = 255; // Badge numbering limit
pub const MAX_TEST_FAILURES: u8 = 255; // Structured failure tracking limit

// =============================================================================
// Line Classification
// =============================================================================

/// Classification of a single line of build output.
/// Determines display behavior in terse vs full mode.
pub const LineKind = enum(u8) {
    // === Kept in terse mode ===
    error_location, // "path:line:col: error: message"
    note_location, // "path:line:col: note: message"
    source_line, // indented source code snippet
    pointer_line, // "    ~~~^~~~" error indicator
    test_fail, // "N/M test_name...FAIL" (direct runner)
    test_fail_header, // "error: 'test_name' failed:" (failure details)
    test_expected_value, // "expected X, found Y" (assertion details)
    test_summary, // "+- run test N/M passed, K failed"
    build_error, // "error: ..." without file:line:col

    // === Hidden in terse mode ===
    test_pass, // "test_name... OK"
    test_internal_frame, // std.testing.zig frames (noise)
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
            .note_location,
            .source_line,
            .pointer_line,
            .test_fail,
            .test_fail_header,
            .test_expected_value,
            .test_summary,
            .build_error,
            .blank,
            => true,

            .test_pass, // Hidden in terse mode
            .test_internal_frame, // std library stack frames
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
            .error_location, .test_fail, .test_fail_header => true,
            else => false,
        };
    }
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
// Test Failure Details
// =============================================================================

/// Parsed test failure information for structured display.
/// Stores offsets into Report.text_buf, not strings themselves (data-oriented).
pub const TestFailure = struct {
    /// Index of the test_fail_header line in lines_buf
    line_index: u16,
    /// Test name: offset into text_buf where name starts
    name_offset: u32,
    name_len: u16,
    /// Expected value (if extracted): offset into text_buf
    expected_offset: u32,
    expected_len: u16,
    /// Actual value (if extracted): offset into text_buf
    actual_offset: u32,
    actual_len: u16,
    /// Failure number (1-indexed, for badge display [1], [2], etc.)
    failure_number: u8,

    pub fn init() TestFailure {
        return .{
            .line_index = 0,
            .name_offset = 0,
            .name_len = 0,
            .expected_offset = 0,
            .expected_len = 0,
            .actual_offset = 0,
            .actual_len = 0,
            .failure_number = 0,
        };
    }

    /// Get the test name from the shared text buffer.
    pub fn getName(self: TestFailure, text_buf: []const u8) []const u8 {
        if (self.name_len == 0) return "";
        const end = @min(self.name_offset + self.name_len, text_buf.len);
        return text_buf[self.name_offset..end];
    }

    /// Get the expected value from the shared text buffer.
    pub fn getExpected(self: TestFailure, text_buf: []const u8) []const u8 {
        if (self.expected_len == 0) return "";
        const end = @min(self.expected_offset + self.expected_len, text_buf.len);
        return text_buf[self.expected_offset..end];
    }

    /// Get the actual value from the shared text buffer.
    pub fn getActual(self: TestFailure, text_buf: []const u8) []const u8 {
        if (self.actual_len == 0) return "";
        const end = @min(self.actual_offset + self.actual_len, text_buf.len);
        return text_buf[self.actual_offset..end];
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
    /// Which item this line belongs to (for grouping)
    item_index: u16,
    /// Parsed location if applicable
    location: ?Location,

    /// Get the text content of this line.
    /// Requires the Report's text buffer since text is stored there, not inline.
    pub fn getText(self: *const Line, text_buf: []const u8) []const u8 {
        // Precondition: offset must be within buffer
        assert(self.text_offset <= text_buf.len);
        const end = @min(self.text_offset + self.text_len, text_buf.len);
        return text_buf[self.text_offset..end];
    }

    pub fn init() Line {
        return .{
            .text_offset = 0,
            .text_len = 0,
            .kind = .other,
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
    errors: u8 = 0,
    notes: u16 = 0,
    tests_passed: u16 = 0,
    tests_failed: u8 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    pub fn hasErrors(self: Stats) bool {
        return self.errors > 0 or self.tests_failed > 0;
    }

    pub fn isSuccess(self: Stats) bool {
        return !self.hasErrors();
    }
};

/// A complete parsed build report.
/// Uses static allocation - no heap after init.
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
    lines_len: u16, // Max 8192 lines
    /// Statistics
    stats: Stats,
    /// Exit code from the build command
    exit_code: ?u8,
    /// Cached terse line count (avoids O(n) iteration on every scroll/render)
    cached_terse_count: u16, // Max 8192 lines
    /// Test failure details for structured display
    test_failures_buf: [MAX_TEST_FAILURES]TestFailure,
    test_failures_len: u8, // Max 64 failures

    pub fn init() Report {
        return .{
            .text_buf = undefined,
            .text_len = 0,
            .lines_buf = undefined,
            .lines_len = 0,
            .stats = .{},
            .exit_code = null,
            .cached_terse_count = 0,
            .test_failures_buf = undefined,
            .test_failures_len = 0,
        };
    }

    pub fn clear(self: *Report) void {
        self.text_len = 0;
        self.lines_len = 0;
        self.stats.reset();
        self.exit_code = null;
        self.cached_terse_count = 0;
        self.test_failures_len = 0;
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
        // Precondition: offset in bounds (should be guaranteed by check above)
        assert(offset + copy_len <= MAX_TEXT_SIZE);
        @memcpy(self.text_buf[offset .. offset + copy_len], text[0..copy_len]);
        self.text_len += @intCast(copy_len);

        // Postcondition: text_len increased by exactly copy_len
        assert(self.text_len == offset + copy_len);
        return .{ .offset = offset, .len = @intCast(copy_len) };
    }

    /// Append a line, returns error if full
    pub fn appendLine(self: *Report, line: Line) !void {
        if (self.lines_len >= MAX_LINES) return error.ReportFull;
        // Precondition: line's text offset should be valid
        assert(line.text_offset <= self.text_len);
        self.lines_buf[self.lines_len] = line;
        self.lines_len += 1;
    }

    /// Get the slice of test failures
    pub fn testFailures(self: *const Report) []const TestFailure {
        return self.test_failures_buf[0..self.test_failures_len];
    }

    /// Get mutable slice of test failures (for updating expected/actual)
    pub fn testFailuresMut(self: *Report) []TestFailure {
        return self.test_failures_buf[0..self.test_failures_len];
    }

    /// Append a test failure, returns error if full
    pub fn appendTestFailure(self: *Report, failure: TestFailure) !void {
        if (self.test_failures_len >= MAX_TEST_FAILURES) return error.TooManyTestFailures;
        self.test_failures_buf[self.test_failures_len] = failure;
        self.test_failures_len += 1;
    }

    /// Get visible line count based on view mode.
    /// Uses cached value for terse mode to avoid O(n) iteration on every call.
    pub fn getVisibleCount(self: *const Report, expanded: bool) u16 {
        if (expanded) return self.lines_len;
        return self.cached_terse_count;
    }

    /// Compute and cache the terse line count.
    /// Call this after parsing is complete.
    pub fn computeTerseCount(self: *Report) void {
        var count: u16 = 0;
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
// View State
// =============================================================================

/// Current view/UI state.
pub const ViewState = struct {
    /// Scroll position (line offset)
    scroll: u16, // Max 8192 lines
    /// Whether we're in expanded (full) view
    expanded: bool,
    /// Whether lines should wrap
    wrap: bool,
    /// Search query
    search: [MAX_SEARCH_LEN]u8,
    search_len: u8,
    /// Current mode
    mode: Mode,

    pub const Mode = enum {
        normal,
        searching,
        help,
    };

    pub fn init() ViewState {
        return .{
            .scroll = 0,
            .expanded = false,
            .wrap = true,
            .search = undefined,
            .search_len = 0,
            .mode = .normal,
        };
    }

    pub fn reset(self: *ViewState) void {
        self.scroll = 0;
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

    const DEFAULT_WATCH_PATHS = [_][]const u8{"."};

    // Prove at comptime that defaults can't overflow
    comptime {
        assert(DEFAULT_WATCH_PATHS.len <= MAX_WATCH_PATHS);
    }

    pub fn init() WatchConfig {
        var config = WatchConfig{
            .paths = undefined,
            .paths_lens = undefined,
            .paths_count = 0,
            .debounce_ms = 100,
            .enabled = true,
        };
        // Default paths - comptime-verified to fit
        for (DEFAULT_WATCH_PATHS) |path| {
            config.addPath(path) catch unreachable; // Proven safe by comptime assert
        }
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
        assert(idx < self.paths_count);
        return self.paths[idx][0..self.paths_lens[idx]];
    }
};

// =============================================================================
// Compile-time Assertions
// =============================================================================

comptime {
    // Line should be small now (no inline text buffer)
    // Target: fit multiple Lines in a cache line (64 bytes)
    assert(@sizeOf(Line) <= 32);

    // Report should be reasonable size for stack allocation
    // With shared text buffer approach: ~700KB total
    // - text_buf: 512KB
    // - lines_buf: 8192 * ~24 = ~196KB
    assert(@sizeOf(Report) < 1024 * 1024); // < 1MB
}

// =============================================================================
// Tests
// =============================================================================

test "LineKind.shownInTerse" {
    try std.testing.expect(LineKind.error_location.shownInTerse());
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
    try std.testing.expectEqual(@as(u16, 0), report.lines_len);
}
