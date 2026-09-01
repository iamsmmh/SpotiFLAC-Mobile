#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Select an Xcode installation that can actually archive for a real device.
#
# Hard-coding `xcode-select -s /Applications/Xcode_26.1.1.app` is not enough:
# GitHub's macOS images ship several Xcode versions whose iOS *SDK* is present
# but whose iOS *platform* (the downloadable "iOS NN.N" component / simulator
# runtime) is not. `xcodebuild -showsdks` happily lists `iphoneos26.1` on such
# an install, yet every device destination is ineligible and the archive dies
# with
#
#   xcodebuild: error: Unable to find a destination matching the provided
#   destination specifier: { generic:1, platform:iOS }
#     { platform:iOS, ... name:Any iOS Device,
#       error:iOS 26.1 is not installed. Please download and install the
#       platform from Xcode > Settings > Components. }
#   xcodebuild: error: Found no destinations for the scheme 'Runner' and
#   action archive.
#
# So instead of trusting a version number (or the SDK list), we probe every
# installed Xcode for
#   1. an iphoneos SDK, and
#   2. an *installed* iOS platform whose version matches that SDK
#      (checked via `simctl list runtimes available`, which is exactly what
#      the "iOS NN.N platform" component provides),
# and pick the newest one that has both (preferring $XCODE_VERSION when it
# qualifies). Only if no Xcode has the platform do we fall back to
# `xcodebuild -downloadPlatform iOS` on the preferred/newest Xcode.
#
# Exports DEVELOPER_DIR (and XCODE_IOS_SDK_VERSION) to $GITHUB_ENV.
# ---------------------------------------------------------------------------
set -euo pipefail

PREFERRED="${XCODE_VERSION:-}"

log() { echo "==> $*"; }

# ios_sdk_version <Xcode.app> -> prints e.g. "26.5" (the iphoneos SDK version)
ios_sdk_version() {
  DEVELOPER_DIR="$1/Contents/Developer" \
    xcodebuild -showsdks 2>/dev/null |
    sed -n 's/.*-sdk iphoneos\([0-9][0-9.]*\).*/\1/p' | sort -V | tail -1
}

# has_ios_platform <Xcode.app> <sdk-version>
# True when the iOS platform matching the SDK is installed for that Xcode.
has_ios_platform() {
  local app="$1" ver="$2" runtimes
  runtimes="$(DEVELOPER_DIR="$app/Contents/Developer" \
    xcrun simctl list runtimes available 2>/dev/null || true)"
  # "iOS 26.5 (26.5 - 23F5049c) - com.apple.CoreSimulator.SimRuntime.iOS-26-5"
  # Match "iOS 26.5" / "iOS 26.5.1"; also accept "iOS 26" for an "26.0" SDK.
  printf '%s\n' "$runtimes" | grep -qE "^iOS ${ver//./\\.}([. (]|$)" && return 0
  case "$ver" in
    *.0) printf '%s\n' "$runtimes" | grep -qE "^iOS ${ver%.0}([. (]|$)" && return 0 ;;
  esac
  return 1
}

# Candidate list: preferred first, then all installed Xcodes newest -> oldest.
candidates=()
if [ -n "$PREFERRED" ] && [ -d "/Applications/Xcode_${PREFERRED}.app" ]; then
  candidates+=("/Applications/Xcode_${PREFERRED}.app")
fi
while IFS= read -r app; do
  # Skip symlinked duplicates (Xcode_26.6.0.app -> Xcode_26.6.app, Xcode.app).
  real="$(cd "$app" 2>/dev/null && pwd -P || echo "$app")"
  dup=0
  for existing in "${candidates[@]:-}"; do
    [ -n "$existing" ] || continue
    [ "$(cd "$existing" 2>/dev/null && pwd -P)" = "$real" ] && dup=1 && break
  done
  [ "$dup" -eq 0 ] && candidates+=("$app")
done < <(ls -d /Applications/Xcode*.app 2>/dev/null | sort -Vr)

log "Installed Xcodes (probe order):"
printf '    %s\n' "${candidates[@]:-none}"

SELECTED=""
SELECTED_SDK=""
FIRST_WITH_SDK=""
FIRST_WITH_SDK_VER=""
for app in "${candidates[@]:-}"; do
  [ -n "$app" ] && [ -d "$app" ] || continue
  ver="$(ios_sdk_version "$app")"
  if [ -z "$ver" ]; then
    log "$(basename "$app"): no iphoneos SDK - skipping"
    continue
  fi
  if [ -z "$FIRST_WITH_SDK" ]; then
    FIRST_WITH_SDK="$app"; FIRST_WITH_SDK_VER="$ver"
  fi
  if has_ios_platform "$app" "$ver"; then
    SELECTED="$app"; SELECTED_SDK="$ver"
    break
  fi
  log "$(basename "$app"): iphoneos${ver} SDK present but iOS ${ver} platform is NOT installed - skipping"
done

if [ -z "$SELECTED" ]; then
  FALLBACK="${FIRST_WITH_SDK:-${candidates[0]:-/Applications/Xcode.app}}"
  log "::warning::no installed Xcode has its iOS platform; downloading it for $(basename "$FALLBACK") (this can take several minutes)"
  sudo xcode-select -s "$FALLBACK"
  # DEVELOPER_DIR overrides xcode-select; make sure the download targets the
  # Xcode we just selected even if an earlier step exported a different one.
  export DEVELOPER_DIR="${FALLBACK}/Contents/Developer"
  sudo xcodebuild -runFirstLaunch || true
  # Xcode 15+ fetches the missing platform on demand.
  xcodebuild -downloadPlatform iOS || sudo xcodebuild -downloadPlatform iOS || true
  ver="$(ios_sdk_version "$FALLBACK")"
  if [ -z "$ver" ] || ! has_ios_platform "$FALLBACK" "$ver"; then
    echo "::error::no iOS device platform available in any installed Xcode (tried downloading for $(basename "$FALLBACK"))" >&2
    exit 1
  fi
  SELECTED="$FALLBACK"; SELECTED_SDK="$ver"
fi

log "Selecting $SELECTED (iphoneos${SELECTED_SDK}, iOS ${SELECTED_SDK} platform installed)"
sudo xcode-select -s "$SELECTED"
export DEVELOPER_DIR="${SELECTED}/Contents/Developer"
xcodebuild -version
xcodebuild -showsdks | grep -i ios || true
xcrun simctl list runtimes available 2>/dev/null | grep '^iOS' || true

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "DEVELOPER_DIR=${DEVELOPER_DIR}"
    echo "XCODE_IOS_SDK_VERSION=${SELECTED_SDK}"
  } >> "$GITHUB_ENV"
fi
