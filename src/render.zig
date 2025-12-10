//! TUI rendering for Vigil.
//!
//! Handles all drawing to the terminal using libvaxis.
//! Organized into focused rendering functions for each UI component.

const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");

// =============================================================================
// Render Context (bundles parameters to avoid pass-through smell)
// =============================================================================

/// All state needed to render a frame.
/// Bundles parameters that would otherwise be passed through multiple layers.
pub const RenderContext = struct {
    report: *const types.Report,
    view: *const types.ViewState,
    watching: bool,
    job_name: []const u8,
    project_name: []const u8,
    project_root: []const u8,
};

// =============================================================================
// Visible Line Iterator (separates "which lines" from "how to draw")
// =============================================================================

/// Iterates over lines that should be displayed, handling:
/// - Terse vs expanded visibility filtering
/// - Consecutive blank line collapsing
/// - Scroll position (skipping lines above viewport)
pub const VisibleLineIterator = struct {
    report: *const types.Report,
    expanded: bool,
    scroll: u16,

    // Internal state
    line_index: u16,
    visible_count: u16,
    prev_blank: bool,

    /// What the iterator yields
    pub const Item = struct {
        line: *const types.Line,
        line_index: u16, // Original index (for test failure lookup)
    };

    pub fn init(report: *const types.Report, view: *const types.ViewState) VisibleLineIterator {
        return .{
            .report = report,
            .expanded = view.expanded,
            .scroll = view.scroll,
            .line_index = 0,
            .visible_count = 0,
            .prev_blank = false,
        };
    }

    pub fn next(self: *VisibleLineIterator) ?Item {
        const lines = self.report.lines();

        while (self.line_index < lines.len) {
            const idx = self.line_index;
            self.line_index += 1;

            const line = &lines[idx];
            const should_show = self.expanded or line.kind.shownInTerse();
            if (!should_show) continue;

            // Collapse consecutive blanks in terse mode
            if (!self.expanded and line.kind == .blank) {
                if (self.prev_blank) continue;
                self.prev_blank = true;
            } else {
                self.prev_blank = false;
            }

            // Handle scrolling (skip lines above viewport)
            if (self.visible_count < self.scroll) {
                self.visible_count += 1;
                continue;
            }
            self.visible_count += 1;

            return Item{
                .line = line,
                .line_index = @intCast(idx),
            };
        }

        return null;
    }
};

/// Color palette for consistent theming.
pub const colors = struct {
    pub const error_fg = vaxis.Color{ .rgb = .{ 0xff, 0x66, 0x66 } };
    pub const error_bg = vaxis.Color{ .rgb = .{ 0x44, 0x22, 0x22 } };
    pub const warning_fg = vaxis.Color{ .rgb = .{ 0xff, 0xcc, 0x66 } };
    pub const warning_bg = vaxis.Color{ .rgb = .{ 0x44, 0x33, 0x22 } };
    pub const note_fg = vaxis.Color{ .rgb = .{ 0x66, 0xcc, 0xff } };
    pub const success_fg = vaxis.Color{ .rgb = .{ 0x66, 0xff, 0x66 } };
    pub const success_bg = vaxis.Color{ .rgb = .{ 0x22, 0x44, 0x22 } };
    pub const muted = vaxis.Color{ .rgb = .{ 0x88, 0x88, 0x88 } };
    pub const header_bg = vaxis.Color{ .rgb = .{ 0x33, 0x33, 0x44 } };
    pub const selected_bg = vaxis.Color{ .rgb = .{ 0x44, 0x44, 0x55 } };
    // Test result colors
    pub const pass_badge_bg = vaxis.Color{ .rgb = .{ 0x22, 0x88, 0x22 } };
    pub const fail_badge_bg = vaxis.Color{ .rgb = .{ 0xcc, 0x44, 0x44 } };
    pub const expected_fg = vaxis.Color{ .rgb = .{ 0x88, 0xcc, 0x88 } }; // Light green
    pub const actual_fg = vaxis.Color{ .rgb = .{ 0xff, 0x88, 0x88 } }; // Light red
};

