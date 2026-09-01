#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Select an Xcode installation that can actually archive for a real device.
#
# Hard-coding `xcode-select -s /Applications/Xcode_26.1.1.app` is not enough:
# GitHub's macOS images ship some Xcode versions *without* the matching iOS
# device platform, and the archive then dies with
#
#   xcodebuild: error: Unable to find a destination matching the provided
#   destination specifier: { generic:1, platform:iOS }
#     ... error:iOS 26.1 is not installed.
#
# So instead of trusting a version number, we probe every installed Xcode for
# an `iphoneos` SDK and pick the newest one that has it (preferring
# $XCODE_VERSION when it qualifies). If none has the iOS platform we try
# `xcodebuild -downloadPlatform iOS` on the preferred Xcode before giving up.
# ---------------------------------------------------------------------------
set -euo pipefail

PREFERRED="${XCODE_VERSION:-}"

log() { echo "==> $*"; }

has_ios_sdk() {
  # $1 = Xcode.app path
  DEVELOPER_DIR="$1/Contents/Developer" \
    xcodebuild -showsdks 2>/dev/null | grep -qi 'iphoneos'
}

# Candidate list: preferred first, then all installed Xcodes newest -> oldest.
candidates=()
if [ -n "$PREFERRED" ] && [ -d "/Applications/Xcode_${PREFERRED}.app" ]; then
  candidates+=("/Applications/Xcode_${PREFERRED}.app")
fi
while IFS= read -r app; do
  candidates+=("$app")
done < <(ls -d /Applications/Xcode*.app 2>/dev/null | sort -Vr)

log "Installed Xcodes:"
printf '    %s\n' "${candidates[@]:-none}"

SELECTED=""
for app in "${candidates[@]}"; do
  [ -d "$app" ] || continue
  if has_ios_sdk "$app"; then
    SELECTED="$app"
    break
  fi
  log "$(basename "$app") has no iphoneos SDK - skipping"
done

if [ -z "$SELECTED" ]; then
  FALLBACK="${candidates[0]:-/Applications/Xcode.app}"
  log "::warning::no Xcode with an installed iOS platform; downloading it for $(basename "$FALLBACK")"
  sudo xcode-select -s "$FALLBACK"
  sudo xcodebuild -runFirstLaunch || true
  # Xcode 16+ can fetch the missing device platform on demand.
  sudo xcodebuild -downloadPlatform iOS || true
  has_ios_sdk "$FALLBACK" || {
    echo "::error::no iOS device platform available in any installed Xcode" >&2
    exit 1
  }
  SELECTED="$FALLBACK"
fi

log "Selecting $SELECTED"
sudo xcode-select -s "$SELECTED"
xcodebuild -version
xcodebuild -showsdks | grep -i ios || true

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=${SELECTED}/Contents/Developer" >> "$GITHUB_ENV"
fi
