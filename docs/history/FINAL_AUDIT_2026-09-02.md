# SpotiFLAC Mobile — Executive Audit Report (2026-09-02)

**Scope:** Flutter `lib/`, Go gomobile backend `go_backend/`, Android Kotlin shell, iOS Swift shell, and GitHub Actions.
**Baseline:** `97191518d615223c69100223538fc2a50d7fc68f` on `arena/01a060c1-spotiflac-mobile`.
**Method:** full-repository review focused on queue scheduling, SAF/fd ownership, storage persistence, channel contracts, and workflow correctness. Dart/Kotlin/Swift are reviewed statically because this sandbox has no Flutter/JDK/Xcode/Go toolchain; the Go and workflow changes are intentionally conservative and covered by new regression tests where possible.

Severity legend: **Critical** = crash / data loss / broken ship; **High** = leak or data-loss path; **Medium** = edge-case bug; **Low** = cleanup / maintainability.

---

## Executive Summary

This pass found **four High/Critical latent defects**, two Medium workflow/channel defects, and one Low diagnostic defect. All seven were patched in the working tree with regression coverage where a test could be authored without a compiler. No existing tests are expected to break: each fix tightens behavior that was previously silently wrong (stale drain, unbounded allow-list growth, SAF fd leak, settings path traversal / torn writes, Pages workflow false failure, channel diagnostic label).

The repository already contains a large set of prior audits (`AUDIT_REPORT.md`, `PRODUCTION_READINESS_AUDIT.md`, `BUILD_FIXES.md`). This report is a fresh layer on top of that baseline, not a replacement.

---

## Findings and Fixes

### Critical

#### C1. `QueueEngine.drained` returned an already-completed future for the next work cycle

- **File:** `lib/core/application/queue_engine.dart`
- **Lines:** getter ~186; `_signalEmptinessIfIdle` ~429
- **Severity:** Critical (concurrency bug that corrupts queue completion signaling)

**Root cause.** `_drainCompleter` was created once, completed at the end of the first batch, and never cleared. When a caller awaited `drained` during a *second* batch, the getter returned the same completed completer, so the caller resumed while downloads were still in flight. Any downstream "queue finished → refresh library / show summary" logic could run early and observe an incomplete result set.

**Fix strategy.** The getter now creates a fresh completer if the stored one is null or already completed, and `_signalEmptinessIfIdle` clears the completer after completing it. A drain future obtained during active work is therefore tied to the current work cycle.

**Regression test added:** `test/core_queue_engine_test.dart` → *“drained waits for the current batch, not a previous work cycle.”*

---

### High

#### H1. Allowed-download directory list grew without bound

- **File:** `go_backend/extension_runtime_file.go`
- **Lines:** `AddAllowedDownloadDir` ~23
- **Severity:** High (memory growth in a long-lived download app)

**Root cause.** Every `DownloadWithExtensionsJSON` job appended `req.OutputDir` to `allowedDownloadDirs` with no deduplication and no cap. A device that queues a few hundred songs (or changes output folders over time) accumulated one entry per job and kept them forever. Each subsequent `isPathInAllowedDirs` also scanned the growing slice.

**Fix strategy.** `AddAllowedDownloadDir` now cleans + deduplicates before inserting and bounds the list at 256 distinct directories, evicting the oldest half when the cap is reached. The same output directory is therefore represented once per session.

**Regression test added:** `go_backend/extension_settings_test.go` → `TestAddAllowedDownloadDirDeduplicates`.

---

#### H2. Extension settings store allowed path traversal and wrote in place

- **File:** `go_backend/extension_settings.go`
- **Lines:** `getSettingsPath` ~43, `saveSettings` ~99
- **Severity:** High (security + data integrity)

**Root cause.**
1. `getSettingsPath` joined `dataDir`, an arbitrary `extensionID`, and `settings.json`. A malicious/compromised extension ID such as `../escape` could write outside the settings root.
2. `saveSettings` used `os.WriteFile` against the live file. A process kill or power loss mid-write left a truncated `settings.json`; the next load treated it as unreadable and reset the user's extension configuration.

**Fix strategy.**
- All store entry points validate the ID against the existing `extensionIDPattern` (`^[a-z0-9][a-z0-9._-]{0,127}$`) before touching memory or disk.
- `saveSettings`, `loadSettings`, and `RemoveAll` now route through a validating path resolver.
- Persistence uses `writeFileAtomic`: write sibling temp → fsync → chmod → rename → best-effort directory fsync.
- `Set`/`SetAll`/`Remove` now build a candidate map, persist it, and only then mutate the in-memory view, so a disk failure cannot silently leave memory and disk out of sync.

**Regression tests added:** `go_backend/extension_settings_test.go` → traversal rejection and atomic-write reload.

---

#### H3. SAF output file descriptor leaked when extensions were disabled

- **File:** `go_backend/exports_download.go`
- **Lines:** `DownloadByStrategy` non-extension branch ~438
- **Severity:** High on SAF devices (fd exhaustion after repeated failed/skipped downloads)

