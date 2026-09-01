import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/utils/string_utils.dart';

/// The streaming engine: source discovery, ranking, health scoring, failover,
/// URL-expiration handling, retry/backoff, preflight validation, and
/// next-track preloading.
///
/// The engine is deliberately transport-agnostic. It produces
/// [StreamDescriptor]s and decides what to do next; the Riverpod layer
/// (streaming_engine_provider.dart) performs the actual HTTP/preflight work and
/// feeds playback into the existing audio_service player.
library;

/// What a source is. [StreamSourceKind] drives both the ranking policy and the
/// terms-of-use checks — protected commercial streams are never promoted to
/// permanent downloads.
enum StreamSourceKind {
  /// A local or downloaded file (never re-downloaded; played directly).
  localFile,

  /// A direct progressive audio URL (e.g. provider preview URLs).
  httpStream,

  /// An authorized provider stream handed over by an extension adapter.
  extensionStream,

  /// A licensed/pre-authorized stream that requires credentials. Kept in the
  /// model so the UI can show "authorized" instead of silently downgrading.
  authorizedStream;
}

/// One candidate source for one logical track.
class StreamDescriptor {
  final String id;
  final String providerId;
  final StreamSourceKind kind;
  final String uri;

  /// Resolved output quality of this source.
  final AudioQualityLevel quality;

  /// Measured/declared characteristics (codec, bitrate, ...).
  final AudioCharacteristics characteristics;

  /// Absolute expiry; null when the source does not expire.
  final DateTime? expiresAt;

  /// When this descriptor's URL was issued, used by the refresh policy.
  final DateTime? validFrom;

  /// Network latency observed during the last preflight (ms).
  final int? latencyMs;

  /// Whether the provider requires the user to have authorized it.
  final bool requiresAuthorization;

  /// Whether the provider's terms permit caching this stream for offline use.
  final bool cachePermitted;

  /// User-configured/provider priority (lower wins).
  final int priority;

  const StreamDescriptor({
    required this.id,
    required this.providerId,
    required this.kind,
    required this.uri,
    this.quality = AudioQualityLevel.auto,
    this.characteristics = const AudioCharacteristics(),
    this.expiresAt,
    this.validFrom,
    this.latencyMs,
    this.requiresAuthorization = false,
    this.cachePermitted = false,
    this.priority = 0,
  });

  bool get isLocal => kind == StreamSourceKind.localFile;

  bool get isRemote => kind != StreamSourceKind.localFile;

  bool get isExpired => _isExpired(DateTime.now());

  bool _isExpired(DateTime now) {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return !now.isBefore(expiry);
  }

  StreamDescriptor copyWith({
    String? uri,
    AudioQualityLevel? quality,
    AudioCharacteristics? characteristics,
    DateTime? expiresAt,
    DateTime? validFrom,
    int? latencyMs,
    int? priority,
  }) => StreamDescriptor(
    id: id,
    providerId: providerId,
    kind: kind,
    uri: uri ?? this.uri,
    quality: quality ?? this.quality,
    characteristics: characteristics ?? this.characteristics,
    expiresAt: expiresAt ?? this.expiresAt,
    validFrom: validFrom ?? this.validFrom,
    latencyMs: latencyMs ?? this.latencyMs,
    requiresAuthorization: requiresAuthorization,
    cachePermitted: cachePermitted,
    priority: priority ?? this.priority,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': providerId,
    'kind': kind.name,
    'uri': uri,
    'quality': quality.name,
    'characteristics': characteristics.toJson(),
    if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
    if (validFrom != null) 'valid_from': validFrom!.toUtc().toIso8601String(),
    if (latencyMs != null) 'latency_ms': latencyMs,
    'requires_authorization': requiresAuthorization,
    'cache_permitted': cachePermitted,
    'priority': priority,
  };

