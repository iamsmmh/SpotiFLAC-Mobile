#!/usr/bin/env python3
"""Emit one GitHub Actions annotation per failing Flutter test.

`flutter test --reporter github` wraps each failing test's exception and
stack trace in a ``::group::...::endgroup::`` block placed immediately after
its ``\\u274c`` (cross-mark) line. Grepping only the cross-mark line - or only
``Expected:`` mismatches - silently drops thrown exceptions, which made red CI
runs undiagnosable from the Checks API (the raw log lives on a host that is
not always reachable). This helper extracts each failing block verbatim and
prints it as ``::error::`` annotations, chunked so GitHub's per-annotation
truncation never cuts a message inside a percent-escape.

Usage:
    python3 scripts/ci_test_failures.py path/to/test.log [max_tests]
"""
from __future__ import annotations

import re
import sys

CROSS_MARK = "\u274c"  # ❌
CHUNK_CHARS = 3800
CONTEXT_LINES = 45


def extract(log_text: str, max_tests: int) -> str:
    text = re.sub(r"\x1b\[[0-9;]*m", "", log_text)
    lines = text.replace("\r", "").split("\n")

    fail_starts = [i for i, line in enumerate(lines) if CROSS_MARK in line]
    summary = [
        line
        for line in lines
        if "tests passed" in line or "Some tests failed" in line
    ]

    blocks: list[str] = []
    for n, start in enumerate(fail_starts[:max_tests]):
        block = lines[start : start + CONTEXT_LINES]
        end = next(
            (j for j, line in enumerate(block) if "::endgroup::" in line),
            len(block),
        )
        block = block[: max(1, end)]
        blocks.append(
            "--- failing test %d of %d ---%s" % (n + 1, len(fail_starts), "\n".join(block))
        )

    return "\n".join(summary) + "\n" + "\n".join(blocks)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: ci_test_failures.py <test.log> [max_tests]", file=sys.stderr)
        return 2
    log_path = argv[1]
    max_tests = int(argv[2]) if len(argv) > 2 else 10

    try:
        with open(log_path, "rb") as handle:
            raw = handle.read().decode("utf-8", "replace")
    except OSError as exc:
        print("::error::ci_test_failures: cannot read %s: %s" % (log_path, exc))
        return 1

    report = extract(raw, max_tests)
    if not report.strip():
        print("::error::flutter test failed but no failing blocks were captured")
        return 0

    # Chunk BEFORE percent-encoding so a split never lands inside a %XX escape.
    for start in range(0, len(report), CHUNK_CHARS):
        piece = report[start : start + CHUNK_CHARS]
        piece = piece.replace("%", "%25").replace("\n", "%0A")
        print("::error::" + piece)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
