#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install the Android SDK components needed by the release builds.
#
# The desired platform (ANDROID_PLATFORM, e.g. "platforms;android-37") is not
# always published to the sdkmanager "stable" channel that GitHub-hosted
# runners use by default. When that happens sdkmanager only prints
#
#     Warning: Failed to find package 'platforms;android-37'
#
# and exits 1, which used to abort the whole workflow. This script instead:
#
#   1. tries the requested platform on every sdkmanager channel (0..3, i.e.
#      stable -> beta -> dev -> canary), so preview API levels still resolve;
#   2. falls back to the highest platform that *is* available if the exact
#      one cannot be installed anywhere;
#   3. exports ANDROID_COMPILE_SDK so Gradle compiles against whatever was
#      actually installed (android/app/build.gradle.kts reads it).
#
# Requires: ANDROID_HOME, ANDROID_NDK_VERSION, ANDROID_PLATFORM,
#           ANDROID_BUILD_TOOLS.
# ---------------------------------------------------------------------------
set -euo pipefail

: "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
: "${ANDROID_NDK_VERSION:?ANDROID_NDK_VERSION must be set}"
: "${ANDROID_PLATFORM:?ANDROID_PLATFORM must be set}"
: "${ANDROID_BUILD_TOOLS:?ANDROID_BUILD_TOOLS must be set}"

SDKMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
[ -x "$SDKMANAGER" ] || SDKMANAGER="$(command -v sdkmanager)"

log() { echo "==> $*"; }

accept_licenses() {
  yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
}

# install <package> [extra sdkmanager args...]
install_pkg() {
  local pkg="$1"; shift
  log "Installing ${pkg} $*"
  yes | "$SDKMANAGER" "$@" "$pkg"
}

accept_licenses

# --- Requested platform, across all channels -------------------------------
REQUESTED_API="${ANDROID_PLATFORM##*android-}"
INSTALLED_API=""

if [ -d "${ANDROID_HOME}/platforms/android-${REQUESTED_API}" ]; then
  log "platforms;android-${REQUESTED_API} already present"
  INSTALLED_API="$REQUESTED_API"
else
  for channel in 0 1 2 3; do
    if install_pkg "$ANDROID_PLATFORM" --channel="$channel"; then
      if [ -d "${ANDROID_HOME}/platforms/android-${REQUESTED_API}" ]; then
        INSTALLED_API="$REQUESTED_API"
        log "Installed ${ANDROID_PLATFORM} from channel ${channel}"
        break
      fi
    fi
    log "channel ${channel}: ${ANDROID_PLATFORM} unavailable"
  done
fi

# --- Fallback: highest platform sdkmanager knows about ----------------------
if [ -z "$INSTALLED_API" ]; then
  log "::warning::${ANDROID_PLATFORM} is not published yet; falling back"
  FALLBACK_API="$(
    "$SDKMANAGER" --list 2>/dev/null |
      sed -n 's/.*platforms;android-\([0-9]\{1,\}\).*/\1/p' |
      sort -n | tail -1
  )"
  if [ -z "${FALLBACK_API:-}" ]; then
    echo "::error::no android platform packages are available from sdkmanager" >&2
    exit 1
  fi
  install_pkg "platforms;android-${FALLBACK_API}"
  INSTALLED_API="$FALLBACK_API"
  log "Falling back to platforms;android-${INSTALLED_API}"
fi

# --- Build tools ------------------------------------------------------------
if ! install_pkg "$ANDROID_BUILD_TOOLS"; then
  BT_FALLBACK="$(
    "$SDKMANAGER" --list 2>/dev/null |
      sed -n 's/.*build-tools;\([0-9][0-9.]*\).*/\1/p' |
      sort -V | tail -1
  )"
  [ -n "${BT_FALLBACK:-}" ] || { echo "::error::no build-tools available" >&2; exit 1; }
  log "::warning::${ANDROID_BUILD_TOOLS} unavailable; using build-tools;${BT_FALLBACK}"
  install_pkg "build-tools;${BT_FALLBACK}"
fi

# --- NDK ---------------------------------------------------------------------
install_pkg "ndk;${ANDROID_NDK_VERSION}"

# --- Export results to the job ----------------------------------------------
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "ANDROID_NDK_HOME=${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}"
    echo "ANDROID_COMPILE_SDK=${INSTALLED_API}"
  } >> "$GITHUB_ENV"
fi

log "Using compileSdk=${INSTALLED_API}"
ls "${ANDROID_HOME}/platforms" || true
