//! Reference raw-profile dump (`-Dpgo-dump=true`, off by default) for checking
//! scripts/pgo/profsnap.py, which builds the profile from the live process instead.
//!
//! The binary is the context-sensitive PGO instrumented relink of the LTO bitcode
//! (`--lto-cs-profile-generate`, LLVM 20's libclang_rt.profile linked in). zigqueen is
//! libc-free, so the runtime's at-exit file writer never runs: main() calls dump() on its
//! way out instead, which writes the profile through the runtime's buffer API (that part
//! of the runtime needs only memcpy/memset). Normal builds never reference these symbols.
const std = @import("std");

extern fn __llvm_profile_get_size_for_buffer() u64;
extern fn __llvm_profile_write_buffer(buffer: [*]u8) c_int;

/// Raw-profile version 10 with the IR and context-sensitive variant bits. Clang's pre-link
/// pass creates this variable; with the instrumentation added only at link time nothing
/// does, and the runtime's weak default (front-end flavour) would make llvm-profdata
/// reject the profile.
export const __llvm_profile_raw_version: u64 = 10 | (1 << 56) | (1 << 57);

/// Writes the raw profile to $ZQ_PROFRAW (default `zigqueen.profraw` in the cwd).
pub fn dump() void {
    const allocator = std.heap.page_allocator;
    const env_path = std.process.getEnvVarOwned(allocator, "ZQ_PROFRAW") catch null;
    const path = env_path orelse "zigqueen.profraw";
    const size: usize = @intCast(__llvm_profile_get_size_for_buffer());
    const buffer = allocator.alloc(u8, size) catch return;
    if (__llvm_profile_write_buffer(buffer.ptr) != 0) return;
    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    file.writeAll(buffer) catch {};
}
