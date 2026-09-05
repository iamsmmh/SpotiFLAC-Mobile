#!/usr/bin/env python3
"""Pre-release gate — toolchain-free release sanity checks.

Run locally (`python3 scripts/release_gate.py`) or from the release
pipelines before any build starts. It refuses to let a release proceed when
the repo's own release-critical metadata is inconsistent.

Checks
------
1. pubspec version is semver+build and the CHANGELOG covers it
   (a staged-ahead `## <version>` heading or a fresh [Unreleased] section).
2. apps.json (AltStore/SideStore feed) is complete: every field AltStore
   actually reads, a machine-readable RFC3339 `date`, and a bundle
   identifier that matches BOTH the Gradle applicationId and the Xcode
   PRODUCT_BUNDLE_IDENTIFIER. A drifted feed silently breaks sideloaded
   update matching (see spotiflacapp issue #554).
3. Localization debt is bounded: staged English-first strings
   (lib/l10n/staged_strings.dart) must be within the Crowdin-sync budget,
   and no locale may fall below the coverage floor.

Exit code 0 = ship, 1 = fix first.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# AltStore parses `date` with a JS Date(); require a full RFC3339 timestamp.
FEED_REQUIRED_APP_FIELDS = (
    "name",
    "bundleIdentifier",
    "version",
    "date",
    "downloadURL",
    "size",
    "localizedDescription",
)
STAGED_STRINGS_BUDGET = 70
LOCALE_COVERAGE_FLOOR = 0.55


class Gate:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.notes: list[str] = []

    def fail(self, msg: str) -> None:
        self.failures.append(msg)

    def note(self, msg: str) -> None:
        self.notes.append(msg)

    @staticmethod
    def ok(label: str, detail: str = "") -> None:
        print(f"  [ok]   {label}{(' — ' + detail) if detail else ''}")


def check_versions(gate: Gate, expect_version: str | None) -> None:
    pubspec = ROOT / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    m = re.search(r"(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", text)
    if not m:
        gate.fail("pubspec.yaml: `version:` is missing or not in MAJOR.MINOR.PATCH+BUILD form")
        return
    version = m.group(1)
    Gate.ok("pubspec version", f"{version}+{m.group(2)}")

    if expect_version and expect_version.lstrip("v") != version:
        gate.fail(
            f"release tag {expect_version!r} does not match pubspec version {version!r} "
            "(auto-tag should have created exactly v%s)" % version
        )

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    has_section = f"## {version}" in changelog
    has_unreleased = "## [Unreleased]" in changelog
    if not has_section and not has_unreleased:
        gate.fail(
            "CHANGELOG.md has neither a `## %s` section nor an [Unreleased] staging "
            "section covering the shipped version" % version
        )
    elif has_section:
        Gate.ok("CHANGELOG covers version", f"## {version}")
    else:
        Gate.ok("CHANGELOG staged-ahead", "[Unreleased] (release notes come from git-cliff)")


def check_feed(gate: Gate) -> None:
    feed_path = ROOT / "apps.json"
    if not feed_path.is_file():
        gate.fail("apps.json (AltStore source) is missing from the repo root")
        return
    try:
        feed = json.loads(feed_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        gate.fail(f"apps.json is not valid JSON: {exc}")
        return

    apps = feed.get("apps") or []
    if not apps:
        gate.fail("apps.json contains no `apps` entries")
        return
    app = apps[0]

    missing = [f for f in FEED_REQUIRED_APP_FIELDS if app.get(f) in (None, "")]
    if missing:
        gate.fail(f"apps.json entry is missing AltStore-required fields: {', '.join(missing)}")
    if "size" in app and not isinstance(app["size"], int):
        gate.fail("apps.json `size` must be an integer byte count (string sizes are read as 0)")

    date_str = str(app.get("date", ""))
    date_ok = False
    try:
        dt.datetime.fromisoformat(date_str.replace("Z", "+00:00"))
        date_ok = bool(re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$", date_str))
    except ValueError:
        pass
    if app.get("date") is not None and not date_ok:
        gate.fail(
            f"apps.json `date` {date_str!r} is not a full RFC3339 timestamp "
            "(AltStore sorts versions by it; a date-only or missing value breaks update lists)"
        )
    elif date_ok:
        Gate.ok("apps.json date", date_str)

    bundle = str(app.get("bundleIdentifier", ""))

    gradle = (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
    gm = re.search(r'applicationId\s*=\s*"([^"]+)"', gradle)
    if gm and bundle and gm.group(1) != bundle:
        gate.fail(
            f"apps.json bundleIdentifier {bundle!r} does not match the Android applicationId "
            f"{gm.group(1)!r} — AltStore would treat installs as a different app (issue #554)"
        )
    elif gm:
        Gate.ok("feed bundle id == Android applicationId", gm.group(1))

    pbx = (ROOT / "ios/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    pm = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = ([\w.\-]+);", pbx)
    if pm and bundle and pm.group(1) != bundle:
        gate.fail(
            f"apps.json bundleIdentifier {bundle!r} does not match the iOS "
            f"PRODUCT_BUNDLE_IDENTIFIER {pm.group(1)!r} (issue #554)"
        )
    elif pm:
        Gate.ok("feed bundle id == iOS bundle id", pm.group(1))

    url = str(app.get("downloadURL", ""))
    ver = str(app.get("version", ""))
    if url and ver and f"v{ver}" not in url:
        gate.fail(f"apps.json downloadURL does not point at a v{ver} asset — version/feed drift")
    elif url:
        Gate.ok("feed downloadURL matches version", ver)


def check_i18n_debt(gate: Gate) -> None:
    staged = ROOT / "lib/l10n/staged_strings.dart"
    count = 0
    if staged.is_file():
        count = len(re.findall(r"static const String", staged.read_text(encoding="utf-8")))
    if count > STAGED_STRINGS_BUDGET:
        gate.fail(
            f"lib/l10n/staged_strings.dart holds {count} English-only strings (budget "
            f"{STAGED_STRINGS_BUDGET}). Move them into lib/l10n/arb/app_en.arb, run "
            "`flutter gen-l10n`, and sync Crowdin before releasing."
        )
    else:
        Gate.ok("staged strings within Crowdin-sync budget", f"{count}/{STAGED_STRINGS_BUDGET}")

    arb_dir = ROOT / "lib/l10n/arb"
    template_path = arb_dir / "app_en.arb"
    if not template_path.is_file():
        gate.fail("lib/l10n/arb/app_en.arb (template) is missing")
        return
    template_keys = {
        k
        for k in json.loads(template_path.read_text(encoding="utf-8"))
        if not k.startswith("@")
    }
    low: list[str] = []
    for path in sorted(arb_dir.glob("app_*.arb")):
        if path.name == "app_en.arb":
            continue
        keys = {k for k in json.loads(path.read_text(encoding="utf-8")) if not k.startswith("@")}
        coverage = len(keys & template_keys) / max(1, len(template_keys))
        if coverage < LOCALE_COVERAGE_FLOOR:
            low.append(f"{path.stem} ({coverage:.0%})")
    if low:
        gate.fail(
            "locales below the %.0f%% coverage floor: %s — translate or explicitly exempt them"
            % (LOCALE_COVERAGE_FLOOR * 100, ", ".join(low))
        )
    else:
        Gate.ok("all locales above coverage floor", f"{LOCALE_COVERAGE_FLOOR:.0%}")


def main() -> int:
    parser = argparse.ArgumentParser(description="SpotiFLAC Mobile pre-release gate")
    parser.add_argument("--version", default=None, help="release tag/version being published (optional)")
    args = parser.parse_args()

    gate = Gate()
    print("== release gate ==")
    check_versions(gate, args.version)
    check_feed(gate)
    check_i18n_debt(gate)

    for note in gate.notes:
        print(f"  [note] {note}")
    if gate.failures:
        print(f"\nRELEASE GATE FAILED ({len(gate.failures)} issue(s)):")
        for failure in gate.failures:
            print(f"  [fail] {failure}")
        return 1
    print("RELEASE GATE PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
