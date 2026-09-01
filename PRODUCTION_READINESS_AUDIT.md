# SpotiFLAC Mobile — Production Readiness Audit

**Audit date:** 2026-09-01
**Baseline commit:** `e1ae41a`
**Branch:** `arena/01a05ee7-spotiflac-mobile`
**Scope:** Flutter app (`lib/`, 259 files / ~187k LOC), Go backend (`go_backend/`, ~180 files / 52.6k LOC), extension runtime, download engine, metadata pipeline, library scanner, Android shell (Kotlin), iOS shell (Swift), dependencies, CI/CD, security, performance.

**Method**

| Tool | Status |
|---|---|
| `go build ./...`, cross-compiled `android/arm64` + `darwin/arm64` | clean |
| `go vet ./...` | clean |
| `staticcheck ./...` (built from source, **all** checks incl. stylecheck) | 0 findings |
| `gofmt -l go_backend` | clean |
| `go test -count=2 ./...` | pass |
| `go test -race -count=1 -shuffle=on ./...` (11 seeds) | pass |
| `.github/workflows/*.yml` structural validation (PyYAML + per-step assertion) | 6/6 OK |
| Purpose-built Dart scanners (`dartscan.py`, `dartscan2.py`, `dartscan3.py`) | 0 deprecated APIs, 0 `print()`, 0 undisposed disposables |
| Secret scan across `lib/ go_backend/ android/ ios/ .github/` | clean |

**Toolchain constraint (important).** The sandbox has no network access to `pub.dev`, `dl.google.com`, `storage.googleapis.com` or the Go module proxy. Go was obtained from a PyPI-hosted toolchain wheel and its dependencies from GitHub mirrors, so **everything on the Go side is compiled and tested for real**. The Flutter SDK is unobtainable here, so `flutter analyze` / `flutter test` / `gradle` / `xcodebuild` **could not be executed**; the Dart, Kotlin and Swift work is manual review plus scripted structural checks. That distinction is carried through every claim below and is restated in *Remaining Risks*.

---

# 1. Full Audit Report

Severity: **S1** ships-broken / crashes, **S2** functional defect or resource leak, **S3** robustness / maintainability.

## S1 — Blocking

### A1. `.github/workflows/ci.yml` was truncated — CI never ran
*File:* `.github/workflows/ci.yml`
**Problem.** The file ended mid-step with a bare `- name:` and no `run`/`uses`. GitHub rejects the whole workflow file, so the Android job and every gate behind it silently never executed. A workflow that fails to parse reports nothing — the repo looked green because nothing ran.
**Root cause.** A partially applied edit (the abandoned `fixed_workflows/` + `workflow-edits.patch` staging area in the repo is from the same episode).
**Fix.** Restored the truncated job, added `go test -race` to the backend job, and deleted the stale staging copies (`fixed_workflows/`, `.github/scripts/workflow-edits.patch`, `scripts/install_android_sdk.sh`) so there is exactly one source of truth.

### A2. iOS launch crash — force cast of `rootViewController`
*File:* `ios/Runner/AppDelegate.swift`
**Problem.** `window!.rootViewController as! FlutterViewController` was used to obtain the binary messenger. Under a UIScene-based launch (`UISceneDelegate` in `Info.plist`, the default on iOS 13+) `window` is `nil` at `didFinishLaunchingWithOptions`, and the force cast traps → **100 % crash on launch** on any path that hits it.
**Root cause.** Pre-UIScene assumption inherited from the iOS 12 app lifecycle.
**Fix.** Added `resolveBinaryMessenger()`: root view controller first, then a walk of `UIApplication.shared.connectedScenes` → `UIWindowScene.windows` for a `FlutterViewController`, then `nil`. Every call site now handles the optional instead of trapping.

