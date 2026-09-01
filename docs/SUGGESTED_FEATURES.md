# Suggested Features

A curated list of proposed enhancements for SpotiFLAC Mobile. Items marked
✅ have been implemented in the source tree on the current branch; the rest
are **suggestions** that may be changed, split, or dropped after discussion.
Use the [Feature Request
template](../.github/ISSUE_TEMPLATE/feature_request.yml) to open an issue for
any item you want to champion.

Legend: ✅ implemented in source (this repo) · 💡 proposed · ⏳ already tracked
as planned in [`ROADMAP.md`](ROADMAP.md) · 🧱 scaffolded (API/UI ready, needs
the remaining work)

---

## High value & roadmap-aligned

### ✅ Wi-Fi / mobile quality-profile UI
- **Status**: Implemented in `lib/screens/settings/streaming_settings_page.dart`
  — per-network quality rows for Wi-Fi, Mobile data, Poor connection and
  **Roaming** are editable under Settings → Streaming & Glass → Quality &
  network policies.
- **Related**: `ROADMAP.md` §2 "Wi-Fi/mobile quality profiles UI".

### ✅ Live bandwidth sampling for adaptive streaming
- **Status**: Implemented in `lib/engine/streaming_engine.dart` +
  `lib/providers/streaming_engine_provider.dart` — a bounded `BandwidthMonitor`
  records preflight throughput samples and exposes an effective-bandwidth
  estimate (label + JSON) on `StreamingDiagnostics`; the Diagnostics Center
  now shows "Effective bandwidth".
- **Related**: `ROADMAP.md` §29 "live bandwidth sampling".

### ✅ Download scheduling
- **Status**: Implemented in
  `lib/providers/download_schedule_settings_provider.dart` +
  `lib/screens/settings/download_schedule_settings_page.dart` +
  `lib/providers/download_queue_provider_schedule.dart` — a configurable local
  time window pauses the queue outside it and resumes automatically when the
  window reopens (supports nightly windows that cross midnight).
- **Related**: `ROADMAP.md` §7 "scheduling/charging hooks" (time-window part).

### ✅ Shared queue / cross-device export
- **Status**: Implemented in
  `lib/services/queue_transfer_service.dart` + queue header actions —
  export the active queue as a portable JSON payload and import it on another
  device.
- **Related**: `ROADMAP.md` §44–45 "backup/restore & import/export".

### ✅ Storage breakdown UI
- **Status**: Implemented in
  `lib/services/storage_breakdown_service.dart` +
  `lib/screens/settings/storage_breakdown_page.dart` — disk usage aggregated
  by format, artist and album for downloaded + local-library files.
- **Related**: `ROADMAP.md` §58–59 "storage breakdown UI".

### ✅ Streaming integrity reporting
- **Status**: Implemented in
  `lib/engine/streaming_engine.dart` (`StreamIntegrityLog`) +
  `lib/providers/streaming_engine_provider.dart` +
  `lib/screens/settings/streaming_integrity_page.dart` — per-URL stream
  attempt records with success/failure/fallback outcomes and readable reasons.
- **Related**: `ROADMAP.md` §42–43 "diagnostics & logs".

### 💡 Crossfade + loudness-normalization knobs
- **Why**: ReplayGain/R128 already applies in the built-in player, but
  users have no crossfade or loudness-aggressiveness control.
- **What**: Add crossfade duration and loudness-normalization target knobs
  in Library → Playback.
- **Related**: ⏳ `ROADMAP.md` §9 "crossfade / loudness normalization knobs".

### 💡 Real EQ / DSP plugin integration
- **Why**: The UI/settings scaffold (more controls sheet, presets
  enumerated) already exists but no platform DSP is wired up.
- **What**: Integrate a platform equalizer (Android `android.media.audiofx`
  / iOS `AVAudioUnitEQ`) and persist user presets.
- **Related**: ⏳ `ROADMAP.md` §10 "platform DSP plugin integration".

### 💡 Streaming cache manager
- **Why**: The engine explicitly avoids buffering protected content into
  permanent downloads, which is the right guardrail — but users still want a
  bounded offline cache for permitted sources.
- **What**: Build a bounded, user-visible streaming cache that is only
  enabled for providers whose `StreamSourceAdapter` sets `cachePermitted`.
- **Related**: 🧱 `ROADMAP.md` §28 "streaming cache gated by provider
  `cachePermitted`".

---

## Data & library

