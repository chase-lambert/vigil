//! TUI rendering for Vigil.
//!
//! Handles all drawing to the terminal using libvaxis.
//! Organized into focused rendering functions for each UI component.

const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");

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

/// Render the complete UI.
pub fn render(
    vx: *vaxis.Vaxis,
    report: *const types.Report,
    view: *const types.ViewState,
    watching: bool,
    job_name: []const u8,
) void {
    const win = vx.window();
    win.clear();

    const height = win.height;
    const width = win.width;

    // Minimum size check
    if (height < 4 or width < 30) {
        _ = printText(win, "Terminal too small", .{ .fg = colors.muted }, .{});
        return;
    }

    // Layout: header (1) + content (height-2) + footer (1)
    const header_win = win.child(.{ .height = 1 });
    const content_win = win.child(.{
        .y_off = 1,
        .height = height -| 2,
    });
    const footer_win = win.child(.{
        .y_off = @intCast(height -| 1),
        .height = 1,
    });

    renderHeader(header_win, report, view, watching, job_name);
    renderContent(content_win, report, view);
    renderFooter(footer_win, report, view);
}

/// Render the header bar in Bacon style: project | job | status
/// Uses writeCell character-by-character like the libvaxis examples do.
fn renderHeader(
    win: vaxis.Window,
    report: *const types.Report,
    _: *const types.ViewState,
    watching: bool,
    job_name: []const u8,
) void {
    const Cell = vaxis.Cell;

    // Colors - softer palette inspired by Bacon
    const project_bg = vaxis.Color{ .rgb = .{ 0x88, 0x44, 0x88 } }; // Purple
    const job_bg = vaxis.Color{ .rgb = .{ 0x44, 0x88, 0x88 } }; // Teal
    const status_ok_bg = vaxis.Color{ .rgb = .{ 0x66, 0xcc, 0x66 } }; // Green
    const status_fail_bg = vaxis.Color{ .rgb = .{ 0xcc, 0x66, 0x66 } }; // Red
    const status_warn_bg = vaxis.Color{ .rgb = .{ 0xcc, 0xaa, 0x55 } }; // Orange
    const watch_on_bg = vaxis.Color{ .rgb = .{ 0x55, 0x77, 0x55 } }; // Muted green
    const watch_off_bg = vaxis.Color{ .rgb = .{ 0x77, 0x55, 0x55 } }; // Muted red
    const white = vaxis.Color{ .rgb = .{ 0xff, 0xff, 0xff } };

    var col: u16 = 0;

    // Helper: write a single character cell
    const writeChar = struct {
        fn f(w: vaxis.Window, c: u8, column: *u16, bg: vaxis.Color, fg: vaxis.Color) void {
            if (column.* >= w.width) return;
            // Create a static single-byte string for the grapheme
            const grapheme: []const u8 = switch (c) {
                ' ' => " ",
                '!' => "!",
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
                'a' => "a",
                'b' => "b",
                'c' => "c",
                'd' => "d",
                'e' => "e",
                'f' => "f",
                'g' => "g",
                'h' => "h",
                'i' => "i",
                'l' => "l",
                'n' => "n",
                'o' => "o",
                'p' => "p",
                'r' => "r",
                's' => "s",
                't' => "t",
                'u' => "u",
                'v' => "v",
                'w' => "w",
                'x' => "x",
                'K' => "K",
                'O' => "O",
                else => "?",
            };
            w.writeCell(column.*, 0, Cell{
                .char = .{ .grapheme = grapheme, .width = 1 },
                .style = .{ .bg = bg, .fg = fg, .bold = true },
            });
            column.* += 1;
        }
    }.f;

    // 1. Project name: " vigil "
    for (" vigil ") |c| writeChar(win, c, &col, project_bg, white);

    // 2. Job name: " build " / " test " / " run "
    writeChar(win, ' ', &col, job_bg, white);
    for (job_name) |c| writeChar(win, c, &col, job_bg, white);
    writeChar(win, ' ', &col, job_bg, white);

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
        // Write the number
        var num = report.stats.tests_failed;
        var digits: [8]u8 = undefined;
        var digit_count: u8 = 0;
        while (num > 0 or digit_count == 0) : (digit_count += 1) {
            digits[digit_count] = @intCast((num % 10) + '0');
            num /= 10;
        }
        var i: u8 = digit_count;
        while (i > 0) {
            i -= 1;
            writeChar(win, digits[i], &col, status_bg, white);
        }
        for (" fail ") |c| writeChar(win, c, &col, status_bg, white);
    } else if (report.stats.errors > 0) {
        writeChar(win, ' ', &col, status_bg, white);
        var num = report.stats.errors;
        var digits: [8]u8 = undefined;
        var digit_count: u8 = 0;
        while (num > 0 or digit_count == 0) : (digit_count += 1) {
            digits[digit_count] = @intCast((num % 10) + '0');
            num /= 10;
        }
        var i: u8 = digit_count;
        while (i > 0) {
            i -= 1;
            writeChar(win, digits[i], &col, status_bg, white);
        }
        for (" error ") |c| writeChar(win, c, &col, status_bg, white);
    } else if (report.stats.warnings > 0) {
        writeChar(win, ' ', &col, status_bg, white);
        var num = report.stats.warnings;
        var digits: [8]u8 = undefined;
        var digit_count: u8 = 0;
        while (num > 0 or digit_count == 0) : (digit_count += 1) {
            digits[digit_count] = @intCast((num % 10) + '0');
            num /= 10;
        }
        var i: u8 = digit_count;
        while (i > 0) {
            i -= 1;
            writeChar(win, digits[i], &col, status_bg, white);
        }
        for (" warn ") |c| writeChar(win, c, &col, status_bg, white);
    } else if (report.stats.tests_passed > 0) {
        for (" pass! ") |c| writeChar(win, c, &col, status_bg, white);
    } else {
        for (" OK ") |c| writeChar(win, c, &col, status_ok_bg, white);
    }

    // 4. Watch status
    const watch_bg = if (watching) watch_on_bg else watch_off_bg;
    const watch_text: []const u8 = if (watching) " watching " else " paused ";
    for (watch_text) |c| writeChar(win, c, &col, watch_bg, white);
}

