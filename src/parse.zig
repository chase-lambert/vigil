//! Output parsing and line classification.
//!
//! Parses Zig compiler output to extract structured information
//! about errors, warnings, and other diagnostics.
//!
//! Design: No regex, hand-written matchers for speed and clarity.

const std = @import("std");
const types = @import("types.zig");

const Line = types.Line;
const LineKind = types.LineKind;
const Location = types.Location;
const Report = types.Report;
const Stream = types.Stream;

// =============================================================================
// Parser State
// =============================================================================

/// Parser for build output. Maintains state across lines to track
/// which "item" (error group) each line belongs to.
pub const Parser = struct {
    /// Current item index (incremented when we see an error/warning header)
    current_item: u16,
    /// State machine for context-aware classification
    state: State,
    /// Whether we're inside a "referenced by:" block
    in_reference_block: bool,

    const State = enum {
        normal,
        after_error,
        after_warning,
        in_test_output,
    };

    pub fn init() Parser {
        return .{
            .current_item = 0,
            .state = .normal,
            .in_reference_block = false,
        };
    }

    pub fn reset(self: *Parser) void {
        self.current_item = 0;
        self.state = .normal;
        self.in_reference_block = false;
    }

    /// Parse a single line of output and add it to the report.
    /// Text is stored in the report's shared buffer (data-oriented design).
    /// Returns error if report is full.
    pub fn parseLine(self: *Parser, raw: []const u8, stream: Stream, report: *Report) !void {
        var line = Line.init();
        line.stream = stream;
        line.item_index = self.current_item;

        // Store text in the shared buffer
        const text_info = try report.appendText(raw);
        line.text_offset = text_info.offset;
        line.text_len = text_info.len;

        // Classify the line
        line.kind = self.classify(raw);

        // Update item index for item headers
        if (line.kind.isItemStart()) {
            self.current_item +|= 1;
            line.item_index = self.current_item;
        }

        // Try to parse location for relevant line types
        if (line.kind == .error_location or
            line.kind == .warning_location or
            line.kind == .note_location)
        {
            line.location = parseLocation(raw);
        }

        // Update stats
        switch (line.kind) {
            .error_location => report.stats.errors += 1,
            .warning_location => report.stats.warnings += 1,
            .note_location => report.stats.notes += 1,
            .test_pass => report.stats.tests_passed += 1,
            .test_fail => report.stats.tests_failed += 1,
            else => {},
        }

        // Track item starts for navigation
        if (line.kind.isItemStart()) {
            report.appendItemStart(@intCast(report.lines_len)) catch {};
        }

        // Store the line
        try report.appendLine(line);
    }

    /// Classify a line based on its content.
    fn classify(self: *Parser, line: []const u8) LineKind {
        // Empty line
        if (line.len == 0) {
            self.in_reference_block = false;
            return .blank;
        }

        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len == 0) return .blank;

        // "referenced by:" starts a block we want to hide
        if (std.mem.startsWith(u8, trimmed, "referenced by:")) {
            self.in_reference_block = true;
            return .referenced_by;
        }

        // Lines in reference block (indented references)
        if (self.in_reference_block) {
            if (countLeadingSpaces(line) >= 4) {
                // Check if it's still a reference line
                if (std.mem.indexOf(u8, trimmed, ".zig:") != null or
                    std.mem.indexOf(u8, line, "reference(s) hidden") != null)
                {
                    return .referenced_by;
                }
            }
            // Non-indented line ends the reference block
            if (countLeadingSpaces(line) == 0) {
                self.in_reference_block = false;
            }
        }

        // Error/warning/note with location pattern: "path:line:col: type:"
        if (std.mem.indexOf(u8, line, ": error:")) |_| {
            self.state = .after_error;
            return .error_location;
        }
        if (std.mem.indexOf(u8, line, ": warning:")) |_| {
            self.state = .after_warning;
            return .warning_location;
        }
        if (std.mem.indexOf(u8, line, ": note:")) |_| {
            return .note_location;
        }

        // Build tree noise (unicode box drawing characters)
        if (std.mem.startsWith(u8, trimmed, "└─") or
            std.mem.startsWith(u8, trimmed, "├─") or
            std.mem.startsWith(u8, trimmed, "│"))
        {
            return .build_tree;
        }

        // Command dump patterns
        if (std.mem.indexOf(u8, line, "zig build-exe") != null) return .command_dump;
        if (std.mem.indexOf(u8, line, "-Mroot=") != null) return .command_dump;
        if (std.mem.indexOf(u8, line, "--cache-dir") != null) return .command_dump;
        if (std.mem.indexOf(u8, line, "--listen=-") != null) return .command_dump;
        if (std.mem.startsWith(u8, trimmed, "error: the following command failed")) return .command_dump;

        // Build summary patterns
        if (std.mem.startsWith(u8, trimmed, "Build Summary:")) return .build_summary;
        if (std.mem.indexOf(u8, line, "transitive failure") != null) return .build_summary;
        if (std.mem.indexOf(u8, line, "steps succeeded") != null) return .build_summary;
        if (std.mem.startsWith(u8, trimmed, "error: the following build command failed")) return .final_error;

        // Test result patterns
        if (isTestPassLine(trimmed)) return .test_pass;
        if (isTestFailLine(trimmed)) return .test_fail;

        // Pointer line (just tildes, carets, pipes, spaces)
        if (isPointerLine(trimmed)) return .pointer_line;

        // Source line (heavily indented code)
        const spaces = countLeadingSpaces(line);
        if (spaces >= 4 and trimmed.len > 0) {
            // Check if it looks like code (not just whitespace junk)
            if (looksLikeCode(trimmed)) return .source_line;
        }

        return .other;
    }
};

// =============================================================================
// Location Parsing
// =============================================================================

