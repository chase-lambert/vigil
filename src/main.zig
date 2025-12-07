//! Vigil - A clean, fast build watcher for Zig
//!
//! Entry point and argument parsing.

const std = @import("std");
const App = @import("app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // Build the zig build command
    var build_args: std.ArrayList([]const u8) = .empty;
    defer build_args.deinit(alloc);

    try build_args.append(alloc, "zig");
    try build_args.append(alloc, "build");

    // Determine job name and pass through extra args
    var job_name: []const u8 = "build";

    if (args.len > 1) {
        // Check for special job names
        const first_arg = args[1];
        if (std.mem.eql(u8, first_arg, "test")) {
            job_name = "test";
            try build_args.append(alloc, "test");
        } else if (std.mem.eql(u8, first_arg, "run")) {
            job_name = "run";
            try build_args.append(alloc, "run");
        } else if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
            printVersion();
            return;
        } else {
            // Pass through all args to zig build
            for (args[1..]) |arg| {
                try build_args.append(alloc, arg);
            }
        }

        // Pass remaining args for special jobs too
        if (std.mem.eql(u8, first_arg, "test") or std.mem.eql(u8, first_arg, "run")) {
            for (args[2..]) |arg| {
                try build_args.append(alloc, arg);
            }
        }
    }

    // Initialize app (Report is a global static, so App is small enough for stack)
    var app = try App.init(alloc);
    defer app.deinit();

    // Configure
    try app.setBuildArgs(build_args.items);
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
        \\    run        Run 'zig build run'
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
        \\    vigil -- -Doptimize=ReleaseFast
        \\    vigil test -- -Dfilter=foo
        \\
        \\KEYBINDINGS:
        \\    j/k     Scroll down/up
        \\    n/N     Next/previous error
        \\    Space   Toggle terse/full view
        \\    r       Manual rebuild
        \\    w       Toggle file watching
        \\    Enter   Open error location in $EDITOR
        \\    q       Quit
        \\    ?       Show help
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn printVersion() void {
    std.debug.print("vigil 0.1.0\n", .{});
}
