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

    // Determine job name and pass through extra args
    var job_name: []const u8 = "build";

    if (args.len > 1) {
        // Check for special job names
        const first_arg = args[1];
        if (std.mem.eql(u8, first_arg, "test")) {
            job_name = "test";
            build_args_buf[build_args_len] = "test";
            build_args_len += 1;
        } else if (std.mem.eql(u8, first_arg, "run")) {
            job_name = "run";
            build_args_buf[build_args_len] = "run";
            build_args_len += 1;
        } else if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
            printVersion();
            return;
        } else {
            // Pass through all args to zig build
            for (args[1..]) |arg| {
                if (build_args_len >= types.MAX_CMD_ARGS) break;
                build_args_buf[build_args_len] = arg;
                build_args_len += 1;
            }
        }

        // Pass remaining args for special jobs too
        if (std.mem.eql(u8, first_arg, "test") or std.mem.eql(u8, first_arg, "run")) {
            for (args[2..]) |arg| {
                if (build_args_len >= types.MAX_CMD_ARGS) break;
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

    // Run initial build
    try app.runBuild();

    // Start the event loop
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
        \\    -h, --help     Show this help
        \\    -v, --version  Show version
        \\
        \\    All other options are passed through to 'zig build'.
        \\
        \\EXAMPLES:
        \\    vigil                      # Watch and run 'zig build'
        \\    vigil test                 # Watch and run 'zig build test'
        \\    vigil -Doptimize=ReleaseFast
        \\    vigil test -Dfilter=foo
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
    std.debug.print("vigil 0.1.0\n", .{});
}