  factory StreamDescriptor.fromJson(Map<String, dynamic> json) {
    final kind = StreamSourceKind.values.firstWhere(
      (value) => value.name == json['kind'],
      orElse: () => StreamSourceKind.httpStream,
    );
    return StreamDescriptor(
      id: json['id']?.toString() ?? json['uri']?.toString() ?? '',
      providerId: json['provider']?.toString() ?? 'unknown',
      kind: kind,
      uri: json['uri']?.toString() ?? '',
      quality: AudioQualityLevel.fromLabel(json['quality']),
      characteristics: json['characteristics'] is Map<String, dynamic>
          ? AudioCharacteristics.fromJson(
              json['characteristics'] as Map<String, dynamic>,
            )
          : const AudioCharacteristics(),
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
      validFrom: DateTime.tryParse(json['valid_from']?.toString() ?? ''),
      latencyMs: (json['latency_ms'] as num?)?.toInt(),
      requiresAuthorization: json['requires_authorization'] == true,
      cachePermitted: json['cache_permitted'] == true,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Live health of one streaming provider, fed by preflight results and
/// playback outcomes.
class ProviderHealth {
  final String providerId;
  final String? version;
  final bool online;
  final int successCount;
  final int failureCount;
  final int consecutiveFailures;
  final int? lastLatencyMs;
  final DateTime? lastCheckedAt;
  final DateTime? lastFailedAt;
  final DateTime? backoffUntil;

  const ProviderHealth({
    required this.providerId,
    this.version,
    this.online = true,
    this.successCount = 0,
    this.failureCount = 0,
    this.consecutiveFailures = 0,
    this.lastLatencyMs,
    this.lastCheckedAt,
    this.lastFailedAt,
    this.backoffUntil,
  });

  factory ProviderHealth.initial(String providerId, {String? version}) =>
      ProviderHealth(providerId: providerId, version: version);

  double get successRate {
    final total = successCount + failureCount;
    if (total == 0) return 1.0;
    return successCount / total;
  }

  /// Whether the provider should currently be attempted at all.
  bool get isAvailable {
    if (!online) return false;
    final backoff = backoffUntil;
    if (backoff != null && DateTime.now().isBefore(backoff)) return false;
    return true;
  }

  /// Composite health in 0..1 used by source ranking.
  double get score {
    if (!online) return 0.0;
    if (DateTime.now().isBefore(backoffUntil ?? DateTime.fromMillisecondsSinceEpoch(0))) {
      return 0.0;
    }
    final reliability = successRate;
    final recency = _recencyScore(lastCheckedAt);
    final latency = lastLatencyMs == null
        ? 0.5
        : (1 - (lastLatencyMs! / 2000)).clamp(0.0, 1.0);
    return ((reliability * 0.55) + (recency * 0.20) + (latency * 0.25))
        .clamp(0.0, 1.0);
  }

  static double _recencyScore(DateTime? checkedAt) {
    if (checkedAt == null) return 1.0;
    final ageHours = DateTime.now().difference(checkedAt).inMinutes / 60;
    return (1 - (ageHours / 24)).clamp(0.0, 1.0);
  }

  ProviderHealth recordSuccess({int? latencyMs, String? version}) =>
      ProviderHealth(
        providerId: providerId,
        version: version ?? this.version,
        online: true,
        successCount: successCount + 1,
        failureCount: failureCount,
        consecutiveFailures: 0,
        lastLatencyMs: latencyMs ?? lastLatencyMs,
        lastCheckedAt: DateTime.now(),
        lastFailedAt: null,
        backoffUntil: null,
      );

  ProviderHealth recordFailure({int? latencyMs, String? version}) {
    const maxBackoff = Duration(minutes: 15);
    final failures = consecutiveFailures + 1;
    final backoffSeconds = math.min(maxBackoff.inSeconds, 2 << math.min(failures - 1, 8));
    return ProviderHealth(
      providerId: providerId,
      version: version ?? this.version,
      online: consecutiveFailures < 5, // only permanently disable after 5 in a row
      successCount: successCount,
      failureCount: failureCount + 1,
      consecutiveFailures: failures,
      lastLatencyMs: latencyMs ?? lastLatencyMs,
      lastCheckedAt: DateTime.now(),
      lastFailedAt: DateTime.now(),
      backoffUntil: DateTime.now().add(Duration(seconds: backoffSeconds)),
    );
  }

  ProviderHealth markOffline({String? reason}) => recordFailure();

  /// A fresh, un-touched health row (used after a provider is re-enabled).
  ProviderHealth reset() => ProviderHealth.initial(providerId, version: version);

  Map<String, dynamic> toJson() => {
    'provider': providerId,
    if (version != null) 'version': version,
    'online': online,
    'success_count': successCount,
    'failure_count': failureCount,
    'consecutive_failures': consecutiveFailures,
    if (lastLatencyMs != null) 'last_latency_ms': lastLatencyMs,
    if (lastCheckedAt != null)
      'last_checked': lastCheckedAt!.toUtc().toIso8601String(),
    if (backoffUntil != null)
      'backoff_until': backoffUntil!.toUtc().toIso8601String(),
  };
}

/// Registry of provider health rows with bounded memory.
class ProviderHealthRegistry {
  final LinkedHashMap<String, ProviderHealth> _health = LinkedHashMap();
  static const int _maxEntries = 64;

  ProviderHealth healthOf(String providerId, {String? version}) =>
      _health[providerId] ?? ProviderHealth.initial(providerId, version: version);

  bool get hasAnyFailure =>
      _health.values.any((h) => h.failureCount > 0 || !h.isAvailable);

  void patch(String providerId, ProviderHealth health) {
    _health[providerId] = health;
    while (_health.length > _maxEntries) {
      _health.remove(_health.keys.first);
    }
  }

  void recordSuccess(String providerId, {int? latencyMs, String? version}) {
    patch(
      providerId,
      healthOf(providerId, version: version)
          .recordSuccess(latencyMs: latencyMs, version: version),
    );
  }

  void recordFailure(String providerId, {int? latencyMs, String? version}) {
    patch(
      providerId,
      healthOf(providerId, version: version)
          .recordFailure(latencyMs: latencyMs, version: version),
    );
  }

  void markOffline(String providerId, {String? version}) {
    patch(
      providerId,
      healthOf(providerId, version: version).markOffline(),
    );
  }

  void reset(String providerId, {String? version}) {
    patch(
      providerId,
      healthOf(providerId, version: version).reset(),
    );
  }

  List<ProviderHealth> snapshot() =>
      List.unmodifiable(_health.values.toList(growable: false));

  Map<String, dynamic> toJson() => {
    'providers': _health.values.map((h) => h.toJson()).toList(growable: false),
  };
}

/// Ranks candidate sources for one track.
///
/// Scoring weights (aligned with the "Source Intelligence Engine"):
///   45% provider health/reliability
///   25% quality fit for the requested profile
///   20% latency
///   10% user/provider priority
///
/// Expired, offline, backoff-pending and unauthorized-but-required sources are
/// filtered before scoring; they remain available as [retrySet] for a later
/// refresh pass, never as an immediate choice.
class StreamSourceResolver {
  final ProviderHealthRegistry health;

  const StreamSourceResolver({required this.health});

  static const double _weightsHealth = 0.45;
  static const double _weightsQuality = 0.25;
  static const double _weightsLatency = 0.20;
  static const double _weightsPriority = 0.10;

  List<StreamDescriptor> candidates(
    List<StreamDescriptor> sources, {
    AudioQualityLevel requested = AudioQualityLevel.auto,
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final filtered = sources.where((source) {
      if (source.uri.trim().isEmpty) return false;
      if (source.kind == StreamSourceKind.authorizedStream &&
          source.requiresAuthorization) {
        // Authorization is checked by the adapter layer; if the descriptor
        // still requires it here, it is not usable right now.
        return false;
      }
      final providerHealth = health.healthOf(source.providerId);
      if (!providerHealth.isAvailable) return false;
      final expiry = source.expiresAt;
      if (expiry != null && !effectiveNow.isBefore(expiry)) return false;
      return true;
    }).toList(growable: false);

    return filtered..sort((a, b) => _compare(a, b, requested));
  }

  int _compare(StreamDescriptor a, StreamDescriptor b, AudioQualityLevel requested) {
    final scoreA = _score(a, requested);
    final scoreB = _score(b, requested);
    final byScore = scoreB.compareTo(scoreA);
    if (byScore != 0) return byScore;
    // Deterministic tiebreak on provider + id so ranking never flaps between
    // equal sources on successive calls.
    final byProvider = a.providerId.compareTo(b.providerId);
    if (byProvider != 0) return byProvider;
    return a.id.compareTo(b.id);
  }

  double _score(StreamDescriptor source, AudioQualityLevel requested) {
    final providerHealth = health.healthOf(source.providerId);
    final healthScore = providerHealth.score;

    final qualityScore = requested == AudioQualityLevel.auto
        ? _qualityFit(source.quality)
        : _qualityFitFor(source.quality, requested);

    final latencyScore = source.latencyMs == null
        ? 0.5
        : (1 - (source.latencyMs! / 3000)).clamp(0.0, 1.0);

    final priorityScore = (1 - (source.priority / 16)).clamp(0.0, 1.0);

    return (healthScore * _weightsHealth) +
        (qualityScore * _weightsQuality) +
        (latencyScore * _weightsLatency) +
        (priorityScore * _weightsPriority);
  }

  /// Neutral quality score when no explicit level was requested: lossless is
  /// always ranked first, unknown/auto last.
  static double _qualityFit(AudioQualityLevel quality) => switch (quality) {
    AudioQualityLevel.hires => 1.00,
    AudioQualityLevel.lossless => 0.92,
    AudioQualityLevel.high => 0.78,
    AudioQualityLevel.normal => 0.60,
    AudioQualityLevel.low => 0.40,
    AudioQualityLevel.auto => 0.20,
  };

  static double _qualityFitFor(AudioQualityLevel quality, AudioQualityLevel requested) {
    if (quality == requested) return 1.0;
    // Lossless satisfies any lower request; a lower source can never satisfy
    // a higher request.
    if (quality.rank >= requested.rank) {
      return 0.85 - ((quality.rank - requested.rank) * 0.08);
    }
    return 0.30 + (quality.rank * 0.06);
  }
}

/// Exponential backoff with full jitter (AWS-style), deterministic under an
/// injected [Random] so tests can assert the sequence.
class BackoffScheduler {
  final Random _random;
  final Duration base;
  final Duration max;
  final double jitter;

  const BackoffScheduler({
    this.base = const Duration(milliseconds: 750),
    this.max = const Duration(seconds: 30),
    this.jitter = 0.5,
    Random? random,
  }) : _random = random ?? const _SecureRandom();

  Duration next(int attempt) {
    final exponent = math.min(attempt, 8);
    final capMs = math.min(max.inMilliseconds, base.inMilliseconds * (1 << exponent));
    final low = (capMs * (1 - jitter)).round();
    final high = capMs;
    final span = math.max(1, high - low);
    final value = low + _random.nextInt(span + 1);
    return Duration(milliseconds: value.clamp(1, max.inMilliseconds));
  }
}

/// Stateless PRNG suitable for tests (system randomness is injected elsewhere
/// where a seeded sequence matters).
class _SecureRandom implements Random {
  const _SecureRandom();

  @override
  int nextInt(int max) => math.Random().nextInt(max);

  @override
  bool nextBool() => math.Random().nextBool();

  @override
  double nextDouble() => math.Random().nextDouble();
}

/// Failure taxonomy with retryability, so the UI can say "stream expired —
/// refreshing" vs "no source available for this track".
enum StreamFailureKind {
  timeout('Timed out', true),
  network('Network error', true),
  urlExpired('Stream URL expired', true),
  forbidden('Source not authorized', false),
  unsupported('Unsupported source', false),
  noSource('No source available', false),
  cancelled('Cancelled', false);

  const StreamFailureKind(this.label, this.retryable);

  final String label;
  final bool retryable;
}

class StreamFailure implements Exception {
  final StreamFailureKind kind;
  final int attempt;
  final String? message;
  final String providerId;

  const StreamFailure({
    required this.kind,
    required this.providerId,
    this.attempt = 1,
    this.message,
  });

  bool get retryable => kind.retryable;

  @override
  String toString() =>
      'StreamFailure(${kind.label}, provider=$providerId, attempt=$attempt'
      '${message == null ? '' : ', $message'})';
}

/// Validates a stream URL before playback. Implemented with `package:http` in
/// the provider layer; the pure engine only defines the contract + result.
abstract class StreamPreflightValidator {
  Future<StreamPreflightResult> validate(StreamDescriptor source);
}

class StreamPreflightResult {
  final bool ok;
  final int? latencyMs;
  final String? contentType;
  final int? contentLengthBytes;
  final String? error;
  final DateTime expiresAt;

  const StreamPreflightResult({
    required this.ok,
    this.latencyMs,
    this.contentType,
    this.contentLengthBytes,
    this.error,
    required this.expiresAt,
  });

  factory StreamPreflightResult.success({
    int? latencyMs,
    String? contentType,
    int? contentLengthBytes,
  }) => StreamPreflightResult(
    ok: true,
    latencyMs: latencyMs,
    contentType: contentType,
    contentLengthBytes: contentLengthBytes,
    expiresAt: DateTime.now().add(const Duration(minutes: 30)),
  );

  factory StreamPreflightResult.failure(String error) =>
      StreamPreflightResult(
        ok: false,
        error: error,
        expiresAt: DateTime.now(),
      );
}

/// One bandwidth observation used by adaptive quality / diagnostics.
///
/// Samples are derived from preflight metadata (content length + measured
/// latency) and from provider-reported transfer rates. The engine never
/// downloads a full stream to measure bandwidth — it keeps estimates bounded
/// and only for sources that already expose a content length.
class BandwidthSample {
  final DateTime at;
  final int? bytes;
  final int? latencyMs;
  final int? bytesPerSecond;
  final String providerId;

  const BandwidthSample({
    required this.at,
    this.bytes,
    this.latencyMs,
    this.bytesPerSecond,
    this.providerId = 'unknown',
  });

  /// Estimate from a preflight result: a single-byte probe gives us a useful
  /// latency reading, while content-length lets us estimate the effective
  /// throughput for the full asset.
  factory BandwidthSample.fromPreflight({
    required int? latencyMs,
    required int? contentLengthBytes,
    String providerId = 'unknown',
  }) {
    final bytes = contentLengthBytes;
    final latency = latencyMs;
    int? bps;
    if (bytes != null && bytes > 0 && latency != null && latency > 0) {
      bps = ((bytes / (latency / 1000)).round()).clamp(0, 1 << 40);
    }
    return BandwidthSample(
      at: DateTime.now(),
      bytes: bytes,
      latencyMs: latency,
      bytesPerSecond: bps,
      providerId: providerId,
    );
  }

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    if (bytes != null) 'bytes': bytes,
    if (latencyMs != null) 'latency_ms': latencyMs,
    if (bytesPerSecond != null) 'bytes_per_second': bytesPerSecond,
    'provider': providerId,
  };
}

/// Rolling bandwidth monitor exposed through [StreamingDiagnostics].
///
/// Keeps the most recent samples (bounded) plus a smoothed estimate so the
/// Diagnostics Center and adaptive-quality logic can answer "how fast is the
/// current link without a full-file download?".
class BandwidthMonitor {
  final List<BandwidthSample> _samples = [];
  static const int _maxSamples = 12;

  List<BandwidthSample> get samples => List.unmodifiable(_samples.reversed);

  int? get latestBytesPerSecond =>
      _samples.isEmpty ? null : _samples.last.bytesPerSecond;

  /// Median of the last samples (robust against one noisy sample).
  int? get smoothedBytesPerSecond {
    final values = _samples
        .map((s) => s.bytesPerSecond)
        .whereType<int>()
        .where((v) => v > 0)
        .toList(growable: false);
    if (values.isEmpty) return null;
    values.sort();
    return values[values.length ~/ 2];
  }

  void record(BandwidthSample? sample) {
    if (sample == null) return;
    _samples.add(sample);
    if (_samples.length > _maxSamples) {
      _samples.removeAt(0);
    }
  }

  void recordPreflight({
    required int? latencyMs,
    required int? contentLengthBytes,
    String providerId = 'unknown',
  }) =>
      record(
        BandwidthSample.fromPreflight(
          latencyMs: latencyMs,
          contentLengthBytes: contentLengthBytes,
          providerId: providerId,
        ),
      );

  Map<String, dynamic> toJson() => {
    'samples': _samples.reversed.map((s) => s.toJson()).toList(growable: false),
  };
}

/// URL-expiration handling policy.
class StreamUrlRefreshPolicy {
  final Duration refreshLeadTime;
  final double ttlFraction;

  const StreamUrlRefreshPolicy({
    this.refreshLeadTime = const Duration(minutes: 5),
    this.ttlFraction = 0.2,
  });

  /// Whether [source]'s URL should be refreshed before the next play attempt.
  bool shouldRefresh(StreamDescriptor source, {DateTime? now}) {
    if (source.kind != StreamSourceKind.authorizedStream &&
        source.kind != StreamSourceKind.extensionStream) {
      return false;
    }
    final expiry = source.expiresAt;
    if (expiry == null) return false;
    final effectiveNow = now ?? DateTime.now();
    if (effectiveNow.isAfter(expiry.subtract(refreshLeadTime))) return true;
    // Refresh once the descriptor has lived past the ttl fraction of its
    // lifetime to keep URLs fresh for long queues.
    final validFrom = source.validFrom ?? DateTime.fromMillisecondsSinceEpoch(0);
    final ttl = expiry.difference(validFrom);
    if (ttl <= const Duration(seconds: 1)) return false;
    return effectiveNow.isAfter(validFrom.add(ttl * ttlFraction));
  }
}

/// Lifecycle of one stream attempt, observable by the diagnostics UI.
enum StreamPhase {
  idle,
  resolving,
  preflighting,
  streaming,
  refreshingUrl,
  fallingBack,
  waitingRetry,
  succeeded,
  failed,
  cancelled,
}

class StreamSessionState {
  final StreamPhase phase;
  final int attempt;
  final StreamDescriptor? active;
  final StreamFailure? lastFailure;
  final DateTime changedAt;
  final AudioQualityLevel quality;

  StreamSessionState({
    this.phase = StreamPhase.idle,
    this.attempt = 0,
    this.active,
    this.lastFailure,
    DateTime? changedAt,
    this.quality = AudioQualityLevel.auto,
  }) : changedAt = changedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  StreamSessionState copyWith({
    StreamPhase? phase,
    int? attempt,
    StreamDescriptor? active,
    StreamFailure? lastFailure,
    DateTime? changedAt,
    AudioQualityLevel? quality,
    bool clearFailure = false,
  }) => StreamSessionState(
    phase: phase ?? this.phase,
    attempt: attempt ?? this.attempt,
    active: active ?? this.active,
    lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
    changedAt: changedAt ?? DateTime.now(),
    quality: quality ?? this.quality,
  );

  Map<String, dynamic> toJson() => {
    'phase': phase.name,
    'attempt': attempt,
    if (active != null) 'active': active!.toJson(),
    if (lastFailure != null) 'last_failure': lastFailure!.toString(),
    'quality': quality.name,
    'changed_at': changedAt.toUtc().toIso8601String(),
  };
}

/// Bounded, ordered event log for the Diagnostics Center.
class EngineEventLog {
  final List<EngineEvent> _events = [];
  static const int _maxEvents = 64;

  List<EngineEvent> get events => List.unmodifiable(_events.reversed);

  void add(EngineEvent event) {
    _events.add(event);
    if (_events.length > _maxEvents) _events.removeAt(0);
  }

  void clear() => _events.clear();

  Map<String, dynamic> toJson() => {
    'events': _events.reversed.map((e) => e.toJson()).toList(growable: false),
  };
}

enum EngineEventSeverity { info, warning, error }

class EngineEvent {
  final DateTime at;
  final EngineEventSeverity severity;
  final String category;
  final String message;

  const EngineEvent({
    required this.at,
    required this.severity,
    required this.category,
    required this.message,
  });

  factory EngineEvent.info(String category, String message) => EngineEvent(
    at: DateTime.now(),
    severity: EngineEventSeverity.info,
    category: category,
    message: message,
  );

  factory EngineEvent.warning(String category, String message) => EngineEvent(
    at: DateTime.now(),
    severity: EngineEventSeverity.warning,
    category: category,
    message: message,
  );

  factory EngineEvent.error(String category, String message) => EngineEvent(
    at: DateTime.now(),
    severity: EngineEventSeverity.error,
    category: category,
    message: message,
  );

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'severity': severity.name,
    'category': category,
    'message': message,
  };
}

/// A planned preload: which next track, which source, and its current state.
class PreloadJob {
  final String trackId;
  final StreamDescriptor source;
  PreloadJobState state;
  int attempt;

  PreloadJob({
    required this.trackId,
    required this.source,
    this.state = PreloadJobState.pending,
    this.attempt = 0,
  });

  Map<String, dynamic> toJson() => {
    'track_id': trackId,
    'source': source.toJson(),
    'state': state.name,
    'attempt': attempt,
  };
}

enum PreloadJobState { pending, preflighting, ready, failed, skipped }

/// Preloads the next N tracks' stream URLs so the next-track switch is instant.
///
/// Validation is a lightweight HEAD/GET-range check via the injected
/// [StreamPreflightValidator]; it never decodes audio. Jobs are keyed by track
/// id so repeated calls cannot duplicate work.
class StreamPreloader {
  final StreamPreflightValidator validator;
  final Map<String, PreloadJob> _jobs = {};
  final Map<String, bool> _ready = {};
  final EngineEventLog log;

  StreamPreloader({
    required this.validator,
    required this.log,
    StreamDescriptor Function(String trackId)? sourceResolver,
  }) : _sourceResolver = sourceResolver;

  final StreamDescriptor Function(String trackId)? _sourceResolver;

  PreloadJob? jobFor(String trackId) => _jobs[trackId];

  bool isReady(String trackId) => _ready[trackId] == true;

  /// Plans preloads for [trackIds] in queue order. [resolver] can be omitted
  /// when the controller registered a resolver at construction time.
  Future<void> plan(
    List<String> trackIds, {
    StreamDescriptor Function(String trackId)? resolver,
    int window = 2,
    Set<String>? skipIds,
  }) async {
    final resolve = resolver ?? _sourceResolver;
    if (resolve == null) return;
    for (final trackId in trackIds.take(window)) {
      if (skipIds?.contains(trackId) ?? false) continue;
      if (_jobs.containsKey(trackId)) continue;
      final source = resolve(trackId);
      if (source == null || source.kind == StreamSourceKind.localFile) continue;
      final job = PreloadJob(trackId: trackId, source: source);
      _jobs[trackId] = job;
      unawaited(_run(job));
    }
  }

  Future<void> _run(PreloadJob job) async {
    job.state = PreloadJobState.preflighting;
    try {
      final result = await validator.validate(job.source);
      if (!result.ok) {
        job.state = PreloadJobState.failed;
        log.add(
          EngineEvent.warning(
            'preload',
            'Preload failed for ${job.trackId}: ${result.error}',
          ),
        );
        return;
      }
      job.state = PreloadJobState.ready;
      _ready[job.trackId] = true;
      if (_ready.length > 32) {
        _ready.remove(_ready.keys.first);
      }
    } catch (e) {
      job.state = PreloadJobState.failed;
      log.add(
        EngineEvent.warning('preload', 'Preload error for ${job.trackId}: $e'),
      );
    }
  }

  void invalidate(String trackId) {
    _jobs[trackId]?.state = PreloadJobState.pending;
    _ready[trackId] = false;
  }

  void clear() {
    _jobs.clear();
    _ready.clear();
  }
}

/// Immutable snapshot handed to the Diagnostics Center.
class StreamingDiagnostics {
  final ProviderHealthRegistry health;
  final EngineEventLog log;
  final StreamSessionState session;
  final BandwidthMonitor bandwidth;

  const StreamingDiagnostics({
    required this.health,
    required this.log,
    required this.session,
    required this.bandwidth,
  });

  int get failures =>
      health.snapshot().fold(0, (sum, h) => sum + h.failureCount);

  int get successes =>
      health.snapshot().fold(0, (sum, h) => sum + h.successCount);

  /// Smoothed effective throughput estimate in bytes/sec, if available.
  int? get effectiveBandwidthBytesPerSecond => bandwidth.smoothedBytesPerSecond;

  /// Human-readable throughput label (e.g. "1.2 Mbps").
  String? get effectiveBandwidthLabel =>
      formatBandwidth(effectiveBandwidthBytesPerSecond);

  Map<String, dynamic> toJson() => {
    'health': health.toJson(),
    'events': log.toJson(),
    'session': session.toJson(),
    'bandwidth': bandwidth.toJson(),
  };

  /// Human-readable one-line summary for status chips.
  String get summaryLine {
    final providers = health.snapshot();
    if (providers.isEmpty) return 'No streaming providers registered';
    final online = providers.where((h) => h.isAvailable).length;
    final base =
        '$online/${providers.length} providers available · '
        '$successes ok · $failures failed';
    final bw = effectiveBandwidthLabel;
    return bw == null ? base : '$base · ~$bw';
  }
}

/// Formats a bytes/sec rate into a compact human label.
String formatBandwidth(int? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) return '';
  final kbps = bytesPerSecond * 8 / 1000; // network bits, decimal units
  if (kbps >= 1000) return '${(kbps / 1000).toStringAsFixed(1)} Mbps';
  if (kbps >= 1) return '${kbps.round()} kbps';
  return '${bytesPerSecond.round()} B/s';
}

/// The engine session controller: owns the state machine for one playback
/// attempt and the policy knobs. Pure Dart (no platform channels), so all
/// failure/backoff behavior is unit-testable.
class StreamingSessionController {
  final StreamSourceResolver resolver;
  final BackoffScheduler backoff;
  final StreamUrlRefreshPolicy refreshPolicy;
  final EngineEventLog log;
  final ProviderHealthRegistry health;

