#!/usr/bin/env python3
"""Side-by-side microbenchmarks for exact-int binary ops.

Compare two Python executables, typically a branch build and a baseline build:

    python Tools/scripts/int64_binary_op_bench.py \
        --baseline /tmp/cpython-origin-main/python.exe \
        --candidate ./python.exe
"""

from __future__ import annotations

import argparse
import os
import subprocess


CASES = (
    ("small+small add", "a=1; b=2", "a+b"),
    ("small+wide add", "a=1; b=10000000000", "a+b"),
    ("wide+small add", "a=10000000000; b=1", "a+b"),
    ("wide+wide add", "a=10000000000; b=10000000001", "a+b"),
    ("wide+wide add small", "a=10000000000; b=-9999999999", "a+b"),
    ("wide add overflow +", "a=(1<<63)-1; b=1", "a+b"),
    ("wide add overflow -", "a=-(1<<63); b=-1", "a+b"),
    ("small+three add", "a=1; b=1<<60", "a+b"),
    ("three+small add", "a=1<<60; b=1", "a+b"),
    ("three+three add", "a=1<<60; b=(1<<60)+1", "a+b"),
    ("small+three sub", "a=1; b=1<<60", "a-b"),
    ("three+small sub", "a=1<<60; b=1", "a-b"),
    ("three+three sub", "a=1<<60; b=(1<<60)+1", "a-b"),
    ("wide+small sub", "a=10000000000; b=1", "a-b"),
    ("wide+wide sub small", "a=10000000000; b=10000000001", "a-b"),
    ("wide+wide sub-", "a=10000000000; b=-1", "a-b"),
    ("wide sub overflow +", "a=(1<<63)-1; b=-1", "a-b"),
    ("wide sub overflow -", "a=-(1<<63); b=1", "a-b"),
)


def _run_timeit(executable: str, setup: str, stmt: str, number: int, repeat: int) -> float:
    code = (
        "import timeit\n"
        f"timer = timeit.Timer({stmt!r}, setup={setup!r})\n"
        f"runs = timer.repeat(repeat={repeat}, number={number})\n"
        "print(min(runs) / %d * 1e9)" % number
    )
    completed = subprocess.run(
        [executable, "-E", "-S", "-c", code],
        check=True,
        capture_output=True,
        text=True,
    )
    return float(completed.stdout.strip())


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare exact-int binary-op timings across two Python builds."
    )
    parser.add_argument(
        "--baseline",
        required=True,
        help="Path to the baseline Python executable, such as origin/main's python.exe",
    )
    parser.add_argument(
        "--candidate",
        default="./python.exe",
        help="Path to the candidate Python executable (default: ./python.exe)",
    )
    parser.add_argument(
        "--number",
        type=int,
        default=5_000_000,
        help="Timeit loop count per sample (default: 5,000,000)",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=5,
        help="Number of timeit repeats (default: 5)",
    )
    args = parser.parse_args()

    baseline = os.path.abspath(args.baseline)
    candidate = os.path.abspath(args.candidate)

    print(f"baseline:  {baseline}")
    print(f"candidate: {candidate}")
    print()
    print(f"{'case':<22}{'baseline ns/op':>16}{'candidate ns/op':>18}{'delta':>14}{'delta %':>10}")

    for name, setup, stmt in CASES:
        base = _run_timeit(baseline, setup, stmt, args.number, args.repeat)
        cand = _run_timeit(candidate, setup, stmt, args.number, args.repeat)
        delta = cand - base
        pct = (delta / base * 100.0) if base else 0.0
        print(f"{name:<22}{base:>16.2f}{cand:>18.2f}{delta:>14.2f}{pct:>9.2f}%")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
