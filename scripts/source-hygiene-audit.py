#!/usr/bin/env python3
"""Audit Zig source for private top-level functions that nothing else mentions.

This conservative maintenance check counts any other identifier mention as a
reference, including functions passed as values to ``std.once`` or a thread
entry point.
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path

PRIVATE_FN_RE = re.compile(r"(?m)^(?:inline\s+)?fn\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(")


@dataclass(frozen=True)
class Finding:
    path: Path
    line: int
    name: str
    references: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("src"), help="source root to scan")
    parser.add_argument("--allow-findings", action="store_true", help="report findings but exit 0")
    parser.add_argument("--self-test", action="store_true", help="run built-in parser/audit tests")
    return parser.parse_args()


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def scan_text(path: Path, text: str) -> list[Finding]:
    findings: list[Finding] = []
    for match in PRIVATE_FN_RE.finditer(text):
        name = match.group("name")
        references = len(re.findall(rf"\b{re.escape(name)}\b", text)) - 1
        if references <= 0:
            findings.append(Finding(path=path, line=line_number(text, match.start()), name=name, references=references))
    return findings


def scan_file(path: Path) -> list[Finding]:
    return scan_text(path, path.read_text(encoding="utf-8", errors="replace"))


def format_report(findings: list[Finding]) -> list[str]:
    lines = ["path\tline\tname\treferences"]
    lines.extend(f"{item.path}\t{item.line}\t{item.name}\t{item.references}" for item in findings)
    lines.append(f"source_hygiene_findings={len(findings)}")
    return lines


def self_test() -> int:
    sample = """const std = @import(\"std\");
fn usedPrivate() void {}
inline fn usedInlinePrivate() void {}
pub fn publicApi() void { usedPrivate(); usedInlinePrivate(); }
pub inline fn publicInlineApi() void {}
var once = std.once(valueReferencedPrivate);
fn valueReferencedPrivate() void {}
pub fn spawner() void { _ = std.Thread.spawn(.{}, threadEntryPrivate, .{}); }
fn threadEntryPrivate() void {}
fn unusedPrivate() void {}
inline fn unusedInlinePrivate() void {}
"""
    findings = scan_text(Path("sample.zig"), sample)
    expected = [
        Finding(path=Path("sample.zig"), line=10, name="unusedPrivate", references=0),
        Finding(path=Path("sample.zig"), line=11, name="unusedInlinePrivate", references=0),
    ]
    if findings != expected:
        print("source_hygiene_audit_self_test_failed")
        print(f"expected={expected!r}")
        print(f"actual={findings!r}")
        return 1
    report = format_report(findings)
    if report[-1] != "source_hygiene_findings=2" or not report[0].startswith("path\tline"):
        print("source_hygiene_audit_self_test_failed")
        print(f"bad_report={report!r}")
        return 1
    empty_report = format_report([])
    if empty_report != ["path\tline\tname\treferences", "source_hygiene_findings=0"]:
        print("source_hygiene_audit_self_test_failed")
        print(f"bad_empty_report={empty_report!r}")
        return 1
    print("source_hygiene_audit_self_test_ok")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    if not args.root.is_dir():
        raise SystemExit(f"source root not found: {args.root}")

    findings: list[Finding] = []
    for path in sorted(args.root.rglob("*.zig")):
        findings.extend(scan_file(path))

    print("\n".join(format_report(findings)))
    if findings and not args.allow_findings:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
