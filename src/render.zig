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
};

/// Helper to print a single text segment with style
fn printText(win: vaxis.Window, text: []const u8, style: vaxis.Cell.Style, opts: vaxis.Window.PrintOptions) vaxis.Window.PrintResult {
    return win.print(&.{.{ .text = text, .style = style }}, opts);
}

/// Helper to format and print (uses a static buffer - TigerStyle)
fn printFmt(win: vaxis.Window, comptime fmt: []const u8, args: anytype, style: vaxis.Cell.Style, opts: vaxis.Window.PrintOptions) vaxis.Window.PrintResult {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return .{ .col = 0, .row = 0, .overflow = true };
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

/// Render the header bar with status badges.
fn renderHeader(
    win: vaxis.Window,
    report: *const types.Report,
    view: *const types.ViewState,
    watching: bool,
    job_name: []const u8,
) void {
    var col: u16 = 0;

    // Mode badge
    const mode_text = if (view.expanded) " FULL " else " TERSE ";
    const mode_bg: vaxis.Color = if (view.expanded)
        .{ .rgb = .{ 0x44, 0x44, 0x88 } }
    else
        .{ .rgb = .{ 0x44, 0x88, 0x44 } };

    var result = printText(win, mode_text, .{
        .bg = mode_bg,
        .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
        .bold = true,
    }, .{ .col_offset = col });
    col = result.col + 1;

    // Watch indicator - only show when active
    if (watching) {
        result = printText(win, "watching ", .{ .fg = colors.success_fg }, .{ .col_offset = col });
        col = result.col;
    }

    // Job name
    result = printText(win, job_name, .{
        .fg = colors.note_fg,
        .bold = true,
    }, .{ .col_offset = col });
    col = result.col + 1;

    // Error count badge
    if (report.stats.errors > 0) {
        const suffix: []const u8 = if (report.stats.errors == 1) " error " else " errors ";
        result = printFmt(win, " {d}{s}", .{ report.stats.errors, suffix }, .{
            .bg = .{ .rgb = .{ 0xcc, 0x44, 0x44 } },
            .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
            .bold = true,
        }, .{ .col_offset = col });
        col = result.col + 1;
    }

    // Warning count badge
    if (report.stats.warnings > 0) {
        const suffix: []const u8 = if (report.stats.warnings == 1) " warning " else " warnings ";
        result = printFmt(win, " {d}{s}", .{ report.stats.warnings, suffix }, .{
            .bg = .{ .rgb = .{ 0xcc, 0x88, 0x22 } },
            .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
            .bold = true,
        }, .{ .col_offset = col });
        col = result.col + 1;
    }

    // Test results
    if (report.stats.tests_passed > 0 or report.stats.tests_failed > 0) {
        if (report.stats.tests_failed > 0) {
            result = printFmt(win, " {d} failed ", .{report.stats.tests_failed}, .{
                .bg = .{ .rgb = .{ 0xcc, 0x44, 0x44 } },
                .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
            }, .{ .col_offset = col });
            col = result.col;
        }
        if (report.stats.tests_passed > 0) {
            result = printFmt(win, " {d} passed ", .{report.stats.tests_passed}, .{
                .bg = colors.success_bg,
                .fg = colors.success_fg,
            }, .{ .col_offset = col });
            col = result.col;
        }
    }

    // Success message if clean build
    if (report.stats.isSuccess() and report.lines_len > 0) {
        _ = printText(win, " OK ", .{
            .bg = colors.success_bg,
            .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
            .bold = true,
        }, .{ .col_offset = col });
    }
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
        .test_fail => colors.error_fg,
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
