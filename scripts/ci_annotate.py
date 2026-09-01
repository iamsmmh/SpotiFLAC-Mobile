#!/usr/bin/env python3
"""Emit a log file as GitHub Actions check-run annotations.

GitHub Actions stores ``::error::`` workflow-command output as annotations on
the job's check run. They are visible in the Actions UI and retrievable via the
checks API, even when the log artifact cannot be downloaded (expired, missing
permissions, or network-restricted environments). CI jobs should call this
helper on failure so the *real* error is always discoverable.

Usage:
    ci_annotate.py LOG_FILE [--file NAME] [--max N]

Example:
    python3 scripts/ci_annotate.py xcodebuild.log --file xcodebuild-archive.log --max 60

If the log has more than ``--max`` lines, the head and tail are kept (the
actionable error is usually at the end) and the middle is summarized.
"""

import argparse
import os


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log", help="path to the log file to annotate")
    ap.add_argument(
        "--file",
        default="ci.log",
        help="value for the annotation 'file' property (default: ci.log)",
    )
    ap.add_argument(
        "--max",
        type=int,
        default=80,
        help="maximum number of annotation lines (default: 80)",
    )
    args = ap.parse_args()

    if not os.path.exists(args.log):
        return 0

    with open(args.log, errors="replace") as fh:
        lines = fh.read().splitlines()

    if len(lines) > args.max:
        head = args.max // 2
        tail = args.max - head - 1
        omitted = len(lines) - args.max
        lines = lines[:head] + [f"... {omitted} lines omitted ..."] + lines[-tail:]

    for line in lines:
        if not line.strip():
            continue
        # Workflow-command escaping: % -> %25, \r -> %0D, \n -> %0A.
        msg = (
            line.replace("%", "%25")
            .replace("\r", "%0D")
            .replace("\n", "%0A")
        )
        print(f"::error file={args.file}::{msg[:2000]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