### A3. Android — unguarded `startForeground()` crashes the process
*File:* `android/app/src/main/kotlin/com/zarz/spotiflac/DownloadService.kt`
**Problem.** `startForeground()` was called bare inside `onStartCommand`. It throws on modern Android: `ForegroundServiceStartNotAllowedException` (API 31+ background start), `SecurityException` / `InvalidForegroundServiceTypeException` (API 34+ type permissions), and **API 35+ once the `dataSync` 6 h/24 h budget is exhausted** — which a long download queue will reach. An uncaught throw in `onStartCommand` kills the process, immediately followed by the *"did not then call startForeground()"* ANR.
**Root cause.** The FGS-denial mapping (`ForegroundServiceStartPolicy`) existed and was wired into the MainActivity method-channel handler, but the service's own promotion path was never covered.
**Fix.** `startForegroundService()` now returns `Boolean`, catches the throw, logs with `ForegroundServiceStartPolicy.errorCode(e)`, reports `"Foreground service start denied by the system"` through the existing native-worker snapshot (so Dart shows a real error instead of a stuck queue), and stops the service gracefully. The native-queue path aborts instead of continuing into a phantom run.

### A4. Go — the gomobile panic-containment contract covered 17 of 267 entry points
*Files:* `go_backend/exports*.go`, `extension_health.go`, `extension_runtime.go`, `extension_runtime_ffmpeg.go`, `extension_signed_session.go`, `httputil.go`, `logbuffer.go`, `lyrics_config.go`, `runtime_metrics.go`
**Problem.** `bridge_safety.go` documents the rule precisely: gomobile installs **no recover** at the JNI/Objective-C boundary, so a Go panic does not surface as a Kotlin/Swift exception — it aborts the whole app with SIGABRT. An AST census found **104 exported entry points that the Kotlin/Swift shells actually call had no guard.** Concretely: a malformed provider JSON payload, a nil-map write in an extension response path, a slice-bounds error in a tag parser on a corrupt file, or a bad type assertion anywhere under `EnrichTrackWithExtensionJSON`, `SearchTracksWithMetadataProvidersJSON`, `HandleURLWithExtensionJSON`, `LoadExtensionFromPath`, `GetLyricsLRC`, `WriteM4AFreeformTags`, … took the app down. This is the single largest gap between the stated requirement *"one bad extension must not crash the app"* and the code.
**Root cause.** The contract was documented and applied to the download hot path, then not extended as the export surface grew.
**Fix.** Added the deferred `recoverBridgePanic` guard to all 104, generated by an AST rewriter and then compiled and tested. Results were named so the guard can report through the channel that already exists for that function: `err = r` where there is an `error` result, `bridgePanicJSON(r)` for `…JSON` string entry points (yields `{"success":false,"error_type":"unknown"}`, which the queue manager already treats as *item failed, continue*), and a plain swallow-and-log otherwise.
**Regression guard.** New `go_backend/bridge_contract_test.go` parses every `exports*.go` and fails the build if any exported function does not begin with a deferred `recoverBridgePanic`.

### A5. `analysis_options.yaml` pinned a plugin version that `pubspec.yaml` cannot resolve
*File:* `analysis_options.yaml`
**Problem.** `plugins: riverpod_lint: 3.1.4-dev.3` — a hard-pinned pre-release. `pubspec.yaml` requires `^3.1.4` and `pubspec.lock` resolves **3.1.4** stable; `^3.1.4` excludes pre-releases, so the analyzer was asked to load two different versions of the same plugin package. `flutter analyze` fails before analysing a single file, taking the CI analyze gate with it.
**Fix.** `riverpod_lint: ^3.1.4`, matching the lockfile, with a comment tying the two together.

## S2 — Functional defects and leaks

### B1. Go — unbounded growth of the cancel registry
*File:* `go_backend/cancel.go`
**Problem.** `cancelRegistry.requestCancel(id)` on an id with no attached work inserted a *tombstone* `{canceled: true, refs: 0}` so a cancel arriving just before the work starts is still honoured. Nothing ever deleted it. On the extension path this leaks permanently: `PlatformBridge._nextExtensionRequestId` mints a **unique** id per call (`kind:microseconds:seq:extId`) and the UI cancels superseded home-feed / search requests optimistically, so every cancel that loses the race with completion appends one map entry that lives for the process lifetime. Scroll the explore tab for a while and the map grows without bound.
**Root cause.** The download path has an explicit escape hatch (`resetIfIdle`, exported as `ResetDownloadCancel`); the extension path has no equivalent, and neither had a time bound.
**Fix.** `cancelEntry` now carries `tombstonedAt`. `pruneLocked` sweeps tombstones older than `cancelTombstoneTTL` (2 min) on every mutation and enforces `cancelRegistryMaxEntries` (1024) by evicting the oldest. Entries with `refs > 0` are never touched, and attaching work clears `tombstonedAt`, so a cancel racing a start is still honoured exactly as before. Covered by 5 new tests in `cancel_registry_test.go` including the eviction cap and the live-work invariant.