**Root cause.** `SafDownloadHandler.kt` detaches a SAF `ParcelFileDescriptor` and hands its numeric fd to Go in the request. When `use_extensions=false`, `DownloadByStrategy` returned before ever calling `DownloadWithExtensionsJSON`, and only the extension export owned/closes the detached fd. Since `SafDownloadHandler` deliberately does *not* re-close a fd it has detached (it might already be closed and its number reused), every non-extension SAF attempt leaked one fd. On a long queue with storage/extension misconfiguration this eventually fails with `EMFILE`.

**Fix strategy.** The non-extension branch now explicitly closes the detached fd before returning the “providers disabled” error. The extension success path is unchanged (it still closes the fd in `DownloadWithExtensionsJSON`).

---

### Medium

#### M1. Pages workflow failed whenever `site/` was absent

- **File:** `.github/workflows/pages.yml`
- **Severity:** Medium (workflow reliability)

**Root cause.** `actions/upload-pages-artifact@v4` unconditionally uploaded `site`, which does not exist in this repository. `workflow_dispatch`, or a push that touched `pages.yml`, therefore failed the workflow even though there is no Pages content to publish.

**Fix strategy.** Added a `site_check` output. Setup/upload are gated on `site_exists == 'true'`, and the deploy job is skipped when the directory is absent.

---

#### M2. `getAllPendingFFmpegCommands` passed a misleading method name to the decoder

- **File:** `lib/services/platform_bridge.dart`
- **Lines:** ~1678
- **Severity:** Low/Medium (diagnostically misleading error messages)

**Root cause.** The helper decoded the result with `method: 'setFFmpegCommandResult'`, so a malformed native response surfaced as if the wrong operation failed.

**Fix strategy.** Pass the actual channel method name (`getAllPendingFFmpegCommands`).

---

## Reviewed but not patched in this batch

These remain as tracked follow-ups. They are lower blast radius or require broader refactoring/toolchain verification.

| File / Location | Severity | Issue | Proposed fix |
|---|---|---|---|
| `go_backend/extension_signed_session.go:342` | Medium | `saveSignedSession` writes auth session JSON in place; a kill can corrupt the session. | Reuse an atomic-write helper like `writeFileAtomic`. |
| `go_backend/audio_metadata_cover.go:385` | Medium | Cover cache entries written in place; corruption causes a cache miss but wastes a request. | Atomic temp + rename. |
| `go_backend/exports_lyrics.go:128,153` | Medium | Sidecar `.lrc` files written in place. | Atomic temp + rename (or use the same helper). |
| `lib/services/cover_cache_manager.dart` ~clearCache | Low | Recreates `CacheManager` without disposing the previous instance. | Track and `dispose()` the manager (`CacheManager` exposes a dispose path) or keep one manager. |
| `lib/core/data/secure_store.dart` | Medium | `ensureInitialized()` sets `_initialized=true` even after a plugin/Keychain failure, so boot-time init never retries. | Set `_initialized=false` in the catch and let callers retry; avoid log spam with a retry cap. |
| `lib/services/music_player_service.dart:1545` | Low | Global `_handlerReadyController` is app-lifetime; not closed. Acceptable for a singleton, but leaks if the service is ever torn down. | Consider `close()` in an app-shutdown teardown hook. |
| `lib/services/platform_bridge.dart` static controllers | Low | Same app-lifetime pattern; no leak under current lifecycle. | Keep, but document as intentional. |
| `android/app/build.gradle.kts` | Low | `compileSdk` defaults to 37 locally; SDK 37 must be installed or `ANDROID_COMPILE_SDK` must point at an installed platform. | Prefer a checked-in documented default or a Gradle environment check with an actionable error. |
| `ios/Runner/AppDelegate.swift` | Low | Native progress stream uses a single serial queue for both download and library-scan timers; a long non-mutating timer callback can delay the other stream. Fine at 800 ms cadence; monitor if polling cadence drops. | Split queues or add separate serial queues per stream if observed lag. |

---

## Test Coverage Added

- `test/core_queue_engine_test.dart`
  - `drained waits for the current batch, not a previous work cycle`
- `go_backend/extension_settings_test.go`
  - `TestExtensionSettingsRejectsTraversalIDs`
  - `TestExtensionSettingsWriteIsAtomicAndReloadable`
  - `TestAddAllowedDownloadDirDeduplicates`

## Changed Files

- `lib/core/application/queue_engine.dart`
- `lib/services/platform_bridge.dart`
- `go_backend/exports_download.go`
- `go_backend/extension_runtime_file.go`
- `go_backend/extension_settings.go`
- `go_backend/extension_settings_test.go` *(new)*
- `.github/workflows/pages.yml`
- `test/core_queue_engine_test.dart`

**Verification note.** This sandbox has no Go/Flutter/JDK/Xcode toolchain, so I could not execute `go test`, `flutter test`, `flutter analyze`, Gradle, or xcodebuild. The Dart and Go changes are deliberately small and localized; run the standard gates (`go test -race ./...`, `flutter analyze`, `flutter test`, `go vet`, `gofmt -l`) on a toolchain-capable runner before tagging a release. If any toolchain-only issue is found, tell me and I will produce the next patch batch.