/// Helper to print a single text segment with style (no wrap by default for headers/footers)
fn printText(win: vaxis.Window, text: []const u8, style: vaxis.Cell.Style, opts: vaxis.Window.PrintOptions) vaxis.Window.PrintResult {
    var print_opts = opts;
    print_opts.wrap = .none; // Prevent text from wrapping to next row
    return win.print(&.{.{ .text = text, .style = style }}, print_opts);
}

/// Helper to format and print (uses a static buffer - TigerStyle)
fn printFmt(win: vaxis.Window, comptime fmt: []const u8, args: anytype, style: vaxis.Cell.Style, opts: vaxis.Window.PrintOptions) vaxis.Window.PrintResult {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return .{ .col = opts.col_offset, .row = opts.row_offset, .overflow = true };
    return printText(win, text, style, opts);
}

/// Write a number digit-by-digit using writeCell.
/// Handles the libvaxis static grapheme requirement for dynamic numbers.
fn writeNumber(win: vaxis.Window, num: u16, col: *u16, bg: vaxis.Color, fg: vaxis.Color) void {
    // Convert number to digits (reverse order)
    var digits: [8]u8 = undefined;
    var digit_count: u8 = 0;
    var n = num;
    while (n > 0 or digit_count == 0) : (digit_count += 1) {
        digits[digit_count] = @intCast((n % 10) + '0');
        n /= 10;
    }
    // Write digits in correct order
    var i: u8 = digit_count;
    while (i > 0) {
        i -= 1;
        if (col.* >= win.width) return;
        win.writeCell(col.*, 0, .{
            .char = .{ .grapheme = charToStaticGrapheme(digits[i]), .width = 1 },
            .style = .{ .bg = bg, .fg = fg, .bold = true },
        });
        col.* += 1;
    }
}

/// Map a byte to a static string literal for writeCell grapheme field.
/// libvaxis requires grapheme to point to static/comptime memory - runtime slices corrupt in ReleaseSafe.
/// Covers all printable ASCII (0x20-0x7E). Returns "?" for unmapped characters.
fn charToStaticGrapheme(c: u8) []const u8 {
    return switch (c) {
        // Space and punctuation (0x20-0x2F)
        ' ' => " ",
        '!' => "!",
        '"' => "\"",
        '#' => "#",
        '$' => "$",
        '%' => "%",
        '&' => "&",
        '\'' => "'",
        '(' => "(",
        ')' => ")",
        '*' => "*",
        '+' => "+",
        ',' => ",",
        '-' => "-",
        '.' => ".",
        '/' => "/",
        // Digits (0x30-0x39)
        '0' => "0",
        '1' => "1",
        '2' => "2",
        '3' => "3",
        '4' => "4",
        '5' => "5",
        '6' => "6",
        '7' => "7",
        '8' => "8",
        '9' => "9",
        // Punctuation (0x3A-0x40)
        ':' => ":",
        ';' => ";",
        '<' => "<",
        '=' => "=",
        '>' => ">",
        '?' => "?",
        '@' => "@",
        // Uppercase letters (0x41-0x5A)
        'A' => "A",
        'B' => "B",
        'C' => "C",
        'D' => "D",
        'E' => "E",
        'F' => "F",
        'G' => "G",
        'H' => "H",
        'I' => "I",
        'J' => "J",
        'K' => "K",
        'L' => "L",
        'M' => "M",
        'N' => "N",
        'O' => "O",
        'P' => "P",
        'Q' => "Q",
        'R' => "R",
        'S' => "S",
        'T' => "T",
        'U' => "U",
        'V' => "V",
        'W' => "W",
        'X' => "X",
        'Y' => "Y",
        'Z' => "Z",
        // Punctuation (0x5B-0x60)
        '[' => "[",
        '\\' => "\\",
        ']' => "]",
        '^' => "^",
        '_' => "_",
        '`' => "`",
        // Lowercase letters (0x61-0x7A)
        'a' => "a",
        'b' => "b",
        'c' => "c",
        'd' => "d",
        'e' => "e",
        'f' => "f",
        'g' => "g",
        'h' => "h",
        'i' => "i",
        'j' => "j",
        'k' => "k",
        'l' => "l",
        'm' => "m",
        'n' => "n",
        'o' => "o",
        'p' => "p",
        'q' => "q",
        'r' => "r",
        's' => "s",
        't' => "t",
        'u' => "u",
        'v' => "v",
        'w' => "w",
        'x' => "x",
        'y' => "y",
        'z' => "z",
        // Punctuation (0x7B-0x7E)
        '{' => "{",
        '|' => "|",
        '}' => "}",
        '~' => "~",
        // Non-printable or extended ASCII
        else => "?",
    };
}

