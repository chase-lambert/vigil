//! Vigil - A clean, fast build watcher for Zig
//!
//! Entry point and argument parsing.

const std = @import("std");
const App = @import("app.zig").App;
const types = @import("types.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // Build the zig build command (static array, no heap)
    var build_args_buf: [types.MAX_CMD_ARGS][]const u8 = undefined;
    var build_args_len: u8 = 0;

    build_args_buf[build_args_len] = "zig";
    build_args_len += 1;
    build_args_buf[build_args_len] = "build";
    build_args_len += 1;

    // Determine job name and parse args
    var job_name: []const u8 = "build";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Vigil's own flags
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "test")) {
            // Job name (only if first non-flag arg)
            if (build_args_len == 2) { // Only "zig" and "build" so far
                job_name = "test";
                build_args_buf[build_args_len] = "test";
                build_args_len += 1;
            }
        } else {
            // Pass through to zig build
            if (build_args_len < types.MAX_CMD_ARGS) {
                build_args_buf[build_args_len] = arg;
                build_args_len += 1;
            }
        }
    }

    // Initialize app (Report is a global static, so App is small enough for stack)
    var app = try App.init(alloc);
    defer app.deinit();

    // Configure
    try app.setBuildArgs(build_args_buf[0..build_args_len]);
    app.setJobName(job_name);

    // Start the event loop (initial build runs asynchronously)
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
