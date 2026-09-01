#!/usr/bin/env bash
# Install the Android SDK / NDK components the Gradle project actually uses.
#
# android/app/build.gradle.kts:
#   compileSdk = 37
#   ndkVersion = "29.0.14206865"
#
# Upstream publishes the API 37 platform as "platforms;android-37.0" (and
# build-tools;37.0.0). Some cmdline-tools builds only know the unsuffixed
# "platforms;android-37" alias. Try both, keep 35/36 so plugin compileSdks
# resolve, and never abort the whole job because one alias is missing.
set -u

SDKMANAGER="${ANDROID_HOME:?ANDROID_HOME is not set}/cmdline-tools/latest/bin/sdkmanager"
NDK_VERSION="${ANDROID_NDK_VERSION:-29.0.14206865}"

if [ ! -x "$SDKMANAGER" ]; then
  echo "::error::sdkmanager not found at $SDKMANAGER"
  exit 1
fi

yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true

install_pkg() {
  local pkg="$1"
  if "$SDKMANAGER" "$pkg"; then
    echo "Installed $pkg"
    return 0
  fi
  echo "::warning::Could not install $pkg"
  return 1
}

# NDK is required: assembleRelease strips native libs / extracts debug
# metadata. Fail the job if this one cannot be installed.
install_pkg "ndk;${NDK_VERSION}" || exit 1

# Platforms / build-tools: try the names upstream uses, then aliases.
platform_ok=0
for pkg in \
    "platforms;android-37.0" \
    "platforms;android-37" \
    "platforms;android-36" \
    "platforms;android-35"
do
  if install_pkg "$pkg"; then
    case "$pkg" in
      *android-37*) platform_ok=1 ;;
    esac
  fi
done

if [ "$platform_ok" -ne 1 ]; then
  echo "::error::Failed to install any Android 37 platform package (needed for compileSdk 37)"
  exit 1
fi

for pkg in \
    "build-tools;37.0.0" \
    "build-tools;36.0.0" \
    "build-tools;35.0.0"
do
  install_pkg "$pkg" || true
done

export ANDROID_NDK_HOME="${ANDROID_HOME}/ndk/${NDK_VERSION}"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ANDROID_NDK_HOME=${ANDROID_NDK_HOME}" >> "$GITHUB_ENV"
fi

echo "::group::Installed SDK components"
ls -la "${ANDROID_HOME}/platforms" || true
ls -la "${ANDROID_HOME}/build-tools" || true
ls -la "${ANDROID_HOME}/ndk" || true
echo "::endgroup::"