  StreamSessionState _state = StreamSessionState();

  StreamingSessionController({
    required this.resolver,
    required this.health,
    required this.log,
    BackoffScheduler? backoff,
    StreamUrlRefreshPolicy? refreshPolicy,
  }) : backoff = backoff ?? const BackoffScheduler(),
       refreshPolicy = refreshPolicy ?? const StreamUrlRefreshPolicy();

  StreamSessionState get state => _state;

  void _transition(StreamSessionState next) {
    _state = next;
  }

  /// Resolves [sources] to the best usable source, skipping a known-bad
  /// provider, and returns the attempt index that was started.
  StreamResolutionOutcome resolve(
    List<StreamDescriptor> sources, {
    AudioQualityLevel requested = AudioQualityLevel.auto,
    DateTime? now,
  }) {
    final candidates = resolver.candidates(sources, requested: requested, now: now);
    if (candidates.isEmpty) {
      final failure = StreamFailure(
        kind: StreamFailureKind.noSource,
        providerId: sources.isEmpty ? 'none' : sources.first.providerId,
        message: 'no candidates remained after health/expiry filtering',
      );
      _transition(
        _state.copyWith(phase: StreamPhase.failed, lastFailure: failure, clearFailure: false),
      );
      log.add(EngineEvent.error('stream', failure.toString()));
      return StreamResolutionOutcome(
        resolved: null,
        alternatives: const [],
        failure: failure,
      );
    }

    final selected = candidates.first;
    final shouldRefresh = refreshPolicy.shouldRefresh(selected, now: now);
    if (shouldRefresh) {
      _transition(
        _state.copyWith(
          phase: StreamPhase.refreshingUrl,
          active: selected,
          quality: selected.quality,
        ),
      );
    }
    _transition(
      _state.copyWith(
        phase: StreamPhase.preflighting,
        active: selected,
        quality: selected.quality,
      ),
    );
    return StreamResolutionOutcome(
      resolved: selected,
      alternatives: candidates.skip(1).toList(growable: false),
    );
  }