/// Render the main content area with build output.
fn renderContent(
    win: vaxis.Window,
    report: *const types.Report,
    view: *const types.ViewState,
) void {
    const content_height = win.height;
    if (content_height == 0) return;

    const text_buf = report.textBuf();
    var row: u16 = 0;
    var prev_blank = false;
    var lines_skipped: usize = 0;

    for (report.lines()) |line| {
        const should_show = view.expanded or line.kind.shownInTerse();
        if (!should_show) continue;

        // Collapse consecutive blanks in terse mode
        if (!view.expanded and line.kind == .blank) {
            if (prev_blank) continue;
            prev_blank = true;
        } else {
            prev_blank = false;
        }

        // Handle scrolling
        if (lines_skipped < view.scroll) {
            lines_skipped += 1;
            continue;
        }

        // Stop if we've filled the screen
        if (row >= content_height) break;

        // Render the line (get text from shared buffer)
        const text = line.getText(text_buf);
        const fg_color = getLineColor(line.kind, view.expanded);

        // Highlight selected item
        const is_selected = line.item_index == view.selected_item and
            line.kind.isItemStart();
        const bg_color: vaxis.Color = if (is_selected)
            colors.selected_bg
        else
            .default;

        _ = printText(win, text, .{ .fg = fg_color, .bg = bg_color }, .{ .row_offset = row });

        row += 1;
    }

    // Show empty state if no lines
    if (report.lines_len == 0) {
        _ = printText(win, "Waiting for build output...", .{ .fg = colors.muted }, .{});
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
