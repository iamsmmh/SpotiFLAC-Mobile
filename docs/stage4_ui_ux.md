# Stage 4 — Modern UI/UX, Advanced Library Management & Personalization

This document records what Stage 4 added on top of the completed Stages 1–3
(Stabilization, Architecture Refactoring, Streaming Engine). It is the
implementation counterpart to the four objectives in the Stage 4 brief.

## What was already in place (reused, not rebuilt)

SpotiFLAC Mobile already shipped a mature LRC/TTML parser
(`lib/utils/lyrics_parser.dart`), synced-scroll math
(`lib/utils/synced_lyrics_scroll.dart`), cover-art palette extraction
(`lib/theme/cover_palette.dart`), AMOLED/adaptive/dynamic-color theming, and a
fully-localized library with full-text search, dynamic sorting
(artist/album/date-added/quality) and a metadata tag editor. The classic Now
Playing screen additionally had a private synchronized-lyrics view and a
metadata list. Stage 4 **fills the gaps** and **shares** those capabilities
with the Liquid Glass player.

## 1. Synchronized lyrics viewer (objective 2)

- **`lib/widgets/synced_lyrics_viewer.dart`** — a reusable, Riverpod-free
  `SyncedLyricsViewer` that renders parsed LRC / enhanced-LRC / TTML with:
  - real-time **auto-scroll** (active line animates to the vertical centre),
  - active-line **highlight** with progressive dimming of past/future lines,
  - **manual jump-to-timestamp**: tapping any line seeks the player,
  - symmetric centre padding, pre-measure scroll fallback, and a user-scroll
    grace window that pauses auto-scroll while the listener browses.
  Because it takes `position` / `playing` / `loading` / `onSeek` as parameters
  (no provider coupling), its timing behaviour is unit-testable in isolation.
- **`lib/providers/now_playing_lyrics_provider.dart`** — resolves the current
  track's embedded lyrics through the same metadata bridge as the classic
  player, skipping remote URLs (streams have no embedded lyrics to probe).
- **`lib/screens/liquid_player_screen.dart`** — the glass player's Lyrics
  button now opens a real synchronized viewer instead of the "open track
  details" placeholder.

The classic Now Playing screen's existing viewer remains untouched and keeps
its word-level (karaoke) sweep, which was intentionally not duplicated.

## 2. Real-time telemetry overlay (objective 2)

- **`lib/providers/playback_telemetry_provider.dart`** — a pure
  `PlaybackTelemetry` model + `playbackTelemetryProvider`. It fuses the engine
  playback context (`EnginePlayContext`), the audio-service `MediaItem`
  extras, and the engine diagnostics (session phase/attempt, smoothed
  throughput, integrity counts) into one read-only snapshot. Local playback
  enriches the engine's *derived* characteristics with *measured* bit
  depth / sample rate / bitrate / format carried by the media item.
- **`lib/widgets/playback_telemetry_card.dart`** — the metrics overlay:
  **Codec, Bitrate, Sample Rate, Bit Depth**, plus **Source driver** and
  **File path / source** (with copy), and a live stream block (phase, attempt,
  throughput, integrity) when streaming.
- The glass player opens the overlay by tapping the source/quality chips (or
  the info affordance), and shows an "Offline mode" chip when active.

## 3. Offline mode (objective 4)

- **`lib/providers/engine_settings_provider.dart`** — new `offlineMode`,
  `maxCacheSizeMb`, `autoCleanCache` knobs (JSON-persisted with the existing
  `engine.*` namespace; no `json_serializable` regeneration needed), plus
  notifier setters and `engineOfflineModeProvider` / `engineMaxCacheSizeMbProvider`.
- **`lib/providers/streaming_engine_provider.dart`** — `currentNetworkProfile()`
  reports `NetworkProfile.offline` while offline mode is on, and
  `shouldAttemptStreamResolution()` short-circuits `decide()` so **no stream
  adapter is ever consulted and no network download is scheduled**. The Smart
  Play ladder already rejects streaming/downloading when the profile is
  offline, so playback is strictly local.
- Toggle surfaces: Streaming & Glass settings (Smart Play → Offline mode) and a
  quick toggle in the glass player's Stream info sheet.

## 4. Offline storage policies & smart caching (objective 4)

- **`lib/services/cache_auto_cleaner.dart`** — pure `CacheCleanPlanner`
  (LRU threshold planning + broken-stream/stale-file detection) separated from
  the I/O `CacheAutoCleaner` (recursive listing, chunked deletion). Never
  touches downloaded music; only the app cache + temp directories.
- **Startup enforcement** (`lib/main.dart`) — when a cache limit is configured
  and auto-clean is on, the app prunes LRU-first and sweeps broken-stream
  artifacts after first frame (fire-and-forget).
- **`lib/screens/settings/cache_management_page.dart`** — new "Clean broken
  streams" maintenance action and the configured limit shown in the summary.
- **`lib/screens/settings/streaming_settings_page.dart`** — new
  "Offline & storage policy" section (cache-limit presets: unlimited / 256 MB /
  512 MB / 1 GB / 2 GB / 4 GB, and the auto-clean switch).

## Validation

New tests (mirroring the repo's existing suite style):

- `test/synced_lyrics_viewer_test.dart` — widget smoke (render, tap-to-seek,
  empty state) + active-index math.
- `test/playback_telemetry_test.dart` — label mapping (measured local values,
  media-item fallback, provider source driver, live stream session).
- `test/offline_mode_gating_test.dart` — `shouldAttemptStreamResolution`,
  `EngineSettings` defaults/round-trip/copyWith for the new knobs.
- `test/cache_auto_cleaner_test.dart` — LRU pruning order, threshold
  boundaries, broken-stream suffix detection, stale cleanup, total-size.

> Sandbox note: the Flutter SDK is unavailable here, so `flutter analyze` /
> `flutter test` could not be executed; the Dart changes are validated by
> manual review plus structural checks (balanced delimiters across all touched
> files). The authoritative gate remains the CI build on GitHub.
