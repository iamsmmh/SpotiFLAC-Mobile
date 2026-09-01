#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Archive ios/Runner.xcworkspace without code signing.
#
# `-destination 'generic/platform=iOS'` is the documented way to archive for
# device, but it fails hard when the runner's Xcode lacks the matching iOS
# device platform:
#
#   Unable to find a destination matching the provided destination specifier:
#     { generic:1, platform:iOS }
#
# `-sdk iphoneos` does not go through destination resolution, so it still
# works on those images. We therefore try the destination form first and fall
# back to the SDK form (never both at once - Xcode 16+ rejects that
# combination with exit code 70).
#
# Usage: archive-ios.sh <archive-path> <log-path>
# ---------------------------------------------------------------------------
set -euo pipefail

ARCHIVE_PATH="${1:?archive path required}"
LOG="${2:-${RUNNER_TEMP:-/tmp}/xcodebuild-archive.log}"

cd "$(dirname "$0")/../../ios"

run_archive() {
  # "$@" = the platform selector flags
  set +o pipefail
  xcodebuild archive \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    "$@" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    EXPANDED_CODE_SIGN_IDENTITY="" \
    ENABLE_USER_SCRIPT_SANDBOXING=NO \
    2>&1 | tee -a "$LOG"
  local status="${PIPESTATUS[0]}"
  set -o pipefail
  return "$status"
}

: > "$LOG"

echo "==> Available destinations for Runner:"
xcodebuild -workspace Runner.xcworkspace -scheme Runner -showdestinations 2>&1 | tail -30 || true

STATUS=0
echo "==> Attempt 1: -destination 'generic/platform=iOS'"
run_archive -destination 'generic/platform=iOS' || STATUS=$?

if [ "$STATUS" -ne 0 ] && grep -q "Unable to find a destination matching" "$LOG"; then
  echo "==> Destination resolution failed; retrying with -sdk iphoneos"
  rm -rf "$ARCHIVE_PATH"
  STATUS=0
  run_archive -sdk iphoneos || STATUS=$?
fi

if [ "$STATUS" -ne 0 ]; then
  echo "::group::xcodebuild diagnostics (last 200 lines)"
  tail -200 "$LOG" || true
  echo "::endgroup::"
  echo "::group::xcodebuild errors"
  grep -nE "error:|fatal error:|Undefined symbol|ld: |clang: error|Command .* failed" "$LOG" | head -100 || true
  echo "::endgroup::"
  echo "::error::xcodebuild archive failed with exit code ${STATUS} - see the diagnostics above and the ios-xcodebuild-log artifact"
  exit "$STATUS"
fi

echo "==> Archive created at ${ARCHIVE_PATH}"