### B2. Go — order-dependent test suite (`-shuffle=on` failed)
*File:* `go_backend/extension_signed_session_test.go`
**Problem.** `go test -shuffle=on ./...` failed on `TestSignedSessionFetchUnauthenticatedTriggersVerification`: `pendingAuthRequests` is a process-global 5-minute dedupe cache keyed by extension id, several tests reuse `"tidal-ext"`, and an auth challenge recorded by an earlier test was replayed into the next one, so the bootstrap request under test never happened. Green in the default order purely by luck — a latent, hard-to-diagnose CI flake.
**Fix.** `newSignedSessionTestRuntime` clears the entry on entry and via `t.Cleanup`. Verified across 11 shuffle seeds under `-race`.

### B3. Go — `-count=2` failed on shared cancel state
*File:* `go_backend/exports_supplement_test.go`
**Problem.** The test cancels the fixed request id `"req-home"`; on a second run in the same process the tombstone from B1 aborted the request instantly.
**Fix.** Added `resetCancelRegistriesForTest()` (in `cancel.go`) and call it at test entry and cleanup. `go test -count=2 ./...` now passes.

### B4. Flutter — `BatchProgressDialog` double-pop and leaked `ValueNotifier`
*File:* `lib/widgets/batch_progress_dialog.dart` (32 call sites)
**Problem.** The static `_activeNotifier` was never disposed, and `dismiss()` called `Navigator.pop(context)` on whatever context it was handed. If the dialog had already been dismissed — hardware back, a route change, a second `dismiss()` from a completion callback — the pop removed **the wrong route**, dropping the user out of the screen underneath. `dismiss()` was not idempotent, and back-button dismissal bypassed the cancel callback entirely, leaving the batch running with no UI.
**Fix.** `show()` captures `Navigator.of(context, rootNavigator: true)` and stores it in a new `_activeNavigator`; the dialog uses `useRootNavigator: true` and is wrapped in `PopScope(canPop: false, onPopInvokedWithResult: …)` so back invokes `onCancel()` instead of silently closing. `dismiss()` returns early when there is no active dialog and pops only `if (navigator.canPop())`. The notifier is disposed in `.whenComplete()`, which owns exactly one notifier per dialog (deliberately *not* disposed in `show()` — a second `dispose()` asserts).

### B5. `AndroidManifest.xml` — AGP-incompatible `package` attribute, missing `<queries>`
*File:* `android/app/src/main/AndroidManifest.xml`
**Problem.** The `package` attribute in the manifest is an error under AGP 8+ (the project is on AGP 9.3.2) — namespace belongs in Gradle. Separately, with `targetSdk 35` and no `<queries>` block, Android 11+ package visibility makes `url_launcher` and `open_filex` fail to resolve a handler, so "open in browser" / "open file" silently no-op.
**Fix.** Removed the attribute; added `<queries>` for the intents the app actually launches.

### B6. `ios/Podfile` — `GCC_PREPROCESSOR_DEFINITIONS` type assumption
*File:* `ios/Podfile`
**Problem.** `post_install` did `definitions << 'PERMISSION_NOTIFICATIONS=1'`. Xcodeproj returns this setting as a **String** when a target defines a single value, and `String#<<` concatenates, producing `"$(inherited)PERMISSION_NOTIFICATIONS=1"` — one malformed macro, so the notification permission is silently compiled out of `permission_handler`.
**Fix.** Normalize first: `definitions.is_a?(Array) ? definitions.dup : [definitions.to_s]`.

