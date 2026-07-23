# Zig 0.16.0 Migration

## Goal

Make Vigil build, test, and run with the stable Zig 0.16.0 toolchain while
preserving its terminal UI, project detection, file watching, bounded build
output capture, and whole-process-tree cancellation behavior on supported
platforms. This is a compatibility migration only: public behavior and APIs
must not change, and source, build metadata, dependency pins, generated-package
hygiene, platform builds, and developer documentation are all in scope.

## Context

- The local compiler is already Zig 0.16.0.
- A fresh `zig build test` on 2026-07-10 stops before compiling Vigil because
  the pinned
  libvaxis 0.5.1 tree contains a Zig 0.15-era `uucode` build script. Its
  unmanaged map insertion does not pass an allocator.
- `build.zig.zon` pins libvaxis commit
  `5915f33c1a7a184d3fb2aa39f087c1e6864a4308`. As of 2026-07-10, upstream has
  no `v0.6.0` tag, but main commit
  `ca781b3c01f44a92e5331652823b5a9ce445be96` declares version 0.6.0,
  requires Zig 0.16.0, and uses Zig 0.16-compatible transitive dependencies.
- Zig 0.16 moves argument, environment, filesystem, process, and much terminal
  I/O access to `std.process.Init` and `std.Io`. Current uses are concentrated
  in `src/main.zig`, `src/app.zig`, and `src/watch.zig`.
- Current libvaxis main also requires `std.Io` and an environment map during
  initialization. Its TTY and event-loop constructors now take `std.Io`;
  `Loop.tryEvent` is fallible and terminal-query timeouts use `std.Io.Duration`.
- Build execution in `src/app.zig` uses removed `std.process.Child` 0.15 APIs.
  The cancellable path must continue draining stdout and stderr without
  deadlock, limiting captured output, reaping the child, and terminating all
  descendants on cancellation.
- `src/windows_job.zig` and Windows-only fields in `src/app.zig` use Windows
  types through `std.os.windows`; these must be compiled against 0.16 even
  though runtime validation may require a Windows host.
- The untracked `ZIG_0_16_TRANSITION.md` contains useful earlier investigation.
  It is source material for this plan and must not be deleted. Because the
  requested scope includes developer docs, update its status and stale proposed
  commit/API details after the migration while preserving the useful history.
- No CI configuration or separate toolchain-version file exists in the current
  tree. The manifest, README, architecture guide, transition note, build script,
  and source are the applicable version/API surfaces.

## Design

Use Zig 0.16 end-to-end rather than adding a 0.15/0.16 compatibility layer.
Accept `std.process.Init` in `main`, iterate `init.minimal.args` with the
allocator-backed cross-platform iterator, and keep that iterator alive for the
entire application run because Windows argument slices borrow its storage.
Thread `init.io`, `init.gpa`, and `init.environ_map` into the application. This
avoids maintaining a second general-purpose allocator and matches both Zig's
new entrypoint model and the current libvaxis API. Treat the environment map as
read-only for the whole run, including when the worker thread spawns builds.
Extract argument classification into a pure incremental helper over string
slices so help, version, initial test mode, passthrough arguments, and the
command-argument cap can be unit tested without constructing
`std.process.Init` or pre-capping the iterator.

Pin libvaxis to a verified Zig 0.16-compatible commit because no 0.6.0 release
tag currently exists. Record `.minimum_zig_version = "0.16.0"` in Vigil's
manifest and refresh the package hash through Zig tooling. Do not patch files
inside generated `zig-pkg/`; add that Zig 0.16 package directory to
`.gitignore` instead.

Store `std.Io` on `App` and pass it to the watcher and process helpers. Port
project discovery and polling directly to `std.Io.Dir`/`std.Io.File`, keeping
the existing fixed-depth iterative traversal and ignored-directory behavior.
Use `std.process.currentPath` with a `std.fs.max_path_bytes` stack scratch
buffer, then retain the existing copy-to-fixed-buffer behavior. This preserves
the current silent truncation semantics for paths longer than
`types.MAX_PATH_LEN` without a heap allocation.

Initialize libvaxis through its 0.16 API (`Tty.init(io, ...)`,
`vaxis.init(io, alloc, environ_map, ...)`, and `Loop.init(io, ...)`). Keep the
existing lifecycle order and legacy SGR setting, install/uninstall the resize
handler when needed to preserve SIGWINCH behavior, propagate errors from
`Loop.tryEvent`, and express the query timeout as
`std.Io.Duration.fromSeconds(1)`. Verify the remaining used 0.6 surfaces against
the pinned commit: `enterAltScreen`, `exitAltScreen`, `queryTerminal`, `render`,
`resize`, `Tty.writer`, and the `Window` `window`/`child`/`clear`/`fill`/`print`/
`writeCell` calls in `src/render.zig`.