/// Render a content line using writeCell character-by-character.
/// This avoids the grapheme lifetime issue with win.print() on runtime strings.
fn printContentLine(win: vaxis.Window, text: []const u8, style: vaxis.Cell.Style, row: u16) void {
    var col: u16 = 0;
    for (text) |byte| {
        if (col >= win.width) break;
        win.writeCell(col, row, .{
            .char = .{ .grapheme = charToStaticGrapheme(byte), .width = 1 },
            .style = style,
        });
        col += 1;
    }
}

/// Clean up a stack trace location line for terse display.
/// Input: "/full/path/to/project/src/main.zig:26:5: 0x10356a8 in test.name (main.zig)"
/// Output: "src/main.zig:26:5" (relative path and location, no memory address)
/// Uses project_root to strip the absolute path prefix.
fn cleanStackTraceLine(text: []const u8, project_root: []const u8) []const u8 {
    // First, find where the useful part ends (before ": 0x" memory address)
    const end_pos = std.mem.indexOf(u8, text, ": 0x") orelse text.len;
    const path_part = text[0..end_pos];

    // Try to strip project root prefix (including trailing slash)
    if (project_root.len > 0) {
        if (std.mem.startsWith(u8, path_part, project_root)) {
            var start = project_root.len;
            // Skip trailing slash if present
            if (start < path_part.len and path_part[start] == '/') {
                start += 1;
            }
            return path_part[start..];
        }
    }

    // Fallback: find "src/" to get relative path
    if (std.mem.indexOf(u8, path_part, "src/")) |src_pos| {
        return path_part[src_pos..];
    }

    // Last resort: just strip the memory address part
    return path_part;
}

