//! Process execution and output capture.
//!
//! Handles spawning build commands and capturing their output.
//! Currently uses blocking execution; future versions may use
//! async/polling for real-time output streaming.

const std = @import("std");
const types = @import("types.zig");

/// Result of running a build command.
pub const BuildResult = struct {
    /// Combined stdout + stderr output
    output: []const u8,
    /// Exit code (null if killed/crashed)
    exit_code: ?u8,
    /// Whether the process was killed
    was_killed: bool,

    pub fn deinit(self: *BuildResult, alloc: std.mem.Allocator) void {
        if (self.output.len > 0) {
            alloc.free(self.output);
        }
        self.* = undefined;
    }
};

/// Run a build command and capture its output.
///
/// Arguments:
/// - alloc: Allocator for output buffer
/// - args: Command arguments (e.g., ["zig", "build", "test"])
///
/// Returns the combined stderr (preferred) or stdout output.
pub fn runBuild(alloc: std.mem.Allocator, args: []const []const u8) !BuildResult {
    // Precondition: must have at least one argument
    std.debug.assert(args.len > 0);

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = args,
        .max_output_bytes = types.MAX_OUTPUT_SIZE,
    });

    // Prefer stderr (where errors go), fall back to stdout
    var output: []const u8 = undefined;

    if (result.stderr.len > 0) {
        output = result.stderr;
        if (result.stdout.len > 0) {
            alloc.free(result.stdout);
        }
    } else if (result.stdout.len > 0) {
        output = result.stdout;
        if (result.stderr.len > 0) {
            alloc.free(result.stderr);
        }
    } else {
        // Both empty - use empty slice
        output = "";
    }

    const exit_code: ?u8 = switch (result.term) {
        .Exited => |code| code,
        .Signal, .Stopped, .Unknown => null,
    };

    return BuildResult{
        .output = output,
        .exit_code = exit_code,
        .was_killed = result.term != .Exited,
    };
}

/// Default build command when none specified.
pub fn defaultBuildArgs() []const []const u8 {
    return &[_][]const u8{ "zig", "build" };
}

// =============================================================================
// Tests
// =============================================================================

test "defaultBuildArgs" {
    const args = defaultBuildArgs();
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("zig", args[0]);
    try std.testing.expectEqualStrings("build", args[1]);
}
