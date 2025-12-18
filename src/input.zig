//! Input handling for Vigil.
//!
//! Processes keyboard events and maps them to application actions.
//! Supports different keybindings for different modes.

const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const assert = std.debug.assert;

/// Actions that can result from input processing.
pub const Action = enum {
    none,
    quit,
    toggle_expanded,
    toggle_watch,
    toggle_wrap,
    scroll_up,
    scroll_down,
    scroll_page_up,
    scroll_page_down,
    scroll_top,
    scroll_bottom,
    start_search,
    next_match,
    prev_match,
    cancel,
    confirm,
    show_help,
    hide_help,
    select_build,
    select_test,
};

pub fn handleNormalMode(key: vaxis.Key) Action {
    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
    if (key.matches('?', .{}) or key.matches('h', .{})) return .show_help;
    if (key.matches(' ', .{}) or key.matches(vaxis.Key.tab, .{})) return .toggle_expanded;
    if (key.matches('p', .{})) return .toggle_watch;
    if (key.matches('w', .{})) return .toggle_wrap;

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

    if (key.matches('/', .{})) return .start_search;
    if (key.matches('n', .{})) return .next_match;
    if (key.matches('N', .{}) or key.matches('n', .{ .shift = true })) return .prev_match;

    const cp = key.codepoint;
    if (cp == 'b') return .select_build;
    if (cp == 't') return .select_test;

    return .none;
}

pub fn handleHelpMode(key: vaxis.Key) Action {
    if (key.matches('q', .{}) or
        key.matches(vaxis.Key.escape, .{}) or
        key.matches('?', .{}) or
        key.matches('h', .{}))
    {
        return .hide_help;
    }
    return .none;
}

pub fn handleSearchMode(key: vaxis.Key, search_buf: *[types.MAX_SEARCH_LEN]u8, search_len: *u8) Action {
    // Search length starts within bounds
    assert(search_len.* <= types.MAX_SEARCH_LEN);

    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.enter, .{})) return .confirm;

    if (key.matches(vaxis.Key.backspace, .{})) {
        if (search_len.* > 0) search_len.* -= 1;
        return .none;
    }

    const cp = key.codepoint;
    if (cp >= 32 and cp < 127) {
        if (search_len.* < types.MAX_SEARCH_LEN) {
            search_buf[search_len.*] = @intCast(cp);
            search_len.* += 1;
        }
    }

    // Search length stays within bounds
    assert(search_len.* <= types.MAX_SEARCH_LEN);
    return .none;
}

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
    };
}

// =============================================================================
// Tests
// =============================================================================

/// Helper to create a key for testing
fn testKey(codepoint: u21, mods: vaxis.Key.Modifiers) vaxis.Key {
    return .{ .codepoint = codepoint, .mods = mods };
}

test "handleNormalMode - quit keys" {
    // 'q' quits
    try std.testing.expectEqual(Action.quit, handleNormalMode(testKey('q', .{})));
    // Ctrl+C quits
    try std.testing.expectEqual(Action.quit, handleNormalMode(testKey('c', .{ .ctrl = true })));
    // Just 'c' without ctrl does nothing
    try std.testing.expectEqual(Action.none, handleNormalMode(testKey('c', .{})));
}

test "handleNormalMode - navigation keys" {
    // Scroll
    try std.testing.expectEqual(Action.scroll_down, handleNormalMode(testKey('j', .{})));
    try std.testing.expectEqual(Action.scroll_up, handleNormalMode(testKey('k', .{})));
    try std.testing.expectEqual(Action.scroll_down, handleNormalMode(testKey(vaxis.Key.down, .{})));
    try std.testing.expectEqual(Action.scroll_up, handleNormalMode(testKey(vaxis.Key.up, .{})));

    // Page scroll
    try std.testing.expectEqual(Action.scroll_page_down, handleNormalMode(testKey('d', .{ .ctrl = true })));
    try std.testing.expectEqual(Action.scroll_page_up, handleNormalMode(testKey('u', .{ .ctrl = true })));

    // Jump to top/bottom
    try std.testing.expectEqual(Action.scroll_top, handleNormalMode(testKey('g', .{})));
    try std.testing.expectEqual(Action.scroll_bottom, handleNormalMode(testKey('G', .{})));
}