For simple synchronous execution, use `std.process.run`. For cancellable
background execution, use `std.process.spawn` with piped stdout/stderr and
`std.Io.File.MultiReader` so neither pipe can block the child. Enforce
`MAX_TEXT_SIZE` independently while draining rather than allowing an unbounded
buffer, preserve stderr-as-report behavior, and always close pipes and reap the
child. Use `.pgid = 0` at spawn time on POSIX; Zig 0.16 performs
`setpgid(0, 0)` in the child before `exec`, removing the parent-side race. Retain
the Windows Job Object path using the 0.16 process handle. Spawn the Windows
child suspended, assign it to the job, publish the job handle, and resume its
public 0.16 thread handle through a checked `ResumeThread` binding. This closes
the previous assign-after-spawn race. External cancellation and every
post-spawn error/limit path must terminate the group or job before normal child
cleanup so no descendants are orphaned. After a
successful spawn, every path must end in exactly one `child.wait(io)` after any
required group/job termination, or `child.kill(io)` only when a normal wait is
not possible; `MultiReader.deinit` frees buffers but does not close child pipe
descriptors. On a size overrun, stop filling, kill the process group/job first,
then wait. Never substitute direct-child `child.kill(io)` for group/job
termination on those paths. Count and discard unused stdout incrementally while
enforcing its cumulative limit, and retain only the stderr slice returned to the
application.

Migrate mechanical API changes only where required or directly related:
lowercase `Child.Term` tags, `std.mem.find`, I/O-aware close/read calls, and
updated libvaxis initialization/loop calls. Avoid unrelated refactoring so
behavioral regressions are easier to isolate.

## Implementation Steps

1. Update project metadata and dependency hygiene.
   - Add `.minimum_zig_version = "0.16.0"` to `build.zig.zon`.
   - Pin libvaxis to the selected Zig 0.16-compatible upstream commit and
     regenerate its package hash with `zig fetch --save` (prefer a stable
     `v0.6.0` tag only if one appears before implementation).
   - Ignore project-local `zig-pkg/`; do not commit or edit fetched dependency
     contents.
   - Update README installation requirements from Zig 0.15.2 to Zig 0.16.0.

2. Port the entrypoint and libvaxis lifecycle.
   - Change `main` to accept `std.process.Init`, initialize and defer the
     allocator-backed argument iterator, skip argv[0], and consume arguments
     cross-platform while preserving help, version, `test`, passthrough
     arguments, and the command-argument cap.
   - Extract and test a pure incremental argument-classification helper while
     keeping the iterator and any borrowed Windows argument slices alive through
     `App.run`.
   - Use `init.gpa`, `init.io`, and `init.environ_map`; remove the project-owned
     GPA and old `std.os.argv`/`argsAlloc` branching.
   - Add `std.Io` to `App`, update `App.init`, TTY/Vaxis initialization,
     event-loop initialization, resize-handler lifecycle, fallible event reads,
     query timeout, and all affected cleanup/render writer calls for current
     libvaxis main. Verify all existing `src/render.zig` Window operations still
     match the pinned commit rather than assuming only constructors changed.

3. Port project discovery and file watching.
   - Replace `std.fs.cwd()` and old file/directory APIs in `src/app.zig` and
     `src/watch.zig` with `std.Io` equivalents.
   - Obtain the current path in a max-path stack scratch buffer before copying
     into `project_root`, preserving the existing fixed-buffer truncation
     behavior.
   - Thread `std.Io` into `Watcher` without changing debounce, pause/resume,
     traversal depth, hidden-file filtering, or mtime semantics.
   - Ensure every opened file/directory is closed with the same `std.Io`,
     including error and depth-limit paths.

4. Port process execution and cancellation.
   - Convert the synchronous helper to `std.process.run` with independent
     stdout/stderr limits and correct ownership cleanup.
   - Convert the cancellable helper to `std.process.spawn` and
     `std.Io.File.MultiReader`; drain both pipes concurrently, enforce the
     bounds during collection, wait/reap on every path, and map lowercase
     termination tags to the existing optional exit code. Make one component
     responsible for child cleanup: `MultiReader.deinit` is not a substitute
     for `child.wait(io)`/`child.kill(io)` because it does not close pipe FDs.
   - Establish a child process group with `.pgid = 0` at spawn time on POSIX
     and preserve atomic publication/clearing of its ID. Keep group-wide
     cancellation and apply it on collection/limit errors as well as user
     cancellation. On a limit error, stop reading, terminate the entire group,
     and only then wait/reap; killing or waiting on the direct child first can
     deadlock or orphan descendants.
   - Adapt Windows Job Object assignment and handle cleanup to the 0.16 child
     process handle. Spawn suspended, assign to the job, publish ownership, and
     resume through a checked binding, preserving job-wide cancellation without
     double-close or stale-handle races. Treat inability to establish or resume
     required cancellation ownership as an execution failure rather than
     silently running an unmanageable child.
   - Count and discard stdout incrementally during concurrent collection and
     transfer ownership of only stderr to `BuildResult`. Keep the currently unused synchronous
     `runBuild`/`runBuildCmd` public surface compiling, while noting that the
     main event loop exercises only the cancellable path.
   - Keep the existing raw Job Object extern signatures and add only the minimal
     checked `ResumeThread` binding needed for suspended assign/resume. At the
     caller, account for optional `Child.id` and the Windows process/thread
     handle types.

