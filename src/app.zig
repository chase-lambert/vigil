//! Application state and main coordination logic.
//!
//! This is the central hub that ties together:
//! - Report (parsed build output)
//! - ViewState (UI state)
//! - Process execution
//! - File watching
//! - Rendering
//!
//! Design: The Report struct is large (~740KB) due to the shared text buffer.
//! We use a global static variable for it - goes in .bss segment, no heap allocation.

const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const parse = @import("parse.zig");
const watch = @import("watch.zig");
const render = @import("render.zig");
const input = @import("input.zig");
const assert = std.debug.assert;

/// Event type for the vaxis Loop
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

/// Global static report buffer - avoids heap allocation for the large text buffer.
var global_report: types.Report = types.Report.init();

/// Main application state.
/// Now small enough for stack allocation since Report is global.
pub const App = struct {
    // Allocator (still needed for vaxis internals and process output)
    alloc: std.mem.Allocator,

    // Core state (report is global, not stored here)
    view: types.ViewState,
    watcher: watch.Watcher,

    // Build configuration (static allocation)
    build_args_buf: [types.MAX_CMD_ARGS][]const u8,
    build_args_len: u8,
    current_job_name: [32]u8,
    current_job_name_len: u8,

    // Project info (detected from build.zig.zon)
    project_name: [64]u8,
    project_name_len: u8,
    project_root: [types.MAX_PATH_LEN]u8,
    project_root_len: u16,

    // Terminal
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    tty_buf: [4096]u8,
    // Note: Loop is NOT stored as a field because it holds pointers to vx and tty.
    // If App is moved, those pointers would become invalid. Loop is created in run().

    // Flags
    needs_redraw: bool,
    running: bool,
    is_building: bool,

    /// Initialize the application.
    pub fn init(alloc: std.mem.Allocator) !App {
        var app = App{
            .alloc = alloc,
            .view = types.ViewState.init(),
            .watcher = watch.Watcher.init(types.WatchConfig.init()),
            .build_args_buf = undefined,
            .build_args_len = 0,
            .current_job_name = undefined,
            .current_job_name_len = 0,
            .project_name = undefined,
            .project_name_len = 0,
            .project_root = undefined,
            .project_root_len = 0,
            .vx = undefined,
            .tty = undefined,
            .tty_buf = undefined,
            .needs_redraw = true,
            .running = true,
            .is_building = false,
        };

        // Initialize TTY with our static buffer
        app.tty = try vaxis.Tty.init(&app.tty_buf);
        errdefer app.tty.deinit();

        // Note: Vaxis.init no longer takes TTY - they're connected via Loop in run()
        app.vx = try vaxis.Vaxis.init(alloc, .{});

        // Set default job name
        app.setJobName("build");

        // Detect project name from build.zig.zon
        app.detectProject();

        return app;
    }

    /// Clean up resources.
    pub fn deinit(self: *App) void {
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
    }

    /// Get the global report.
    pub fn report(_: *const App) *types.Report {
        return &global_report;
    }

    /// Set the current job name for display.
    pub fn setJobName(self: *App, name: []const u8) void {
        const len = @min(name.len, self.current_job_name.len);
        @memcpy(self.current_job_name[0..len], name[0..len]);
        self.current_job_name_len = @intCast(len);
    }

    pub fn getJobName(self: *const App) []const u8 {
        return self.current_job_name[0..self.current_job_name_len];
    }

    /// Get project name (from build.zig.zon or fallback to directory name).
    pub fn getProjectName(self: *const App) []const u8 {
        if (self.project_name_len == 0) return "project";
        return self.project_name[0..self.project_name_len];
    }

    /// Get project root path.
    pub fn getProjectRoot(self: *const App) []const u8 {
        return self.project_root[0..self.project_root_len];
    }

    /// Detect project info from build.zig.zon in current directory.
    fn detectProject(self: *App) void {
        // Get current working directory as project root
        if (std.fs.cwd().realpathAlloc(self.alloc, ".")) |cwd| {
            defer self.alloc.free(cwd);
            const len = @min(cwd.len, self.project_root.len);
            @memcpy(self.project_root[0..len], cwd[0..len]);
            self.project_root_len = @intCast(len);
        } else |_| {}

        // Try to read build.zig.zon and extract name
        const file = std.fs.cwd().openFile("build.zig.zon", .{}) catch {
            // Fallback: use directory name as project name
            self.extractDirName();
            return;
        };
        defer file.close();

        // Read first 1KB (name should be near the top)
        var buf: [1024]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch {
            self.extractDirName();
            return;
        };

        // Parse ".name = .identifier" (Zig 0.15 enum literal style)
        if (self.parseZonName(buf[0..bytes_read])) |name| {
            const len = @min(name.len, self.project_name.len);
            @memcpy(self.project_name[0..len], name[0..len]);
            self.project_name_len = @intCast(len);
        } else {
            self.extractDirName();
        }
    }

    fn parseZonName(_: *App, content: []const u8) ?[]const u8 {
        return parseZonNameFromContent(content);
    }

    /// Extract project name from directory name as fallback.
    fn extractDirName(self: *App) void {
        if (self.project_root_len == 0) return;
        const root = self.project_root[0..self.project_root_len];

        // Find last path separator
        var last_sep: usize = 0;
        for (root, 0..) |c, i| {
            if (c == '/' or c == '\\') last_sep = i + 1;
        }

        const dir_name = root[last_sep..];
        if (dir_name.len > 0) {
            const len = @min(dir_name.len, self.project_name.len);
            @memcpy(self.project_name[0..len], dir_name[0..len]);
            self.project_name_len = @intCast(len);
        }
    }

    /// Set build arguments.
    pub fn setBuildArgs(self: *App, args: []const []const u8) !void {
        if (args.len > types.MAX_CMD_ARGS) return error.TooManyArgs;
        for (args, 0..) |arg, i| {
            self.build_args_buf[i] = arg;
        }
        self.build_args_len = @intCast(args.len);
    }

    /// Get build arguments slice.
    pub fn getBuildArgs(self: *const App) []const []const u8 {
        return self.build_args_buf[0..self.build_args_len];
    }

    /// Set custom watch paths (overrides defaults).
    pub fn setWatchPaths(self: *App, paths: []const []const u8) !void {
        var config = types.WatchConfig{
            .paths = undefined,
            .paths_lens = undefined,
            .paths_count = 0,
            .debounce_ms = 100,
            .enabled = true,
        };
        for (paths) |path| {
            try config.addPath(path);
        }
        self.watcher = watch.Watcher.init(config);
    }

    /// Run a build and update the report.
    pub fn runBuild(self: *App) !void {
        // Show "building" status before blocking on child process
        self.is_building = true;
        self.renderView();
        self.vx.render(self.tty.writer()) catch {};
        self.tty.writer().flush() catch {};
        defer self.is_building = false;

        const args = if (self.build_args_len > 0)
            self.getBuildArgs()
        else
            defaultBuildArgs();

        var result = try runBuildCmd(self.alloc, args);
        defer result.deinit(self.alloc);

        // Parse the output into the global report
        const rpt = self.report();
        parse.parseOutput(result.output, rpt);
        rpt.exit_code = result.exit_code;

        // Reset view state for new output
        self.view.reset();
        self.needs_redraw = true;

        // Update watcher to avoid immediate re-trigger
        self.watcher.snapshot();
    }

    /// Main event loop.
    pub fn run(self: *App) !void {
        const writer = self.tty.writer();

        // Create Loop as a local variable - it stores pointers to tty and vx,
        // so it must be created here where self has a stable address.
        var loop: vaxis.Loop(Event) = .{ .tty = &self.tty, .vaxis = &self.vx };

        // Initialize the loop FIRST (sets up signal handlers for window resize)
        // This must happen before starting the input thread
        try loop.init();

        // Start input thread BEFORE entering alt screen or querying terminal
        // This ensures query responses can be read
        try loop.start();
        defer loop.stop();

        // Enter alternate screen
        try self.vx.enterAltScreen(writer);
        // exitAltScreen in defer: if cleanup fails, we're exiting anyway
        defer self.vx.exitAltScreen(writer) catch {};

        // Query terminal capabilities and wait for responses
        // Using queryTerminal (not queryTerminalSend) which properly waits
        // The 1 second timeout allows time for terminal to respond
        try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);

        while (self.running) {
            // Process all pending events (non-blocking)
            while (loop.tryEvent()) |event| {
                self.handleEvent(event);
            }

            // Check for file changes (if watching)
            if (self.watcher.checkForChanges()) {
                self.runBuild() catch |err| {
                    std.log.err("Build failed: {}", .{err});
                };
            }

            // Render if needed
            if (self.needs_redraw) {
                self.renderView();
                try self.vx.render(writer);
                try writer.flush();
                self.needs_redraw = false;
            }

            // Sleep to avoid busy-waiting
            std.Thread.sleep(16 * std.time.ns_per_ms); // ~60fps
        }
    }

    /// Handle a vaxis event.
    fn handleEvent(self: *App, event: Event) void {
        switch (event) {
            .key_press => |key| self.handleKey(key),
            .winsize => |ws| {
                // Resize failure: display may be off until next successful resize
                self.vx.resize(self.alloc, self.tty.writer(), ws) catch {};
                self.needs_redraw = true;
            },
            .focus_in, .focus_out => {},
        }
    }

    /// Handle a key press.
    fn handleKey(self: *App, key: vaxis.Key) void {
        const action = input.handleKey(
            key,
            self.view.mode,
            &self.view.search,
            &self.view.search_len,
        );

        switch (action) {
            .none => {},
            .quit => self.running = false,
            .toggle_expanded => {
                // Preserve approximate scroll position when toggling modes
                const old_visible = self.report().getVisibleCount(self.view.expanded);
                const old_scroll = self.view.scroll;
                self.view.expanded = !self.view.expanded;
                const new_visible = self.report().getVisibleCount(self.view.expanded);
                // Scale scroll proportionally to new visible count
                if (old_visible > 0) {
                    self.view.scroll = @intCast(@as(u32, old_scroll) * new_visible / old_visible);
                }
                self.needs_redraw = true;
            },
            .toggle_watch => {
                self.watcher.toggle();
                self.needs_redraw = true;
            },
            .toggle_wrap => {
                self.view.wrap = !self.view.wrap;
                self.needs_redraw = true;
            },
            .scroll_up => self.scrollUp(1),
            .scroll_down => self.scrollDown(1),
            .scroll_page_up => self.scrollUp(20),
            .scroll_page_down => self.scrollDown(20),
            .scroll_top => {
                self.view.scroll = 0;
                self.needs_redraw = true;
            },
            .scroll_bottom => {
                self.view.scroll = self.getMaxScroll();
                self.needs_redraw = true;
            },
            .start_search => {
                self.view.mode = .searching;
                self.view.search_len = 0;
                self.needs_redraw = true;
            },
            .show_help => {
                self.view.mode = .help;
                self.needs_redraw = true;
            },
            .hide_help => {
                self.view.mode = .normal;
                self.needs_redraw = true;
            },
            .cancel => {
                self.view.mode = .normal;
                self.needs_redraw = true;
            },
            .confirm => {
                // TODO: Implement search confirmation
                self.view.mode = .normal;
                self.needs_redraw = true;
            },
            .select_job => |job_idx| {
                self.switchJob(job_idx);
            },
        }
    }

    /// Scroll up by n lines.
    fn scrollUp(self: *App, n: u16) void {
        if (self.view.scroll >= n) {
            self.view.scroll -= n;
        } else {
            self.view.scroll = 0;
        }
        self.needs_redraw = true;
    }

    /// Scroll down by n lines.
    fn scrollDown(self: *App, n: u16) void {
        const max_scroll = self.getMaxScroll();
        self.view.scroll = @min(self.view.scroll + n, max_scroll);
        self.needs_redraw = true;
    }

    /// Get the content area height (viewport).
    /// Layout: header (1) + gap (1) + content + footer (1)
    fn getContentHeight(self: *const App) u16 {
        return self.vx.screen.height -| 3;
    }

    /// Get the maximum scroll position.
    ///
    /// Calculates exactly how many visible lines fit in the viewport when accounting
    /// for multi-row rendering (error badges, test failures with expected/found, wrapped lines).
    fn getMaxScroll(self: *const App) u16 {
        const visible = self.report().getVisibleCount(self.view.expanded);
        const viewport = self.getContentHeight();
        const lines_fit = render.countLinesThatFitInViewport(
            self.report(),
            &self.view,
            viewport,
            self.vx.screen.width,
        );
        return visible -| lines_fit;
    }

    /// Switch to a different job (build=0, test=1).
    fn switchJob(self: *App, job_idx: u8) void {
        switch (job_idx) {
            0 => { // build
                self.build_args_buf[0] = "zig";
                self.build_args_buf[1] = "build";
                self.build_args_len = 2;
                self.setJobName("build");
            },
            1 => { // test
                self.build_args_buf[0] = "zig";
                self.build_args_buf[1] = "build";
                self.build_args_buf[2] = "test";
                self.build_args_len = 3;
                self.setJobName("test");
            },
            else => return,
        }
        self.runBuild() catch {};
    }

    /// Render the current state.
    fn renderView(self: *App) void {
        render.render(&self.vx, .{
            .report = self.report(),
            .view = &self.view,
            .watching = self.watcher.active,
            .is_building = self.is_building,
            .job_name = self.getJobName(),
            .project_name = self.getProjectName(),
            .project_root = self.getProjectRoot(),
        });

        if (self.view.mode == .help) {
            render.renderHelp(&self.vx);
        }
    }
};