/// Render a test failure in Bacon style with expected/actual values.
/// Returns the number of rows used.
fn renderTestFailureLine(
    win: vaxis.Window,
    line: types.Line,
    report: *const types.Report,
    row: u16,
    bg_color: vaxis.Color,
    line_idx: u16,
    max_rows: u16,
) u16 {
    const text_buf = report.textBuf();
    var col: u16 = 0;
    var rows_used: u16 = 0;

    // Find the matching TestFailure to get the failure number, name, and values
    var failure_num: u8 = 1;
    var test_name: []const u8 = "";
    var expected_value: []const u8 = "";
    var actual_value: []const u8 = "";
    for (report.testFailures()) |tf| {
        if (tf.line_index == line_idx) {
            failure_num = tf.failure_number;
            test_name = tf.getName(text_buf);
            expected_value = tf.getExpected(text_buf);
            actual_value = tf.getActual(text_buf);
            break;
        }
    }

    // If no TestFailure found, fall back to extracting from line text
    if (test_name.len == 0) {
        const line_text = line.getText(text_buf);
        // Pattern: "error: 'test_name' failed:"
        if (std.mem.indexOf(u8, line_text, "error: '")) |start| {
            const name_start = start + 8;
            if (std.mem.indexOf(u8, line_text[name_start..], "' failed:")) |name_end| {
                test_name = line_text[name_start..][0..name_end];
            }
        }
    }

    // Render badge: " N " with colored background
    const badge_bg = colors.fail_badge_bg;
    const white = vaxis.Color{ .rgb = .{ 0xff, 0xff, 0xff } };

    win.writeCell(col, row, .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = badge_bg, .fg = white, .bold = true },
    });
    col += 1;

    // Write failure number
    win.writeCell(col, row, .{
        .char = .{ .grapheme = charToStaticGrapheme('0' + failure_num), .width = 1 },
        .style = .{ .bg = badge_bg, .fg = white, .bold = true },
    });
    col += 1;

    win.writeCell(col, row, .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = badge_bg, .fg = white, .bold = true },
    });
    col += 1;
    col += 1; // Gap

    // Render "failed: " in red
    const failed_text = "failed: ";
    for (failed_text) |c| {
        if (col >= win.width) break;
        win.writeCell(col, row, .{
            .char = .{ .grapheme = charToStaticGrapheme(c), .width = 1 },
            .style = .{ .fg = colors.error_fg, .bg = bg_color, .bold = true },
        });
        col += 1;
    }

    // Render test name
    for (test_name) |c| {
        if (col >= win.width) break;
        win.writeCell(col, row, .{
            .char = .{ .grapheme = charToStaticGrapheme(c), .width = 1 },
            .style = .{ .fg = colors.error_fg, .bg = bg_color },
        });
        col += 1;
    }
    rows_used += 1;

    // Render expected/actual values if present (using Zig's terminology)
    if (expected_value.len > 0 and actual_value.len > 0 and rows_used + 2 < max_rows) {
        // Blank line before values
        rows_used += 1;

        // Render "expected: <value>" - aligned with indent
        const current_row = row + rows_used;
        col = 0;
        const expected_label = "expected: ";
        for (expected_label) |c| {
            if (col >= win.width) break;
            win.writeCell(col, current_row, .{
                .char = .{ .grapheme = charToStaticGrapheme(c), .width = 1 },
                .style = .{ .fg = colors.muted, .bg = bg_color },
            });
            col += 1;
        }
        // Render expected value in green
        for (expected_value) |c| {
            if (col >= win.width) break;
            win.writeCell(col, current_row, .{
                .char = .{ .grapheme = charToStaticGrapheme(c), .width = 1 },
                .style = .{ .fg = colors.expected_fg, .bg = bg_color },
            });
            col += 1;
        }
        rows_used += 1;

        // Render "   found: <actual>" - aligned with "expected:"
        if (rows_used < max_rows) {
            const next_row = row + rows_used;
            col = 0;
            const found_label = "   found: ";
            for (found_label) |c| {
                if (col >= win.width) break;
                win.writeCell(col, next_row, .{
                    .char = .{ .grapheme = charToStaticGrapheme(c), .width = 1 },
                    .style = .{ .fg = colors.muted, .bg = bg_color },
                });
                col += 1;
            }
            // Render actual value in red
            for (actual_value) |c| {
                if (col >= win.width) break;
                win.writeCell(col, next_row, .{
                    .char = .{ .grapheme = charToStaticGrapheme(c), .width = 1 },
                    .style = .{ .fg = colors.actual_fg, .bg = bg_color },
                });
                col += 1;
            }
            rows_used += 1;
        }
    }

    return rows_used;
}

/// Render the complete UI.
pub fn render(vx: *vaxis.Vaxis, ctx: RenderContext) void {
    const win = vx.window();
    win.clear();

    const height = win.height;
    const width = win.width;

    // Minimum size check
    if (height < 4 or width < 30) {
        _ = printText(win, "Terminal too small", .{ .fg = colors.muted }, .{});
        return;
    }

    // Layout: header (1) + gap (1) + content (height-3) + footer (1)
    const header_win = win.child(.{ .height = 1 });
    const content_win = win.child(.{
        .y_off = 2, // Gap after header
        .height = height -| 3,
    });
    const footer_win = win.child(.{
        .y_off = @intCast(height -| 1),
        .height = 1,
    });

    renderHeader(header_win, ctx);
    renderContent(content_win, ctx);
    renderFooter(footer_win, ctx.report, ctx.view);
}

