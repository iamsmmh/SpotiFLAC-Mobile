#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install the Android SDK components needed by the release builds.
#
# Since API 36 Google publishes "minor" platform releases, and the sdkmanager
# package for a major API level is now suffixed with the minor version:
#
#     platforms;android-36        (legacy naming, still exists)
#     platforms;android-36.1
#     platforms;android-37.0      <- API 37 / Android 17 (there is NO android-37)
#     platforms;android-37.1
#
# Asking sdkmanager for the bare "platforms;android-37" therefore only prints
#
#     Warning: Failed to find package 'platforms;android-37'
#
# and exits 1. AGP itself is fine with compileSdk = 37 against the
# platforms/android-37.0 directory, so this script:
#
#   1. accepts ANDROID_PLATFORM in either form ("platforms;android-37" or
#      "platforms;android-37.0") and treats an already-installed
#      android-<major>[.<minor>] directory as satisfying the request;
#   2. tries the exact package, then "<major>.0", then the bare "<major>",
#      on the stable channel first and then including preview channels;
#   3. falls back to the highest *numeric* platform sdkmanager knows about
#      (never a -beta / -ext / codename package) if none of those install;
#   4. exports ANDROID_COMPILE_SDK (major API level) so Gradle compiles
#      against whatever was actually installed
#      (android/app/build.gradle.kts reads it).
#
# Requires: ANDROID_HOME, ANDROID_NDK_VERSION, ANDROID_PLATFORM,
#           ANDROID_BUILD_TOOLS.
# ---------------------------------------------------------------------------
set -euo pipefail

: "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
: "${ANDROID_HOME:?ANDROID_HOME / ANDROID_SDK_ROOT must be set}"
: "${ANDROID_NDK_VERSION:?ANDROID_NDK_VERSION must be set}"
: "${ANDROID_PLATFORM:?ANDROID_PLATFORM must be set}"
: "${ANDROID_BUILD_TOOLS:?ANDROID_BUILD_TOOLS must be set}"

SDKMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
[ -x "$SDKMANAGER" ] || SDKMANAGER="$(command -v sdkmanager)"
[ -x "$SDKMANAGER" ] || { echo "::error::sdkmanager not found" >&2; exit 1; }

log() { echo "==> $*"; }

accept_licenses() {
  yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
}

# install_pkg <package> [extra sdkmanager args...]
# Succeeds only if sdkmanager exits 0 AND did not print the "Failed to find
# package" warning (sdkmanager sometimes exits 0 for unknown packages).
install_pkg() {
  local pkg="$1"; shift
  local out status
  log "Installing ${pkg} $*"
  # `yes` dies with SIGPIPE once sdkmanager exits; with pipefail that would
  # turn a successful install into status 141, so feed stdin via process
  # substitution and only observe sdkmanager's own exit code.
  set +e
  out="$("$SDKMANAGER" "$@" "$pkg" 2>&1 < <(yes 2>/dev/null))"
  status=$?
  set -e
  printf '%s\n' "$out" | grep -vE '^\[=*[[:space:]]*\][[:space:]]+[0-9]+%' || true
  if [ "$status" -ne 0 ] || printf '%s' "$out" | grep -q "Failed to find package"; then
    return 1
  fi
  return 0
}

