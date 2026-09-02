/// Cold-start sequence for the production binary.
///
/// The first frame must paint before any gomobile / FFmpeg / extension work.
/// Everything after [ColdStartPhase.firstFrame] is fire-and-forget so a slow
/// SAF grant check or cover-cache sweep cannot block launch.
library;

enum ColdStartPhase {
  /// Binding + SharedPreferences + runtime-profile + image-cache caps.
  bindings,

  /// `runApp` — first frame.
  firstFrame,

  /// Cover cache, notifications, share intent (post-frame).
  services,

  /// Extension VM, queue composition, engine savepoint.
  engines,

  /// LRU cache prune, SAF validation, local-library warmup.
  maintenance,
}

class ColdStartStep {
  const ColdStartStep({
    required this.phase,
    required this.id,
    required this.blocksFirstFrame,
  });

  final ColdStartPhase phase;
  final String id;
  final bool blocksFirstFrame;
}

abstract final class ColdStartPolicy {
  static const List<ColdStartStep> sequence = <ColdStartStep>[
    ColdStartStep(
      phase: ColdStartPhase.bindings,
      id: 'widgets_binding',
      blocksFirstFrame: true,
    ),
    ColdStartStep(
      phase: ColdStartPhase.bindings,
      id: 'shared_preferences',
      blocksFirstFrame: true,
    ),
    ColdStartStep(
      phase: ColdStartPhase.bindings,
      id: 'secure_store_init',
      blocksFirstFrame: true,
    ),
    ColdStartStep(
      phase: ColdStartPhase.bindings,
      id: 'runtime_profile',
      blocksFirstFrame: true,
    ),
    ColdStartStep(
      phase: ColdStartPhase.bindings,
      id: 'image_cache_caps',
      blocksFirstFrame: true,
    ),
    ColdStartStep(
      phase: ColdStartPhase.firstFrame,
      id: 'run_app',
      blocksFirstFrame: true,
    ),
    ColdStartStep(
      phase: ColdStartPhase.services,
      id: 'cover_cache',
      blocksFirstFrame: false,
    ),
    ColdStartStep(
      phase: ColdStartPhase.services,
      id: 'notifications',
      blocksFirstFrame: false,
    ),
    ColdStartStep(
      phase: ColdStartPhase.engines,
      id: 'extensions',
      blocksFirstFrame: false,
    ),
    ColdStartStep(
      phase: ColdStartPhase.engines,
      id: 'queue_engine',
      blocksFirstFrame: false,
    ),
    ColdStartStep(
      phase: ColdStartPhase.maintenance,
      id: 'cache_policy',
      blocksFirstFrame: false,
    ),
  ];

  static List<ColdStartStep> get blockingSteps => sequence
      .where((step) => step.blocksFirstFrame)
      .toList(growable: false);

  static List<ColdStartStep> get deferredSteps => sequence
      .where((step) => !step.blocksFirstFrame)
      .toList(growable: false);

  /// Image-cache entry cap for [tier]. Mirrors SessionResourceBudget so the
  /// cold-start path and the 2-hour leak audit cannot drift.
  static int imageCacheEntriesForTier(String tier) {
    return switch (tier) {
      'low' => 120,
      'high' => 320,
      _ => 240,
    };
  }

  static int imageCacheBytesForTier(String tier) {
    return switch (tier) {
      'low' => 24 << 20,
      'high' => 80 << 20,
      _ => 60 << 20,
    };
  }

  /// A deferred step must never be awaited on the first-frame path.
  static bool isDeferred(String id) {
    return sequence.any((step) => step.id == id && !step.blocksFirstFrame);
  }
}