/// Render the header bar in Bacon style: project | job | status | mode | watch
/// Uses writeCell character-by-character like the libvaxis examples do.
fn renderHeader(win: vaxis.Window, ctx: RenderContext) void {
    const report = ctx.report;
    const view = ctx.view;
    const watching = ctx.watching;
    const job_name = ctx.job_name;
    const project_name = ctx.project_name;
    const Cell = vaxis.Cell;

    // Colors - softer palette inspired by Bacon
    const project_bg = vaxis.Color{ .rgb = .{ 0x88, 0x44, 0x88 } }; // Purple
    const job_bg = vaxis.Color{ .rgb = .{ 0x44, 0x88, 0x88 } }; // Teal
    const status_ok_bg = vaxis.Color{ .rgb = .{ 0x66, 0xcc, 0x66 } }; // Green
    const status_fail_bg = vaxis.Color{ .rgb = .{ 0xcc, 0x66, 0x66 } }; // Red
    const status_warn_bg = vaxis.Color{ .rgb = .{ 0xcc, 0xaa, 0x55 } }; // Orange
    const mode_terse_bg = vaxis.Color{ .rgb = .{ 0x55, 0x55, 0x66 } }; // Muted gray-blue
    const mode_verbose_bg = vaxis.Color{ .rgb = .{ 0x66, 0x55, 0x66 } }; // Muted purple
    const watch_on_bg = vaxis.Color{ .rgb = .{ 0x55, 0x77, 0x55 } }; // Muted green
    const watch_off_bg = vaxis.Color{ .rgb = .{ 0x77, 0x55, 0x55 } }; // Muted red
    const white = vaxis.Color{ .rgb = .{ 0xff, 0xff, 0xff } };

    var col: u16 = 0;

    // Helper: write a single character cell (uses shared charToStaticGrapheme)
    const writeChar = struct {
        fn f(w: vaxis.Window, c: u8, column: *u16, bg: vaxis.Color, fg: vaxis.Color) void {
            if (column.* >= w.width) return;
            w.writeCell(column.*, 0, Cell{
                .char = .{ .grapheme = charToStaticGrapheme(c), .width = 1 },
                .style = .{ .bg = bg, .fg = fg, .bold = true },
            });
            column.* += 1;
        }
    }.f;

    // 1. Project name: " <name> "
    writeChar(win, ' ', &col, project_bg, white);
    for (project_name) |c| writeChar(win, c, &col, project_bg, white);
    writeChar(win, ' ', &col, project_bg, white);
    col += 1; // Gap

    // 2. Job name: " build " / " test " / " run "
    writeChar(win, ' ', &col, job_bg, white);
    for (job_name) |c| writeChar(win, c, &col, job_bg, white);
    writeChar(win, ' ', &col, job_bg, white);
    col += 1; // Gap

    // 3. Status badge
    const status_bg = if (report.stats.tests_failed > 0 or report.stats.errors > 0)
        status_fail_bg
    else if (report.stats.warnings > 0)
        status_warn_bg
    else
        status_ok_bg;

    if (report.stats.tests_failed > 0) {
        // " N fail "
        writeChar(win, ' ', &col, status_bg, white);
        writeNumber(win, report.stats.tests_failed, &col, status_bg, white);
        for (" fail ") |c| writeChar(win, c, &col, status_bg, white);
    } else if (report.stats.errors > 0) {
        writeChar(win, ' ', &col, status_bg, white);
        writeNumber(win, report.stats.errors, &col, status_bg, white);
        for (" error ") |c| writeChar(win, c, &col, status_bg, white);
    } else if (report.stats.warnings > 0) {
        writeChar(win, ' ', &col, status_bg, white);
        writeNumber(win, report.stats.warnings, &col, status_bg, white);
        for (" warn ") |c| writeChar(win, c, &col, status_bg, white);
    } else if (report.stats.tests_passed > 0) {
        for (" pass! ") |c| writeChar(win, c, &col, status_bg, white);
    } else {
        for (" OK ") |c| writeChar(win, c, &col, status_ok_bg, white);
    }
    col += 1; // Gap

    // 4. Mode indicator (terse/verbose)
    const mode_bg = if (view.expanded) mode_verbose_bg else mode_terse_bg;
    const mode_text: []const u8 = if (view.expanded) " verbose " else " terse ";
    for (mode_text) |c| writeChar(win, c, &col, mode_bg, white);
    col += 1; // Gap

    // 5. Watch status
    const watch_bg = if (watching) watch_on_bg else watch_off_bg;
    const watch_text: []const u8 = if (watching) " watching " else " paused ";
    for (watch_text) |c| writeChar(win, c, &col, watch_bg, white);
}

