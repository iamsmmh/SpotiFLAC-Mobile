#!/usr/bin/env python3
"""Emit a CI log excerpt as one GitHub Actions check-run annotation.

GitHub Actions keeps only a small number of workflow-command annotations per
step. Emitting one annotation per log line therefore loses the diagnostic tail
on long compiler logs. This helper puts likely failure lines first, fills the
remaining excerpt from the tail, and encodes the result into one annotation
that remains retrievable through the Checks API.

Usage:
    ci_annotate.py LOG_FILE [--file NAME] [--max N]
"""

import argparse
import os
import re

_DIAGNOSTIC = re.compile(
    r"(?:\berror:|\bfatal error:|\bfailed\b|\bfailure:|undefined symbols?|"
    r"linker command failed|could not build|could not resolve|exception|"
    r"no such module|not found|duplicate symbol)",
    re.IGNORECASE,
)


def _select_excerpt(lines: list[str], limit: int) -> list[str]:
    nonempty = [(index, line) for index, line in enumerate(lines) if line.strip()]
    if len(nonempty) <= limit:
        return [line for _, line in nonempty]

    diagnostic_indices = [
        index for index, line in nonempty if _DIAGNOSTIC.search(line)
    ]
    # Failure summaries are normally near the end. Put the newest actionable
    # diagnostics first so they survive even if a consumer truncates messages.
    selected_indices: list[int] = []
    for index in reversed(diagnostic_indices):
        if index not in selected_indices:
            selected_indices.append(index)
        if len(selected_indices) >= limit // 2:
            break
    for index, _ in reversed(nonempty):
        if index not in selected_indices:
            selected_indices.append(index)
        if len(selected_indices) >= limit:
            break

    omitted = len(nonempty) - len(selected_indices)
    selected = [lines[index] for index in selected_indices]
    if omitted > 0:
        selected.append(f"... {omitted} non-empty lines omitted ...")
    return selected


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
        help="maximum lines included in the single annotation (default: 80)",
    )
    args = ap.parse_args()

    if not os.path.exists(args.log):
        return 0

    with open(args.log, errors="replace") as fh:
        lines = fh.read().splitlines()

    excerpt = _select_excerpt(lines, max(1, args.max))
    if not excerpt:
        return 0

    message = "\n".join(excerpt)
    # Workflow-command escaping: % -> %25, \r -> %0D, \n -> %0A.
    message = (
        message.replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
    )
    print(f"::error file={args.file}::{message[:60000]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