# installed_platform_dir <major> -> prints the best installed platform dir
# for that API level (android-<major> or android-<major>.<minor>), if any.
installed_platform_dir() {
  local major="$1" dir
  for dir in \
      "${ANDROID_HOME}/platforms/android-${major}" \
      "${ANDROID_HOME}"/platforms/android-"${major}".[0-9]*; do
    if [ -f "${dir}/android.jar" ]; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

# available_platforms -> "<major>[.<minor>]" versions sdkmanager can install,
# numeric only (no -ext, -beta, codenames), highest last.
available_platforms() {
  "$SDKMANAGER" --list 2>/dev/null |
    sed -n 's/^[[:space:]]*platforms;android-\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\)[[:space:]|].*/\1/p' |
    sort -uV
}

accept_licenses

# --- Requested platform -------------------------------------------------------
REQUESTED="${ANDROID_PLATFORM#platforms;android-}"   # "37" or "37.0"
REQUESTED_MAJOR="${REQUESTED%%.*}"
if ! [[ "$REQUESTED_MAJOR" =~ ^[0-9]+$ ]]; then
  echo "::error::ANDROID_PLATFORM='${ANDROID_PLATFORM}' is not a numeric API level" >&2
  exit 1
fi

INSTALLED_API=""

if dir="$(installed_platform_dir "$REQUESTED_MAJOR")"; then
  log "API ${REQUESTED_MAJOR} already present at ${dir}"
  INSTALLED_API="$REQUESTED_MAJOR"
else
  # Candidate package names, most specific first, de-duplicated.
  candidates=()
  for c in "platforms;android-${REQUESTED}" \
           "platforms;android-${REQUESTED_MAJOR}.0" \
           "platforms;android-${REQUESTED_MAJOR}"; do
    skip=0
    for existing in "${candidates[@]:-}"; do
      [ "$existing" = "$c" ] && skip=1
    done
    [ "$skip" -eq 0 ] && candidates+=("$c")
  done

  # Stable channel first, then everything up to canary (--channel=3 includes
  # channels 0..3) so preview API levels still resolve.
  for channel_args in "" "--channel=3"; do
    for pkg in "${candidates[@]}"; do
      # shellcheck disable=SC2086
      if install_pkg "$pkg" $channel_args && dir="$(installed_platform_dir "$REQUESTED_MAJOR")"; then
        INSTALLED_API="$REQUESTED_MAJOR"
        log "Installed ${pkg} -> ${dir}"
        break 2
      fi
      log "${pkg} ${channel_args:-(stable)}: unavailable"
    done
  done
fi

# --- Fallback: highest numeric platform sdkmanager knows about ---------------
if [ -z "$INSTALLED_API" ]; then
  log "::warning::No API ${REQUESTED_MAJOR} platform package could be installed; falling back"
  FALLBACK_VERSION="$(available_platforms | tail -1 || true)"
  if [ -z "${FALLBACK_VERSION:-}" ]; then
    echo "::error::no android platform packages are available from sdkmanager" >&2
    exit 1
  fi
  FALLBACK_MAJOR="${FALLBACK_VERSION%%.*}"
  if ! dir="$(installed_platform_dir "$FALLBACK_MAJOR")"; then
    install_pkg "platforms;android-${FALLBACK_VERSION}" ||
      install_pkg "platforms;android-${FALLBACK_VERSION}" --channel=3 || {
        echo "::error::failed to install platforms;android-${FALLBACK_VERSION}" >&2
        exit 1
      }
    dir="$(installed_platform_dir "$FALLBACK_MAJOR")" || {
      echo "::error::platforms;android-${FALLBACK_VERSION} installed but android.jar is missing" >&2
      exit 1
    }
  fi
  INSTALLED_API="$FALLBACK_MAJOR"
  log "::warning::Falling back to API ${INSTALLED_API} (${dir}); requested was ${REQUESTED}"
fi

# --- Build tools ------------------------------------------------------------
BT_VERSION="${ANDROID_BUILD_TOOLS#build-tools;}"
if [ -x "${ANDROID_HOME}/build-tools/${BT_VERSION}/aapt2" ] || [ -x "${ANDROID_HOME}/build-tools/${BT_VERSION}/apksigner" ]; then
  log "${ANDROID_BUILD_TOOLS} already present"
elif ! install_pkg "$ANDROID_BUILD_TOOLS"; then
  BT_FALLBACK="$(
    "$SDKMANAGER" --list 2>/dev/null |
      sed -n 's/^[[:space:]]*build-tools;\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[[:space:]|].*/\1/p' |
      sort -uV | tail -1
  )"
  [ -n "${BT_FALLBACK:-}" ] || { echo "::error::no build-tools available" >&2; exit 1; }
  log "::warning::${ANDROID_BUILD_TOOLS} unavailable; using build-tools;${BT_FALLBACK}"
  install_pkg "build-tools;${BT_FALLBACK}"
fi

# --- NDK ---------------------------------------------------------------------
if [ -f "${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}/source.properties" ]; then
  log "ndk;${ANDROID_NDK_VERSION} already present"
else
  install_pkg "ndk;${ANDROID_NDK_VERSION}" || {
    echo "::error::failed to install ndk;${ANDROID_NDK_VERSION}" >&2
    exit 1
  }
fi

# --- Export results to the job ----------------------------------------------
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "ANDROID_NDK_HOME=${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}"
    echo "ANDROID_COMPILE_SDK=${INSTALLED_API}"
  } >> "$GITHUB_ENV"
fi

log "Using compileSdk=${INSTALLED_API}"
ls "${ANDROID_HOME}/platforms" || true
ls "${ANDROID_HOME}/build-tools" || true
