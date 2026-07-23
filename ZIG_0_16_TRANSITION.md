# Zig 0.16.0 Transition Plan

This plan moves Vigil from the current Zig 0.15-era API surface to Zig 0.16.0.
The compiler in the local test environment is already `0.16.0`.

## Current Status

**✅ MIGRATION COMPLETE (2026-07-10)**

Vigil now builds, tests, and runs with Zig 0.16.0. All automated checks pass
including native tests, `--help`, `--version`, and cross-compilation for
Windows and macOS.

The migration was performed according to the approved plan at
`docs/plans/zig-0.16-migration.md`.

### Dependency

libvaxis is pinned to upstream commit
`ca781b3c01f44a92e5331652823b5a9ce445be96` (declared version 0.6.0,
requires Zig 0.16.0). No v0.6.0 release tag exists; we pin a commit.

## Relevant 0.16 Changes

- Standard library I/O, filesystem, and process APIs moved toward `std.Io`.
  The release notes show `std.fs.cwd()` becoming `std.Io.Dir.cwd`, many file
  operations taking an `io` argument, and `std.process.Child` helpers moving to
  `std.process.spawn` / `std.process.run`.
- CLI arguments and environment variables are no longer globally available in
  the old way. `main` should accept `std.process.Init` or
  `std.process.Init.Minimal` when it needs argv/env access.
- `std.mem.indexOf` is renamed toward `std.mem.find`; existing uses may still
  compile for now, but they should be cleaned up during the port.
- Zig 0.16 fetches dependencies into project-local `zig-pkg/`, and adds
  `zig build --fork=[path]` for temporary dependency forks.
- Package manifests now require the new package metadata rules, including
  fingerprint and enum-literal package names.

Primary source: https://ziglang.org/download/0.16.0/release-notes.html

## What Changed

### Entrypoint (`src/main.zig`)
- `main` now accepts `std.process.Init`, using `init.gpa`, `init.io`, and `init.environ_map`
- Cross-platform argument iteration uses `std.process.Args.Iterator.initAllocator`
- Argument classification uses incremental `ArgClass.feed()` state machine

### I/O and Filesystem (`src/app.zig`, `src/watch.zig`)
- `std.Io` threaded through `App` and `Watcher`
- Project detection uses `std.Io.Dir.cwd()` and `Dir.readFile`
- `std.process.currentPath` with stack scratch buffer replaces `realpathAlloc`
- `std.Thread.sleep` → `std.Io.sleep(io, duration, .awake)`
- `std.time.nanoTimestamp` → `std.Io.Timestamp.now(io, .awake)`

### libvaxis 0.16 (`src/app.zig`)
- `Tty.init(io, buffer)`, `Vaxis.init(io, alloc, environ_map, opts)`
- `Loop.init(io, tty, vx)`, fallible `Loop.tryEvent()`
- `queryTerminal(writer, Duration.fromSeconds(1))`
- Writer type changed to `*std.Io.Writer`

### Process Execution (`src/app.zig`)
- `std.process.run(alloc, io, opts)` for synchronous path
- `std.process.spawn(io, opts)` + `MultiReader` for cancellable path
- `MultiReader.fill` / `reader` pattern for bounded concurrent pipe draining
- Unused stdout is counted and discarded incrementally; stderr is retained for diagnostics
- `.pgid = 0` for POSIX process group creation (handled by child before exec)
- Lowercase `Child.Term` tags: `.exited`, `.signal`, `.stopped`, `.unknown`
- Limit enforcement with group/job termination on overflow

### Windows (`src/windows_job.zig`)
- `BOOL` comparison updated: `== 0` → `== .FALSE` (Win32 BOOL is now enum)
- Added `ResumeThread` extern binding + `resumeThread` helper for suspended spawn

### stdlib Cleanup
- `std.mem.trimLeft` → `std.mem.trimStart`
- `std.mem.indexOf` → `std.mem.find` (alias, done for cleanliness)

## Historical Phases (all completed as of 2026-07-10)

### Phase 1: Unblock Dependencies ✅

1. Upgraded libvaxis to upstream commit
   `ca781b3c01f44a92e5331652823b5a9ce445be96` (declared 0.6.0, requires
   Zig 0.16.0). No v0.6.0 tag existed at migration time.
2. Refreshed with `zig fetch --save`; transitive zigimg/uucode now match the
   Zig 0.16-compatible tree.

### Phase 2: Port Vigil Entrypoint and I/O Shape ✅

Completed in `src/main.zig`, `src/app.zig`, `src/watch.zig`.
- Entrypoint uses `std.process.Init` with `Iterator.initAllocator`.
- `std.Io` threaded through `App` and `Watcher`.
- Filesystem calls migrated to `std.Io.Dir` / `std.Io.File`.
- `windows_job.zig` extern signatures updated; `BOOL == 0` → `.FALSE`; added `ResumeThread` binding.

### Phase 3: Port Build Execution ✅

- Synchronous: `std.process.run(alloc, io, .{...})` with `Limit.limited(n)`.
- Cancellable: `std.process.spawn(io, .{...})` + `MultiReader.fill`/`reader`.
- POSIX: `.pgid = 0` at spawn (child calls `setpgid(0,0)` before exec).
- Windows: Suspended spawn + Job Object assignment + resume (see below).
- Cumulative stdout and retained stderr are checked for `MAX_TEXT_SIZE` after every fill.

### Phase 4: Mechanical stdlib Cleanup ✅

- `std.mem.indexOf` → `std.mem.find` across parse.zig and render.zig.
- `std.mem.trimLeft` → `std.mem.trimStart`.
- Lowercase `Child.Term` tags: `.exited`, `.signal`, `.stopped`, `.unknown`.

### Phase 5: Validation Matrix ✅

All automated checks pass (see `docs/plans/zig-0.16-migration.md`).
Manual TUI and platform checks to be completed on Linux/macOS/Windows hosts.

## Windows Process Management

Windows children are spawned suspended (`SpawnOptions.start_suspended`),
assigned to a Job Object, and then resumed via a checked `kernel32
ResumeThread` binding. The job handle is published before resume so
`cancelBuild` can see it. If assignment or resume fails, the job is
atomically taken + terminated, the suspended child is killed, and the
error is surfaced. This closes the pre-migration assign-after-spawn race
without relying on unsupported handle manipulation.