### B7. iOS — data race on the progress-stream cursors
*File:* `ios/Runner/AppDelegate.swift`
**Problem.** `start/stopDownloadProgressStream` and the library-scan equivalent mutated the cursor/sequence state and the `DispatchSourceTimer` from the platform thread while the timer handler read them on `streamQueue` — an unsynchronised read/write pair, i.e. an intermittent corrupt-progress / crash source that only shows under load.
**Fix.** All cursor state and timer lifecycle moved inside `streamQueue`: `start*` resets and creates/resumes the source in `streamQueue.async { [weak self] }`; `stop*` clears the main-thread-only event sink, then `streamQueue.sync { setEventHandler({}); cancel(); … }`. No deadlock is possible — start/stop are only reached from the platform (main) thread and `deinit`, the handler leaves the queue only via `DispatchQueue.main.async`, and the async closures hold `weak self` so `deinit` cannot be entered on `streamQueue`.

### B8. `pages.yml` failed the run when the site directory is absent
*File:* `.github/workflows/pages.yml`
**Fix.** Detect and skip cleanly instead of failing the job.

### B9. `release.yml` — apksigner/build-tools mismatch, hard failure on missing secrets
*File:* `.github/workflows/release.yml`
**Problem.** The signing step referenced a build-tools version that the SDK setup does not necessarily install, and steps gated on repository secrets failed outright on forks/PRs. Note the GitHub-specific trap here: **the `secrets` context is not available in `if:` expressions**, so the obvious guard silently evaluates false-y.
**Fix.** Resolve apksigner from the SDK that was actually installed; map secret presence to a job-level `env:` flag and gate on that; add least-privilege `permissions:` blocks.

## S3 — Robustness

### C1. Go — redundant goroutine in HTTP/2 connection retirement
*File:* `go_backend/httputil_utls.go`. `retirePooledHTTP2Conn` spawned a goroutine whose only statement spawned another goroutine. Collapsed to one. Also documented why the `timeout <= 0` branch (streams still in flight) intentionally has no deadline — a single track can legitimately stream for minutes, so a watchdog there would abort live downloads. See *Remaining Risks* R4.

### C2. Docs referenced deleted scripts
*File:* `BUILD_FIXES.md` pointed at `scripts/install_android_sdk.sh`, removed in A1. Repointed at `.github/scripts/setup-android-sdk.sh` and documented the `ANDROID_COMPILE_SDK` / `ANDROID_NDK_HOME` contract it has with `android/app/build.gradle.kts`.

## Verified clean (reviewed, no change required)

