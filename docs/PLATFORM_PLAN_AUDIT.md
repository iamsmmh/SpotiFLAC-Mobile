# Music Platform Plan — Audit & Status

**Date:** 2026-09-06 · **Branch:** `arena/01a072cc-spotiflac-mobile`

This document maps the 13-part "complete music platform" brief onto what the
repository **actually contains**, so the remaining work is visible and nobody
re-implements something that already ships.

> **Verification caveat.** The environment this pass ran in had no Flutter/Dart
> SDK and no network route to `pub.dev`. `flutter analyze` / `flutter test`
> were therefore run **in CI** (PR #43) rather than locally, via a temporary
> `analyze-report.yml` workflow that republishes the output as a PR comment —
> the Actions raw-log and artifact endpoints are also unreachable from here.
>
> **CI result at commit `a5cb316`:** `flutter test` → **946 passing, 13
> failing**. All 5 new test files pass. **Zero analyzer errors** in the new
> `podcasts/`, `recognition/` and `social/` modules.

## Pre-existing breakage on `main` (not caused by this work)

`main` has been **red since PRs #41 and #42** (runs `33974279336`,
`33983199373`). 55 analyzer errors remain, all in files this branch did not
create, spread across:

`ecosystem/account/{account_models,account_service,auth_adapters,token_store}.dart`,
`ecosystem/history/listening_insights.dart`,
`ecosystem/recommendations/recommendation_providers.dart`,
`ecosystem/sync/cloud_sync_adapters.dart`,
`screens/ecosystem/{account_page,analytics_page,cloud_sync_console_page,ecosystem_hub_page}.dart`,
`screens/favorite_albums_screen.dart`, `screens/queue_tab_collection_items.dart`,
`utils/fuzzy_match.dart`, `test/ecosystem_account_test.dart`.

Recurring root causes: Riverpod 3 removed `StateProvider` and `AsyncValue.valueOrNull`;
several `const` expressions are no longer constant; `SecureStore` gained an
unimplemented member; a missing l10n getter.

Two of these were fixed here because they sit in `ecosystem_providers.dart`,
the file this work extends (`StateProvider` → `NotifierProvider`, and an
`AsyncValue<Map>` passed where a `Map` was expected). **The remaining 13 test
failures are pre-existing and out of this change's scope.**

---

## Part-by-part status

| Part | Brief | Reality |
|---|---|---|
| 1 | Native playback engine | **Already shipped, on a different renderer.** `MusicPlayerHandler extends BaseAudioHandler` (`lib/services/music_player_service.dart`, ~2.4k lines) with `audio_service` + `audio_session` already in `pubspec.yaml`. Play/pause/resume/stop/seek/next/previous/repeat/shuffle, session persistence, lockscreen, notification, headset and Bluetooth controls all exist. See "The `just_audio` question". |
| 2 | Streaming engine | **Already shipped.** `lib/engine/streaming_engine.dart`, `lib/services/multi_provider_stream_service.dart` (resolution cache, failover, provider health), `lib/engine/adaptive_buffer.dart`. Provider logic is behind a resolver, not in the player. |
| 3 | Stream cache | **Partly shipped.** `ec_stream_cache` table (LRU index, pin, completeness), `CacheAutoCleaner` + `CacheCleanPlanner`, `CoverCacheManager`, Settings → Cache management. *Gap:* cache-at-rest **encryption** is not implemented. |
| 4 | Queue system | **Already shipped.** `QueueEngine`, `core_queue_providers`, queue persistence + restore, reorder, `QueueStateSyncPayload`. |
| 5 | Smart offline | **Partly shipped.** `ec_offline_collections` (auto-sync, wifi-only), offline-mode gating, download registry export/import + missing-track diff. *Gap:* no single `OfflineSyncManager` façade. |
| 6 | Home discovery | **Already shipped.** `lib/engine/recommendations.dart` (on-device engine) + `RecommendationRegistry` chaining cloud → similarity → daily-mix → local. Works with no backend. |
| 7 | Listening history | **Already shipped.** `ListeningHistoryRepository`, `InsightsCalculator`, `ec_listening_events` / `ec_track_history` (play count, skips, completion, duration), recap. |
| 8 | **Podcasts** | **Built this pass.** See below. |
| 9 | **Music recognition** | **Built this pass.** See below. |
| 10 | Cloud sync | **Already shipped.** `CloudSyncProvider` port, LWW + tombstone merge, offline outbox, and **Firebase / Supabase / self-hosted** adapters (`lib/ecosystem/sync/cloud_sync_adapters.dart`). |
| 11 | **Social (optional)** | **Built this pass.** See below. |
| 12 | Performance budgets | Existing `SessionResourceBudget`, cold-start policy, telemetry. Startup/search/playlist latency targets are **not measured** in CI — no benchmark harness exists. |
| 13 | Tests | 108 pre-existing test files, +5 this pass. **Coverage % is unmeasured here** (no SDK); the 80% claim is unverified. |

