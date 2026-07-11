//! File system watching for automatic rebuilds.
//!
//! Currently implements simple polling-based watching.

const std = @import("std");
const types = @import("types.zig");
const assert = std.debug.assert;

/// File watcher using simple polling.
///
/// Checks file modification times periodically to detect changes.
/// Always watches current directory "." recursively.
/// This is less efficient than OS-native watching but works everywhere
/// and is simple to implement correctly.
pub const Watcher = struct {
    /// Configuration
    config: types.WatchConfig,
    /// Last check timestamp (monotonic clock)
    last_check: std.Io.Timestamp,
    /// Last known modification time for watched directory
    mtime: std.Io.Timestamp,
    /// Whether watching is currently active
    active: bool,

    pub fn init(config: types.WatchConfig) Watcher {
        const self = Watcher{
            .config = config,
            .last_check = std.Io.Timestamp.zero,
            .mtime = std.Io.Timestamp.zero,
            .active = config.enabled,
        };
        assert(self.last_check.nanoseconds == 0);
        return self;
    }

    /// Check if any watched files have changed.
    /// Returns true if a rebuild should be triggered.
    ///
    /// This function is meant to be called from the main event loop.
    /// It implements debouncing internally.
    pub fn checkForChanges(self: *Watcher, io: std.Io) bool {
        if (!self.active) return false;

        const now = std.Io.Timestamp.now(io, .awake);
        const elapsed = self.last_check.durationTo(now);
        const debounce = std.Io.Duration.fromMilliseconds(self.config.debounce_ms);

        // Debounce: don't check too frequently
        if (elapsed.nanoseconds < debounce.nanoseconds) {
            return false;
        }
        self.last_check = now;

        // Check current directory recursively
        const new_mtime = getPathMtime(io, ".");
        if (new_mtime.nanoseconds > self.mtime.nanoseconds) {
            self.mtime = new_mtime;
            return true;
        }
        return false;
    }

    /// Snapshot current modification time.
    /// Call this after a build completes to avoid immediate re-trigger.
    pub fn snapshot(self: *Watcher, io: std.Io) void {
        self.mtime = getPathMtime(io, ".");
        self.last_check = std.Io.Timestamp.now(io, .awake);
    }

    /// Enable or disable watching.
    /// Only snapshots on first activation (when last_check == 0).
    /// On resume, skips snapshot so files changed while paused are detected.
    fn setActive(self: *Watcher, io: std.Io, active: bool) void {
        self.active = active;
        if (active and self.last_check.nanoseconds == 0) {
            self.snapshot(io);
        }
    }

    pub fn toggle(self: *Watcher, io: std.Io) void {
        self.setActive(io, !self.active);
    }
};

/// Maximum depth for directory watching
const MAX_WATCH_DEPTH: usize = 16;

/// Entry in the directory traversal stack
const DirStackEntry = struct {
    dir: std.Io.Dir,
    iter: std.Io.Dir.Iterator,
};

/// Get the modification time of a path.
/// For directories, iteratively finds the newest mtime of any file within.
/// Uses explicit stack instead of recursion.
fn getPathMtime(io: std.Io, path: []const u8) std.Io.Timestamp {
    const cwd = std.Io.Dir.cwd();

    // Try to stat as file first (skip if it's a directory)
    if (cwd.statFile(io, path, .{})) |stat| {
        if (stat.kind != .directory) {
            return stat.mtime;
        }
    } else |_| {}

    // Try as directory - use explicit stack for traversal (no recursion)
    var stack_buf: [MAX_WATCH_DEPTH]DirStackEntry = undefined;
    var stack_len: usize = 0;

    // Push initial directory
    var root_dir = cwd.openDir(io, path, .{ .iterate = true }) catch return std.Io.Timestamp.zero;
    stack_buf[0] = .{ .dir = root_dir, .iter = root_dir.iterate() };
    stack_len = 1;

    var newest: std.Io.Timestamp = std.Io.Timestamp.zero;

    // Process stack iteratively
    while (stack_len > 0) {
        const top = &stack_buf[stack_len - 1];

        if (top.iter.next(io) catch null) |entry| {
            // Skip hidden files and irrelevant directories
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            if (std.mem.eql(u8, entry.name, "zig-out")) continue;
            if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
            if (std.mem.eql(u8, entry.name, "node_modules")) continue;
            if (std.mem.eql(u8, entry.name, "vendor")) continue;
            if (std.mem.eql(u8, entry.name, "third_party")) continue;
            if (std.mem.eql(u8, entry.name, "dist")) continue;

            switch (entry.kind) {
                .file => {
                    if (top.dir.statFile(io, entry.name, .{}) catch null) |stat| {
                        if (stat.mtime.nanoseconds > newest.nanoseconds) {
                            newest = stat.mtime;
                        }
                    }
                },
                .directory => {
                    // Push subdirectory onto stack if we have room
                    if (stack_len < MAX_WATCH_DEPTH) {
                        if (top.dir.openDir(io, entry.name, .{ .iterate = true })) |sub_dir| {
                            stack_buf[stack_len] = .{ .dir = sub_dir, .iter = sub_dir.iterate() };
                            stack_len += 1;
                            assert(stack_len <= MAX_WATCH_DEPTH);
                        } else |_| {}
                    }
                },
                else => {},
            }
        } else {
            // Directory exhausted, pop from stack
            top.dir.close(io);
            stack_len -= 1;
        }
    }

    return newest;
}

// =============================================================================
// Tests
// =============================================================================

test "Watcher.init" {
    const config = types.WatchConfig.init();
    const watcher = Watcher.init(config);
    try std.testing.expect(watcher.active);
}
