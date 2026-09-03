# SpotiFLAC Streaming Engine

The unified **Track → Source → Playback Engine** layer. Everything new —
streaming, Smart Play, provider failover, preloading, source ranking, the
Liquid Glass player — builds on this layer instead of becoming separate
systems.

```
        ┌────────────────────────────────────────────────────────────┐
        │            MusicPlayerHandler (audio_service)              │
        │  queue · transport · interrupts · savepoints · metadata    │
        └───────────────▲───────────────────────▲───────────────────┘
                        │ PlayableMedia         │ failure hook
        ┌───────────────┴───────────────────────┴───────────────────┐
        │              StreamingEngineController (Riverpod)         │
        │  decide() → startLocal() / startStream() / download&play  │
        │  preflight · health · failover · refresh · preload        │
        └───────────────▲───────────────────────────────────────────┘
                        │ SmartPlayDecision
        ┌───────────────┴───────────────────────────────────────────┐
        │  SmartPlayEngine (pure)   ←  ladder: local → stream →     │
        │                             download & play → unavailable  │
        │  StreamSourceResolver     ←  health .45 + quality .25 +    │
        │                             latency .20 + priority .10     │
        │  ProviderHealthRegistry   ←  success rate · backoff ·     │
        │                             offline marking                 │
        │  StreamingSessionController← phase machine + retry budget  │
        │  StreamPreloader          ←  next-track URL validation     │
        └────────────────────────────────────────────────────────────┘
                        │ StreamSourceAdapter (extensions)
        ┌───────────────▼───────────────────────────────────────────┐
        │  Track identity (ISRC-first canonical matching)           │
        │  Download history · local library · preview streams       │
        │  Provider extensions (metadata / download / lyrics)       │
        └────────────────────────────────────────────────────────────┘
```

## Decisions are pure; I/O is injected

All policy lives in `lib/engine/` and is 100% unit-testable:

| File | Responsibility |
|---|---|
| `track_identity.dart` | Canonical `TrackIdentityInput` → `CanonicalTrackKey`; ISRC-first matching; fuzzy title/artist/duration scoring; duplicate merging |
| `audio_characteristics.dart` | Quality ladder (Auto → Hi-Res), network profiles, codec/bitrate/sample-rate/bit-depth display model, quality policy, `StreamBufferPolicy`, per-source ReplayGain fields |
| `streaming_engine.dart` | `StreamDescriptor`, provider health + exponential backoff, source ranking, session phase machine, URL-expiry refresh policy, preflight contract, preloader, diagnostics |
| `smart_play.dart` | The Smart Play ladder with decision traces |
| `playback_session.dart` | Queue planner, shuffle/repeat, savepoint + sanitize, listening statistics |
| `replay_gain.dart` | ReplayGain dB↔linear conversion, tag parsing, track/album selection, peak-clipping protection |
| `gapless_policy.dart` | Gapless transition planning (seamless lossless splice vs. pre-buffer vs. disabled) |
| `adaptive_buffer.dart` | Adaptive buffer planner: network profile + throughput → lookahead window and head pre-buffer size |

The Riverpod layer (`lib/providers/streaming_engine_provider.dart`) performs the
actual HTTP work (`HttpStreamPreflightValidator`, `StreamHeadWarmer`,
`NetworkStatusMonitor`) and drives the existing `MusicPlayerHandler` — which
now accepts progressive `UrlSource` playback, exposes a playback-failure hook
for failover, and keeps its original content-URI/local-file behavior untouched.

## Real-time audio pipeline

The handler (`lib/services/music_player_service.dart`) now normalizes both
transports through the same pure `ReplayGain` policy:

* **Local files** — track/album gain and peak tags are probed from the file
  (`replaygain_track_gain`, `replaygain_album_gain`, `replaygain_track_peak`).
* **Progressive streams** — gain metadata rides on the resolved
  `StreamDescriptor` → `AudioCharacteristics` → `PlayableMedia`, so extensions
  can supply ReplayGain for authorized streams without re-probing a URL.
* **Peak-clipping protection** — a reported peak above full scale is attenuated
  back to 1.0; positive gains clamp at unity because the platform volume can
  only attenuate.

Gapless transitions are planned by `GaplessPolicy`: two consecutive items on the
same transport with identical codec/sample rate/bit depth/channels and a
lossless codec (FLAC/ALAC/WAV/AIFF/APE/WavPack) splice seamlessly by skipping
source teardown; every other transition pre-buffers the next head to shrink the
gap. The engine's `StreamHeadWarmer` pulls a bounded ranged-GET prefix of the
next stream (respecting `bufferPreviewStreams` / `cachePermitted`) while the
current track plays, and `AdaptiveBufferPlanner` sizes that prefix from the
network profile and live bandwidth — poor links open a deeper low-bandwidth
lookahead window.