// =============================================================================
// Build Execution (merged from process.zig - was too shallow to justify module)
// =============================================================================

/// Result of running a build command.
pub const BuildResult = struct {
    /// Combined stdout + stderr output
    output: []const u8,
    /// Exit code (null if killed/crashed)
    exit_code: ?u8,

    pub fn deinit(self: *BuildResult, alloc: std.mem.Allocator) void {
        if (self.output.len > 0) {
            alloc.free(self.output);
        }
        self.* = undefined;
    }
};

/// Run a build command and capture its output (stderr only).
/// Zig outputs all build/test errors to stderr; stdout is unused.
fn runBuildCmd(alloc: std.mem.Allocator, args: []const []const u8) !BuildResult {
    assert(args.len > 0);

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = args,
        .max_output_bytes = types.MAX_TEXT_SIZE,
    });

    if (result) |r| {
        // Free stdout - we only care about stderr for build errors
        if (r.stdout.len > 0) alloc.free(r.stdout);

        const exit_code: ?u8 = switch (r.term) {
            .Exited => |code| code,
            .Signal, .Stopped, .Unknown => null,
        };

        return BuildResult{
            .output = r.stderr,
            .exit_code = exit_code,
        };
    } else |_| {
        return BuildResult{
            .output = "",
            .exit_code = null,
        };
    }
}

