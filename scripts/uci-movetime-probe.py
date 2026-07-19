#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class ProbeResult:
    engine_cmd: list[str]
    go_args: dict[str, Any]
    position: str
    moves: list[str]
    bestmove: str | None
    ponder: str | None
    info: dict[str, Any]
    raw_info: str | None
    wall_elapsed_ms: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a simple UCI movetime probe and emit the final info line as JSON")
    parser.add_argument("--engine", nargs="+", required=True, help="Engine command and arguments")
    parser.add_argument("--uci-option", action="append", default=[], help="UCI option as Name=Value")
    parser.add_argument("--position", required=True, help="'startpos' or a full FEN string")
    parser.add_argument("--moves", nargs="*", default=[], help="Optional UCI moves to append to the position")
    parser.add_argument("--movetime-ms", type=int, default=None)
    parser.add_argument("--depth", type=int, default=None)
    parser.add_argument("--nodes", type=int, default=None)
    parser.add_argument("--wtime-ms", type=int, default=None)
    parser.add_argument("--btime-ms", type=int, default=None)
    parser.add_argument("--winc-ms", type=int, default=0)
    parser.add_argument("--binc-ms", type=int, default=0)
    parser.add_argument("--movestogo", type=int, default=None)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    args = parser.parse_args()
    if args.movetime_ms is None and args.depth is None and args.nodes is None and args.wtime_ms is None and args.btime_ms is None:
        args.movetime_ms = 1000
    return args


def send(proc: subprocess.Popen[str], command: str) -> None:
    assert proc.stdin is not None
    proc.stdin.write(command + "\n")
    proc.stdin.flush()


def read_until(proc: subprocess.Popen[str], predicate) -> list[str]:
    assert proc.stdout is not None
    lines: list[str] = []
    while True:
        line = proc.stdout.readline()
        if line == "":
            raise RuntimeError("engine exited before completing UCI handshake")
        line = line.rstrip("\n")
        lines.append(line)
        if predicate(line):
            return lines


def parse_info_line(line: str) -> dict[str, Any]:
    tokens = line.split()
    if not tokens or tokens[0] != "info":
        return {}

    out: dict[str, Any] = {}
    i = 1
    while i < len(tokens):
        token = tokens[i]
        if token in {"depth", "seldepth", "nodes", "nps", "hashfull", "time", "multipv"}:
            if i + 1 < len(tokens):
                try:
                    out[token] = int(tokens[i + 1])
                except ValueError:
                    out[token] = tokens[i + 1]
                i += 2
                continue
        if token == "score" and i + 2 < len(tokens):
            out["score_kind"] = tokens[i + 1]
            try:
                out["score_value"] = int(tokens[i + 2])
            except ValueError:
                out["score_value"] = tokens[i + 2]
            i += 3
            continue
        if token == "pv":
            out["pv"] = tokens[i + 1 :]
            break
        if token == "string":
            out["string"] = " ".join(tokens[i + 1 :])
            break
        i += 1
    return out


def run_probe(args: argparse.Namespace) -> ProbeResult:
    proc = subprocess.Popen(
        args.engine,
        cwd=args.cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    try:
        send(proc, "uci")
        read_until(proc, lambda line: line == "uciok")

        for option in args.uci_option:
            if "=" not in option:
                raise SystemExit(f"invalid --uci-option {option!r}; expected Name=Value")
            name, value = option.split("=", 1)
            send(proc, f"setoption name {name} value {value}")

        send(proc, "isready")
        read_until(proc, lambda line: line == "readyok")
        send(proc, "ucinewgame")
        send(proc, "isready")
        read_until(proc, lambda line: line == "readyok")

        position_cmd = "position startpos" if args.position == "startpos" else f"position fen {args.position}"
        if args.moves:
            position_cmd += " moves " + " ".join(args.moves)
        send(proc, position_cmd)
        started_at = time.monotonic()
        go_parts = ["go"]
        if args.movetime_ms is not None:
            go_parts += ["movetime", str(args.movetime_ms)]
        if args.depth is not None:
            go_parts += ["depth", str(args.depth)]
        if args.nodes is not None:
            go_parts += ["nodes", str(args.nodes)]
        if args.wtime_ms is not None:
            go_parts += ["wtime", str(args.wtime_ms)]
        if args.btime_ms is not None:
            go_parts += ["btime", str(args.btime_ms)]
        if args.winc_ms:
            go_parts += ["winc", str(args.winc_ms)]
        if args.binc_ms:
            go_parts += ["binc", str(args.binc_ms)]
        if args.movestogo is not None:
            go_parts += ["movestogo", str(args.movestogo)]
        send(proc, " ".join(go_parts))

        bestmove: str | None = None
        ponder: str | None = None
        last_info: dict[str, Any] = {}
        last_info_raw: str | None = None
        assert proc.stdout is not None
        while True:
            line = proc.stdout.readline()
            if line == "":
                raise RuntimeError("engine exited before bestmove")
            line = line.rstrip("\n")
            if line.startswith("info "):
                parsed = parse_info_line(line)
                if parsed:
                    last_info = parsed
                    last_info_raw = line
                continue
            if line.startswith("bestmove "):
                parts = line.split()
                if len(parts) >= 2:
                    bestmove = parts[1]
                if len(parts) >= 4 and parts[2] == "ponder":
                    ponder = parts[3]
                break

        send(proc, "quit")
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        wall_elapsed_ms = int(round((time.monotonic() - started_at) * 1000.0))
        return ProbeResult(
            engine_cmd=args.engine,
            go_args={
                'movetime_ms': args.movetime_ms,
                'depth': args.depth,
                'nodes': args.nodes,
                'wtime_ms': args.wtime_ms,
                'btime_ms': args.btime_ms,
                'winc_ms': args.winc_ms,
                'binc_ms': args.binc_ms,
                'movestogo': args.movestogo,
            },
            position=args.position,
            moves=list(args.moves),
            bestmove=bestmove,
            ponder=ponder,
            info=last_info,
            raw_info=last_info_raw,
            wall_elapsed_ms=wall_elapsed_ms,
        )
    finally:
        if proc.poll() is None:
            try:
                send(proc, "quit")
            except Exception:
                pass
            try:
                proc.kill()
            except Exception:
                pass


def main() -> None:
    args = parse_args()
    result = run_probe(args)
    print(json.dumps(result.__dict__, indent=2))


if __name__ == "__main__":
    main()
