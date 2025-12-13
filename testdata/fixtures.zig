//! Test fixtures for golden tests.
//! Embedded at compile time for hermetic, CWD-independent tests.

pub const compile_error = @embedFile("compile_error.txt");
pub const test_failure = @embedFile("test_failure.txt");
pub const success = @embedFile("success.txt");
