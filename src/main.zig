//! Vigil - A clean, fast build watcher for Zig
//!
//! Entry point and argument parsing.

const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const types = @import("types.zig");

pub fn main() !void {
    // GPA only needed for App internals (vaxis)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok); // Catch leaks in debug builds
    const alloc = gpa.allocator();

    // Cross-platform argument access:
    // - Unix: std.os.argv provides zero-copy access to OS-provided argv
    // - Windows: must parse command line string, requires allocation
    const argv = if (builtin.os.tag == .windows)
        try std.process.argsAlloc(alloc)
    else
        std.os.argv;
    defer if (builtin.os.tag == .windows) std.process.argsFree(alloc, argv);

    var build_args_buf: [types.MAX_CMD_ARGS][]const u8 = undefined;
    var build_args_len: u8 = 0;

    build_args_buf[build_args_len] = "zig";
    build_args_len += 1;
    build_args_buf[build_args_len] = "build";
    build_args_len += 1;

    var job_name: []const u8 = "build";

    // Skip argv[0] (program name), iterate the rest
    for (argv[1..]) |arg_ptr| {
        // Convert to slice: Unix has [*:0]u8 (needs span), Windows has [:0]u8 (coerces directly)
        const arg: []const u8 = if (builtin.os.tag == .windows) arg_ptr else std.mem.span(arg_ptr);

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "test")) {
            if (build_args_len == 2) {
                job_name = "test";
                build_args_buf[build_args_len] = "test";
                build_args_len += 1;
            }
        } else {
            if (build_args_len < types.MAX_CMD_ARGS) {
                build_args_buf[build_args_len] = arg;
                build_args_len += 1;
            }
        }
    }

    var app = try App.init(alloc);
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
