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

## Android: `Gradle task assembleRelease failed with exit code 1` — `compileSdk 37` vs `platforms;android-35` (2026-09-01)

### Root Cause

`android/app/build.gradle.kts` sets `compileSdk = 37` (the current Flutter plugin
dependency set — `audioplayers_android 5.3.0`, `connectivity_plus 7.3.1`,
`file_picker 12.0.0`, `receive_sharing_intent 1.9.0` — genuinely requires API 37
to compile). The `build-mobile.yml` workflow installs only `platforms;android-35`.
AGP cannot fall back to a lower platform; the exact `compileSdk` API level must be
installed, causing `assembleRelease` to fail with exit code 1.

Note: `compileDebugKotlin` (the CI task) succeeds because GitHub Actions
`ubuntu-latest` runners already have `android-37` pre-installed; the explicit
`sdkmanager` step in `ci.yml` only adds NDK and build-tools on top of the
pre-installed baseline SDK. `assembleRelease` (in `build-mobile.yml`) requires the
full platform to be explicitly available.

### Fix (requires `workflows` permission to push)

In `.github/workflows/build-mobile.yml`, change:
```yaml
ANDROID_PLATFORM: "platforms;android-35"
```
to:
```yaml
ANDROID_PLATFORM: "platforms;android-37"
```

The fixed workflow is saved in `fixed_workflows/build-mobile.yml`.
Apply it by copying it to `.github/workflows/build-mobile.yml` after granting
Arena the `workflows` GitHub App permission, or apply it manually.

### Why `compileSdk` cannot simply be lowered to 35

An attempt to set `compileSdk = 35` to match the workflow's `android-35` install
was tested (PR #11) but caused `compileDebugKotlin` to fail — confirming that the
plugin dependency set genuinely requires API 37 at compile time.

---

## iOS: `xcodebuild archive failed with exit code 70` — conflicting `-sdk` and `-destination` flags (2026-09-01)

### Root Cause

The archive command in `build-mobile.yml` passed both `-sdk iphoneos` **and**
`-destination 'generic/platform=iOS'`. Xcode 16+ rejects this combination with
exit code 70 and writes virtually nothing to the log (observed: 1 312-byte
compressed artifact).

### Fix (requires `workflows` permission to push)

Remove `-sdk iphoneos` from the `xcodebuild archive` call. The
`-destination 'generic/platform=iOS'` flag automatically selects the correct SDK.
The fixed workflow (in `fixed_workflows/build-mobile.yml`) includes this change
plus improved on-failure diagnostics (dumps the last 200 log lines).
