#!/usr/bin/env bash
# Build the release Android App Bundle and surface the underlying Gradle
# diagnostic as a check-run annotation when Flutter reports only bundleRelease.
set -u

LOG="${RUNNER_TEMP:-/tmp}/gradle-bundleRelease.log"
mkdir -p "$(dirname "$LOG")"

set +o pipefail
flutter build appbundle --release \
  --target-platform android-arm,android-arm64 \
  2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -o pipefail

if [ "$STATUS" -ne 0 ]; then
  echo "::group::Gradle failure excerpt"
  grep -nE "FAILURE:|What went wrong|Execution failed|> [A-Z]|error:|Error:|NDK |16 KB|Duplicate class|files found with path|lintVital|AAR metadata|compileSdk" "$LOG" | tail -100 || true
  echo "::endgroup::"
  if [ -f scripts/ci_annotate.py ]; then
    python3 scripts/ci_annotate.py "$LOG" --file gradle-bundleRelease.log --max 80 || true
  fi
  echo "::error::Gradle task bundleRelease failed with exit code ${STATUS}"
  exit "$STATUS"
fi

BUNDLE="build/app/outputs/bundle/release/app-release.aab"
if [ ! -s "$BUNDLE" ]; then
  echo "::error::Release AAB is missing or empty: $BUNDLE"
  exit 1
fi
ls -la "$BUNDLE"
