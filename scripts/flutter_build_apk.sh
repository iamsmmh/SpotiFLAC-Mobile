#!/usr/bin/env bash
# Run `flutter build apk` and, on failure, surface the real Gradle diagnostic
# as a check-run annotation (the Flutter wrapper otherwise collapses it to
# "Gradle task assembleRelease failed with exit code 1").
set -u

LOG="${RUNNER_TEMP:-/tmp}/gradle-assembleRelease.log"
mkdir -p "$(dirname "$LOG")"

set +o pipefail
flutter build apk --release --split-per-abi \
  --target-platform android-arm,android-arm64,android-x64 \
  2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -o pipefail

if [ "$STATUS" -ne 0 ]; then
  echo "::group::Gradle failure excerpt"
  grep -nE "FAILURE:|What went wrong|Execution failed|> [A-Z]|error:|Error:|NDK |16 KB|Duplicate class|files found with path|lintVital|AAR metadata|compileSdk" "$LOG" | tail -100 || true
  echo "::endgroup::"
  if [ -f scripts/ci_annotate.py ]; then
    python3 scripts/ci_annotate.py "$LOG" --file gradle-assembleRelease.log --max 80 || true
  fi
  echo "::error::Gradle task assembleRelease failed with exit code ${STATUS}"
  exit "$STATUS"
fi

ls -la build/app/outputs/flutter-apk/

# Existing release workflows call this long-standing APK wrapper. Build the
# App Bundle here by default as well so AAB configuration is continuously
# exercised even before those workflows adopt the dedicated wrapper step.
if [ "${BUILD_APP_BUNDLE:-1}" != "0" ]; then
  bash "$(dirname "$0")/flutter_build_appbundle.sh"
fi
