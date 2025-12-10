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
const TestFailure = types.TestFailure;

// =============================================================================
// Parser State
// =============================================================================

/// Parser for build output. Maintains state across lines to track
/// which "item" (error group) each line belongs to.
pub const Parser = struct {
    /// Current item index (incremented when we see an error/warning header)
    current_item: u16,
    /// Whether we're inside a "referenced by:" block
    in_reference_block: bool,
    /// Current test failure being parsed (for associating expected/actual values)
    current_test_failure: ?u8,
    /// Running count of test failures for badge numbering
    test_failure_count: u8,
    /// Lines remaining to capture after note_location (source + pointer)
    /// Zig's note context lines have NO indentation unlike error context
    note_context_remaining: u8,

    pub fn init() Parser {
        return .{
            .current_item = 0,
            .in_reference_block = false,
            .current_test_failure = null,
            .test_failure_count = 0,
            .note_context_remaining = 0,
        };
    }

    pub fn reset(self: *Parser) void {
        self.current_item = 0;
        self.in_reference_block = false;
        self.current_test_failure = null;
        self.test_failure_count = 0;
        self.note_context_remaining = 0;
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

        // Update item index and track item starts for navigation
        if (line.kind.isItemStart()) {
            self.current_item +|= 1;
            line.item_index = self.current_item;
            // Note: if we exceed MAX_ITEMS, navigation won't work for later items
            // but lines are still added to the report and visible. This is acceptable.
            report.appendItemStart(@intCast(report.lines_len)) catch {};
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
            .test_fail, .test_fail_header => report.stats.tests_failed += 1,
            else => {},
        }

        // Extract test failure details for Bacon-style display
        if (line.kind == .test_fail_header) {
            self.test_failure_count += 1;
            if (extractTestName(raw)) |name_info| {
                var failure = TestFailure.init();
                failure.line_index = report.lines_len;
                failure.name_offset = text_info.offset + name_info.start;
                failure.name_len = name_info.len;
                failure.failure_number = self.test_failure_count;
                report.appendTestFailure(failure) catch {};
                self.current_test_failure = report.test_failures_len -| 1;
            }
        }

        // Associate expected/actual values with current test failure
        if (line.kind == .test_expected_value) {
            if (self.current_test_failure) |idx| {
                if (extractExpectedActual(raw)) |values| {
                    var failures = report.testFailuresMut();
                    if (idx < failures.len) {
                        failures[idx].expected_offset = text_info.offset + values.expected_start;
                        failures[idx].expected_len = values.expected_len;
                        failures[idx].actual_offset = text_info.offset + values.actual_start;
                        failures[idx].actual_len = values.actual_len;
                    }
                }
            }
        }

        // Store the line
        try report.appendLine(line);
    }

    /// Classify a line based on its content.
    fn classify(self: *Parser, line: []const u8) LineKind {
        // Empty line
        if (line.len == 0) {
            self.in_reference_block = false;
            self.note_context_remaining = 0;
            return .blank;
        }

        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len == 0) return .blank;

        // Note context lines: Zig's note context has NO indentation (unlike error context)
        // We expect 2 lines after a note: source line, then pointer line
        if (self.note_context_remaining > 0) {
            self.note_context_remaining -= 1;
            // Check if it's actually context (not another location line or keyword)
            if (std.mem.indexOf(u8, line, ": note:") == null and
                std.mem.indexOf(u8, line, ": error:") == null and
                std.mem.indexOf(u8, line, ": warning:") == null and
                !std.mem.startsWith(u8, trimmed, "referenced by:"))
            {
                if (isPointerLine(trimmed)) return .pointer_line;
                return .source_line;
            }
            // It's another location line, stop expecting context
            self.note_context_remaining = 0;
        }

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
            return .error_location;
        }
        if (std.mem.indexOf(u8, line, ": warning:")) |_| {
            return .warning_location;
        }
        if (std.mem.indexOf(u8, line, ": note:")) |_| {
            // Start expecting 2 context lines (source + pointer)
            self.note_context_remaining = 2;
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

        // Test result patterns (order matters - check specific patterns first)
        if (isTestFailHeader(line)) return .test_fail_header;
        if (isTestSummaryLine(trimmed)) return .test_summary;
        if (isExpectedValueLine(line)) return .test_expected_value;
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
    // Direct test runner: "1/2 main.test.name...OK"
    if (std.mem.endsWith(u8, line, "...OK")) return true;

    // Build system summary: "+- run test 3/3 passed, 0 failed" (all pass)
    if (std.mem.indexOf(u8, line, "run test") != null and
        std.mem.indexOf(u8, line, "passed") != null and
        std.mem.indexOf(u8, line, "0 failed") != null)
    {
        return true;
    }

    return false;
}