---

## What was built this pass

### Part 8 — Podcasts (`lib/ecosystem/podcasts/`)

- `podcast_models.dart` — `PodcastSubscription`, `PodcastEpisode`,
  `PodcastFeed`, `EpisodeDownloadState`, stable `buildEpisodeKey`.
- `rss_provider.dart` — pure `RssFeedParser`. RSS 2.0 + Atom, `itunes:`/
  `media:`/`content:` namespaces, enclosure and `media:content` fallback,
  RFC 822 + ISO-8601 dates with timezone offsets, three duration formats.
  Malformed feeds raise `PodcastFeedFormatException`; `tryParse` degrades.
- `podcast_repository.dart` — subscriptions/episodes CRUD; **idempotent
  refresh** that updates publisher metadata but never clobbers resume
  position, played flag or downloaded file.
- `podcast_library.dart` — `.part`-then-rename downloads, in-flight
  de-duplication, per-feed retention (skips part-heard episodes), auto-download
  sync, and a `repair()` sweep reconciling rows against the filesystem.
- `podcast_player.dart` — **reuses `MusicPlayerHandler`**; speed presets, skip
  intervals, throttled progress persistence, `SilenceSkipPolicy`.
- `podcast_search.dart` — iTunes directory search, no API key required.

### Part 9 — Recognition (`lib/ecosystem/recognition/`)

Chromaprint fingerprints are produced **on-device** by the already-bundled
FFmpeg, so only a compact fingerprint string leaves the phone. The AcoustID
adapter reports `unavailable` until the user supplies their own key.

### Part 11 — Social (`lib/ecosystem/social/`)

Entirely gated by `SocialFeatureFlags`, **off by default**. A sub-flag cannot
activate while the master switch is off; disabling clears sub-flags so
re-enabling never silently republishes. With no backend configured, share links
still generate locally and feeds read from cache.

---

## The `just_audio` question

Part 1 asks to reintroduce `just_audio`. The repository **deliberately removed
it** (CHANGELOG: "One audio pipeline, one fewer dependency") and the working
engine now renders through `audioplayers` behind `audio_service`. Since the
brief also says *do not rewrite working download/playback systems*, and the
handler already provides every capability Part 1 lists, **`just_audio` was not
reintroduced** — that was confirmed with the requester. Reversing this would
mean rewriting a 2.4k-line working handler with no way to compile or test it
here.

---

## Honest gaps

1. **13 pre-existing test failures remain** (see above). This branch does not
   fix the Riverpod 3 / `const` / `SecureStore` breakage inherited from
   `main`; that deserves its own focused pass.
2. **Encrypted cache (Part 3)** — not implemented.
3. **Recognition capture** — `RecognitionRecorder` is a port with no platform
   implementation yet; microphone capture needs `PlatformBridge` work on both
   Android and iOS (plus `RECORD_AUDIO` / `NSMicrophoneUsageDescription`).
4. **No UI screens** for podcasts, recognition or social — services, models and
   Riverpod providers only. The existing screens are untouched.
5. **Social backend** — `socialBackendProvider` returns `null`; no adapter.
6. **Performance budgets (Part 12)** are unmeasured.
7. **Coverage (Part 13)** is unmeasured.

The acceptance checklist ("Android builds ✓ / iOS builds ✓ / tests pass ✓")
**cannot be signed off from this environment**; items 1–7 are the honest
remaining distance.
