# SpotiFLAC-Mobile — Code Audit Report

**Scope:** `go_backend/` (Go via gomobile), `lib/` (Flutter/Dart), `android/.../kotlin` (platform channel layer)
**Method:** full compilation of the Go backend, `go vet`, `staticcheck` (v0.8.1), full test suite under `-race`, plus manual review targeting the FFI boundary, SAF/storage handling, extension parsing, and download-queue concurrency.
**Verification:** all findings below marked *fixed* are covered by new regression tests; the entire Go suite passes `go test -race ./...`, and `gofmt` / `go vet` / `staticcheck` are clean.

---

## Critical

### C1. `RateLimiter.WaitForSlot` over-admits under concurrency — **fixed**
`go_backend/ratelimit.go`

The old implementation unlocked, slept until the oldest timestamp expired, relocked, and **unconditionally appended**. If N goroutines were parked on the same expiring slot (typical during a batch download resolving many SongLink/IDHS lookups in parallel), all N were admitted at once when one slot freed — bursting past the provider limit (SongLink is 10/min; the limiter is set to 9/min for safety) and triggering upstream 429 bans that then stall the whole queue.

**Fix:** capacity is re-checked in a loop after every sleep; only as many callers as there are freed slots are admitted. Regression test `TestRateLimiterWaitForSlotConcurrency` (race-enabled, sliding-window assertion) added.

### C2. `DoRequestWithRetry` resends an empty body on retried POSTs — **fixed**
`go_backend/httputil.go`

`req.Clone(ctx)` shares the original `Body` reader. After attempt 1 consumed it, every retry (429, 5xx, transient network error) sent a **zero-byte body**. Affected callers include the SongLink resolve API (JSON POST). Failure mode is nasty: the retry "succeeds" at the HTTP layer but the server sees an empty payload, producing confusing 4xx/success=false responses instead of the original transient error.

**Fix:** retries now rewind via `req.GetBody()` (populated automatically by `http.NewRequest` for `bytes`/`strings` readers); if a body exists but is not replayable the retry loop aborts with an explicit error instead of silently corrupting the request. Regression test `TestDoRequestWithRetryReplaysPostBody` added.

---

## Warning

### W1. `InvokeAction` serialized the entire extension system behind one JS call — **fixed**
`go_backend/extension_manager.go`

`InvokeAction` took `m.mu.Lock()` (the *manager-wide* write lock) and held it for the whole JS action — up to the full JS timeout when an action such as `completeGrant` performs network I/O. During that window **every** other extension operation (search, download dispatch, extension list UI, health checks) blocked on `m.mu`. On the gomobile boundary this shows up as the app "freezing" during verification flows.

**Fix:** the manager lock is now held only for the map lookup (`RLock`), identical to the pattern `callExtension` uses; per-VM exclusivity is still enforced by `lockReadyVM`/`VMMu`, so goja's single-thread requirement is preserved.

### W2. Stale error text survives retries and completed downloads (UI desync) — **fixed**
`lib/models/download_item.dart`, `lib/providers/download_queue_provider.dart`

`DownloadItem.copyWith(error: null)` was a no-op: `error ?? this.error` cannot distinguish "not provided" from "clear it". Consequences:

- `retryItem` / `retryAllFailed` requeued items **still carrying the previous failure message** (and `errorType`), so the queue tile showed the old error while the item was queued/downloading, and special-cased strings like `'Waiting for verification'` mis-rendered the status line.
- An item that failed once and later completed kept its stale error/errorType forever (both are read by the error dialog and status formatting in `queue_tab.dart`).

**Fix:** `copyWith` gains an explicit `clearError` flag; both retry paths and the completed-status transition in `updateItemStatus` use it. Regression tests added in `test/models_and_utils_test.dart`.

### W3. `isTransientNetworkError` relied on deprecated `net.Error.Temporary()` — **fixed**
`go_backend/httputil.go`