### ✅ Recently played / most-played aggregation UI
- **Status**: Implemented in
  `lib/screens/settings/listening_statistics_page.dart` +
  `lib/providers/playback_statistics_provider.dart` — per-track plays and
  listened time are now recorded on-device (via a `PlaybackStatsObserver` in
  `music_player_service.dart`), persisted in SharedPreferences, and surfaced
  as Recently Played / Most Played in Settings → Streaming & Glass → Listening
  Statistics.
- **Related**: `ROADMAP.md` §1 "recently played / most played aggregation UI".

### ✅ History clear UI
- **Status**: Implemented in `streaming_settings_page.dart` — "Clear restore
  memory" clears the engine savepoint and the Listening Statistics page has a
  confirmed "Reset statistics" action.
- **Related**: `ROADMAP.md` §25 "history clearing UI wiring".

### 💡 Storage breakdown UI
- **Why**: Users have no per-collection disk usage view for downloaded and
  converted files.
- **What**: Show per-format, per-album, per-artist disk usage and a size
  ladder of the largest files.
- **Related**: ⏳ `ROADMAP.md` §58–59 "storage breakdown UI".

### 💡 Advanced library filters
- **Why**: The library metadata model already carries codec, bitrate,
  sample rate, bit depth, format, and source.
- **What**: Add filter UI for those fields alongside the existing quality /
  format / source filters.
- **Related**: 🧱 `ROADMAP.md` §54 "metadata filters".

### 💡 Audio fingerprinting for unknown files
- **Why**: The canonical identity engine (`track_identity.dart`) makes
  ISRC-first matching possible, but files without tags/ISRC are still hard
  to auto-fill.
- **What**: Generate a long-term audio fingerprint for untagged local files
  and use it to find metadata (authorized metadata providers only).
- **Related**: 🧱 `ROADMAP.md` §55–57 "fingerprinting via identity matching".

---

## Playback & UX

### 💡 `spotiflac://` deep-link routes
- **Why**: The app already receives share intents and resolves links, but
  has no first-party deep-link routes.
- **What**: Define `spotiflac://album/...`, `spotiflac://track/...`,
  `spotiflac://playlist/...`, `spotiflac://download/...` routes and link them
  into the existing URL handlers.
- **Related**: ⏳ `ROADMAP.md` §46–47 "`spotiflac://` deep-link routes".

### 💡 Dedicated car mode layout
- **Why**: Large touch targets and media buttons already exist, but there is
  no distraction-minimized layout.
- **What**: A simple full-screen player mode with oversized controls, minimal
  text, and auto-play / resume behavior.
- **Related**: ⏳ `ROADMAP.md` §51–52 "dedicated car mode layout".

### 💡 iOS Live Activity / widgets
- **Why**: Android already has a download widget; iOS has no equivalent
  Lock Screen / home-screen presence.
- **What**: Add a Live Activity for active downloads and a Now Playing / queue
  widget.
- **Related**: ⏳ platform parity with `ROADMAP.md` §62.

### 💡 Download scheduling
- **Why**: Wi-Fi-only mode exists, but there is no charge-aware or
  time-window scheduling.
- **What**: Add "download only on Wi-Fi", "pause while on battery", and
  "download during this time window" options.
- **Related**: 🧱 `ROADMAP.md` §7 "scheduling/charging hooks".

---

## Reliability & trust

### 💡 Per-provider permissions & data-access audit
- **Why**: Extensions are sandboxed and versioned, but users don't have a
  clear view of what each one can do.
- **What**: Show a per-extension capabilities / storage / URL-host audit
  screen, with a "what this extension accessed recently" log.

### 💡 Streaming integrity reporting
- **Why**: The Diagnostics Center shows provider health, success rates,
  latency, and the event log, but failures are hard to drill into.
- **What**: Add per-URL success/failure history and a "why did this fail"
  deep link to the relevant log entry.

### 💡 Cross-device queue / history export
- **Why**: Backup & Restore covers settings and library, but the queue and
  download history are still device-bound.
- **What**: Add JSON export/import for the active queue, failed-history, and
  listening statistics.

### 💡 Shared queue / "send queue" action
- **Why**: Users often want to hand off a playlist or partial queue to
  another device.
- **What**: Add "Share queue as M3U8/JSON" and "Import queue" actions.

---

## Suggested next steps

1. Pick one remaining **High value & roadmap-aligned** item (e.g. crossfade
   knobs or the streaming cache manager).
2. Open a feature request issue using
   [`.github/ISSUE_TEMPLATE/feature_request.yml`](../.github/ISSUE_TEMPLATE/feature_request.yml).
3. Update [`ROADMAP.md`](ROADMAP.md) and this file when an item moves from
   💡/⏳ to 🧱 or ✅.