fn isTestFailLine(line: []const u8) bool {
    // Direct test runner: "2/2 main.test.name...FAIL (reason)"
    if (std.mem.indexOf(u8, line, "...FAIL") != null) return true;

    return false;
}

/// Check if line is a test failure header: "error: 'test.name' failed:"
/// This is the detailed failure message (not the ...FAIL line)
fn isTestFailHeader(line: []const u8) bool {
    // Pattern: error: '<test_name>' failed:
    if (std.mem.indexOf(u8, line, "error: '") == null) return false;
    if (std.mem.indexOf(u8, line, "' failed:") == null) return false;
    return true;
}

/// Check if line is a test summary: "+- run test N/M passed, K failed"
fn isTestSummaryLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "run test") != null and
        std.mem.indexOf(u8, line, "passed") != null;
}

/// Check if line contains expected/actual assertion values
fn isExpectedValueLine(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    // Pattern: "expected X, found Y"
    return std.mem.startsWith(u8, trimmed, "expected ") and
        std.mem.indexOf(u8, trimmed, ", found ") != null;
}

// =============================================================================
// Test Name/Value Extraction
// =============================================================================

/// Extract test name from failure header
/// Input: "error: 'main.test.my test name' failed: ..."
/// Returns: offset and length of "main.test.my test name" in the line
pub fn extractTestName(line: []const u8) ?struct { start: u16, len: u16 } {
    const start_marker = "error: '";
    const end_marker = "' failed:";

    const marker_pos = std.mem.indexOf(u8, line, start_marker) orelse return null;
    const name_start = marker_pos + start_marker.len;

    const after_name = line[name_start..];
    const name_len = std.mem.indexOf(u8, after_name, end_marker) orelse return null;

    return .{
        .start = @intCast(name_start),
        .len = @intCast(name_len),
    };
}

/// Extract expected and actual values from assertion line
/// Input: "expected 42, found 4"
/// Returns: offsets for expected ("42") and actual ("4") values
pub fn extractExpectedActual(line: []const u8) ?struct {
    expected_start: u16,
    expected_len: u16,
    actual_start: u16,
    actual_len: u16,
} {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    const base_offset: u16 = @intCast(line.len - trimmed.len);

    // Pattern: "expected X, found Y"
    const expected_prefix = "expected ";
    const found_marker = ", found ";
    if (!std.mem.startsWith(u8, trimmed, expected_prefix)) return null;

    const after_expected = trimmed[expected_prefix.len..];
    const comma_pos = std.mem.indexOf(u8, after_expected, found_marker) orelse return null;

    const expected_value_len: u16 = @intCast(comma_pos);
    const actual_start_in_trimmed: u16 = @intCast(expected_prefix.len + comma_pos + found_marker.len);
    const actual_value = trimmed[actual_start_in_trimmed..];

    return .{
        .expected_start = base_offset + @as(u16, @intCast(expected_prefix.len)),
        .expected_len = expected_value_len,
        .actual_start = base_offset + actual_start_in_trimmed,
        .actual_len = @intCast(actual_value.len),
    };
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

    // Cache the terse line count for O(1) lookups
    report.computeTerseCount();
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
    try std.testing.expectEqual(@as(u16, 1), report.lines_len);
    try std.testing.expectEqual(LineKind.error_location, report.lines()[0].kind);
}

