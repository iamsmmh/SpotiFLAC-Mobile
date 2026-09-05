#!/usr/bin/env python3
"""Translation coverage per locale against the English template.

Compares every lib/l10n/arb/*.arb against app_en.arb (keys, not '@' metadata)
and prints a coverage table. Missing keys fall back to English at runtime via
filteredSupportedLocales/gen-l10n, so this is informational — but a locale
that drifts hundreds of keys behind (historically: generic es/pt) should be
excluded from the supported list or re-synced via Crowdin.

Exit code is always 0; wire the output into release notes, not gates.
"""
from __future__ import annotations

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, "lib", "l10n", "arb")


def load_keys(path: str) -> set[str]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return {k for k in data if not k.startswith("@")}


def main() -> int:
    template = os.path.join(ARB_DIR, "app_en.arb")
    if not os.path.isfile(template):
        print(f"template not found: {template}", file=sys.stderr)
        return 1
    en_keys = load_keys(template)
    print(f"template app_en.arb: {len(en_keys)} keys\n")
    print(f"{'locale':<10} {'keys':>6} {'missing':>8} {'coverage':>9}")
    print("-" * 38)
    total_missing = 0
    for name in sorted(os.listdir(ARB_DIR)):
        if not name.endswith(".arb"):
            continue
        keys = load_keys(os.path.join(ARB_DIR, name))
        missing = len(en_keys - keys)
        total_missing += missing
        coverage = 100.0 * (len(en_keys) - missing) / max(len(en_keys), 1)
        print(f"{name[4:-4]:<10} {len(keys):>6} {missing:>8} {coverage:>8.1f}%")
    print(f"\ntotal missing keys across locales: {total_missing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
