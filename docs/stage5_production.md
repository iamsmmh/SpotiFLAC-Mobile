# Stage 5 — Production hardening, distribution & multi-platform delivery

SpotiFLAC Mobile **v1.0 production** is a milestone on top of `4.9.0+141`
(the version is **not** bumped). Stages 1–4 remain the functional baseline;
this stage makes a 2-hour lossless stream + background download session
safe to ship, and makes the GitHub Actions pipelines produce the artifacts
a store / sideload channel actually needs.

## 1. Obfuscation & secret storage

* **R8 minify + resource shrink** is on for `release` in
  `android/app/build.gradle.kts`. `android.enableR8.fullMode` stays **false**
  so Flutter MethodChannel reflection, gomobile `Gobackend.*`, and both
  FFmpeg Kit packages survive. Keep rules live in
  `android/app/proguard-rules.pro` (Flutter embedding, gomobile, FFmpeg Kit
  old + new packages, `audio_service`, `flutter_secure_storage`, Tink /
  EncryptedSharedPreferences).
* **Secrets / tokens / extension signatures** go through `SecureStore`
  (`lib/core/data/secure_store.dart`):
  * Android — `EncryptedSharedPreferences` via
    `flutter_secure_storage` (`encryptedSharedPreferences: true`) **and** a
    native warmup (`NativeSecureStore.warmup` in `MainActivity.onCreate`)
    using **security-crypto 1.0.0** `MasterKeys.getOrCreate` (not the 1.1
    alpha `MasterKey` builder).
  * iOS — Keychain, `first_unlock_this_device`, `synchronizable: false`.
  * Schema v1; the retired plaintext `spotify_client_secret` is wiped on
    boot.

## 2. Memory / battery (2h+ session)

Caps live in `SessionResourceBudget` / `RebuildBudget` and are applied by
cold start, `CoverCacheManager`, and `CachedCoverImage`:

| Tier     | Image cache entries | Image cache bytes | Cover disk        |
| -------- | ------------------- | ----------------- | ----------------- |
| low      | 120                 | 24 MiB            | 1000 / 150 MiB    |
| standard | 240                 | 60 MiB            | 1000 / 150 MiB    |
| high     | 320                 | 80 MiB            | 1000 / 150 MiB    |

List tiles (logical size ≤ 256) also cap **disk** decode so a 1800 px cover
is not stored at full resolution a thousand times. Download / FFmpeg worker
threads run at `THREAD_PRIORITY_BACKGROUND` /
`BACKGROUND + MORE_FAVORABLE` (`NativeThreadPriority`) so a long queue
cannot starve UI or the `mediaPlayback` FGS. Stream head buffer stays at
4 MiB.

## 3. Distribution

Required Android ABIs: **arm64-v8a, armeabi-v7a, x86_64**. Matching
gomobile target: `android/arm,android/arm64,android/amd64`. Flutter
`--target-platform`: `android-arm,android-arm64,android-x64`.

Published names (see `ReleaseArtifactPolicy`):

```
SpotiFLAC-<version>-arm64.apk
SpotiFLAC-<version>-arm32.apk
SpotiFLAC-<version>-x86_64.apk
SpotiFLAC-<version>.aab
SpotiFLAC-<version>-ios-unsigned.ipa
SHA256SUMS.txt
```

Checksums are `sha256sum` text mode (`<hex>  <filename>`), parsed and
verified in Dart with `lib/core/data/sha256.dart`.

Workflows:

* `.github/workflows/release.yml` — signed APK splits + AAB + unsigned IPA.
  Keystore / Telegram secrets are copied into job `env:` and gated with
  `if: env.X != ''` so a missing secret skips signing instead of failing
  closed on a fork.
* `.github/workflows/unsigned-release.yml` / `build-mobile.yml` — same ABI
  set + AAB, debug-signed when `key.properties` is absent.
* `.github/workflows/auto-tag.yml` — annotated tag message is the
  `git-cliff` changelog (`cliff.toml`).

## 4. E2E sanity (policy + wiring)

These are encoded as pure Dart / Kotlin unit tests so CI can run them
without a device farm. The production call sites are:

| Scenario                         | Policy                         | Call site                                      |
| -------------------------------- | ------------------------------ | ---------------------------------------------- |
| Cold start                       | `ColdStartPolicy`              | `lib/main.dart` (bindings vs post-frame)       |
| Wi-Fi ↔ cellular                 | `NetworkSwitchPolicy`          | `download_queue_provider_connectivity.dart`    |
| Android 13–16+ storage           | `AndroidStoragePermissionPolicy` | `setup_screen.dart`                          |
| iOS 17+ background playback      | `BackgroundPlaybackPolicy`     | `music_player_service.dart`; Info.plist `audio` only |

`UIBackgroundModes` stays **`audio` only** — do not add `processing`.

## What this sandbox cannot prove

The Agent Mode checkout has no Flutter SDK, Gradle, or Xcode. `flutter analyze`,
`flutter test`, `assembleRelease`, and an IPA archive have to run in GitHub
Actions (`ci.yml` + `release.yml` / `unsigned-release.yml`). The Dart and
Kotlin unit tests plus the workflow/script ABI lists are the structural gate.