test "classify build tree" {
    var parser = Parser.init();
    var report = Report.init();
    try parser.parseLine("└─ compile exe example Debug native", .stderr, &report);
    try std.testing.expectEqual(@as(u16, 1), report.lines_len);
    try std.testing.expectEqual(LineKind.build_tree, report.lines()[0].kind);
}

test "classify pointer line" {
    var parser = Parser.init();
    var report = Report.init();
    try parser.parseLine("            ~~~~~~~~~~^~~~", .stderr, &report);
    try std.testing.expectEqual(@as(u16, 1), report.lines_len);
    try std.testing.expectEqual(LineKind.pointer_line, report.lines()[0].kind);
}

test "isPointerLine" {
    try std.testing.expect(isPointerLine("~~~^~~~"));
    try std.testing.expect(isPointerLine("    ~~~~~~~~~~^~~~"));
    try std.testing.expect(!isPointerLine("hello world"));
    try std.testing.expect(!isPointerLine(""));
    try std.testing.expect(!isPointerLine("   ")); // Just spaces, no pointer chars
}

test "isTestPassLine" {
    // Direct test runner format
    try std.testing.expect(isTestPassLine("1/2 main.test.passing test one...OK"));
    // Build system all-pass format
    try std.testing.expect(isTestPassLine("+- run test 3/3 passed, 0 failed"));
    // Not a pass
    try std.testing.expect(!isTestPassLine("+- run test 2/3 passed, 1 failed"));
    try std.testing.expect(!isTestPassLine("some random line"));
}

test "isTestFailLine" {
    // Direct test runner format: "N/M test.name...FAIL"
    try std.testing.expect(isTestFailLine("2/2 main.test.this test will fail...FAIL (TestUnexpectedResult)"));
    // Not failures (these are now separate line kinds)
    try std.testing.expect(!isTestFailLine("+- run test 2/3 passed, 1 failed")); // Now test_summary
    try std.testing.expect(!isTestFailLine("error: 'main.test.foo' failed: ...")); // Now test_fail_header
    try std.testing.expect(!isTestFailLine("some random line"));
}

test "isTestFailHeader" {
    // Pattern: error: 'test_name' failed:
    try std.testing.expect(isTestFailHeader("error: 'main.test.this test will fail' failed: expected 42, found 4"));
    try std.testing.expect(isTestFailHeader("error: 'test.simple' failed:"));
    // Not failure headers
    try std.testing.expect(!isTestFailHeader("error: compilation failed"));
    try std.testing.expect(!isTestFailHeader("2/2 main.test.foo...FAIL"));
}

test "isTestSummaryLine" {
    try std.testing.expect(isTestSummaryLine("+- run test 3/3 passed, 0 failed"));
    try std.testing.expect(isTestSummaryLine("+- run test 2/3 passed, 1 failed"));
    try std.testing.expect(isTestSummaryLine("run test 1/2 passed, 1 failed"));
    try std.testing.expect(!isTestSummaryLine("some random line"));
    try std.testing.expect(!isTestSummaryLine("2/2 main.test.foo...FAIL"));
}

test "extractTestName" {
    const result = extractTestName("error: 'main.test.my test name' failed: expected 42");
    try std.testing.expect(result != null);
    const info = result.?;
    // The name starts after "error: '"
    try std.testing.expectEqual(@as(u16, 8), info.start);
    try std.testing.expectEqual(@as(u16, 22), info.len); // "main.test.my test name" = 22 chars
}

test "extractExpectedActual" {
    const result = extractExpectedActual("  expected 42, found 4");
    try std.testing.expect(result != null);
    const info = result.?;
    // expected starts at offset 2 (spaces) + 9 ("expected ") = 11
    try std.testing.expectEqual(@as(u16, 11), info.expected_start);
    try std.testing.expectEqual(@as(u16, 2), info.expected_len); // "42"
    // actual starts after ", found "
    try std.testing.expectEqual(@as(u16, 1), info.actual_len); // "4"
}
