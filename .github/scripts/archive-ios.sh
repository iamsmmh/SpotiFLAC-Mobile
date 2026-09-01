#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Archive ios/Runner.xcworkspace without code signing.
#
# `-destination 'generic/platform=iOS'` is the documented way to archive for
# device, but it fails hard when the selected Xcode lacks the matching iOS
# device *platform* (the "iOS NN.N" component), even though the SDK exists:
#
#   Unable to find a destination matching the provided destination specifier:
#     { generic:1, platform:iOS }
#     { platform:iOS, ... name:Any iOS Device, error:iOS 26.1 is not installed. }
#
# `-sdk iphoneos` used to sidestep destination resolution, but Xcode 26 still
# refuses with "Found no destinations for the scheme 'Runner' and action
# archive" (exit 70) when the platform is missing. So the strategy is:
#
#   1. archive with -destination 'generic/platform=iOS'
#   2. if that fails because the platform is missing, download it with
#      `xcodebuild -downloadPlatform iOS` and retry (1)
#   3. as a last resort try -sdk iphoneos (older Xcodes accept it without a
#      platform). Never pass both flags at once - Xcode 16+ rejects that.
#
# Usage: archive-ios.sh <archive-path> <log-path>
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve the repository root before changing directories. `$0` is passed as a
# relative path by Actions; resolving it after `cd ios` made the failure
# annotation helper resolve as `ios/.github/...` and exit before reporting the
# actual Xcode error.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ARCHIVE_PATH="${1:?archive path required}"
LOG="${2:-${RUNNER_TEMP:-/tmp}/xcodebuild-archive.log}"

cd "$REPO_ROOT/ios"

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

ATTEMPT_START=0
mark_attempt() { ATTEMPT_START="$(wc -l < "$LOG" | tr -d ' ')"; }
platform_missing() {
  # Only look at the output of the most recent attempt.
  tail -n "+$((ATTEMPT_START + 1))" "$LOG" |
    grep -qE "is not installed\. Please download and install the platform|Found no destinations for the scheme|Unable to find a destination matching"
}

: > "$LOG"

echo "==> Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ') (DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)})"
echo "==> Installed iOS runtimes:"
xcrun simctl list runtimes available 2>/dev/null | grep '^iOS' || echo "    (none)"
echo "==> Available destinations for Runner:"
xcodebuild -workspace Runner.xcworkspace -scheme Runner -showdestinations 2>&1 | tail -30 || true

STATUS=0
echo "==> Attempt 1: -destination 'generic/platform=iOS'"
mark_attempt
run_archive -destination 'generic/platform=iOS' || STATUS=$?

if [ "$STATUS" -ne 0 ] && platform_missing; then
  echo "==> iOS platform is not installed for this Xcode; downloading it (xcodebuild -downloadPlatform iOS)"
  rm -rf "$ARCHIVE_PATH"
  ( xcodebuild -downloadPlatform iOS || sudo xcodebuild -downloadPlatform iOS ) 2>&1 | tail -20 || true
  xcrun simctl list runtimes available 2>/dev/null | grep '^iOS' || true
  echo "==> Attempt 2: -destination 'generic/platform=iOS' (after platform download)"
  STATUS=0
  mark_attempt
  run_archive -destination 'generic/platform=iOS' || STATUS=$?
fi

if [ "$STATUS" -ne 0 ] && platform_missing; then
  echo "==> Destination resolution still failing; attempt 3: -sdk iphoneos"
  rm -rf "$ARCHIVE_PATH"
  STATUS=0
  mark_attempt
  run_archive -sdk iphoneos || STATUS=$?
fi

if [ "$STATUS" -ne 0 ]; then
  echo "::group::xcodebuild diagnostics (last 200 lines)"
  tail -200 "$LOG" || true
  echo "::endgroup::"
  echo "::group::xcodebuild errors"
  grep -nE "error:|fatal error:|Undefined symbol|ld: |clang: error|Command .* failed" "$LOG" | head -100 || true
  echo "::endgroup::"
  # Mirror the log into check-run annotations so the failure stays visible
  # even when the uploaded artifact is not reachable (see scripts/ci_annotate.py).
  ANNOTATE="$REPO_ROOT/scripts/ci_annotate.py"
  if [ -f "$ANNOTATE" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$ANNOTATE" "$LOG" --file xcodebuild-archive.log --max 80 || true
  fi
  echo "::error::xcodebuild archive failed with exit code ${STATUS} - see the diagnostics above and the ios-xcodebuild-log artifact"
  exit "$STATUS"
fi

test -d "$ARCHIVE_PATH/Products/Applications/Runner.app" || {
  echo "::error::archive succeeded but Runner.app is missing from ${ARCHIVE_PATH}" >&2
  exit 1
}
echo "==> Archive created at ${ARCHIVE_PATH}"