  /// Records a failed playback/preflight attempt and returns the next
  /// candidate (or null when the chain is exhausted).
  StreamDescriptor? onFailure(
    StreamFailure failure,
    StreamDescriptor failedSource,
    List<StreamDescriptor> alternatives,
  ) {
    health.recordFailure(
      failedSource.providerId,
      latencyMs: failedSource.latencyMs,
    );
    log.add(EngineEvent.error('stream', failure.toString()));

    final next = alternatives
        .where((source) => health.healthOf(source.providerId).isAvailable)
        .where((source) => !source.isExpired)
        .toList(growable: false);

    if (next.isEmpty) {
      _transition(
        _state.copyWith(phase: StreamPhase.failed, lastFailure: failure),
      );
      return null;
    }

    _transition(
      _state.copyWith(
        phase: StreamPhase.fallingBack,
        attempt: _state.attempt + 1,
        active: next.first,
        lastFailure: failure,
      ),
    );
    log.add(
      EngineEvent.info(
        'stream',
        'Falling back to ${next.first.providerId} '
        'for ${next.first.uri == failedSource.uri ? 'same source' : 'alternate source'}',
      ),
    );
    return next.first;
  }

  /// Returns the delay before retrying the *same* source, or null when the
  /// retry budget is exhausted.
  Duration? retryDelay(StreamFailure failure, int maxAttempts) {
    if (!failure.retryable) return null;
    if (_state.attempt + 1 >= maxAttempts) return null;
    final delay = backoff.next(_state.attempt + 1);
    _transition(
      _state.copyWith(
        phase: StreamPhase.waitingRetry,
        attempt: _state.attempt + 1,
        lastFailure: failure,
      ),
    );
    return delay;
  }

