//! Windows Job Object bindings for process group management.
//!
//! Job Objects are the Windows equivalent of POSIX process groups, but superior:
//! - All descendants of a job process are automatically added to the job
//! - TerminateJobObject() kills the entire process tree atomically
//!
//! These APIs are not wrapped by Zig's stdlib, so we declare raw FFI bindings.

const std = @import("std");
const windows = std.os.windows;

// Raw FFI declarations for kernel32 Job Object functions
pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: windows.HANDLE,
    hProcess: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn TerminateJobObject(
    hJob: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

/// Resumes a suspended Windows thread. Returns the previous suspend count, or
/// `windows.MAXDWORD` on failure.
pub extern "kernel32" fn ResumeThread(
    hThread: windows.HANDLE,
) callconv(.winapi) windows.DWORD;

pub const MAXDWORD: windows.DWORD = 0xFFFFFFFF;

/// Create a job object and assign a process to it.
/// Returns the job handle, or null on failure.
/// All child processes spawned by the assigned process will automatically
/// be added to the job (Windows 8+ nested job support).
pub fn createAndAssign(process_handle: windows.HANDLE) ?windows.HANDLE {
    const job = CreateJobObjectW(null, null) orelse return null;
    if (AssignProcessToJobObject(job, process_handle) == .FALSE) {
        windows.CloseHandle(job);
        return null;
    }
    return job;
}

/// Terminate all processes in the job and close the handle.
/// This atomically kills the entire process tree.
pub fn terminateAndClose(job: windows.HANDLE) void {
    _ = TerminateJobObject(job, 1);
    windows.CloseHandle(job);
}

/// Resume a suspended Windows thread. Returns true on success.
pub fn resumeThread(thread: windows.HANDLE) bool {
    const result = ResumeThread(thread);
    if (result == MAXDWORD) return false;
    // Previous suspend count > 0 means the thread was indeed suspended.
    // A return of 0 means the thread was not suspended — still a success
    // in our context (the child can proceed).
    return true;
}
