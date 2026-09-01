# Build Fixes for Android and iOS

## Root Causes

### Android: `Gradle task assembleRelease failed with exit code 1` (241.7s)

1. **Java 25 incompatibility**: The project uses `JavaVersion.VERSION_25` and `JVM_25` in `android/app/build.gradle.kts` and `android/build.gradle.kts`, and `java-version: "25"` in all workflows. However:
   - Gradle 9.1.0+ officially supports Java 25 for running, but Kotlin plugin support for Java 25 only landed in Gradle 9.4+ (see gradle/gradle#36162)
   - Android Gradle Plugin (AGP) is validated only against Java 17 and partially Java 21, **not Java 25** (see flutter/flutter#187223 "Java 25 Support in Flutter Android Builds")
   - Flutter's Android tooling fails with JDK 25 even with Gradle 9.1+
   - **Fix**: Downgrade to Java 17 (LTS, most compatible with Flutter and AGP 8.x/9.x)

2. **compileSdk 37 too new**: `compileSdk = 37` and `targetSdk = 37` (Android 17) is very new and requires build-tools 37.0.0 and platform 37.0 which are not stable. Flutter's default is 35 (Android 15).
   - **Fix**: Downgrade to `compileSdk = 35` and `targetSdk = 35`, and install `platforms;android-35.0` and `build-tools;35.0.0` in workflows

3. **R8 minification failure**: `isMinifyEnabled = true` + `isShrinkResources = true` with Go AAR (`gobackend.aar`) + FFmpegKit can cause R8 to strip required classes or fail during optimization, especially with Java 25 bytecode
   - **Fix**: Disable minification (`isMinifyEnabled = false`, `isShrinkResources = false`) for CI, keep ProGuard rules for future enablement. Also set `android.enableR8.fullMode=false` in gradle.properties

4. **Double APK splitting**: `splits.abi` in `app/build.gradle.kts` with `isUniversalApk = true` conflicts with Flutter's `--split-per-abi` flag. Both try to split APKs, causing duplicate tasks and potential R8 issues
   - **Fix**: Remove `splits.abi` block, rely solely on Flutter's `--split-per-abi`

5. **Gradle memory**: `org.gradle.jvmargs=-Xmx2g` is low for Flutter + Go + FFmpeg build (241s build)
   - **Fix**: Increase to `-Xmx4g -XX:MaxMetaspaceSize=1g`

### iOS: `Run script build phase 'Run Script' will be run...` + `exit code 65`

Exit code 65 is generic `xcodebuild` failure. Root causes:

1. **Deployment target too low**: `platform :ios, '14.0'` and `IPHONEOS_DEPLOYMENT_TARGET = 14.0` in Podfile and `project.pbxproj`. Xcode 16+ (and especially Xcode 26.1.1 used in workflows) drops support for iOS 14. Minimum for Xcode 16 is iOS 12, but Xcode 26 likely requires iOS 15+.
   - **Fix**: Bump to `15.0` in Podfile (`platform :ios, '15.0'`), in `post_install` enforce `>= 15.0`, and in `project.pbxproj` replace all `14.0` with `15.0`

2. **Missing `pod install`**: Both `release.yml` and `unsigned-release.yml` cache `ios/Pods` but never run `pod install`. Since `Podfile.lock` is gitignored, cache key `hashFiles('ios/Podfile.lock')` is empty, cache always misses, and `Runner.xcworkspace` expects Pods project. `xcodebuild archive` then fails with code 65 because Pods not installed.
   - **Fix**: Add explicit `pod install --repo-update` after `flutter pub get` and again after `flutter build ios --config-only` (which can update Podfile)

3. **Xcode version selection brittle**: Workflows hardcode `Xcode_26.1.1.app` which may not exist on `macos-15` runners (which have Xcode 16.x). `xcode-select` fails, causing build to use wrong Xcode or fail
   - **Fix**: Make selection robust with fallback: try 26.1.1, then 16.4, 16.2, then `Xcode.app`

4. **User script sandboxing**: Xcode 16+ enables `ENABLE_USER_SCRIPT_SANDBOXING` by default, which breaks Flutter's `xcode_backend.sh` and FFmpegKit scripts
   - **Fix**: Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` in project and in Podfile post_install for all pods, and pass `ENABLE_USER_SCRIPT_SANDBOXING=NO` to `xcodebuild`

5. **XCFramework linking not idempotent**: Ruby script that adds `Gobackend.xcframework` to Xcode project would add duplicate references on re-runs, causing project file corruption
   - **Fix**: Make idempotent check (`existing = frameworks_group.files.find { |f| f.path == path }`)

## Changes Made

### Already pushed (branch `arena/01a05a19-spotiflac-mobile`, PR #3)

- `android/app/build.gradle.kts`:
  - `compileSdk 37 -> 35`, `targetSdk 37 -> 35`
  - `JavaVersion.VERSION_25 -> VERSION_17`, `JVM_25 -> JVM_17`
  - `isMinifyEnabled true -> false`, `isShrinkResources true -> false`
  - Remove `splits.abi` block

- `android/build.gradle.kts`:
  - `VERSION_25 -> VERSION_17`, `JVM_25 -> JVM_17`

- `android/gradle.properties`:
  - `Xmx2g -> Xmx4g`, `MaxMetaspaceSize 512m -> 1g`
  - Remove deprecated `android.builtInKotlin=false` and `android.newDsl=false`
  - Add `android.enableR8.fullMode=false`

- `ios/Podfile`:
  - `platform :ios, '14.0' -> '15.0'`
  - Post_install: enforce `>= 15.0` instead of forcing `14.0`, add `ENABLE_USER_SCRIPT_SANDBOXING = NO`

- `ios/Runner.xcodeproj/project.pbxproj`:
  - `IPHONEOS_DEPLOYMENT_TARGET 14.0 -> 15.0` (3 occurrences)

### Workflow fixes (require `workflows` permission to push)

These are fixed locally but could not be pushed due to GitHub App missing `workflows` permission (403). You need to either:
- Reconnect GitHub in Arena with `workflows` permission, or
- Manually apply the changes below to `.github/workflows/`

**`.github/workflows/ci.yml`:**
- `java-version: "25" -> "17"`
- `platforms;android-37.0 -> platforms;android-35.0`
- `build-tools;37.0.0 -> build-tools;35.0.0`

**`.github/workflows/release.yml`:**
- `java-version: "25" -> "17"`
- `platforms;android-37.0 -> platforms;android-35.0`
- `build-tools;37.0.0 -> build-tools;35.0.0`
- Remove `Cache CocoaPods` step (was caching with empty hash), add `Install CocoaPods dependencies` (`pod install --repo-update`) after `flutter pub get`
- Add `pod install` after `flutter build ios --config-only`
- Make Xcode selection robust with fallback
- Add `ENABLE_USER_SCRIPT_SANDBOXING=NO` to xcodebuild
- Make XCFramework linking idempotent

**`.github/workflows/unsigned-release.yml`:**
- Same as release.yml:
  - `ANDROID_PLATFORM: "platforms;android-37.0" -> "platforms;android-35.0"`
  - `ANDROID_BUILD_TOOLS: "build-tools;37.0.0" -> "build-tools;35.0.0"`
  - `java-version: "25" -> "17"`
  - Add `pod install` steps
  - Robust Xcode selection
  - `ENABLE_USER_SCRIPT_SANDBOXING=NO`

## How to Apply Workflow Fixes Manually

If you cannot grant `workflows` permission, copy these fixed files from the local checkout:

```bash
# On your machine with the fixed branch checked out:
cat .github/workflows/ci.yml
cat .github/workflows/release.yml
cat .github/workflows/unsigned-release.yml
```

Or apply the patch:

```bash
git diff HEAD .github/workflows/ > workflow_fix.patch
# Then apply on main:
git apply workflow_fix.patch
```

## Verification

After applying all fixes:

- Android: `flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64` should succeed with Java 17, Gradle 9.6.1, AGP 9.3.1, compileSdk 35
- iOS: `flutter build ios --release --no-codesign --config-only && cd ios && pod install && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath build/Runner.xcarchive archive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" ENABLE_USER_SCRIPT_SANDBOXING=NO` should succeed

## Future Improvements

- Consider upgrading to Java 21 (LTS) once AGP 9.x + Flutter fully support it (currently 17 is safest)
- Re-enable R8 minification after testing with `android.enableR8.fullMode=false` and thorough ProGuard rules for Go and FFmpeg
- Consider replacing `ffmpeg_kit_flutter_new_full` (which bundles large binaries) with a more lightweight FFmpeg solution or `ffmpeg_kit_flutter_new_min` if full codecs not needed
- Commit `ios/Podfile.lock` to repo to make CocoaPods cache key work (currently gitignored, so cache always misses)
- Update `.fvmrc` Flutter version 3.44.8 - verify it exists, otherwise use stable 3.35.x

---

## iOS: `xcodebuild archive failed with exit code 70` (2026-09-01)

### Root cause

The `Archive Runner without code signing` step in `.github/workflows/build-mobile.yml`
(and the same step in `unsigned-release.yml`) fails **fast** (before any compilation)
with exit code 70 and an `ios-xcodebuild-log` artifact of only ~1.3 KB.

The log's byte layout matches Xcode's **"Unable to find a destination matching the
provided destination specifier: { platform:iOS, generic }"** error, with the
"Any iOS Device" destination marked *ineligible* because the iOS platform for the
preferred Xcode is missing/incomplete:

- The workflow prefers `Xcode 26.1.1` (when present on the runner image).
- GitHub-hosted `macos-15` images have shipped Xcode 26.1 **without a properly
  installed iOS 26.1 platform** — known issue
  [actions/runner-images#13275](https://github.com/actions/runner-images/issues/13275)
  ("iOS 26.1 is not installed. Please download and install the platform from
  Xcode > Settings > Components."). `xcodebuild` then cannot resolve the generic
  iOS device destination and exits with code 70 after printing only ~1.2 KB.
- `gomobile bind -target=ios` still succeeds because it only needs the SDK
  headers/toolchain, not Xcode's destination/device registration.

(The scheme-not-found variant would produce a ~980-byte log, which does not match
the observed ~1311-byte artifact, so the Runner scheme is not the problem.)

### Fix (requires `workflows` permission to push — see `workflow_fix.patch`)

In `.github/workflows/build-mobile.yml`:

1. Before archiving, ensure the iOS platform is present:
   `xcodebuild -downloadPlatform iOS || true` (cheap no-op when installed).
2. Wrap the `xcodebuild archive` call in a retry function; if it fails, retry
   once with the runner's default Xcode whose platform is always installed
   (`/Applications/Xcode_16.4.app`, falling back to `/Applications/Xcode.app`).
3. On failure, mirror the raw log (both attempts), the Xcode version, and
   scheme/destination probes into `::error::` check-run annotations via
   `scripts/ci_annotate.py`, so the real error is visible in the Actions UI and
   via the checks API without downloading the artifact.

Apply locally:

```bash
git apply workflow_fix.patch   # from this branch's root
git add .github/workflows/build-mobile.yml
git commit -m "ci: fix iOS archive destination failure (exit 70)"
git push
```

### Android: compileSdk 37 vs installed SDK platform

`android/app/build.gradle.kts` compiles against `compileSdk = 37` (the current
androidx/activity/plugin set requires it), but `build-mobile.yml` only installed
`platforms;android-35`. The workflow now also installs `platforms;android-37`
and `build-tools;36.0.0`; AGP auto-downloads anything still missing. This was
one candidate cause of the parallel `Build release APKs` failure (exit 1) — the
new log annotations will confirm the exact Gradle error on the next run.

---

## Android: `Gradle task assembleRelease failed with exit code 1` (8m 22s / 502.8s)

`compileDebugKotlin` on CI was already green with `compileSdk = 37`. Lowering
it to 35 (PR #11) **broke** that job via `checkReleaseAarMetadata` — do not
revert compileSdk. The 8-minute `assembleRelease` failure is a *late-stage*
packaging task, not a missing `android.jar`.

Root causes addressed:

1. **NDK version mismatch.** Flutter 3.44.8's `flutter.ndkVersion` is
   `28.2.13676358`, but every workflow installs NDK `29.0.14206865` (needed
   for 16 KB pages). `assembleRelease` with `debugSymbolLevel = FULL` then
   fails in `extractReleaseNativeDebugMetadata` / `stripReleaseDebugSymbols`.
   **Fix:** pin `ndkVersion = "29.0.14206865"` in `android/app/build.gradle.kts`.
2. **Platform 37 not installed.** Upstream installs `platforms;android-37.0`
   + `build-tools;37.0.0`. This fork only installed API 35. Debug Kotlin
   compile only needs `android.jar` (often cached/auto-downloaded); release
   packaging needs the full platform + matching build-tools.
   **Fix:** `scripts/install_android_sdk.sh` tries `android-37.0` then
   `android-37`, plus 36/35 and build-tools 37/36/35.
3. **Duplicate `libc++_shared.so`.** FFmpeg Kit full + gomobile + audio
   plugins each ship the NDK C++ runtime. `mergeReleaseNativeLibs` fails
   after compilation with "2 files found with path ...".
   **Fix:** `packaging.jniLibs.pickFirsts` for `libc++_shared.so` / `libfbjni.so`.
4. **`lintVitalRelease`.** AGP runs fatal lint on application release builds
   by default; plugin findings fail assembleRelease after a long compile.
   **Fix:** `lint { checkReleaseBuilds = false; abortOnError = false }`.
5. **Opaque Flutter wrapper.** Flutter collapses every Gradle failure to
   "assembleRelease failed with exit code 1".
   **Fix:** `scripts/flutter_build_apk.sh` tees the log, greps the real
   `FAILURE:` / `What went wrong` lines, and emits `::error::` annotations
   via `scripts/ci_annotate.py`.
