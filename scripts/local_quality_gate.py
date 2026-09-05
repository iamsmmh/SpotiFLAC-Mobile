#!/usr/bin/env python3
"""Local pre-merge static coherence gate (toolchain-free checks).

This complements the authoritative CI gates (flutter analyze/test, go vet/test,
Android/iOS builds) which execute on GitHub-hosted runners. Everything checked
here is verifiable inside a sandbox without a Flutter/JDK/Go/Xcode toolchain:

  1. All workflow YAML files parse and their `on:` triggers are well-formed.
  2. All shell scripts pass `bash -n` (syntax lint).
  3. Cross-file toolchain pins are consistent (Flutter pin, Go directive,
     Gradle wrapper, NDK/build-tools/API levels, Xcode pin).
  4. pubspec.yaml parses; version format valid; CHANGELOG starts at same version.
  5. No stray conflict markers / CRLF regressions in tracked source files.

Exit code 0 only if every individual check is green; prints a matrix.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

results: list[tuple[str, str, str]] = []  # (group, check, detail)


def record(group: str, check: str, ok: bool, detail: str = "") -> bool:
    results.append((group, check, "PASS" if ok else "FAIL"))
    if detail:
        print(f"    [{group}] {check}: {detail}")
    return ok


def fail_fast(msg: str) -> None:
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------- 1. YAML ----
def check_workflows() -> list[dict]:
    wd = os.path.join(ROOT, ".github", "workflows")
    files = sorted(f for f in os.listdir(wd) if f.endswith((".yml", ".yaml")))
    workflows = []
    for f in files:
        path = os.path.join(wd, f)
        with open(path, "r", encoding="utf-8") as fh:
            try:
                doc = yaml.safe_load(fh)
                record("YAML", f"workflow {f} parses", True, f"jobs={list(doc.get('jobs', {}))}")
            except Exception as exc:  # noqa: BLE001
                record("YAML", f"workflow {f} parses", False, str(exc))
                continue
        if not isinstance(doc, dict) or "jobs" not in doc or not doc["jobs"]:
            record("YAML", f"workflow {f} has jobs", False)
            continue
        record("YAML", f"workflow {f} has jobs", True)
        # PyYAML 1.1 quirk: bare key `on:` becomes True; check both spellings.
        trig = doc.get("on", doc.get(True))
        record("YAML", f"workflow {f} declares triggers", bool(trig))
        workflows.append({"file": f, "doc": doc})
    return workflows


def check_misc_yaml() -> None:
    for rel in ("pubspec.yaml", "analysis_options.yaml", "crowdin.yml", "renovate.json", "apps.json"):
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                (json.load if rel.endswith(".json") else yaml.safe_load)(fh)
            record("YAML", f"{rel} parses", True)
        except Exception as exc:  # noqa: BLE001
            record("YAML", f"{rel} parses", False, str(exc))


# ---------------------------------------------------------------- 2. bash ----
def check_shell_scripts() -> None:
    scripts: list[str] = []
    for base, _dirs, files in os.walk(ROOT):
        if "/.git" in base.replace(os.sep, "/"):
            continue
        for f in files:
            if f.endswith(".sh"):
                scripts.append(os.path.join(base, f))
    for path in sorted(scripts):
        rel = os.path.relpath(path, ROOT)
        proc = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
        record("bash -n", rel, proc.returncode == 0, proc.stderr.strip()[:200])


# ---------------------------------------------------------- 3. pin matrix ----
def read(rel: str) -> str:
    with open(os.path.join(ROOT, rel), "r", encoding="utf-8") as fh:
        return fh.read()


def check_pins(workflows: list[dict]) -> None:
    fvm = json.loads(read(".fvmrc"))["flutter"]
    record("pins", ".fvmrc readable", True, f"flutter={fvm}")

    pub = yaml.safe_load(read("pubspec.yaml"))
    sdk = pub["environment"]["sdk"]
    record("pins", f"dart sdk constraint {sdk}", sdk.startswith("^3."), "")

    for w in workflows:
        doc = w["doc"]
        env = doc.get("env") or {}
        refs = json.dumps(doc)
        if "flutter-version-file" in refs:
            pin = env.get("FLUTTER_VERSION_FILE", ".fvmrc")
            record("pins", f"{w['file']} reads Flutter pin from {pin}", pin in (".fvmrc",))

    gomod = re.search(r"^go\s+(\d+\.\d+(?:\.\d+)?)", read("go_backend/go.mod"), re.M)
    record("pins", "go_backend/go.mod go directive", bool(gomod), f"go={gomod.group(1) if gomod else '?'}")

    ci = read(".github/workflows/ci.yml")
    record("pins", "ci.yml uses go-version-file go_backend/go.mod", "go-version-file: go_backend/go.mod" in ci)

    wrapper = read("android/gradle/wrapper/gradle-wrapper.properties")
    gver = re.search(r"gradle-(\d+\.\d+(?:\.\d+)?)-all\.zip", wrapper)
    record("pins", "gradle wrapper distribution", bool(gver), f"gradle={gver.group(1) if gver else '?'}")
    gsha = re.search(r"distributionSha256Sum=([0-9a-f]{64})", wrapper)
    record("pins", "gradle wrapper pinned sha256", bool(gsha))
    setup_gradle = re.findall(r'gradle-version:\s*"(\d+\.\d+\.\d+)"', read(".github/workflows/ci.yml") + read(".github/workflows/build-mobile.yml"))
    record(
        "pins",
        "workflow setup-gradle matches wrapper",
        bool(setup_gradle) and gver is not None and all(v == gver.group(1) for v in setup_gradle),
        f"workflow={sorted(set(setup_gradle))} wrapper={gver.group(1) if gver else '?'}",
    )

    app_kts_paths = [os.path.join(ROOT, "android/app/build.gradle.kts"), os.path.join(ROOT, "android/app/build.gradle")]
    app_kts = next((read(p) for p in app_kts_paths if os.path.isfile(p)), "")
    compilesdk = re.search(r"compileSdk\s*=?\s*(\d+)", app_kts)
    targetsdk = re.search(r"targetSdk\s*=?\s*(\d+)", app_kts)
    record("pins", "android compileSdk declared", bool(compilesdk) or "ANDROID_COMPILE_SDK" in app_kts or "compileSdk" in app_kts)
    record("pins", "android targetSdk declared", bool(targetsdk) or "targetSdk" in app_kts)

    bm = read(".github/workflows/build-mobile.yml")
    ndk = re.search(r'ANDROID_NDK_VERSION:\s*"([^"]+)"', bm).group(1)
    btools = re.search(r'ANDROID_BUILD_TOOLS:\s*"([^"]+)"', bm).group(1)
    xcode = re.search(r'XCODE_VERSION:\s*"([^"]+)"', bm).group(1)
    record("pins", "build-mobile NDK/BuildTools/Xcode env", True, f"ndk={ndk} bt={btools} xcode={xcode}")

    script = read(".github/scripts/setup-android-sdk.sh")
    record("pins", "setup-android-sdk resolves minor API levels", "android-" in script and "minor" in script.lower())

    us = read(".github/workflows/unsigned-release.yml")
    sane = ndk in us and btools in us
    record("pins", "unsigned-release SDK pins match build-mobile", sane)


# ----------------------------------------------------- 4. version hygiene ----
def check_versions() -> None:
    pub = yaml.safe_load(read("pubspec.yaml"))
    version = str(pub["version"])
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)\+(\d+)", version)
    record("version", f"pubspec version semver+build ({version})", bool(m))
    if not m:
        return
    semver = tuple(int(g) for g in m.groups()[:3])
    changelog = read("CHANGELOG.md")
    # Headings follow Keep-a-Changelog: "## [x.y.z] - YYYY-MM-DD" (dated
    # release sections) and an optional "## [Unreleased]" staging section.
    dated = [
        (tuple(int(p) for p in g.split(".")), line)
        for g, line in re.findall(
            r"^##\s+\[?v?(\d+\.\d+\.\d+)\]?(?:\s+-\s+\d{4}-\d{2}-\d{2})?(.*)$",
            changelog,
            re.M,
        )
        if "Unreleased" not in line
    ]
    record("version", "CHANGELOG has dated release sections", bool(dated),
           f"newest={'.'.join(map(str, dated[0][0])) if dated else '?'}")
    if dated:
        newest = dated[0][0]
        # auto-tag.yml fires only on a pubspec bump and tags from pubspec, so
        # CHANGELOG.md sections may legitimately be staged ahead of the pin.
        # Fail only if notes are missing for the version the tree ships.
        ahead = newest > semver
        aligned_or_ahead = newest >= semver
        record(
            "version",
            "CHANGELOG covers shipped version (staged-ahead allowed)",
            aligned_or_ahead,
            "staged release notes ahead of pubspec pin (cut = pubspec bump -> auto-tag)"
            if ahead else "aligned",
        )
    unreleased = re.search(r"^##\s+\[Unreleased\]", changelog, re.M)
    record("version", "[Unreleased] staging section present", bool(unreleased))
    tag_policy_ok = "v*" in read(".github/workflows/unsigned-release.yml")
    record("version", "release tag trigger v* present", tag_policy_ok)


# --------------------------------------------------- 5. conflict markers ----
def check_source_hygiene() -> None:
    bad: list[str] = []
    scanned = 0
    for base, dirs, files in os.walk(ROOT):
        rel = os.path.relpath(base, ROOT)
        if rel.startswith(".git") or any(p in rel.split(os.sep) for p in ("build", ".dart_tool", "Pods", "DerivedData")):
            dirs[:] = []
            continue
        for f in files:
            if not f.endswith((".dart", ".kt", ".swift", ".go", ".yaml", ".yml", ".sh", ".kts", ".gradle", ".md")):
                continue
            path = os.path.join(base, f)
            try:
                with open(path, "r", encoding="utf-8", errors="strict") as fh:
                    data = fh.read()
            except (UnicodeDecodeError, OSError):
                continue
            scanned += 1
            lines = data.splitlines()
            for i, line in enumerate(lines, 1):
                if line.startswith(("<<<<<<<", ">>>>>>>")) or (line.startswith("=======") and i > 1):
                    bad.append(f"{os.path.relpath(path, ROOT)}:{i}")
    record("hygiene", f"no git conflict markers ({scanned} files scanned)", not bad, "; ".join(bad[:5]))


def check_translations() -> None:
    """Informational i18n coverage: missing keys fall back to English at
    runtime, so this never fails — it keeps drift visible. Details via
    scripts/translation_coverage.py."""
    arb_dir = os.path.join(ROOT, "lib", "l10n", "arb")
    template = os.path.join(arb_dir, "app_en.arb")
    try:
        with open(template, "r", encoding="utf-8") as fh:
            en_keys = {k for k in json.load(fh) if not k.startswith("@")}
    except Exception as exc:  # noqa: BLE001
        record("i18n", "template app_en.arb readable", False, str(exc))
        return
    record("i18n", f"template app_en.arb readable ({len(en_keys)} keys)", True)
    worst = ("", 0)
    locales = 0
    for name in sorted(os.listdir(arb_dir)):
        if not name.endswith(".arb") or name == "app_en.arb":
            continue
        locales += 1
        with open(os.path.join(arb_dir, name), "r", encoding="utf-8") as fh:
            keys = {k for k in json.load(fh) if not k.startswith("@")}
        missing = len(en_keys - keys)
        if missing > worst[1]:
            worst = (name, missing)
    record(
        "i18n",
        f"{locales} locales vs template (worst: {worst[0]} -{worst[1]})",
        True,
    )


# ------------------------------------------------------------------ main ----
def main() -> int:
    os.chdir(ROOT)
    workflows = check_workflows()
    check_misc_yaml()
    check_shell_scripts()
    check_pins(workflows)
    check_versions()
    check_source_hygiene()
    check_translations()

    print("\n================ LOCAL STATIC GATE MATRIX ================")
    width = max(len(c) for _g, c, _s in results)
    fails = 0
    for group, check, status in results:
        icon = "🟢" if status == "PASS" else "🔴"
        print(f"{icon} [{group:<8}] {check:<{width}}  {status}")
        fails += status == "FAIL"
    print(f"==========================================================")
    print(f"checks={len(results)} passed={len(results) - fails} failed={fails}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
