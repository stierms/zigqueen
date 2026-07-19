#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import tempfile
from pathlib import Path

SCORE_MAP = {"1-0": (1.0, 0.0), "0-1": (0.0, 1.0), "1/2-1/2": (0.5, 0.5)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Write a compact two-engine match summary from a fastchess PGN")
    parser.add_argument("--pgn", type=Path)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--transcript", type=Path, help="Optional fastchess stdout/stderr transcript to summarize")
    parser.add_argument("--engine1", help="First engine name. If omitted, infer the two engine names from PGN headers.")
    parser.add_argument("--engine2", help="Second engine name. If omitted, infer the two engine names from PGN headers.")
    parser.add_argument("--metadata", action="append", default=[], help="Extra key=value line to include in the summary")
    parser.add_argument("--self-test", action="store_true", help="run built-in PGN/transcript parser tests")
    return parser.parse_args()


def header_value(line: str) -> str | None:
    match = re.search(r'"(.*)"', line)
    return match.group(1) if match else None


def infer_engines(pgn_path: Path) -> tuple[str, str]:
    names: list[str] = []
    for raw in pgn_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("[White ") or raw.startswith("[Black "):
            name = header_value(raw)
            if name is not None and name not in names:
                names.append(name)
                if len(names) == 2:
                    return names[0], names[1]
    raise SystemExit(f"failed to infer two engine names from {pgn_path}")


def parse_transcript(transcript_path: Path) -> list[str]:
    text = transcript_path.read_text(encoding="utf-8", errors="replace")
    lines = [f"fastchess_stdout_file={transcript_path}"]

    llr_matches = re.findall(
        r"^LLR:\s+([-+0-9.]+)\s+\(([-+0-9.]+)%\)\s+"
        r"\(([-+0-9.]+),\s*([-+0-9.]+)\)\s+"
        r"\[([-+0-9.]+),\s*([-+0-9.]+)\]",
        text,
        re.MULTILINE,
    )
    if llr_matches:
        llr, progress_pct, lower, upper, elo0, elo1 = llr_matches[-1]
        lines.extend(
            [
                f"sprt_llr={llr}",
                f"sprt_progress_pct={progress_pct}",
                f"sprt_lower_bound={lower}",
                f"sprt_upper_bound={upper}",
                f"sprt_reported_elo0={elo0}",
                f"sprt_reported_elo1={elo1}",
            ]
        )

    decision_matches = re.findall(
        r"^SPRT\s+\(\[([-+0-9.]+),\s*([-+0-9.]+)\]\)\s+completed\s+-\s+(H[01])\s+was accepted",
        text,
        re.MULTILINE,
    )
    if decision_matches:
        elo0, elo1, decision = decision_matches[-1]
        lines.extend(
            [
                f"sprt_decision={decision}",
                f"sprt_decision_elo0={elo0}",
                f"sprt_decision_elo1={elo1}",
            ]
        )

    total_time_matches = re.findall(r"^Total Time:\s+(.+)$", text, re.MULTILINE)
    if total_time_matches:
        lines.append(f"fastchess_total_time={total_time_matches[-1]}")
    return lines


def parse_scores(pgn_path: Path, engine1: str, engine2: str) -> dict[str, dict[str, float | int]]:
    records: dict[str, dict[str, float | int]] = {
        engine1: {"games": 0, "points": 0.0, "wins": 0, "losses": 0, "draws": 0},
        engine2: {"games": 0, "points": 0.0, "wins": 0, "losses": 0, "draws": 0},
    }
    white: str | None = None
    black: str | None = None
    result: str | None = None

    def consume() -> None:
        if white is None or black is None or result not in SCORE_MAP:
            return
        white_score, black_score = SCORE_MAP[result]
        for name, score in ((white, white_score), (black, black_score)):
            if name not in records:
                continue
            rec = records[name]
            rec["games"] = int(rec["games"]) + 1
            rec["points"] = float(rec["points"]) + score
            if score == 1.0:
                rec["wins"] = int(rec["wins"]) + 1
            elif score == 0.0:
                rec["losses"] = int(rec["losses"]) + 1
            else:
                rec["draws"] = int(rec["draws"]) + 1

    for raw in pgn_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("[White "):
            white = header_value(raw)
        elif raw.startswith("[Black "):
            black = header_value(raw)
        elif raw.startswith("[Result "):
            result = header_value(raw)
        elif raw == "":
            consume()
            white = black = result = None
    consume()
    return records


def self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        pgn = root / "match.pgn"
        transcript = root / "fastchess.log"
        pgn.write_text(
            '[White "engine-a"]\n[Black "engine-b"]\n[Result "1-0"]\n\n'
            '[White "engine-b"]\n[Black "engine-a"]\n[Result "1/2-1/2"]\n\n',
            encoding="utf-8",
        )
        transcript.write_text(
            "LLR: 1.23 (45.6%) (-2.00, 2.00) [0.00, 10.00]\n"
            "SPRT ([0.00, 10.00]) completed - H1 was accepted\n"
            "Total Time: 00:00:12\n",
            encoding="utf-8",
        )
        if infer_engines(pgn) != ("engine-a", "engine-b"):
            print("summarize_match_pgn_self_test_failed infer_engines")
            return 1
        records = parse_scores(pgn, "engine-a", "engine-b")
        expected_a = {"games": 2, "points": 1.5, "wins": 1, "losses": 0, "draws": 1}
        expected_b = {"games": 2, "points": 0.5, "wins": 0, "losses": 1, "draws": 1}
        if records["engine-a"] != expected_a or records["engine-b"] != expected_b:
            print("summarize_match_pgn_self_test_failed parse_scores")
            print(f"records={records!r}")
            return 1
        transcript_lines = parse_transcript(transcript)
        required = {"sprt_llr=1.23", "sprt_decision=H1", "fastchess_total_time=00:00:12"}
        if not required.issubset(set(transcript_lines)):
            print("summarize_match_pgn_self_test_failed parse_transcript")
            print(f"transcript_lines={transcript_lines!r}")
            return 1
    print("summarize_match_pgn_self_test_ok")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    if args.pgn is None or args.log is None or args.out is None:
        raise SystemExit("--pgn, --log, and --out are required unless --self-test is used")
    if (args.engine1 is None) != (args.engine2 is None):
        raise SystemExit("provide both --engine1 and --engine2, or omit both to infer from PGN")
    engine1, engine2 = (args.engine1, args.engine2) if args.engine1 is not None else infer_engines(args.pgn)
    records = parse_scores(args.pgn, engine1, engine2)
    lines = [
        "match_summary",
        f"pgn_file={args.pgn}",
        f"log_file={args.log}",
        f"engine1_name={engine1}",
        f"engine2_name={engine2}",
    ]
    lines.extend(args.metadata)
    if args.transcript is not None:
        lines.extend(parse_transcript(args.transcript))
    for name in (engine1, engine2):
        rec = records[name]
        games = int(rec["games"])
        points = float(rec["points"])
        pct = (100.0 * points / games) if games else 0.0
        lines.append(
            f"score {name}: games={games} points={points:.1f} score_pct={pct:.2f}% "
            f"wins={int(rec['wins'])} losses={int(rec['losses'])} draws={int(rec['draws'])}"
        )
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
