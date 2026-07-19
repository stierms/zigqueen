#!/usr/bin/env python3
"""Compare fixed-depth zigqueen outputs while ignoring volatile timing fields.

This helper is intended for exact-output performance work. It compares bench,
search_profile, or similar line-oriented command outputs and ignores fields that
are expected to vary between runs without indicating a search-behavior change.
"""

from __future__ import annotations

import argparse
import difflib
import tempfile
from pathlib import Path

DEFAULT_IGNORED_KEYS = {
    "time_ms",
    "nps",
    "hashfull",
    "last_iteration_elapsed_ms",
    "projected_next_iteration_ms",
}
DEFAULT_IGNORED_PREFIXES = (
    "time_",
    "nps_",
)


def normalized_lines(path: Path, ignored_keys: set[str], ignored_prefixes: tuple[str, ...]) -> list[str]:
    lines: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip("\r")
        if not line.strip():
            continue
        key = line.split(maxsplit=1)[0]
        if key in ignored_keys:
            continue
        if any(key.startswith(prefix) for prefix in ignored_prefixes):
            continue
        lines.append(line)
    return lines


def parse_csv_set(text: str) -> set[str]:
    if not text:
        return set()
    return {part.strip() for part in text.split(",") if part.strip()}


def self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        baseline = root / "baseline.txt"
        candidate = root / "candidate.txt"
        baseline.write_text("bestmove e2e4\ntime_ms 100\nnps 1000\nnodes 42\n", encoding="utf-8")
        candidate.write_text("bestmove e2e4\ntime_ms 200\nnps 900\nnodes 42\n", encoding="utf-8")
        if normalized_lines(baseline, set(DEFAULT_IGNORED_KEYS), DEFAULT_IGNORED_PREFIXES) != ["bestmove e2e4", "nodes 42"]:
            print("compare_fixed_output_self_test_failed normalization")
            return 1
        if normalized_lines(baseline, set(DEFAULT_IGNORED_KEYS), DEFAULT_IGNORED_PREFIXES) != normalized_lines(
            candidate,
            set(DEFAULT_IGNORED_KEYS),
            DEFAULT_IGNORED_PREFIXES,
        ):
            print("compare_fixed_output_self_test_failed volatile_match")
            return 1
        candidate.write_text("bestmove d2d4\ntime_ms 200\nnps 900\nnodes 42\n", encoding="utf-8")
        if normalized_lines(baseline, set(DEFAULT_IGNORED_KEYS), DEFAULT_IGNORED_PREFIXES) == normalized_lines(
            candidate,
            set(DEFAULT_IGNORED_KEYS),
            DEFAULT_IGNORED_PREFIXES,
        ):
            print("compare_fixed_output_self_test_failed behavior_mismatch")
            return 1
    if parse_csv_set("alpha,beta, alpha, ") != {"alpha", "beta"}:
        print("compare_fixed_output_self_test_failed csv_parse")
        return 1
    print("compare_fixed_output_self_test_ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, nargs="?", help="baseline output file")
    parser.add_argument("candidate", type=Path, nargs="?", help="candidate output file")
    parser.add_argument("--self-test", action="store_true", help="run built-in normalization tests")
    parser.add_argument(
        "--ignore-key",
        action="append",
        default=[],
        help="additional first-token key to ignore; may be repeated or comma-separated",
    )
    parser.add_argument(
        "--ignore-prefix",
        action="append",
        default=[],
        help="additional first-token prefix to ignore; may be repeated or comma-separated",
    )
    parser.add_argument(
        "--no-default-ignores",
        action="store_true",
        help="compare every nonblank line except explicitly ignored keys/prefixes",
    )
    parser.add_argument(
        "--diff-lines",
        type=int,
        default=120,
        help="maximum unified-diff lines to print on mismatch (default: 120)",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.baseline is None or args.candidate is None:
        parser.error("baseline and candidate are required unless --self-test is used")

    ignored_keys: set[str] = set() if args.no_default_ignores else set(DEFAULT_IGNORED_KEYS)
    ignored_prefixes: tuple[str, ...] = () if args.no_default_ignores else DEFAULT_IGNORED_PREFIXES
    for item in args.ignore_key:
        ignored_keys.update(parse_csv_set(item))
    extra_prefixes: list[str] = list(ignored_prefixes)
    for item in args.ignore_prefix:
        extra_prefixes.extend(sorted(parse_csv_set(item)))
    ignored_prefixes = tuple(extra_prefixes)

    baseline = normalized_lines(args.baseline, ignored_keys, ignored_prefixes)
    candidate = normalized_lines(args.candidate, ignored_keys, ignored_prefixes)

    if baseline == candidate:
        print("fixed_output_match=true")
        print(f"compared_lines={len(baseline)}")
        return 0

    print("fixed_output_match=false")
    print(f"baseline_lines={len(baseline)}")
    print(f"candidate_lines={len(candidate)}")
    diff = list(
        difflib.unified_diff(
            baseline,
            candidate,
            fromfile=str(args.baseline),
            tofile=str(args.candidate),
            lineterm="",
        )
    )
    for line in diff[: args.diff_lines]:
        print(line)
    if len(diff) > args.diff_lines:
        print(f"... diff truncated after {args.diff_lines} lines of {len(diff)} total")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