## Smart Play ladder

```
Downloaded?        ── YES ──► local playback (instant, offline-safe)
   │ NO
Streaming ok?      ── YES ──► progressive stream (preflighted, preloaded)
   │ NO
Downloadable?      ── YES ──► queue download → play on completion
   │ NO
Unavailable        ─────────► explicit reason (never a silent spinner)
```

Every decision returns a trace (`SmartPlayStep`) so the UI can explain itself
("Playing from local — offline") and the Diagnostics Center can show why a
particular provider was chosen.

## Source intelligence

Candidates are filtered (expired URLs, offline/backoff providers, missing
authorization) and ranked:

```
score = 0.45 × health + 0.25 × quality-fit + 0.20 × latency + 0.10 × priority
```

Failures feed `ProviderHealthRegistry`: consecutive failures trigger
exponential backoff with full jitter (750 ms → 30 s cap), five consecutive
failures mark the provider offline until it records a fresh success. The audio
engine's runtime failure hook re-resolves the same track to the next ranked
source without losing the queue.

## Terms-of-use guardrails

- The engine never turns protected/authorized streams into permanent
  downloads. `cacheStreams` defaults to **off** and is only enabled per source
  kind when the descriptor says `cachePermitted`.
- Commercial services are integrated through their own authorized APIs/accounts
  (metadata, playback, lyrics), never by extracting DRM audio.
- Preflight performs a single-byte ranged GET and closes the stream after the
  first chunk — no full-file buffering, no hidden downloads.

## Extension adapter API

New streaming providers register a `StreamSourceAdapter`:

```dart
abstract class StreamSourceAdapter {
  String get id;
  Future<List<StreamDescriptor>> candidatesFor(Track track);
}
```

Add the adapter to `streamSourceAdaptersProvider` and the engine ranks, healths,
preflights, and fails over to it automatically. The `preview` adapter ships as
the reference implementation (provider-supplied preview URLs), and the built-in
`MultiProviderStreamAdapter` exposes the app's multi-provider resolver (YouTube
universal fallback, SoundCloud, credential-gated lossless providers) to Smart
Play — so the play path resolves real full streams, not only previews. Previews
are ranked below full streams and are the last resort.

## Queue playback & deferred sources

`StreamingEngineController.playTracks` is the list-play entry point:

1. The tapped track runs the full Smart Play ladder and starts immediately.
2. Remaining tracks are queued behind it — pre-resolved local copies play
   directly, and everything else becomes a **deferred** queue item
   (`deferred-stream://track/<id>`).
3. When playback reaches a deferred item, the player asks the engine to
   resolve it (`resolveDeferredSource`): a *fresh* Smart Play decision runs at
   play time, so stream URLs are never stale, files downloaded in the meantime
   are picked up, and offline/local-only policies apply per track.
4. Deferred items survive session restore (paused) and re-resolve on resume;
   low-confidence or unresolvable items stop playback gracefully with a
   logged reason instead of silently substituting another track.

## Recovery

- The audio service persists its own session and restores **paused** at launch.
- The engine persists an independent `PlaybackSavepoint` (queue, mode, quality,
  volume, rate, balance). `sanitize()` drops dead files and expired stream URLs
  so recovery never presents a dead queue, and it always asks the user before
  resuming.
- Download & Play watches the existing download queue and starts local playback
  when the item completes.

## Seamless failover

When a stream URL expires or breaks mid-playback, the runtime failure hook
re-resolves the same track to the next ranked source **and resumes at the
position where the dead source stopped** (`t`): the handler's
`currentPlaybackPosition()` is captured before the switch and passed through
`replaceCurrentAndPlay(item, resumeAt: t)`, so the listener hears a jump of at
most the resolve/backoff delay instead of a restart from 0:00.

Failover also applies *before* playback: a failed preflight walks the ranked
alternative candidates (bounded by the configured attempt budget and a
tried-URI set), so Provider A → Provider B → Provider C succeeds without
re-trying a URI that already failed.

## Match confidence

The anonymous fallback providers (YouTube, SoundCloud) score every candidate
(Topic/official markers, duration drift, cover/karaoke/live penalties) and
**reject low-confidence matches** instead of playing an unrelated track: the
resolution falls through to the next provider or fails with a clear reason.