  void markSuccess(StreamDescriptor source, {int? latencyMs}) {
    health.recordSuccess(source.providerId, latencyMs: latencyMs);
    _transition(
      _state.copyWith(
        phase: StreamPhase.streaming,
        active: source,
        quality: source.quality,
        clearFailure: true,
      ),
    );
    log.add(
      EngineEvent.info(
        'stream',
        'Streaming from ${source.providerId} (${source.quality.label})',
      ),
    );
  }

  void cancel() {
    _transition(_state.copyWith(phase: StreamPhase.cancelled));
    log.add(EngineEvent.info('stream', 'Streaming cancelled'));
  }

  void reset() {
    _transition(StreamSessionState());
  }
}

class StreamResolutionOutcome {
  final StreamDescriptor? resolved;
  final List<StreamDescriptor> alternatives;
  final StreamFailure? failure;

  const StreamResolutionOutcome({
    required this.resolved,
    required this.alternatives,
    this.failure,
  });

  bool get failed => resolved == null;

  String? get failureReason => failure?.message;
}

/// Convenience helpers shared by the engine providers.
extension StreamDescriptorText on StreamDescriptor {
  /// Short human label: "Provider · 320kbps".
  String get displayLabel {
    final quality = characteristics.compactLabel.isNotEmpty
        ? characteristics.compactLabel
        : quality.label;
    return '$providerId · $quality';
  }

  String get safeUriLabel {
    final uriText = normalizeOptionalString(uri) ?? '';
    if (uriText.isEmpty) return '';
    if (uriText.length <= 72) return uriText;
    return '${uriText.substring(0, 44)}…${uriText.substring(uriText.length - 20)}';
  }
}