/// Default build command when none specified.
fn defaultBuildArgs() []const []const u8 {
    return &[_][]const u8{ "zig", "build" };
}

// =============================================================================
// Project Detection
// =============================================================================

/// Parse project name from build.zig.zon content.
/// Handles ".name = .identifier" (Zig 0.15) and ".name = \"string\"" (older)
pub fn parseZonNameFromContent(content: []const u8) ?[]const u8 {
    const name_marker = ".name = ";
    const pos = std.mem.indexOf(u8, content, name_marker) orelse return null;
    const after_marker = content[pos + name_marker.len ..];

    if (after_marker.len == 0) return null;

    if (after_marker[0] == '.') {
        // Enum literal: .name = .identifier
        const start = 1;
        var end: usize = start;
        while (end < after_marker.len) : (end += 1) {
            const c = after_marker[end];
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
        }
        if (end > start) {
            return after_marker[start..end];
        }
    } else if (after_marker[0] == '"') {
        // String literal: .name = "string"
        const start = 1;
        const end_quote = std.mem.indexOf(u8, after_marker[start..], "\"") orelse return null;
        return after_marker[start .. start + end_quote];
    }

    return null;
}

test "parseZonNameFromContent - enum literal format (Zig 0.15)" {
    const content =
        \\.{
        \\    .name = .vigil,
        \\    .version = "0.1.0",
        \\}
    ;
    const name = parseZonNameFromContent(content);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("vigil", name.?);
}

test "parseZonNameFromContent - string literal format (older Zig)" {
    const content =
        \\.{
        \\    .name = "my_project",
        \\    .version = "0.1.0",
        \\}
    ;
    const name = parseZonNameFromContent(content);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("my_project", name.?);
}

test "parseZonNameFromContent - missing name field" {
    const content =
        \\.{
        \\    .version = "0.1.0",
        \\}
    ;
    try std.testing.expect(parseZonNameFromContent(content) == null);
}

test "parseZonNameFromContent - empty content" {
    try std.testing.expect(parseZonNameFromContent("") == null);
}

test "parseZonNameFromContent - name with underscores" {
    const content = ".name = .my_cool_project,";
    const name = parseZonNameFromContent(content);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("my_cool_project", name.?);
}