/// Render the main content area with build output.
/// Uses VisibleLineIterator to separate "which lines" from "how to draw".
fn renderContent(win: vaxis.Window, ctx: RenderContext) void {
    const content_height = win.height;
    if (content_height == 0) return;

    // Empty state
    if (ctx.report.lines_len == 0) {
        _ = printText(win, "Waiting for build output...", .{ .fg = colors.muted }, .{});
        return;
    }

    const text_buf = ctx.report.textBuf();
    var iter = VisibleLineIterator.init(ctx.report, ctx.view);
    var row: u16 = 0;
    var seen_test_fail: bool = false;

    while (iter.next()) |item| {
        if (row >= content_height) break;

        const line = item.line;

        // Selection highlighting
        const is_selected = line.item_index == ctx.view.selected_item and line.kind.isItemStart();
        const bg_color: vaxis.Color = if (is_selected) colors.selected_bg else .default;

        // Special rendering for test failure headers (Bacon-style badge)
        if (line.kind == .test_fail_header) {
            // Add blank line before 2nd+ test failures
            if (seen_test_fail and row < content_height) {
                row += 1;
            }
            seen_test_fail = true;
            const remaining_rows = content_height -| row;
            row += renderTestFailureLine(win, line.*, ctx.report, row, bg_color, item.line_index, remaining_rows);
            // Add blank line after
            if (row < content_height) {
                row += 1;
            }
            continue;
        }

        // Normal line rendering
        var text = line.getText(text_buf);
        const fg_color = getLineColor(line.kind, ctx.view.expanded);

        // In terse mode, clean up stack trace paths
        if (!ctx.view.expanded and line.kind == .note_location) {
            text = cleanStackTraceLine(text, ctx.project_root);
        }

        printContentLine(win, text, .{ .fg = fg_color, .bg = bg_color }, row);
        row += 1;

        // Visual separation after test summary
        if (line.kind == .test_summary and row < content_height) {
            row += 1;
        }
    }
}

/// Render the footer with help text and stats.
fn renderFooter(
    win: vaxis.Window,
    report: *const types.Report,
    view: *const types.ViewState,
) void {
    const visible = report.getVisibleCount(view.expanded);
    const total = report.lines_len;

    // Help text based on mode
    const help = switch (view.mode) {
        .normal => "? for help, q to quit",
        .searching => "enter to confirm, esc to cancel",
        .help => "q to close",
    };

    _ = printFmt(win, "{s}  |  {d}/{d}", .{ help, visible, total }, .{ .fg = colors.muted }, .{});
}

/// Get the display color for a line type.
fn getLineColor(kind: types.LineKind, expanded: bool) vaxis.Color {
    return switch (kind) {
        .error_location => colors.error_fg,
        .warning_location => colors.warning_fg,
        .note_location => colors.note_fg,
        .test_pass => colors.success_fg,
        .test_fail, .test_fail_header => colors.error_fg,
        .test_expected_value => colors.muted, // Will be rendered with special highlighting
        .test_summary => colors.muted,
        .source_line, .pointer_line, .blank => .default,
        // In expanded mode, show filtered content in muted color
        else => if (expanded) colors.muted else .default,
    };
}

/// Render a help overlay.
pub fn renderHelp(vx: *vaxis.Vaxis) void {
    const win = vx.window();
    const width = win.width;
    const height = win.height;

    // Center the help box
    const box_width: u16 = 50;
    const box_height: u16 = 15;
    const x: i17 = @intCast((width -| box_width) / 2);
    const y: i17 = @intCast((height -| box_height) / 2);

    const help_win = win.child(.{
        .x_off = x,
        .y_off = y,
        .width = box_width,
        .height = box_height,
    });

    // Clear the area
    help_win.fill(.{ .char = .{ .grapheme = " " }, .style = .{ .bg = colors.header_bg } });

    // Title
    _ = printText(help_win, " Vigil - Keyboard Shortcuts ", .{
        .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
        .bold = true,
        .bg = colors.header_bg,
    }, .{ .row_offset = 0 });

    // Help content
    const help_lines = [_][]const u8{
        "",
        "  j/k        Scroll down / up",
        "  g/G        Jump to top / bottom",
        "  n/N        Next / prev error",
        "",
        "  Space      Toggle terse / full",
        "  Enter      Open in $EDITOR",
        "",
        "  b/t/x      Switch to build / test / run",
        "  r          Rebuild current job",
        "  w          Toggle file watching",
        "",
        "  q          Quit",
    };

    for (help_lines, 0..) |line, i| {
        _ = printText(help_win, line, .{
            .fg = colors.muted,
            .bg = colors.header_bg,
        }, .{ .row_offset = @intCast(i + 1) });
    }
}

