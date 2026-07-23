//! Vigil - A clean, fast build watcher for Zig
//!
//! Entry point and argument parsing.

const std = @import("std");
const App = @import("app.zig").App;
const types = @import("types.zig");

/// Pure incremental argument classification.
///
/// Processes one argument at a time, maintaining call-site state so the
/// iterator need not be pre-collected into a capped array. `--help`/`-v`
/// are recognized at any position. `test` selects test mode only while the
/// command is exactly `zig build` (no passthrough args yet); later/repeated
/// `test` tokens are silently ignored.
///
/// Returns: `.help`, `.version`, `.is_test`, `.passthrough_args` (borrows
/// arg slices) and `.passthrough_len`. Passthrough accumulation stops at
/// the capacity implied by the already-established base entries and the
/// optional `test` entry.
pub const ArgClass = struct {
    help: bool = false,
    version: bool = false,
    is_test: bool = false,
    passthrough_args: [types.MAX_CMD_ARGS][]const u8 = undefined,
    passthrough_len: usize = 0,

    /// Maximum passthrough slots given current flags.
    /// 2 base ("zig", "build") + optional "test" use MAX_CMD_ARGS slots.
    fn passthroughCapacity(self: ArgClass) usize {
        const base: usize = 2;
        const maybe_test: usize = @intFromBool(self.is_test);
        if (base + maybe_test >= types.MAX_CMD_ARGS) return 0;
        return types.MAX_CMD_ARGS - (base + maybe_test);
    }

    /// Feed one post-argv[0] argument. Returns true if processing should stop
    /// (help/version was requested).
    pub fn feed(self: *ArgClass, arg: []const u8) bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            self.help = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            self.version = true;
            return true;
        }
        // "test" selects test mode only while command is still "zig build"
        // (no passthrough args yet and test not already selected).
        // Any later/repeated "test" token is silently ignored.
        if (std.mem.eql(u8, arg, "test")) {
            if (!self.is_test and self.passthrough_len == 0) {
                self.is_test = true;
            }
            return false;
        }
        // Accumulate passthrough up to the capacity
        const cap = self.passthroughCapacity();
        if (self.passthrough_len < cap) {
            self.passthrough_args[self.passthrough_len] = arg;
            self.passthrough_len += 1;
        }
        return false;
    }
};

pub fn main(init: std.process.Init) !void {
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iter.deinit();

    var classified: ArgClass = .{};
    _ = args_iter.next(); // drop program name

    while (args_iter.next()) |arg| {
        if (classified.feed(arg)) break; // stop on help/version
    }

    if (classified.help) {
        printHelp();
        return;
    }
    if (classified.version) {
        printVersion();
        return;
    }

    // Build argument list for the child process (capped at MAX_CMD_ARGS).
    var build_args_buf: [types.MAX_CMD_ARGS][]const u8 = undefined;
    var build_args_len: usize = 0;

    build_args_buf[build_args_len] = "zig";
    build_args_len += 1;
    build_args_buf[build_args_len] = "build";
    build_args_len += 1;

    var job_name: []const u8 = "build";

    if (classified.is_test) {
        job_name = "test";
        build_args_buf[build_args_len] = "test";
        build_args_len += 1;
    }

    // Add passthrough args (already capped by feed)
    for (classified.passthrough_args[0..classified.passthrough_len]) |p_arg| {
        if (build_args_len < types.MAX_CMD_ARGS) {
            build_args_buf[build_args_len] = p_arg;
            build_args_len += 1;
        }
    }

    var app = try App.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();

    try app.setBuildArgs(build_args_buf[0..build_args_len]);
    app.setJobName(job_name);

    try app.run();
}

