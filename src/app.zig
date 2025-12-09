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
//! We use a global static variable for it (TigerStyle - like TigerBeetle does).
//! This goes in .bss segment, not the heap - no runtime allocation.

const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const parse = @import("parse.zig");
const process = @import("process.zig");
const watch_mod = @import("watch.zig");
const render = @import("render.zig");
const input = @import("input.zig");

/// Event type for the vaxis Loop
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

/// Global static report buffer (TigerStyle: static allocation, goes in .bss)
/// This avoids heap allocation for the large text buffer.
var global_report: types.Report = types.Report.init();

/// Main application state.
/// Now small enough for stack allocation since Report is global.
pub const App = struct {
    // Allocator (still needed for vaxis internals and process output)
    alloc: std.mem.Allocator,

    // Core state (report is global, not stored here)
    view: types.ViewState,
    watcher: watch_mod.Watcher,

    // Build configuration (static allocation - TigerStyle)
    build_args_buf: [types.MAX_CMD_ARGS][]const u8,
    build_args_len: u8,
    current_job_name: [32]u8,
    current_job_name_len: u8,

    // Terminal
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    tty_buf: [4096]u8,
    // Note: Loop is NOT stored as a field because it holds pointers to vx and tty.
    // If App is moved, those pointers would become invalid. Loop is created in run().

    // Flags
    needs_redraw: bool,
    running: bool,

    /// Initialize the application.
    pub fn init(alloc: std.mem.Allocator) !App {
        var app = App{
            .alloc = alloc,
            .view = types.ViewState.init(),
            .watcher = watch_mod.Watcher.init(types.WatchConfig.init()),
            .build_args_buf = undefined,
            .build_args_len = 0,
            .current_job_name = undefined,
            .current_job_name_len = 0,
            .vx = undefined,
            .tty = undefined,
            .tty_buf = undefined,
            .needs_redraw = true,
            .running = true,
        };

        // Initialize TTY with our static buffer
        app.tty = try vaxis.Tty.init(&app.tty_buf);
        errdefer app.tty.deinit();

        // Note: Vaxis.init no longer takes TTY - they're connected via Loop in run()
        app.vx = try vaxis.Vaxis.init(alloc, .{});

        // Set default job name
        app.setJobName("build");

        return app;
    }

    /// Clean up resources.
    pub fn deinit(self: *App) void {
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
    }

    /// Get the global report (TigerStyle: single instance).
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

    /// Set build arguments (static buffer - TigerStyle).
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

    /// Run a build and update the report.
    pub fn runBuild(self: *App) !void {
        const args = if (self.build_args_len > 0)
            self.getBuildArgs()
        else
            process.defaultBuildArgs();

        var result = try process.runBuild(self.alloc, args);
        defer result.deinit(self.alloc);

        // Parse the output into the global report
        const rpt = self.report();
        parse.parseOutput(result.output, rpt);
        rpt.exit_code = result.exit_code;
        rpt.was_killed = result.was_killed;

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
            .rebuild => {
                self.runBuild() catch |err| {
                    std.log.err("Build failed: {}", .{err});
                };
            },
            .toggle_expanded => {
                self.view.expanded = !self.view.expanded;
                self.view.scroll = 0;
                self.needs_redraw = true;
            },
            .toggle_watch => {
                self.watcher.toggle();
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
                const visible = self.report().getVisibleCount(self.view.expanded);
                self.view.scroll = visible;
                self.needs_redraw = true;
            },
            .next_error => self.navigateError(1),
            .prev_error => self.navigateError(-1),
            .open_in_editor => self.openInEditor(),
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
            .select_job => |_| {
                // TODO: Implement job selection
                self.view.mode = .normal;
                self.needs_redraw = true;
            },
        }
    }

    /// Scroll up by n lines.
    fn scrollUp(self: *App, n: usize) void {
        if (self.view.scroll >= n) {
            self.view.scroll -= n;
        } else {
            self.view.scroll = 0;
        }
        self.needs_redraw = true;
    }

    /// Scroll down by n lines.
    fn scrollDown(self: *App, n: usize) void {
        const max_scroll = self.report().getVisibleCount(self.view.expanded);
        self.view.scroll = @min(self.view.scroll + n, max_scroll);
        self.needs_redraw = true;
    }

    /// Navigate to next/previous error.
    fn navigateError(self: *App, direction: i32) void {
        const rpt = self.report();
        if (rpt.item_starts_len == 0) return;

        const current = self.view.selected_item;
        var new_idx: i32 = @as(i32, current) + direction;

        if (new_idx < 0) {
            new_idx = 0;
        } else if (new_idx >= @as(i32, @intCast(rpt.item_starts_len))) {
            new_idx = @intCast(rpt.item_starts_len - 1);
        }

        self.view.selected_item = @intCast(new_idx);

        // Scroll to show the selected item
        const line_idx = rpt.itemStarts()[@intCast(new_idx)];
        self.view.scroll = line_idx;

        self.needs_redraw = true;
    }

    /// Open the current error location in $EDITOR.
    fn openInEditor(self: *App) void {
        const rpt = self.report();

        // Find the currently selected item's location
        if (rpt.item_starts_len == 0) return;

        const item_idx = self.view.selected_item;
        if (item_idx >= rpt.item_starts_len) return;

        const line_idx = rpt.itemStarts()[item_idx];
        if (line_idx >= rpt.lines_len) return;

        const line = &rpt.lines()[line_idx];
        const location = line.location orelse return;

        // Get the line text from the shared buffer
        const text_buf = rpt.textBuf();
        const path = location.getPath(line.getText(text_buf));
        if (path.len == 0) return;

        // Get editor from environment
        const editor = std.posix.getenv("EDITOR") orelse "vim";

        // Format line number argument (most editors use +N)
        var line_arg_buf: [32]u8 = undefined;
        const line_arg = std.fmt.bufPrint(&line_arg_buf, "+{d}", .{location.line}) catch return;

        // Spawn editor (don't wait, let it run in background)
        // Note: This is simplified - in practice you'd want to
        // exit alt screen, run editor, then re-enter
        _ = std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = &[_][]const u8{ editor, line_arg, path },
        }) catch return;
    }

    /// Render the current state.
    fn renderView(self: *App) void {
        render.render(
            &self.vx,
            self.report(),
            &self.view,
            self.watcher.active,
            self.getJobName(),
        );

        if (self.view.mode == .help) {
            render.renderHelp(&self.vx);
        }
    }
};
