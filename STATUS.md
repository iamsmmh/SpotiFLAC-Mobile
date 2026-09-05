# SpotiFLAC Mobile — Current Status

**Last updated:** 2026-09-05 · **App version:** 5.0.0+142 · **Branch:** `arena/01a07100-spotiflac-mobile`

This is the single current-state document. It supersedes the historical
session reports at the repo root (`AUDIT_REPORT.md`,
`PRODUCTION_READINESS_AUDIT.md`, `FINAL_AUDIT_2026-09-02.md`,
`FIX_REPORT.md`, `BUILD_FIXES.md`, `RELEASE_GATE_VERIFICATION_2026-09-02.md`),
which are kept for archaeology but contain stale claims (e.g. "no green run
exists", "cover/sidecar writes are non-atomic" — both fixed since).
`TEST_REPORT.md` and `BUILD_REPORT.md` remain the CI evidence logs.

## What works out of the box (fresh install)

| Capability | State |
|---|---|
| Local file playback, queue, background audio, notifications | ✅ complete |
| First-run setup (language, permissions, folder) | ✅ complete |
| Official extension registry pre-configured + recommended starter set auto-install (search/metadata, lossless + fallback downloads) | ✅ **new in this pass** |
| Store tab with one-tap **Install recommended** | ✅ **new in this pass** |
| YouTube / SoundCloud anonymous fallback streaming, 30s previews | ✅ complete |
| Lossless streaming with user tokens (Tidal, Qobuz, Apple, Deezer, Amazon) via **Settings → Provider accounts** (encrypted keystore) | ✅ **new in this pass** |
| No-provider failures route to the Store (queue banner, error dialog, empty search) instead of dead ends | ✅ **new in this pass** |
| Lyrics (LRCLIB/Paxsenix/NetEase/QQ/Apple/Musixmatch), synced scroll | ✅ complete |
| Metadata/tag editing (FLAC/MP3/AAC/M4A/OGG/OPUS/WAV/AIFF), Deezer metadata, ISRC identity | ✅ complete |
| Library scan, duplicates, playlists (M3U/CSV/JSON), backup/restore, queue share | ✅ complete |
| Android EQ/DSP (DynamicsProcessing / Equalizer) | ✅ complete |
| AltStore/SideStore feed (`apps.json`) auto-updated by the unsigned-release pipeline | ✅ **new in this pass** (feed also bumped to v4.9.5) |

## What still needs the user / provider side

- **Downloads** require at least one download extension (now one tap away via
  setup or the Store card). There is intentionally no built-in download
  provider — the backend fails loudly (`Extension providers are disabled…`)
  and the UI routes that error to the Store.
- **Lossless streams** require the user's own account tokens (provider
  accounts page) or provider extensions. Without them the engine falls back
  to YouTube/SoundCloud/previews by design.
- **iOS equalizer** stays unavailable (AVPlayer cannot host AudioUnit
  effects without an AVAudioEngine re-route); the UI reports this honestly.
- **CI APKs are debug-signed.** Play-Store artifacts need `key.properties` /
  signing secrets (documented in `BUILD_REPORT.md`).

## Verification

- `python3 scripts/local_quality_gate.py` — 48+ static checks, must be green
  (runs without a toolchain).
- `scripts/translation_coverage.py` — translation completeness per locale
  (informational; English fallback covers gaps at runtime).
- Authoritative gates run on CI: `flutter analyze`, `flutter test`
  (93 files), `go vet`/`go test`, Android/iOS builds. This sandbox has no
  Flutter/Go toolchain, so every change here is verified by CI on push.

## Known follow-ups (scoped, not started)

1. **Commit `pubspec.lock`** — removed from `.gitignore`; run
   `flutter pub get` once on a toolchain machine and commit the result.
2. **Crowdin sync** for the English-first strings (`lib/l10n/staged_strings.dart`,
   provider-accounts page, setup extensions step) + backfill `es`/`pt`.
3. **God-file splits** (`track_metadata_edit_sheet`, `ffmpeg_service`,
   `platform_bridge`, `music_player_service`) — maintainability only.
4. **Android 15 `dataSync` budget strategy** (WorkManager migration) for very
   long queues; denial is currently handled gracefully, not scheduled around.
5. **CI emulator smoke test** (boot + local play + queue round-trip) for the
   SAF/FGS paths that are reviewed but device-unproven.
6. Executed DB-migration tests (`sqflite_common_ffi`) to replace the current
   source-contract assertions; iOS EQ engine; car mode; `spotiflac://` links.
