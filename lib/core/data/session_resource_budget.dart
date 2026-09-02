/// Memory / battery budgets for multi-hour streaming and download sessions.
///
/// These caps are the production counterpart of a 2+ hour leak audit: every
/// cache the Flutter engine, cover disk store, and native download worker
/// touch is bounded so a lossless stream + background queue cannot grow
/// without limit. Values are the *maximum* a tier may hold, not a target.
library;

/// Device capability tier used to size image caches and rebuild budgets.
enum RuntimeMemoryTier { low, standard, high }

/// One snapshot of live resource use, compared against [SessionResourceBudget].
class SessionResourceSnapshot {
  const SessionResourceSnapshot({
    required this.imageCacheEntries,
    required this.imageCacheBytes,
    required this.coverDiskBytes,
    required this.liveSubscriptions,
    required this.decodedCoversInFlight,
    required this.nativeWorkerItems,
    required this.streamBufferBytes,
  });

  final int imageCacheEntries;
  final int imageCacheBytes;
  final int coverDiskBytes;
  final int liveSubscriptions;
  final int decodedCoversInFlight;
  final int nativeWorkerItems;
  final int streamBufferBytes;
}

/// Hard caps plus the reasons a 2-hour session would be considered leaking.
class SessionResourceBudget {
  const SessionResourceBudget({
    required this.tier,
    required this.maxImageCacheEntries,
    required this.maxImageCacheBytes,
    required this.maxCoverDiskBytes,
    required this.maxLiveSubscriptions,
    required this.maxDecodedCoversInFlight,
    required this.maxNativeWorkerItems,
    required this.maxStreamBufferBytes,
  });

  final RuntimeMemoryTier tier;
  final int maxImageCacheEntries;
  final int maxImageCacheBytes;
  final int maxCoverDiskBytes;
  final int maxLiveSubscriptions;
  final int maxDecodedCoversInFlight;
  final int maxNativeWorkerItems;
  final int maxStreamBufferBytes;

  /// Cover disk store: 1000 objects / 150 MiB, matching CoverCacheManager.
  static const int coverDiskObjectCap = 1000;
  static const int coverDiskByteCap = 150 << 20;
  static const int coverDiskSweepTargetBytes = 120 << 20;

  /// Absolute ceiling on a single progressive-playback head buffer (4 MiB).
  static const int streamHeadBufferCapBytes = 4 << 20;

  static const SessionResourceBudget low = SessionResourceBudget(
    tier: RuntimeMemoryTier.low,
    maxImageCacheEntries: 120,
    maxImageCacheBytes: 24 << 20,
    maxCoverDiskBytes: coverDiskByteCap,
    maxLiveSubscriptions: 24,
    maxDecodedCoversInFlight: 8,
    maxNativeWorkerItems: 512,
    maxStreamBufferBytes: 2 << 20,
  );

  static const SessionResourceBudget standard = SessionResourceBudget(
    tier: RuntimeMemoryTier.standard,
    maxImageCacheEntries: 240,
    maxImageCacheBytes: 60 << 20,
    maxCoverDiskBytes: coverDiskByteCap,
    maxLiveSubscriptions: 48,
    maxDecodedCoversInFlight: 16,
    maxNativeWorkerItems: 2048,
    maxStreamBufferBytes: streamHeadBufferCapBytes,
  );

  static const SessionResourceBudget high = SessionResourceBudget(
    tier: RuntimeMemoryTier.high,
    maxImageCacheEntries: 320,
    maxImageCacheBytes: 80 << 20,
    maxCoverDiskBytes: coverDiskByteCap,
    maxLiveSubscriptions: 64,
    maxDecodedCoversInFlight: 24,
    maxNativeWorkerItems: 4096,
    maxStreamBufferBytes: streamHeadBufferCapBytes,
  );

  static SessionResourceBudget forTier(RuntimeMemoryTier tier) =>
      switch (tier) {
        RuntimeMemoryTier.low => low,
        RuntimeMemoryTier.standard => standard,
        RuntimeMemoryTier.high => high,
      };

  static SessionResourceBudget fromTierName(String? name) => switch (name) {
    'low' => low,
    'high' => high,
    _ => standard,
  };

  /// True when every field is inside the cap. A 2-hour session that still
  /// returns true has no unbounded growth in the audited caches.
  bool allows(SessionResourceSnapshot snapshot) {
    return snapshot.imageCacheEntries <= maxImageCacheEntries &&
        snapshot.imageCacheBytes <= maxImageCacheBytes &&
        snapshot.coverDiskBytes <= maxCoverDiskBytes &&
        snapshot.liveSubscriptions <= maxLiveSubscriptions &&
        snapshot.decodedCoversInFlight <= maxDecodedCoversInFlight &&
        snapshot.nativeWorkerItems <= maxNativeWorkerItems &&
        snapshot.streamBufferBytes <= maxStreamBufferBytes;
  }

  /// Fields that exceeded their cap, used by diagnostics / tests.
  List<String> violations(SessionResourceSnapshot snapshot) {
    final out = <String>[];
    if (snapshot.imageCacheEntries > maxImageCacheEntries) {
      out.add('imageCacheEntries');
    }
    if (snapshot.imageCacheBytes > maxImageCacheBytes) {
      out.add('imageCacheBytes');
    }
    if (snapshot.coverDiskBytes > maxCoverDiskBytes) {
      out.add('coverDiskBytes');
    }
    if (snapshot.liveSubscriptions > maxLiveSubscriptions) {
      out.add('liveSubscriptions');
    }
    if (snapshot.decodedCoversInFlight > maxDecodedCoversInFlight) {
      out.add('decodedCoversInFlight');
    }
    if (snapshot.nativeWorkerItems > maxNativeWorkerItems) {
      out.add('nativeWorkerItems');
    }
    if (snapshot.streamBufferBytes > maxStreamBufferBytes) {
      out.add('streamBufferBytes');
    }
    return out;
  }
}

/// Rebuild / paint isolation budget for progress-heavy screens.
abstract final class RebuildBudget {
  /// Minimum interval between list-wide rebuilds driven by download progress.
  static const Duration progressRebuildFloor = Duration(milliseconds: 200);

  /// Skip a rebuild when the previous and next signatures match.
  static bool shouldSkipRebuild(String? previous, String next) {
    if (previous == null) return false;
    return previous == next;
  }

  /// Decode covers at display size, never above [maxExtent] device pixels.
  static int decodeExtent(double logicalSize, double devicePixelRatio) {
    final dpr = devicePixelRatio.clamp(1.0, 3.0);
    final raw = (logicalSize * dpr).round();
    return raw.clamp(64, 512);
  }

  /// List tiles (logical size ≤ 256) should also cap the on-disk decode so
  /// a 1800px cover is not stored at full resolution 1000 times.
  static bool shouldResizeDiskCache(double? width, double? height) {
    final candidates = <double>[
      if (width != null && width.isFinite && width > 0) width,
      if (height != null && height.isFinite && height > 0) height,
    ];
    if (candidates.isEmpty) return false;
    var maxSide = candidates.first;
    for (final side in candidates.skip(1)) {
      if (side > maxSide) maxSide = side;
    }
    return maxSide <= 256;
  }
}