- **Extension isolation.** `RunWithTimeoutContext` is correct and notably careful: on timeout it calls `vm.Interrupt` and then **blocks until the JS goroutine actually exits** — because goja is not thread-safe and returning early would let the next caller touch a live VM. If the goroutine does not exit within the 5 s grace period the runtime is quarantined rather than reused. Infinite loops, `while(true)`, and blocking host calls are all contained.
- **Network sandbox / SSRF.** Explicit private-network blocking with dedicated tests (`extension_test.go`), `SetAllowPrivateNetwork` off by default.
- **Library scanner concurrency.** `library_scan.go:264-330` producer/worker/closer trio verified leak-free on cancellation and on sink error.
- **ISRC duplicate workers.** `duplicate.go:137-155` workers write disjoint `isrcs[i]` slots — no race. (No cancellation path; see R5.)
- **Dart lifecycle.** `share_intent_service.dart` cancels its subscription and closes its controller; `music_player_service.dart` and `preview_player_provider.dart` collect every `.listen()` into a `_subscriptions` list that `dispose()` drains; `smoothed_progress.dart` disposes via a cascade. All `dartscan` hits in these areas are false positives.
- **Secrets.** No hardcoded credentials anywhere in the audited tree.
- **`unsigned-release.yml`** (this fork's primary release path, `v*` tags) reviewed end to end: gomobile bind → XCFramework link/embed → `pod install` → `flutter build ios --no-codesign` → archive → strip `_CodeSignature`/`embedded.mobileprovision` → zip `Payload/` → verify `Info.plist`. No blocking defect. Cosmetic only: `merge-multiple: true` also lands the `ios-xcodebuild-log` artifact in `dist/`.

---

# 2. Code Changes

Two commits on `arena/01a05ee7-spotiflac-mobile`, 42 files, +1256 / −2279.

| Commit | Contents |
|---|---|
| `6e77214` | CI workflow repair, manifest, FGS hardening, iOS launch crash + stream race, Podfile, BatchProgressDialog, shuffle-order test fix |
| `51b48fd` | gomobile panic containment (104 entry points + AST contract test), cancel-registry leak fix + 5 tests, HTTP/2 retirement cleanup |

Representative before/after:

**A4 — panic containment.** *Before*
```go
func GetProviderMetadataJSON(providerID, resourceType, resourceID string) (string, error) {
    trimmedProviderID := strings.TrimSpace(providerID)
```
*After*
```go
func GetProviderMetadataJSON(providerID, resourceType, resourceID string) (bridgeOut string, bridgeErr error) {
    defer func() {
        if r := recoverBridgePanic(recover()); r != nil {
            bridgeErr = r
        }
    }()

    trimmedProviderID := strings.TrimSpace(providerID)
```
*Rationale.* Zero behavioural change on the success path; a panic now becomes an ordinary error on the channel the caller already handles, instead of SIGABRT. Named results are required for a deferred closure to set them; `bridge`-prefixed names avoid collisions with existing locals.

**B1 — cancel registry.** *Before*
```go
} else {
    r.entries[id] = &cancelEntry{canceled: true}   // never removed
}
```
*After*
```go
} else {
    r.entries[id] = &cancelEntry{canceled: true, tombstonedAt: time.Now()}
}
r.pruneLocked(time.Now())
```
plus `pruneLocked`, which drops tombstones past `cancelTombstoneTTL`, enforces `cancelRegistryMaxEntries`, and skips anything with `refs > 0`.
*Rationale.* Keeps the intended cancel-before-start semantics inside a bounded window, converts an unbounded leak into a self-healing cache, and makes the suite hermetic.

**A3 — foreground service.** *Before* `startForeground(...)` bare, returning `Unit`. *After* the call is wrapped, the failure is classified via the existing `ForegroundServiceStartPolicy`, surfaced to Dart through the native-worker snapshot, and the service stops itself; `startNativeWorker` returns early on `false`.
*Rationale.* On Android 15 the `dataSync` budget makes this failure *expected*, not exceptional. Degrading to a reported error keeps the queue state consistent instead of crashing.

**A2 — iOS messenger.** *Before* `window!.rootViewController as! FlutterViewController`. *After* `resolveBinaryMessenger()` returning `FlutterBinaryMessenger?` via root VC → connected-scene walk → `nil`, with all call sites unwrapping.
*Rationale.* Removes the only force-unwrap on the launch path and makes the code correct for both window- and scene-based lifecycles.

---

# 3. Production Readiness Report

| Area | Rating | Basis |
|---|---|---|
| **Go backend** | **A−** | Compiles for android/arm64 + darwin/arm64; `go vet`, `staticcheck` (all checks) and `gofmt` clean; suite green under `-race`, `-count=2` and 11 `-shuffle` seeds. The two order-dependency bugs and the registry leak found here are fixed with tests. Not yet exercised: `gomobile bind` itself (needs the Android/Xcode toolchains). |
| **Extension stability** | **A−** | Timeout + interrupt + VM quarantine are genuinely well built; the network sandbox is tested. The missing piece was the FFI boundary, which is now guarded on every shell-called entry point and enforced by a contract test. Remaining exposure is panics inside goroutines the extension path spawns (R3). |
| **Android** | **B+** | Toolchain is current (AGP 9.3.2 / Kotlin 2.4.10 / Gradle 9.6.1 / JDK 17 / compileSdk 37 / NDK 29 for 16 KB pages). The manifest and the FGS crash path are fixed. Unverified because Gradle cannot run here: the actual release assemble, SAF behaviour on a device, and the API 35 `dataSync` budget path (now handled, not observed). |
| **iOS** | **B** | The launch-time force cast and the progress-stream race are gone; Podfile post-install is type-safe; deployment target 15.0; the unsigned-IPA pipeline is coherent. Lowest confidence of the four: no `xcodebuild`, no `pod install`, no simulator run was possible, and the `device_info_plus` vision-selector patch in the Podfile is a fragile third-party workaround (R2). |
| **Download stability** | **B+** | Queue/pause/resume/cancel/dedupe logic reviewed; the cancel registry is now leak-free and its semantics are test-pinned; a panic mid-item now fails that item instead of the process; FGS denial no longer kills a running queue. End-to-end multi-hundred-item runs were not executable here. |
| **Metadata reliability** | **B** | All format writers are behind the now-guarded entry points, so a corrupt file degrades to a reported error rather than SIGABRT — the single biggest reliability change for this area. Format-by-format correctness (FLAC/MP3/AAC/M4A/OGG/OPUS/WAV/AIFF, cover, lyrics, ReplayGain, Unicode) rests on the existing Go test suite, which passes; no new field testing was possible. |
| **CI/CD** | **B+** | All six workflows now parse and every step is well-formed (previously `ci.yml` did not parse at all, so nothing ran). Secret-gated steps no longer break forks; permissions are least-privilege; the real Gradle error is surfaced instead of Flutter's opaque wrapper. **This cannot be called an A until one green run exists on GitHub** — see R1. |

**Overall: B+ / release-candidate.** No known crash-on-launch, crash-on-panic, or CI-dead-on-arrival defect remains. The gating item is not a known bug but the absence of a real build: nothing here has been compiled by Gradle or Xcode.

---

# 4. Remaining Risks

**R1 — No Flutter/Android/iOS build was executed (highest).**
`pub.dev`, `dl.google.com` and `storage.googleapis.com` are unreachable from this environment, so `flutter pub get`, `flutter analyze`, `flutter test`, `gradle assembleRelease` and `xcodebuild` could not run. Every Dart/Kotlin/Swift change is manual review plus structural checking. **Required action:** push the branch and let `build-mobile.yml` run; treat the first green Android + iOS artifact as the actual release gate. The `analysis_options.yaml` plugin change (A5) in particular flips a gate that has never been observed passing — if `flutter analyze` still errors on the plugin, the fallback is to drop the `plugins:` block and the `analyzer`/`riverpod_lint` dev-dependencies entirely, which costs lint coverage but nothing else.

**R2 — `device_info_plus` vision-selector patch in `ios/Podfile`.**
`patch_device_info_plus_vision_selector` injects an `isiOSAppOnVision` compatibility category into a third-party pod at install time. It will break the moment upstream changes that file or the plugin version moves. Not auto-fixable — it needs an upstream fix or a pinned plugin version.

**R3 — Panics inside goroutines are still fatal.**
`recoverBridgePanic` protects the calling goroutine only. A panic inside one of the 12 background goroutines (library-scan workers, ISRC parse workers, HTTP/2 retirement, stall watchdog) still aborts the process. Adding a guard to each is mechanical but changes failure semantics per site, so it was left out of this pass; the download and scan workers are the ones worth doing next.

**R4 — HTTP/2 retirement with active streams has no deadline.**
When a retired connection still has in-flight streams, `conn.Shutdown(context.Background())` runs unbounded (deliberately — a single track can stream for minutes and a watchdog would abort live downloads). A peer that never closes the stream holds one goroutine and one socket for the process lifetime. Bounding it correctly needs a real-network measurement of worst-case track duration.

**R5 — ISRC duplicate-parse workers have no cancellation path.**
`duplicate.go:137-155` spawns per-file parse workers that cannot be cancelled. On a very large library a cancelled scan still pays for the whole ISRC pass. Memory-safe and race-free, just not interruptible; wiring a context through is a behavioural change best made with a real library to measure against.

**R6 — Android 15 `dataSync` foreground-service budget.**
A3 makes the denial survivable, but the app has no *strategy* for it: once the 6 h/24 h budget is exhausted, long queues cannot run in the foreground at all. The real fix is migrating the long-tail queue to `WorkManager` with an expedited job, which is a feature-level change and out of scope for a stability pass.

**R7 — Unverifiable areas.**
SAF/scoped-storage behaviour on a real device, the `gomobile bind` step for both platforms, notification-permission flow on Android 13+, security-scoped bookmarks on iOS, and end-to-end download/metadata runs across all eight audio formats all require physical or CI execution. They are reviewed but not proven.