// =============================================================================
// Tests
// =============================================================================

test "VisibleLineIterator - basic iteration" {
    var report = types.Report.init();

    // Add some lines with text
    const text1 = try report.appendText("error line");
    try report.appendLine(.{
        .text_offset = text1.offset,
        .text_len = text1.len,
        .kind = .error_location,
        .stream = .stderr,
        .item_index = 0,
        .location = null,
    });

    const text2 = try report.appendText("source line");
    try report.appendLine(.{
        .text_offset = text2.offset,
        .text_len = text2.len,
        .kind = .source_line,
        .stream = .stderr,
        .item_index = 0,
        .location = null,
    });

    const view = types.ViewState.init();
    var iter = VisibleLineIterator.init(&report, &view);

    // Should get both lines
    const item1 = iter.next();
    try std.testing.expect(item1 != null);
    try std.testing.expectEqual(types.LineKind.error_location, item1.?.line.kind);

    const item2 = iter.next();
    try std.testing.expect(item2 != null);
    try std.testing.expectEqual(types.LineKind.source_line, item2.?.line.kind);

    // No more lines
    try std.testing.expect(iter.next() == null);
}

test "VisibleLineIterator - blank collapsing in terse mode" {
    var report = types.Report.init();

    // Add: error, blank, blank, source
    const text1 = try report.appendText("error line");
    try report.appendLine(.{
        .text_offset = text1.offset,
        .text_len = text1.len,
        .kind = .error_location,
        .stream = .stderr,
        .item_index = 0,
        .location = null,
    });

    // Two consecutive blanks
    try report.appendLine(.{ .text_offset = 0, .text_len = 0, .kind = .blank, .stream = .stderr, .item_index = 0, .location = null });
    try report.appendLine(.{ .text_offset = 0, .text_len = 0, .kind = .blank, .stream = .stderr, .item_index = 0, .location = null });

    const text2 = try report.appendText("source line");
    try report.appendLine(.{
        .text_offset = text2.offset,
        .text_len = text2.len,
        .kind = .source_line,
        .stream = .stderr,
        .item_index = 0,
        .location = null,
    });

    var view = types.ViewState.init();
    view.expanded = false; // Terse mode

    var iter = VisibleLineIterator.init(&report, &view);

    // Should get: error, ONE blank (collapsed), source
    try std.testing.expectEqual(types.LineKind.error_location, iter.next().?.line.kind);
    try std.testing.expectEqual(types.LineKind.blank, iter.next().?.line.kind);
    try std.testing.expectEqual(types.LineKind.source_line, iter.next().?.line.kind);
    try std.testing.expect(iter.next() == null);
}

test "VisibleLineIterator - scroll handling" {
    var report = types.Report.init();

    // Add 5 error lines
    var i: u16 = 0;
    while (i < 5) : (i += 1) {
        const text = try report.appendText("error");
        try report.appendLine(.{
            .text_offset = text.offset,
            .text_len = text.len,
            .kind = .error_location,
            .stream = .stderr,
            .item_index = 0,
            .location = null,
        });
    }

    var view = types.ViewState.init();
    view.scroll = 3; // Skip first 3

    var iter = VisibleLineIterator.init(&report, &view);

    // Should only get 2 lines (indices 3 and 4)
    const item1 = iter.next();
    try std.testing.expect(item1 != null);
    try std.testing.expectEqual(@as(u16, 3), item1.?.line_index);

    const item2 = iter.next();
    try std.testing.expect(item2 != null);
    try std.testing.expectEqual(@as(u16, 4), item2.?.line_index);

    try std.testing.expect(iter.next() == null);
}