5. Resolve remaining compiler errors narrowly.
   - Replace deprecated `std.mem.indexOf` aliases with `std.mem.find` across
     `src/`; this is cleanup rather than a compiler blocker in Zig 0.16.
   - Update stale Zig 0.15 comments and any directly affected stdlib/libvaxis
     call sites.
   - Run formatting and avoid changing test fixture text that intentionally
     represents Zig 0.15 diagnostics unless tests show the fixture format is
     no longer representative.

6. Update user-facing and migration documentation.
   - Keep README requirements and platform notes accurate.
   - Update `ARCHITECTURE.md` examples and API names to match the migrated
     allocator, I/O, watcher, libvaxis, and process lifecycle.
   - Retain `ZIG_0_16_TRANSITION.md`, mark the migration status accurately, and
     update stale proposed dependency/API details without discarding its useful
     investigation. The plan under `docs/plans/` remains the canonical workflow
     record.

## Test Plan

Automated checks on the local Zig 0.16.0 toolchain:

```sh
zig fmt --check build.zig build.zig.zon src testdata/fixtures.zig
zig build test
zig build
zig build run -- --help
zig build run -- --version
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos
```

Add or adapt unit tests where seams permit, especially for argument handling,
project-name parsing, watcher state transitions, termination-to-exit-code
mapping, simultaneous stdout/stderr draining, output-limit behavior, and cleanup
after process errors. Existing parse/render/input/type tests must continue to
pass. Do not rewrite fixture strings that intentionally model older compiler
paths unless their format is no longer accepted by the parser.

Manual Linux TUI checks:

- Start in both build and test modes and confirm output updates.
- Edit a watched Zig file and confirm exactly one debounced rebuild.
- Exercise pause/resume, build/test switching, terse/full mode, wrapping,
  search navigation, help, scrolling, and quit.
- Start a build that spawns descendants, cancel or switch jobs, and verify the
  complete process group exits without orphaned children.
- Confirm terminal state is restored after normal exit and an error path.

Cross-compilation validates Windows/macOS code shape, but runtime smoke tests
for terminal behavior and process-tree cancellation should be performed on
those hosts when available.

## Risks / Open Questions

- **Unreleased dependency:** libvaxis reports 0.6.0 but has no matching tag.
  Pinning a commit is reproducible but not a stable release. The chosen commit
  should be recorded exactly and only advanced to fix a demonstrated issue.
- **Dependency API drift:** current libvaxis main changes initialization,
  event-loop concurrency, and terminal I/O. These changes may expose more call
  site updates after the dependency is unblocked.
- **Pipe draining and cancellation:** a sequential read can deadlock when one
  child pipe fills. The implementation must use Zig 0.16's multi-stream drain,
  enforce limits during collection, and prove cleanup for success, size-limit,
  cancellation, and read-error paths.
- **POSIX process groups:** local Zig 0.16 stdlib inspection confirms `.pgid =
  0` calls `setpgid(0, 0)` in the child before `exec`. Cross-compilation still
  cannot runtime-prove group cancellation on every POSIX target.
- **Windows race (RESOLVED):** Zig 0.16's public `SpawnOptions.start_suspended`
  and `Child.thread_handle` were used successfully. Children are spawned
  suspended, assigned to the Job Object, and resumed via a checked `kernel32
  ResumeThread` binding. This closes the pre-migration assign-after-spawn race.
  Assignment or resume failure still terminates the child and surfaces as an
  execution failure.
- **Platform validation:** Linux can provide full automated and manual checks;
  cross-compilation alone cannot prove macOS terminal behavior or Windows Job
  Object cancellation.
- **Pre-existing untracked work:** `ZIG_0_16_TRANSITION.md` and `zig-pkg/` were
  present before this workflow. Implementation must not mistake them for new
  deliverables or delete user work. The transition note may be updated in place
  as scoped developer documentation; generated `zig-pkg/` must not be edited
  and should merely become ignored.
- **Formatting scope decision:** the critic suggested `zig fmt --check .`, but
  this repository already contains generated, untracked dependency sources in
  `zig-pkg/`. The explicit formatting command intentionally covers every
  project-owned Zig/ZON surface while excluding generated dependencies; using
  `.` would incorrectly make third-party formatting part of acceptance.
