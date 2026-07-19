#!/usr/bin/env python3
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} <worktree-dir>")

worktree = Path(sys.argv[1])
path = worktree / "src/uci/protocol.zig"
if not path.is_file():
    print(f"skip: {path} missing")
    raise SystemExit(0)

text = path.read_text(encoding="utf-8")
old_block = """const StdoutOutput = struct {
    mutex: std.Thread.Mutex = .{},
    file: std.fs.File = std.fs.File.stdout(),

    fn sink(self: *StdoutOutput) worker_mod.OutputSink {
        return .{ .ctx = self, .write_fn = write };
    }
"""
new_block = """const StdoutOutput = struct {
    mutex: std.Thread.Mutex = .{},
    file: std.fs.File,

    fn init() StdoutOutput {
        return .{ .file = std.fs.File.stdout() };
    }

    fn sink(self: *StdoutOutput) worker_mod.OutputSink {
        return .{ .ctx = self, .write_fn = write };
    }
"""
old_run = "var stdout_output = StdoutOutput{};"
new_run = "var stdout_output = StdoutOutput.init();"

changed = False
if old_block in text:
    text = text.replace(old_block, new_block)
    changed = True
if old_run in text:
    text = text.replace(old_run, new_run)
    changed = True

if changed:
    path.write_text(text, encoding="utf-8")
    print(f"patched: {path}")
else:
    print(f"no-op: {path}")
