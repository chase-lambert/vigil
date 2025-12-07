//! File system watching for automatic rebuilds.
//!
//! Currently implements simple polling-based watching.
//! Future versions may use inotify (Linux), FSEvents (macOS),
//! or ReadDirectoryChangesW (Windows) for efficiency.

const std = @import("std");
const types = @import("types.zig");

/// File watcher using simple polling.
///
/// Checks file modification times periodically to detect changes.
/// This is less efficient than OS-native watching but works everywhere
/// and is simple to implement correctly.
pub const Watcher = struct {
    /// Configuration
    config: types.WatchConfig,
    /// Last check timestamp (nanoseconds)
    last_check: i128,
    /// Last known modification times
    mtimes: [types.MAX_WATCH_PATHS]i128,
    /// Whether watching is currently active
    active: bool,

    pub fn init(config: types.WatchConfig) Watcher {
        return .{
            .config = config,
            .last_check = 0,
            .mtimes = [_]i128{0} ** types.MAX_WATCH_PATHS,
            .active = config.enabled,
        };
    }

    /// Check if any watched files have changed.
    /// Returns true if a rebuild should be triggered.
    ///
    /// This function is meant to be called from the main event loop.
    /// It implements debouncing internally.
    pub fn checkForChanges(self: *Watcher) bool {
        if (!self.active) return false;

        const now = std.time.nanoTimestamp();
        const debounce_ns = @as(i128, self.config.debounce_ms) * std.time.ns_per_ms;

        // Debounce: don't check too frequently
        if (now - self.last_check < debounce_ns) {
            return false;
        }
        self.last_check = now;

        // Check each watched path
        var changed = false;
        var i: u8 = 0;
        while (i < self.config.paths_count) : (i += 1) {
            const path = self.config.getPath(i);
            const new_mtime = getPathMtime(path);

            if (new_mtime > self.mtimes[i]) {
                self.mtimes[i] = new_mtime;
                changed = true;
            }
        }

        return changed;
    }

    /// Initialize modification times for all watched paths.
    /// Call this after a build completes to avoid immediate re-trigger.
    pub fn snapshot(self: *Watcher) void {
        var i: u8 = 0;
        while (i < self.config.paths_count) : (i += 1) {
            const path = self.config.getPath(i);
            self.mtimes[i] = getPathMtime(path);
        }
        self.last_check = std.time.nanoTimestamp();
    }

    /// Enable or disable watching.
    pub fn setActive(self: *Watcher, active: bool) void {
        self.active = active;
        if (active) {
            self.snapshot();
        }
    }

    /// Toggle watching on/off.
    pub fn toggle(self: *Watcher) void {
        self.setActive(!self.active);
    }
};

/// Get the modification time of a path.
/// For directories, returns the newest mtime of any file within (non-recursive for now).
fn getPathMtime(path: []const u8) i128 {
    const cwd = std.fs.cwd();

    // Try to stat as file first
    if (cwd.statFile(path)) |stat| {
        return stat.mtime;
    } else |_| {}

    // Try as directory
    var dir = cwd.openDir(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var newest: i128 = 0;
    var iter = dir.iterate();

    while (iter.next() catch null) |entry| {
        // Skip hidden files and common ignore patterns
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;

        // For files, check mtime
        if (entry.kind == .file) {
            if (dir.statFile(entry.name)) |stat| {
                if (stat.mtime > newest) {
                    newest = stat.mtime;
                }
            } else |_| {}
        }

        // TODO: For directories, recurse (with depth limit)
    }

    return newest;
}

// =============================================================================
// Future: Native Watchers
// =============================================================================

// TODO: Implement platform-native watchers for better efficiency:
//
// Linux: inotify
// - IN_MODIFY, IN_CREATE, IN_DELETE, IN_MOVED_FROM, IN_MOVED_TO
//
// macOS: FSEvents or kqueue
// - FSEventStreamCreate with kFSEventStreamCreateFlagFileEvents
//
// Windows: ReadDirectoryChangesW
// - FILE_NOTIFY_CHANGE_LAST_WRITE, FILE_NOTIFY_CHANGE_FILE_NAME

// =============================================================================
// Tests
// =============================================================================

test "Watcher.init" {
    const config = types.WatchConfig.init();
    const watcher = Watcher.init(config);
    try std.testing.expect(watcher.active);
}