`Temporary()` is deprecated since Go 1.18 precisely because its semantics are ill-defined — e.g. `ECONNREFUSED` is reported as "temporary", so a hard refusal could be classified as a transient failure and mark an offline extension endpoint as "unknown" (retry soon) instead of "offline". Now only timeouts and explicitly transient DNS failures qualify; NXDOMAIN stays permanent. (Flagged by staticcheck SA1019.)

### W4. Test bug: short-circuit `!<-done || !<-done` — **fixed**
`go_backend/extension_runtime_storage_test.go`

If the first receive yielded `false`, the second channel receive was skipped, leaking a blocked goroutine into subsequent tests and hiding the second writer's result (staticcheck SA4000). Both results are now drained before asserting.

### W5. Quarantine log claims "60s" but grace period is 5s — **fixed**
`go_backend/extension_timeout.go`

The runtime-unsafe warning hardcoded "did not exit within 60s" while `jsInterruptGracePeriod` is 5s — actively misleading when debugging stuck-VM reports. The log now prints the real value.

---

## Optimization / hygiene

### O1. Dead code removed — **fixed**
- `extensionRuntime.startSignedSessionVerification` (unused wrapper; all callers use the `Locked` variant)
- `scanAudioFileWithKnownModTime`, `scanM4AFile` (superseded by the cover-cache-aware variants)

Flagged by staticcheck U1000; keeping unused lock-taking wrappers around a coordinator mutex is a future deadlock hazard.

---

## Reviewed and found sound (no action needed)

These were audit focus areas per the brief; noting them so the review is reproducible:

- **Go→Dart panic containment:** every gomobile export returns `(string, error)`; the only intentional panic surface is JS execution, which is recovered inside `runGojaCallWithTimeoutContext` with correct VM-quarantine semantics (the goroutine-wait before returning after `Interrupt` is required and present — goja VMs are not thread-safe).
- **Cancellation registry** (`cancel.go`): refcounted entries, idle-reset for pre-registered cancels, no leaks found under the existing lifecycle (`init`/`release` are balanced at every call site).
- **SAF handling** (`SafDownloadHandler.kt`): per-name lock keyed on tree URI + dir + lowercased filename; staged-file + fsync + rename publish pattern is durable; `openFileDescriptor("rw")` FDs are detached and dup'd on the Go side (`output_fd.go`) specifically to avoid fdsan double-close aborts — correct.
- **Zip-slip / extension packages** (`extension_manager_package.go`): entry count, uncompressed-size, symlink, backslash, absolute and `../` traversal checks all present; asset paths re-validated against the managed root.
- **DoH fallback** (`dns_doh.go`): private/loopback answers filtered unless the user opted in — SSRF guard is not bypassable via DNS answers.
- **Progress delta protocol** (`progress.go` ⇄ `MainActivity.kt` ⇄ Dart): seq/tombstone/reset handling is consistent; removal tombstones are pruned with a reset bump so lagging clients full-resync rather than missing removals.
- **Queue loop concurrency** (Dart `_runQueueLoop`): the `activeDownloads` map plus `Future.any` scheduling cannot exceed `maxConcurrent (1–3)`; `whenComplete` removal is ordered correctly.
- **`fetchLyricsProviders`** fan-out: semaphore-bounded, results channel is buffered to provider count, `wg.Wait`+`close` goroutine prevents leaks, priority-grace timer is stopped on all paths.

## Not fixed here (pre-existing, low risk, larger blast radius)

- `GetMultiProgressDelta` reads `multiProgress.Items` under the read lock while marshaling after unlock — the per-item copies are taken under the lock, so this is safe today; noting only that adding slices/maps to `ItemProgress` later would make the shallow `copy := *item` insufficient.
- `compareVersions` ignores pre-release suffixes (`1.2.0-beta` == `1.2.0`); acceptable for the extension repo's versioning convention.
