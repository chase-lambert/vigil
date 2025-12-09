//! Input handling for Vigil.
//!
//! Processes keyboard events and maps them to application actions.
//! Supports different keybindings for different modes.

const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");

/// Actions that can result from input processing.
pub const Action = union(enum) {
    none,
    quit,
    rebuild,
    toggle_expanded,
    toggle_watch,
    scroll_up,
    scroll_down,
    scroll_page_up,
    scroll_page_down,
    scroll_top,
    scroll_bottom,
    next_error,
    prev_error,
    open_in_editor,
    start_search,
    cancel,
    confirm,
    show_help,
    hide_help,
    select_job: u8, // Job index 0-9
};

/// Process a key event in normal mode.
pub fn handleNormalMode(key: vaxis.Key) Action {
    // Quit
    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
        return .quit;
    }

    // Help
    if (key.matches('?', .{}) or key.matches('h', .{})) {
        return .show_help;
    }

    // Rebuild
    if (key.matches('r', .{})) {
        return .rebuild;
    }

    // Toggle view mode
    if (key.matches(' ', .{}) or key.matches(vaxis.Key.tab, .{})) {
        return .toggle_expanded;
    }

    // Toggle watching
    if (key.matches('w', .{})) {
        return .toggle_watch;
    }

    // Scrolling
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        return .scroll_down;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        return .scroll_up;
    }
    if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
        return .scroll_page_down;
    }
    if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
        return .scroll_page_up;
    }
    if (key.matches('g', .{})) {
        return .scroll_top;
    }
    if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
        return .scroll_bottom;
    }

    // Error navigation
    if (key.matches('n', .{})) {
        return .next_error;
    }
    if (key.matches('N', .{}) or key.matches('n', .{ .shift = true })) {
        return .prev_error;
    }

    // Open in editor
    if (key.matches(vaxis.Key.enter, .{})) {
        return .open_in_editor;
    }

    // Search
    if (key.matches('/', .{})) {
        return .start_search;
    }

    // Job shortcuts
    const cp = key.codepoint;
    if (cp == 't') return .{ .select_job = 1 }; // test
    if (cp == 'b') return .{ .select_job = 0 }; // build
    if (cp == 'x') return .{ .select_job = 2 }; // run

    return .none;
}

/// Process a key event in help mode.
pub fn handleHelpMode(key: vaxis.Key) Action {
    if (key.matches('q', .{}) or
        key.matches(vaxis.Key.escape, .{}) or
        key.matches('?', .{}))
    {
        return .hide_help;
    }
    return .none;
}

/// Process a key event in search mode.
pub fn handleSearchMode(key: vaxis.Key, search_buf: *[types.MAX_SEARCH_LEN]u8, search_len: *u8) Action {
    // Cancel
    if (key.matches(vaxis.Key.escape, .{})) {
        return .cancel;
    }

    // Confirm
    if (key.matches(vaxis.Key.enter, .{})) {
        return .confirm;
    }

    // Backspace
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (search_len.* > 0) {
            search_len.* -= 1;
        }
        return .none;
    }

    // Character input
    const cp = key.codepoint;
    if (cp >= 32 and cp < 127) { // Printable ASCII
        if (search_len.* < types.MAX_SEARCH_LEN) {
            search_buf[search_len.*] = @intCast(cp);
            search_len.* += 1;
        }
    }

    return .none;
}

/// Process a key event in job select mode.
pub fn handleJobSelectMode(key: vaxis.Key) Action {
    if (key.matches(vaxis.Key.escape, .{})) {
        return .cancel;
    }

    const cp = key.codepoint;
    if (cp >= '1' and cp <= '9') {
        return .{ .select_job = @intCast(cp - '1') };
    }

    return .none;
}

/// Dispatch to the appropriate handler based on current mode.
pub fn handleKey(
    key: vaxis.Key,
    mode: types.ViewState.Mode,
    search_buf: *[types.MAX_SEARCH_LEN]u8,
    search_len: *u8,
) Action {
    return switch (mode) {
        .normal => handleNormalMode(key),
        .help => handleHelpMode(key),
        .searching => handleSearchMode(key, search_buf, search_len),
        .job_select => handleJobSelectMode(key),
    };
}
