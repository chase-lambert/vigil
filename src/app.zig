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

/// Case-insensitive substring search.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;

    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

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

    // State
    state: types.RunState,
    needs_redraw: bool,
    spawn_failed: bool, // True if build command failed to spawn

    // Async build state
    build_thread: ?std.Thread = null,
    build_output: []const u8 = "",
    build_exit_code: ?u8 = null,
    build_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    build_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Child process PID for cancellation (0 = no child running)
    build_child_pid: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

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
            .state = .idle,
            .needs_redraw = true,
            .spawn_failed = false,
        };

        app.tty = try vaxis.Tty.init(&app.tty_buf);
        errdefer app.tty.deinit();

        // Note: Vaxis.init no longer takes TTY - they're connected via Loop in run()
        app.vx = try vaxis.Vaxis.init(alloc, .{});
        // Use legacy SGR format (semicolons) for broader terminal compatibility.
        // Standard format uses colons which many terminals can't parse (Mac Terminal, IntelliJ).
        app.vx.sgr = .legacy;
        // Defensive errdefer: currently nothing after this can fail, but if someone
        // adds a fallible operation later, this ensures vx gets cleaned up on error.
        errdefer app.vx.deinit(alloc, app.tty.writer());

        app.setJobName("build");
        app.detectProject();

        return app;
    }

    pub fn deinit(self: *App) void {
        self.cancelBuild();
        if (self.build_output.len > 0) {
            self.alloc.free(self.build_output);
        }
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
    }

    /// Access the global report. Instance method for encapsulation
    /// (allows future refactoring to per-App report without changing call sites).
    pub fn report(_: *const App) *types.Report {
        return &global_report;
    }

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
        if (parseZonName(buf[0..bytes_read])) |name| {
            const len = @min(name.len, self.project_name.len);
            @memcpy(self.project_name[0..len], name[0..len]);
            self.project_name_len = @intCast(len);
        } else {
            self.extractDirName();
        }
    }

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

    pub fn setBuildArgs(self: *App, args: []const []const u8) !void {
        if (args.len > types.MAX_CMD_ARGS) return error.TooManyArgs;
        for (args, 0..) |arg, i| {
            self.build_args_buf[i] = arg;
        }
        self.build_args_len = @intCast(args.len);
    }

    pub fn getBuildArgs(self: *const App) []const []const u8 {
        return self.build_args_buf[0..self.build_args_len];
    }

    /// Run a build and update the report.
    pub fn runBuild(self: *App) !void {
        // Clear previous build error state - this build attempt started
        self.spawn_failed = false;

        // Show "building" status before blocking on child process
        self.state = .building;
        self.renderView();
        self.vx.render(self.tty.writer()) catch {};
        self.tty.writer().flush() catch {};
        defer self.state = .idle;

        const args = if (self.build_args_len > 0)
            self.getBuildArgs()
        else
            defaultBuildArgs();

        var result = try runBuildCmd(self.alloc, args);
        defer result.deinit(self.alloc);

        const rpt = self.report();
        parse.parseOutput(result.output, rpt);
        rpt.exit_code = result.exit_code;

        // Reset view state for new output
        self.view.reset();
        self.needs_redraw = true;

        // Update watcher to avoid immediate re-trigger
        self.watcher.snapshot();
    }

    /// Start a build in a background thread. Returns immediately.
    pub fn startBuild(self: *App) void {
        // Cancel any existing build first (no-op if already idle)
        // Note: switchJob() calls cancelBuild() before modifying args,
        // so this may be redundant, but it's safe and handles other callers.
        if (self.state == .building or self.build_thread != null) {
            self.cancelBuild();
        }

        // Must have build args configured
        assert(self.build_args_len > 0);

        self.state = .building;
        self.build_complete.store(false, .seq_cst);
        self.build_error.store(false, .release);
        self.spawn_failed = false;
        self.needs_redraw = true;

        // Spawn build thread
        self.build_thread = std.Thread.spawn(.{}, buildThreadFn, .{self}) catch {
            self.spawn_failed = true;
            self.state = .idle;
            return;
        };

        // Thread spawned successfully
        assert(self.state == .building);
        assert(self.build_thread != null);
    }

    /// Thread function: runs build, stores result, signals completion.
    fn buildThreadFn(app: *App) void {
        // Read args at thread start (before any potential modification)
        const args = if (app.build_args_len > 0)
            app.getBuildArgs()
        else
            defaultBuildArgs();

        // Run build with cancellation support - stores PID in app.build_child_pid
        const result = runBuildCmdCancellable(app.alloc, args, &app.build_child_pid, &app.build_error);

        // Store results for main thread to process
        app.build_output = result.output;
        app.build_exit_code = result.exit_code;
        app.build_complete.store(true, .seq_cst);
        // Note: Don't call result.deinit() - main thread owns the output now
    }

    /// Called from event loop when build completes.
    fn finishBuild(self: *App) void {
        // Join thread (should be instant since it signaled complete)
        if (self.build_thread) |thread| {
            thread.join();
            self.build_thread = null;
        }

        if (self.build_error.load(.acquire)) {
            self.spawn_failed = true;
        } else {
            // Parse output into report
            const rpt = self.report();
            parse.parseOutput(self.build_output, rpt);
            rpt.exit_code = self.build_exit_code;

            // Free the output buffer
            if (self.build_output.len > 0) {
                self.alloc.free(self.build_output);
            }
            self.build_output = "";
            self.build_exit_code = null;

            self.view.reset();
            self.watcher.snapshot();
        }

        self.state = .idle;
        self.build_error.store(false, .release);
        self.needs_redraw = true;

        // Build finished - thread joined, idle state
        assert(self.build_thread == null);
        assert(self.state == .idle);
    }

    /// Cancel running build (for job switch or quit).
    /// Kills the child process group (if running) and joins the build thread.
    pub fn cancelBuild(self: *App) void {
        // If thread exists but PID not yet stored, spin briefly waiting for it.
        // This closes the race window where user quits immediately after build starts.
        // CANCEL_PID_WAIT_MS is a pragmatic upper bound; if we still haven't observed
        // the PID after this, we proceed to join() which may block until the build
        // exits naturally. In practice, PID publication happens almost immediately
        // after spawn().
        if (self.build_thread != null) {
            var attempts: u8 = 0;
            while (self.build_child_pid.load(.acquire) == 0 and attempts < types.CANCEL_PID_WAIT_MS) : (attempts += 1) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        // Kill child process GROUP if running - this causes collectOutput to return.
        // We use -pid (negative) to kill the entire process group, not just the parent.
        // This is critical because zig build spawns many child processes!
        const pid = self.build_child_pid.load(.acquire);
        if (pid > 0) {
            // SIGKILL the entire process group (negative PID = process group)
            std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        }

        // Now safe to join - child is dead, thread will exit quickly
        if (self.build_thread) |thread| {
            thread.join();
            self.build_thread = null;
        }

        // Clear PID (thread may have already cleared it, but be safe)
        self.build_child_pid.store(0, .release);

        // Free any pending output from previous build
        if (self.build_output.len > 0) {
            self.alloc.free(self.build_output);
            self.build_output = "";
        }
        self.state = .idle;

        // Cancellation complete - no thread, no child, idle state
        assert(self.build_thread == null);
        assert(self.build_child_pid.load(.acquire) == 0);
        assert(self.state == .idle);
    }

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

        try self.vx.enterAltScreen(writer);
        // exitAltScreen in defer: if cleanup fails, we're exiting anyway
        defer self.vx.exitAltScreen(writer) catch {};

        // Query terminal capabilities and wait for responses
        // Using queryTerminal (not queryTerminalSend) which properly waits
        // The 1 second timeout allows time for terminal to respond
        try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);

        // Build runs in background thread - TUI appears immediately
        self.startBuild();

        while (self.state != .quitting) {
            // Process all pending events (non-blocking)
            while (loop.tryEvent()) |event| {
                self.handleEvent(event);
            }

            if (self.build_complete.load(.seq_cst) and self.state == .building) {
                self.finishBuild();
            }

            if (self.state == .idle and self.watcher.checkForChanges()) {
                self.startBuild();
            }

            if (self.needs_redraw) {
                self.renderView();
                try self.vx.render(writer);
                try writer.flush();
                self.needs_redraw = false;
            }

            // Sleep to avoid busy-waiting
            std.Thread.sleep(16 * std.time.ns_per_ms); // ~60fps
        }

        // Cleanup: cancel any running build before exit
        self.cancelBuild();
    }

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

    fn handleKey(self: *App, key: vaxis.Key) void {
        const action = input.handleKey(
            key,
            self.view.mode,
            &self.view.search,
            &self.view.search_len,
        );

        switch (action) {
            .none => {
                // In search mode, typing characters modifies buffer but returns .none
                // Still need to redraw to show the updated search query
                if (self.view.mode == .searching) {
                    self.needs_redraw = true;
                }
            },
            .quit => {
                self.cancelBuild();
                self.state = .quitting;
            },
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
                // Clamp to valid range (prevents out-of-bounds after mode switch)
                const max_scroll = self.getMaxScroll();
                self.view.scroll = @min(self.view.scroll, max_scroll);
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
            .cancel_search => {
                self.view.mode = .normal;
                self.needs_redraw = true;
            },
            .confirm_search => {
                // Search for query and scroll to first match
                if (self.findNextMatch(0)) |match_scroll| {
                    self.view.scroll = match_scroll;
                }
                self.view.mode = .normal;
                self.needs_redraw = true;
            },
            .next_match => {
                // Find next match, wrapping to top if needed
                if (self.view.search_len > 0) {
                    const match = self.findNextMatch(self.view.scroll + 1) orelse
                        self.findNextMatch(0); // Wrap to beginning
                    if (match) |match_scroll| {
                        self.view.scroll = match_scroll;
                        self.needs_redraw = true;
                    }
                }
            },
            .prev_match => {
                // Find previous match, wrapping to bottom if needed
                if (self.view.search_len > 0) {
                    const match = self.findPrevMatch(self.view.scroll) orelse blk: {
                        // Wrap: find last match by searching from end
                        const visible = self.report().getVisibleCount(self.view.expanded);
                        break :blk self.findPrevMatch(visible);
                    };
                    if (match) |match_scroll| {
                        self.view.scroll = match_scroll;
                        self.needs_redraw = true;
                    }
                }
            },
            .select_build => self.switchToBuild(),
            .select_test => self.switchToTest(),
        }
    }

    fn scrollUp(self: *App, n: u16) void {
        const scroll_before = self.view.scroll;
        if (self.view.scroll >= n) {
            self.view.scroll -= n;
        } else {
            self.view.scroll = 0;
        }
        self.needs_redraw = true;

        // Scroll decreased or stayed at 0
        assert(self.view.scroll <= scroll_before);
    }

    fn scrollDown(self: *App, n: u16) void {
        const max_scroll = self.getMaxScroll();
        self.view.scroll = @min(self.view.scroll + n, max_scroll);
        self.needs_redraw = true;

        // Scroll never exceeds max
        assert(self.view.scroll <= max_scroll);
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

    /// Find the next visible line containing the search query.
    /// Returns the scroll position of the match, or null if not found.
    fn findNextMatch(self: *App, start_from: u16) ?u16 {
        const query = self.view.getSearch();
        if (query.len == 0) return null;

        const rep = self.report();
        const lines = rep.lines();
        const text_buf = rep.textBuf();

        var visible_idx: u16 = 0;
        var prev_blank = false;

        for (lines) |line| {
            const should_show = self.view.expanded or line.kind.shownInTerse();
            if (!should_show) continue;

            // Collapse consecutive blanks in terse mode
            if (!self.view.expanded and line.kind == .blank) {
                if (prev_blank) continue;
                prev_blank = true;
            } else {
                prev_blank = false;
            }

            // Check if this visible line matches (case-insensitive)
            if (visible_idx >= start_from) {
                const text = line.getText(text_buf);
                if (containsIgnoreCase(text, query)) {
                    return visible_idx;
                }
            }

            visible_idx += 1;
        }

        return null;
    }

    /// Find the previous visible line containing the search query.
    /// Returns the scroll position of the match, or null if not found.
    fn findPrevMatch(self: *App, start_from: u16) ?u16 {
        const query = self.view.getSearch();
        if (query.len == 0) return null;
        if (start_from == 0) return null;

        const rep = self.report();
        const lines = rep.lines();
        const text_buf = rep.textBuf();

        var visible_idx: u16 = 0;
        var prev_blank = false;
        var last_match: ?u16 = null;

        for (lines) |line| {
            const should_show = self.view.expanded or line.kind.shownInTerse();
            if (!should_show) continue;

            // Collapse consecutive blanks in terse mode
            if (!self.view.expanded and line.kind == .blank) {
                if (prev_blank) continue;
                prev_blank = true;
            } else {
                prev_blank = false;
            }

            // Stop before reaching current position
            if (visible_idx >= start_from) break;

            // Check if this visible line matches (case-insensitive)
            const text = line.getText(text_buf);
            if (containsIgnoreCase(text, query)) {
                last_match = visible_idx;
            }

            visible_idx += 1;
        }

        return last_match;
    }

    /// Switch to build job.
    fn switchToBuild(self: *App) void {
        // Cancel current build FIRST - ensures old thread is joined
        // before we modify build_args_buf (which it may reference)
        self.cancelBuild();

        self.build_args_buf[0] = "zig";
        self.build_args_buf[1] = "build";
        self.build_args_len = 2;
        self.setJobName("build");

        self.startBuild();
    }

    /// Switch to test job.
    fn switchToTest(self: *App) void {
        // Cancel current build FIRST - ensures old thread is joined
        // before we modify build_args_buf (which it may reference)
        self.cancelBuild();

        self.build_args_buf[0] = "zig";
        self.build_args_buf[1] = "build";
        self.build_args_buf[2] = "test";
        self.build_args_len = 3;
        self.setJobName("test");

        self.startBuild();
    }

    fn renderView(self: *App) void {
        render.render(&self.vx, .{
            .report = self.report(),
            .view = &self.view,
            .watching = self.watcher.active,
            .is_building = (self.state == .building),
            .spawn_failed = self.spawn_failed,
            .job_name = self.getJobName(),
            .project_name = self.getProjectName(),
            .project_root = self.getProjectRoot(),
        });

        if (self.view.mode == .help) {
            render.renderHelp(&self.vx);
        } else if (self.view.mode == .searching) {
            render.renderSearchInput(&self.vx, self.view.getSearch());
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

/// Zig outputs build/test errors to stderr; stdout is unused.
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

/// Run a build command with cancellation support.
/// Stores the child PID atomically so it can be killed from another thread.
/// Sets error_out to true if spawn/collection/wait fails (not just "build had errors").
/// Returns null output if the process was killed (cancelled).
fn runBuildCmdCancellable(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    pid_out: *std.atomic.Value(i32),
    error_out: *std.atomic.Value(bool),
) BuildResult {
    assert(args.len > 0);

    // Initialize child process with pipes for output capture
    var child = std.process.Child.init(args, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        error_out.store(true, .release);
        return BuildResult{ .output = "", .exit_code = null };
    };

    // Put child in its own process group so we can kill all descendants.
    // When zig build runs, it spawns many child processes. If we only kill
    // the parent, the children become orphaned and keep running!
    // By making the child its own process group leader (pgid = pid),
    // we can later kill(-pid) to terminate the entire group.
    const child_pid: std.posix.pid_t = @intCast(child.id);
    std.posix.setpgid(child_pid, child_pid) catch {};

    // Store PID atomically so main thread can kill if needed
    // This PID is also the PGID since we made it the group leader
    pid_out.store(child_pid, .release);

    // Collect output - blocks until EOF (process exits or is killed)
    // In Zig 0.15, ArrayList is unmanaged by default - allocator passed to methods
    var stdout_list: std.ArrayList(u8) = .empty;
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(alloc); // We only care about stderr

    child.collectOutput(alloc, &stdout_list, &stderr_list, types.MAX_TEXT_SIZE) catch {
        // Collection failed (unlikely) - clear PID and wait
        pid_out.store(0, .release);
        _ = child.wait() catch {};
        stderr_list.deinit(alloc);
        error_out.store(true, .release);
        return BuildResult{ .output = "", .exit_code = null };
    };

    // Clear PID before wait - process has finished or been killed
    pid_out.store(0, .release);

    // Reap the process
    const term = child.wait() catch {
        stderr_list.deinit(alloc);
        error_out.store(true, .release);
        return BuildResult{ .output = "", .exit_code = null };
    };

    const exit_code: ?u8 = switch (term) {
        .Exited => |code| code,
        .Signal, .Stopped, .Unknown => null,
    };

    // Transfer ownership of stderr to caller
    const output = stderr_list.toOwnedSlice(alloc) catch {
        // Allocation failed - must free the list's buffer to avoid leak
        stderr_list.deinit(alloc);
        return BuildResult{ .output = "", .exit_code = exit_code };
    };
    return BuildResult{ .output = output, .exit_code = exit_code };
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
pub fn parseZonName(content: []const u8) ?[]const u8 {
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

test "parseZonName - enum literal format (Zig 0.15)" {
    const content =
        \\.{
        \\    .name = .vigil,
        \\    .version = "0.1.0",
        \\}
    ;
    const name = parseZonName(content);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("vigil", name.?);
}

test "parseZonName - string literal format (older Zig)" {
    const content =
        \\.{
        \\    .name = "my_project",
        \\    .version = "0.1.0",
        \\}
    ;
    const name = parseZonName(content);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("my_project", name.?);
}

test "parseZonName - missing name field" {
    const content =
        \\.{
        \\    .version = "0.1.0",
        \\}
    ;
    try std.testing.expect(parseZonName(content) == null);
}

test "parseZonName - empty content" {
    try std.testing.expect(parseZonName("") == null);
}

test "parseZonName - name with underscores" {
    const content = ".name = .my_cool_project,";
    const name = parseZonName(content);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("my_cool_project", name.?);
}

// =============================================================================
// containsIgnoreCase Tests
// =============================================================================

test "containsIgnoreCase - empty needle always matches" {
    // Empty search query matches everything (standard behavior for incremental search)
    try std.testing.expect(containsIgnoreCase("hello", ""));
    try std.testing.expect(containsIgnoreCase("", ""));
}

test "containsIgnoreCase - needle longer than haystack" {
    // Can't find a 5-char needle in a 3-char haystack
    try std.testing.expect(!containsIgnoreCase("abc", "abcde"));
}

test "containsIgnoreCase - case insensitivity" {
    // The core functionality: case shouldn't matter
    try std.testing.expect(containsIgnoreCase("Hello World", "hello"));
    try std.testing.expect(containsIgnoreCase("Hello World", "WORLD"));
    try std.testing.expect(containsIgnoreCase("Hello World", "LO WO")); // Mixed case in middle
    try std.testing.expect(containsIgnoreCase("ERROR", "error"));
    try std.testing.expect(containsIgnoreCase("error", "ERROR"));
}

test "containsIgnoreCase - match positions" {
    const haystack = "the quick brown fox";
    // Match at start
    try std.testing.expect(containsIgnoreCase(haystack, "the"));
    // Match in middle
    try std.testing.expect(containsIgnoreCase(haystack, "quick"));
    // Match at end
    try std.testing.expect(containsIgnoreCase(haystack, "fox"));
    // Spanning word boundary
    try std.testing.expect(containsIgnoreCase(haystack, "k bro"));
}

test "containsIgnoreCase - no match" {
    try std.testing.expect(!containsIgnoreCase("hello world", "xyz"));
    try std.testing.expect(!containsIgnoreCase("hello world", "worlds")); // Partial at end
    try std.testing.expect(!containsIgnoreCase("abc", "abcd")); // Would extend past end
}

test "containsIgnoreCase - real search scenarios" {
    // Realistic error message searches
    const error_line = "src/main.zig:42:13: error: expected type 'u32'";
    try std.testing.expect(containsIgnoreCase(error_line, "error"));
    try std.testing.expect(containsIgnoreCase(error_line, "MAIN.ZIG"));
    try std.testing.expect(containsIgnoreCase(error_line, "u32"));
    try std.testing.expect(!containsIgnoreCase(error_line, "warning"));
}