/// Parse a file:line:col location from a line.
/// Expects format like "src/main.zig:42:13: error: message"
pub fn parseLocation(line: []const u8) ?Location {
    // Find ": error:", ": warning:", or ": note:"
    const markers = [_][]const u8{ ": error:", ": warning:", ": note:" };

    var marker_pos: ?usize = null;
    for (markers) |marker| {
        if (std.mem.indexOf(u8, line, marker)) |pos| {
            marker_pos = pos;
            break;
        }
    }

    const end_of_location = marker_pos orelse return null;
    const location_part = line[0..end_of_location];

    // Parse backwards to find line:col
    // Format: path:line:col
    var colon_positions: [2]usize = .{ 0, 0 };
    var colon_count: usize = 0;

    var i: usize = location_part.len;
    while (i > 0) : (i -= 1) {
        if (location_part[i - 1] == ':') {
            if (colon_count < 2) {
                colon_positions[colon_count] = i - 1;
                colon_count += 1;
            }
            if (colon_count == 2) break;
        }
    }

    if (colon_count < 2) return null;

    // colon_positions[0] is the last colon (before col)
    // colon_positions[1] is the second-to-last (before line)
    const col_start = colon_positions[0] + 1;
    const line_start = colon_positions[1] + 1;
    const path_end = colon_positions[1];

    const col_str = location_part[col_start..];
    const line_str = location_part[line_start..colon_positions[0]];
    const path = location_part[0..path_end];

    const line_num = std.fmt.parseInt(u32, line_str, 10) catch return null;
    const col_num = std.fmt.parseInt(u16, col_str, 10) catch 1;

    // Validate we have a reasonable path
    if (path.len == 0) return null;

    return Location{
        .path_start = 0,
        .path_len = @intCast(path.len),
        .line = line_num,
        .col = col_num,
    };
}

// =============================================================================
// Helper Functions
// =============================================================================

fn countLeadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

fn isPointerLine(line: []const u8) bool {
    if (line.len == 0) return false;

    var has_pointer = false;
    for (line) |c| {
        switch (c) {
            '~', '^' => has_pointer = true,
            ' ', '-', '|' => {},
            else => return false,
        }
    }
    return has_pointer; // Must have at least one ~ or ^
}

fn isTestPassLine(line: []const u8) bool {
    // Pattern: "test_name... OK" or similar
    return std.mem.endsWith(u8, line, "... OK") or
        std.mem.endsWith(u8, line, "...OK");
}

fn isTestFailLine(line: []const u8) bool {
    // Pattern: "test_name... FAIL"
    return std.mem.endsWith(u8, line, "... FAIL") or
        std.mem.endsWith(u8, line, "...FAIL") or
        std.mem.indexOf(u8, line, "FAILED") != null;
}

fn looksLikeCode(line: []const u8) bool {
    // Heuristic: contains common code characters
    for (line) |c| {
        switch (c) {
            '=', '.', '(', ')', '{', '}', '[', ']', ';', ':', '@', '_' => return true,
            else => {},
        }
    }
    // Also accept if it's mostly alphanumeric (variable names, etc.)
    var alpha_count: usize = 0;
    for (line) |c| {
        if (std.ascii.isAlphanumeric(c)) alpha_count += 1;
    }
    return alpha_count > line.len / 2;
}

// =============================================================================
// Report Builder
// =============================================================================

/// Parse complete build output into a Report.
pub fn parseOutput(output: []const u8, report: *Report) void {
    report.clear();

    var parser = Parser.init();
    var line_iter = std.mem.splitScalar(u8, output, '\n');

    while (line_iter.next()) |raw_line| {
        // parseLine now handles everything: text storage, stats, item tracking
        parser.parseLine(raw_line, .stderr, report) catch break;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parseLocation basic" {
    const loc = parseLocation("src/main.zig:42:13: error: something");
    try std.testing.expect(loc != null);
    try std.testing.expectEqual(@as(u32, 42), loc.?.line);
    try std.testing.expectEqual(@as(u16, 13), loc.?.col);
}

test "parseLocation with path containing colon" {
    // Windows-style paths or other edge cases
    const loc = parseLocation("C:/Users/test/main.zig:10:5: warning: unused");
    // This should handle the path correctly
    if (loc) |l| {
        try std.testing.expectEqual(@as(u32, 10), l.line);
    }
}

test "classify error line" {
    var parser = Parser.init();
    var report = Report.init();
    try parser.parseLine("src/main.zig:42:13: error: expected type 'u32'", .stderr, &report);
    try std.testing.expectEqual(@as(usize, 1), report.lines_len);
    try std.testing.expectEqual(LineKind.error_location, report.lines()[0].kind);
}

test "classify build tree" {
    var parser = Parser.init();
    var report = Report.init();
    try parser.parseLine("└─ compile exe example Debug native", .stderr, &report);
    try std.testing.expectEqual(@as(usize, 1), report.lines_len);
    try std.testing.expectEqual(LineKind.build_tree, report.lines()[0].kind);
}

test "classify pointer line" {
    var parser = Parser.init();
    var report = Report.init();
    try parser.parseLine("            ~~~~~~~~~~^~~~", .stderr, &report);
    try std.testing.expectEqual(@as(usize, 1), report.lines_len);
    try std.testing.expectEqual(LineKind.pointer_line, report.lines()[0].kind);
}

test "isPointerLine" {
    try std.testing.expect(isPointerLine("~~~^~~~"));
    try std.testing.expect(isPointerLine("    ~~~~~~~~~~^~~~"));
    try std.testing.expect(!isPointerLine("hello world"));
    try std.testing.expect(!isPointerLine(""));
    try std.testing.expect(!isPointerLine("   ")); // Just spaces, no pointer chars
}
