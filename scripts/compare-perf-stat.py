#!/usr/bin/env python3
"""Compare two Linux perf stat stderr files.

The script intentionally parses only the stable metric prefix that appears in this
repo's profiling artifacts and prints a compact tab-separated delta table.
"""

from __future__ import annotations

import argparse
import re
import tempfile
from pathlib import Path

METRICS = (
    "seconds_time_elapsed",
    "task_clock_msec",
    "cycles",
    "instructions",
    "branches",
    "branch_misses",
)

NUMBER_RE = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)")


def parse_number(text: str) -> float:
    match = NUMBER_RE.search(text.replace(",", ""))
    if not match:
        raise ValueError(f"missing numeric value in line: {text!r}")
    return float(match.group(0))


def parse_perf_stat(path: Path) -> dict[str, float]:
    values: dict[str, float] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if "seconds time elapsed" in line:
            values["seconds_time_elapsed"] = parse_number(line)
            continue
        if "msec task-clock" in line:
            values["task_clock_msec"] = parse_number(line)
            continue

        fields = line.split()
        if len(fields) < 2:
            continue
        metric = fields[1]
        if metric.startswith("cycles"):
            values["cycles"] = parse_number(fields[0])
        elif metric.startswith("instructions"):
            values["instructions"] = parse_number(fields[0])
        elif metric.startswith("branches"):
            values["branches"] = parse_number(fields[0])
        elif metric.startswith("branch-misses"):
            values["branch_misses"] = parse_number(fields[0])
    return values


def delta_pct(baseline: float, candidate: float) -> float:
    if baseline == 0:
        return 0.0 if candidate == 0 else float("inf")
    return (candidate - baseline) * 100.0 / baseline


def self_test() -> int:
    if parse_number("1,234 cycles") != 1234.0:
        print("compare_perf_stat_self_test_failed parse_commas")
        return 1
    if delta_pct(100.0, 90.0) != -10.0 or delta_pct(0.0, 0.0) != 0.0:
        print("compare_perf_stat_self_test_failed delta_pct")
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "perf.stderr.txt"
        path.write_text(
            "1.25 seconds time elapsed\n"
            "250.0 msec task-clock\n"
            "1,000 cycles\n"
            "2,000 instructions\n"
            "300 branches\n"
            "12 branch-misses\n",
            encoding="utf-8",
        )
        parsed = parse_perf_stat(path)
    expected = {
        "seconds_time_elapsed": 1.25,
        "task_clock_msec": 250.0,
        "cycles": 1000.0,
        "instructions": 2000.0,
        "branches": 300.0,
        "branch_misses": 12.0,
    }
    if parsed != expected:
        print("compare_perf_stat_self_test_failed parse_perf_stat")
        print(f"expected={expected!r}")
        print(f"actual={parsed!r}")
        return 1
    print("compare_perf_stat_self_test_ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, nargs="?", help="baseline perf stat stderr")
    parser.add_argument("candidate", type=Path, nargs="?", help="candidate perf stat stderr")
    parser.add_argument("--self-test", action="store_true", help="run built-in perf parser tests")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.baseline is None or args.candidate is None:
        parser.error("baseline and candidate are required unless --self-test is used")

    baseline = parse_perf_stat(args.baseline)
    candidate = parse_perf_stat(args.candidate)

    print("metric\tbaseline\tcandidate\tdelta_pct")
    for metric in METRICS:
        if metric not in baseline or metric not in candidate:
            continue
        b = baseline[metric]
        c = candidate[metric]
        print(f"{metric}\t{b:.6g}\t{c:.6g}\t{delta_pct(b, c):+.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
