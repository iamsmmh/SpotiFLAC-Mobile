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
| `audio_characteristics.dart` | Quality ladder (Auto → Hi-Res), network profiles, codec/bitrate/sample-rate/bit-depth display model, quality policy |
| `streaming_engine.dart` | `StreamDescriptor`, provider health + exponential backoff, source ranking, session phase machine, URL-expiry refresh policy, preflight contract, preloader, diagnostics |
| `smart_play.dart` | The Smart Play ladder with decision traces |
| `playback_session.dart` | Queue planner, shuffle/repeat, savepoint + sanitize, listening statistics |

The Riverpod layer (`lib/providers/streaming_engine_provider.dart`) performs the
actual HTTP work (`HttpStreamPreflightValidator`, `NetworkStatusMonitor`) and
drives the existing `MusicPlayerHandler` — which now accepts progressive
`UrlSource` playback, exposes a playback-failure hook for failover, and keeps
its original content-URI/local-file behavior untouched.

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
the reference implementation (provider-supplied preview URLs).

## Recovery

- The audio service persists its own session and restores **paused** at launch.
- The engine persists an independent `PlaybackSavepoint` (queue, mode, quality,
  volume, rate, balance). `sanitize()` drops dead files and expired stream URLs
  so recovery never presents a dead queue, and it always asks the user before
  resuming.
- Download & Play watches the existing download queue and starts local playback
  when the item completes.