test "handleNormalMode - actions" {
    // Toggle view
    try std.testing.expectEqual(Action.toggle_expanded, handleNormalMode(testKey(' ', .{})));
    try std.testing.expectEqual(Action.toggle_expanded, handleNormalMode(testKey(vaxis.Key.tab, .{})));
    // Toggle watch (pause)
    try std.testing.expectEqual(Action.toggle_watch, handleNormalMode(testKey('p', .{})));
    // Help
    try std.testing.expectEqual(Action.show_help, handleNormalMode(testKey('?', .{})));
    try std.testing.expectEqual(Action.show_help, handleNormalMode(testKey('h', .{})));
    // Search
    try std.testing.expectEqual(Action.start_search, handleNormalMode(testKey('/', .{})));
}

test "handleNormalMode - job selection" {
    try std.testing.expectEqual(Action.select_build, handleNormalMode(testKey('b', .{})));
    try std.testing.expectEqual(Action.select_test, handleNormalMode(testKey('t', .{})));
}

test "handleNormalMode - unmapped keys return none" {
    // Random unmapped keys should return .none
    try std.testing.expectEqual(Action.none, handleNormalMode(testKey('z', .{})));
    try std.testing.expectEqual(Action.none, handleNormalMode(testKey('1', .{})));
    try std.testing.expectEqual(Action.none, handleNormalMode(testKey('!', .{})));
}

test "handleHelpMode - exit keys" {
    try std.testing.expectEqual(Action.hide_help, handleHelpMode(testKey('q', .{})));
    try std.testing.expectEqual(Action.hide_help, handleHelpMode(testKey(vaxis.Key.escape, .{})));
    try std.testing.expectEqual(Action.hide_help, handleHelpMode(testKey('?', .{})));
    try std.testing.expectEqual(Action.hide_help, handleHelpMode(testKey('h', .{})));
    // Other keys do nothing in help mode
    try std.testing.expectEqual(Action.none, handleHelpMode(testKey('j', .{})));
    try std.testing.expectEqual(Action.none, handleHelpMode(testKey('r', .{})));
}

test "handleSearchMode - character input" {
    var buf: [types.MAX_SEARCH_LEN]u8 = undefined;
    var len: u8 = 0;

    // Type 'a'
    _ = handleSearchMode(testKey('a', .{}), &buf, &len);
    try std.testing.expectEqual(@as(u8, 1), len);
    try std.testing.expectEqual(@as(u8, 'a'), buf[0]);

    // Type 'b'
    _ = handleSearchMode(testKey('b', .{}), &buf, &len);
    try std.testing.expectEqual(@as(u8, 2), len);
    try std.testing.expectEqualStrings("ab", buf[0..len]);
}

test "handleSearchMode - backspace" {
    var buf: [types.MAX_SEARCH_LEN]u8 = undefined;
    var len: u8 = 2;
    buf[0] = 'a';
    buf[1] = 'b';

    // Backspace removes last char
    _ = handleSearchMode(testKey(vaxis.Key.backspace, .{}), &buf, &len);
    try std.testing.expectEqual(@as(u8, 1), len);

    // Backspace again
    _ = handleSearchMode(testKey(vaxis.Key.backspace, .{}), &buf, &len);
    try std.testing.expectEqual(@as(u8, 0), len);

    // Backspace at empty does nothing (no underflow)
    _ = handleSearchMode(testKey(vaxis.Key.backspace, .{}), &buf, &len);
    try std.testing.expectEqual(@as(u8, 0), len);
}

test "handleSearchMode - escape and enter" {
    var buf: [types.MAX_SEARCH_LEN]u8 = undefined;
    var len: u8 = 0;

    try std.testing.expectEqual(Action.cancel, handleSearchMode(testKey(vaxis.Key.escape, .{}), &buf, &len));
    try std.testing.expectEqual(Action.confirm, handleSearchMode(testKey(vaxis.Key.enter, .{}), &buf, &len));
}

test "handleKey - mode dispatch" {
    var buf: [types.MAX_SEARCH_LEN]u8 = undefined;
    var len: u8 = 0;

    // In normal mode, 'q' quits
    try std.testing.expectEqual(Action.quit, handleKey(testKey('q', .{}), .normal, &buf, &len));

    // In help mode, 'q' hides help
    try std.testing.expectEqual(Action.hide_help, handleKey(testKey('q', .{}), .help, &buf, &len));

    // In search mode, 'q' types 'q'
    const action = handleKey(testKey('q', .{}), .searching, &buf, &len);
    try std.testing.expectEqual(Action.none, action);
    try std.testing.expectEqual(@as(u8, 1), len);
    try std.testing.expectEqual(@as(u8, 'q'), buf[0]);
}
