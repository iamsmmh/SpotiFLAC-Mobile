/// Hybrid playback planning (Feature 3) — pure decision core.
///
/// The ladder for "press play, hear it instantly, end up with a local
/// copy":
///
///   1. local file already present → play local (nothing to do);
///   2. cache holds a verified copy → play the cache hit (offline replay);
///   3. resolve a stream → play it immediately *and* start a background
///      cache fetch in parallel (when the source permits caching);
///   4. fetch completes → digest-verify → swap the live remote playback
///      to the local file without an audible gap
///      (`MusicPlayerHandler.replaceCurrentAndPlay` keeps position);
///   5. no stream → fall back to the existing download-&-play ladder.
///
/// This file owns the *policy* (what should happen, in which order, given
/// which facts); the runtime manager lives in the provider layer.
library;

/// Facts the planner needs (all resolved before planning).
class HybridPlaybackFacts {
  const HybridPlaybackFacts({
    required this.hasLocalFile,
    required this.hasVerifiedCache,
    required this.streamResolved,
    required this.cachePermitted,
    required this.cacheEnabled,
    required this.offline,
  });

  final bool hasLocalFile;
  final bool hasVerifiedCache;
  final bool streamResolved;

  /// Provider terms allow caching this source.
  final bool cachePermitted;

  /// User cache toggle (`EngineSettings.cacheStreams`).
  final bool cacheEnabled;

  final bool offline;
}

/// What the runtime should do.
enum HybridPlaybackAction {
  /// Play the existing local file; no background work.
  playLocal,

  /// Play the verified cache copy (decrypted temp if needed).
  playCache,

  /// Start remote playback and fetch the cache in parallel; swap when the
  /// fetch verifies.
  playStreamAndCache,

  /// Start remote playback only (caching not permitted/disabled).
  playStream,

  /// No remote option: use the Smart Play download-&-play ladder.
  downloadAndPlay,

  /// Nothing is playable; surface the reason.
  unavailable,
}

class HybridPlaybackPlan {
  const HybridPlaybackPlan({
    required this.action,
    required this.backgroundFetch,
    required this.swapWhenVerified,
    required this.reason,
  });

  final HybridPlaybackAction action;

  /// Whether a parallel background fetch should start.
  final bool backgroundFetch;

  /// Whether a verified fetch should hot-swap into live playback.
  final bool swapWhenVerified;

  /// Human-readable explanation (diagnostics + tests).
  final String reason;

  bool get startsPlayback =>
      action != HybridPlaybackAction.unavailable &&
      action != HybridPlaybackAction.downloadAndPlay;
}

/// Pure planner. Deterministic, side-effect free, exhaustively tested.
class HybridPlaybackPlanner {
  const HybridPlaybackPlanner();

  HybridPlaybackPlan plan(HybridPlaybackFacts facts) {
    if (facts.hasLocalFile) {
      return const HybridPlaybackPlan(
        action: HybridPlaybackAction.playLocal,
        backgroundFetch: false,
        swapWhenVerified: false,
        reason: 'Local file already present',
      );
    }
    if (facts.hasVerifiedCache) {
      return const HybridPlaybackPlan(
        action: HybridPlaybackAction.playCache,
        backgroundFetch: false,
        swapWhenVerified: false,
        reason: 'Verified cache copy available (offline replay)',
      );
    }
    if (facts.offline) {
      return const HybridPlaybackPlan(
        action: HybridPlaybackAction.unavailable,
        backgroundFetch: false,
        swapWhenVerified: false,
        reason: 'Offline and no local copy',
      );
    }
    if (facts.streamResolved) {
      final cache = facts.cachePermitted && facts.cacheEnabled;
      return HybridPlaybackPlan(
        action: HybridPlaybackAction.playStreamAndCache,
        backgroundFetch: cache,
        swapWhenVerified: cache,
        reason: cache
            ? 'Streaming now; caching in background, swap when verified'
            : 'Streaming without caching (source terms or user setting)',
      );
    }
    return const HybridPlaybackPlan(
      action: HybridPlaybackAction.downloadAndPlay,
      backgroundFetch: false,
      swapWhenVerified: false,
      reason: 'No stream source; using download & play',
    );
  }
}