fn printHelp() void {
    const help =
        \\Vigil - A clean, fast build watcher for Zig
        \\
        \\USAGE:
        \\    vigil [COMMAND] [OPTIONS]
        \\
        \\COMMANDS:
        \\    (none)     Run 'zig build' (default)
        \\    test       Run 'zig build test'
        \\
        \\OPTIONS:
        \\    -h, --help          Show this help
        \\    -v, --version       Show version
        \\
        \\    All other options are passed through to 'zig build'.
        \\
        \\EXAMPLES:
        \\    vigil                           # Watch project, run 'zig build'
        \\    vigil test                      # Watch project, run tests
        \\    vigil -Doptimize=ReleaseFast    # Pass options to zig build
        \\
        \\Note: -D options are project-specific (defined in build.zig).
        \\
        \\KEYBINDINGS:
        \\    j/k     Scroll down/up
        \\    g/G     Jump to top/bottom
        \\    Space   Toggle terse/full view
        \\    w       Toggle line wrap
        \\    b/t     Switch to build/test job
        \\    p       Pause/resume watching
        \\    q       Quit
        \\    ?       Show help
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn printVersion() void {
    std.debug.print("vigil 1.0.0\n", .{});
}

// =============================================================================
// Tests
// =============================================================================

test "classifyArgs - help flag" {
    var c: ArgClass = .{};
    _ = c.feed("--help");
    try std.testing.expect(c.help);
}

test "classifyArgs - version flag" {
    var c: ArgClass = .{};
    _ = c.feed("-v");
    try std.testing.expect(c.version);
}

test "classifyArgs - test mode" {
    var c: ArgClass = .{};
    _ = c.feed("test");
    try std.testing.expect(c.is_test);
    try std.testing.expectEqual(@as(usize, 0), c.passthrough_len);
}

test "classifyArgs - test with passthrough" {
    var c: ArgClass = .{};
    _ = c.feed("test");
    _ = c.feed("-Dtest-filter=foo");
    try std.testing.expect(c.is_test);
    try std.testing.expectEqual(@as(usize, 1), c.passthrough_len);
    try std.testing.expectEqualStrings("-Dtest-filter=foo", c.passthrough_args[0]);
}

test "classifyArgs - test after passthrough is silently ignored" {
    // "test" after other args does NOT become passthrough; it is dropped.
    var c: ArgClass = .{};
    _ = c.feed("-Dfoo=bar");
    _ = c.feed("test");
    try std.testing.expect(!c.is_test);
    try std.testing.expectEqual(@as(usize, 1), c.passthrough_len);
    try std.testing.expectEqualStrings("-Dfoo=bar", c.passthrough_args[0]);
}

test "classifyArgs - repeated test token silently ignored" {
    // Only the first "test" enables test mode; second is dropped.
    var c: ArgClass = .{};
    _ = c.feed("test");
    _ = c.feed("test");
    try std.testing.expect(c.is_test);
    try std.testing.expectEqual(@as(usize, 0), c.passthrough_len);
}

test "classifyArgs - help honored after passthrough cap" {
    // help/version flags are recognized even after passthrough buf is full.
    var c: ArgClass = .{};
    var i: u8 = 0;
    while (i < types.MAX_CMD_ARGS) : (i += 1) {
        _ = c.feed("-Ddummy");
    }
    _ = c.feed("--help");
    try std.testing.expect(c.help);
}

test "classifyArgs - command cap: passthrough stops at capacity" {
    // Build mode passthrough capacity is MAX_CMD_ARGS - 2 = 30.
    var c: ArgClass = .{};
    var i: u8 = 0;
    while (i < types.MAX_CMD_ARGS + 5) : (i += 1) {
        _ = c.feed("-Ddummy");
    }
    try std.testing.expect(!c.is_test);
    try std.testing.expect(c.passthrough_len <= types.MAX_CMD_ARGS - 2);
}

test "classifyArgs - test mode passthrough capacity is 29" {
    // Test mode: 2 base + 1 test = 3 used, so 29 passthrough slots.
    var c: ArgClass = .{};
    _ = c.feed("test");
    var i: u8 = 0;
    while (i < types.MAX_CMD_ARGS + 5) : (i += 1) {
        _ = c.feed("-Ddummy");
    }
    try std.testing.expect(c.is_test);
    try std.testing.expectEqual(@as(usize, types.MAX_CMD_ARGS - 3), c.passthrough_len);
}

test "classifyArgs - version honored amid args" {
    var c: ArgClass = .{};
    _ = c.feed("-Dfoo=bar");
    _ = c.feed("--version");
    try std.testing.expect(c.version);
}
