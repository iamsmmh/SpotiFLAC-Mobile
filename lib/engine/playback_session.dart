import 'dart:math' as math;

/// Playback session state: queue, shuffle/repeat, transport savepoints, and
/// listening statistics.
///
/// This is the engine-side counterpart of the audio_service player session.
/// The player persists the raw queue for OS-level restore; this model adds the
/// *engine* dimensions the player does not know about — playback mode, quality
/// level, provider, volume/rate/balance — plus honest recovery semantics:
/// a savepoint restores paused, and the UI asks the user before resuming.
library;

enum SessionRepeatMode {
  none('Off'),
  one('Repeat one'),
  all('Repeat queue');

  const SessionRepeatMode(this.label);

  final String label;

  SessionRepeatMode next() => switch (this) {
    SessionRepeatMode.none => SessionRepeatMode.one,
    SessionRepeatMode.one => SessionRepeatMode.all,
    SessionRepeatMode.all => SessionRepeatMode.none,
  };

  static SessionRepeatMode fromName(String? name) =>
      SessionRepeatMode.values.firstWhere(
        (mode) => mode.name == name,
        orElse: () => SessionRepeatMode.none,
      );
}

enum SessionShuffleMode { off('Off'), on('On') }

/// One queue entry at engine level. Mirrors `PlayableMedia` but is
/// engine-owned so the savepoint never depends on the audio player's schema.
class SessionQueueEntry {
  final String id;
  final String trackId;
  final String providerId;
  final String title;
  final String artist;
  final String album;
  final String? artUri;
  final int durationSeconds;
  final String playbackMode;
  final String? qualityLabel;
  final String? localPath;
  final String? streamUrl;

  const SessionQueueEntry({
    required this.id,
    required this.trackId,
    required this.providerId,
    required this.title,
    required this.artist,
    this.album = '',
    this.artUri,
    this.durationSeconds = 0,
    this.playbackMode = 'smart',
    this.qualityLabel,
    this.localPath,
    this.streamUrl,
  });

  bool get isPlayable =>
      (localPath != null && localPath!.trim().isNotEmpty) ||
      (streamUrl != null && streamUrl!.trim().isNotEmpty);

  Map<String, dynamic> toJson() => {
    'id': id,
    'track_id': trackId,
    'provider': providerId,
    'title': title,
    'artist': artist,
    if (album.isNotEmpty) 'album': album,
    if (artUri != null) 'art_uri': artUri,
    'duration_seconds': durationSeconds,
    'playback_mode': playbackMode,
    if (qualityLabel != null) 'quality': qualityLabel,
    if (localPath != null) 'local_path': localPath,
    if (streamUrl != null) 'stream_url': streamUrl,
  };

  factory SessionQueueEntry.fromJson(Map<String, dynamic> json) =>
      SessionQueueEntry(
        id: json['id']?.toString() ?? '',
        trackId: json['track_id']?.toString() ?? '',
        providerId: json['provider']?.toString() ?? 'unknown',
        title: json['title']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        album: json['album']?.toString() ?? '',
        artUri: json['art_uri']?.toString(),
        durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
        playbackMode: json['playback_mode']?.toString() ?? 'smart',
        qualityLabel: json['quality']?.toString(),
        localPath: json['local_path']?.toString(),
        streamUrl: json['stream_url']?.toString(),
      );
}

/// Deterministic planning helpers for queue navigation.
class QueuePlanner {
  const QueuePlanner._();

  /// Fisher–Yates with a seedable [math.Random] so a saved session can
  /// reproduce its shuffle order exactly (recovery == user expectation).
  static List<int> shuffledIndices(int length, {int? seed}) {
    if (length <= 1) return List<int>.generate(length, (i) => i);
    final random = seed == null ? math.Random() : math.Random(seed);
    final indices = List<int>.generate(length, (i) => i);
    for (var i = length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final swap = indices[i];
      indices[i] = indices[j];
      indices[j] = swap;
    }
    return indices;
  }

  static int nextIndex({
    required int current,
    required int length,
    required SessionRepeatMode repeat,
    required bool shuffle,
    List<int>? shuffleOrder,
  }) {
    if (length == 0) return -1;
    if (shuffle && shuffleOrder != null && shuffleOrder.isNotEmpty) {
      return shuffleOrder[(current + 1) % shuffleOrder.length];
    }
    if (current + 1 < length) return current + 1;
    if (repeat == SessionRepeatMode.all) return 0;
    return -1;
  }

  static int previousIndex({
    required int current,
    required int length,
    required SessionRepeatMode repeat,
    required bool shuffle,
    List<int>? shuffleOrder,
  }) {
    if (length == 0) return -1;
    if (shuffle && shuffleOrder != null && shuffleOrder.isNotEmpty) {
      final position = shuffleOrder.indexOf(current);
      if (position <= 0) {
        return repeat == SessionRepeatMode.all
            ? shuffleOrder.last
            : shuffleOrder.first;
      }
      return shuffleOrder[position - 1];
    }
    if (current - 1 >= 0) return current - 1;
    if (repeat == SessionRepeatMode.all) return length - 1;
    return -1;
  }
}

const int playbackSavepointVersion = 1;

/// Snapshot of the engine session, safe to persist and safe to restore.
///
/// [sanitize] drops queue entries that have no resolvable source (the file is
/// gone and the stream URL expired), so recovery never presents a dead queue.
class PlaybackSavepoint {
  final int version;
  final List<SessionQueueEntry> entries;
  final int currentIndex;
  final int positionMs;
  final SessionShuffleMode shuffle;
  final SessionRepeatMode repeat;
  final String playbackMode;
  final double volume;
  final double playbackRate;
  final double balance;
  final DateTime savedAt;

  PlaybackSavepoint({
    this.version = playbackSavepointVersion,
    required this.entries,
    this.currentIndex = 0,
    this.positionMs = 0,
    this.shuffle = SessionShuffleMode.off,
    this.repeat = SessionRepeatMode.none,
    this.playbackMode = 'smart',
    this.volume = 1.0,
    this.playbackRate = 1.0,
    this.balance = 0.0,
    DateTime? savedAt,
  }) : savedAt = savedAt ?? DateTime.now();

  bool get isEmpty => entries.isEmpty;

  PlaybackSavepoint sanitize({
    DateTime? now,
    Duration maxStreamAge = const Duration(hours: 6),
  }) {
    final effectiveNow = now ?? DateTime.now();
    final alive = <SessionQueueEntry>[];
    for (final entry in entries) {
      if (entry.localPath != null && entry.localPath!.trim().isNotEmpty) {
        alive.add(entry);
        continue;
      }
      final streamUrl = entry.streamUrl;
      if (streamUrl == null || streamUrl.trim().isEmpty) continue;
      // Stream URLs are ephemeral by design; restore keeps them only when
      // fresh enough to plausibly still work.
      if (effectiveNow.difference(savedAt) <= maxStreamAge) {
        alive.add(entry);
      }
    }
    return PlaybackSavepoint(
      version: version,
      entries: alive,
      currentIndex: currentIndex.clamp(0, math.max(0, alive.length - 1)),
      positionMs: positionMs,
      shuffle: shuffle,
      repeat: repeat,
      playbackMode: playbackMode,
      volume: volume,
      playbackRate: playbackRate,
      balance: balance,
      savedAt: savedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'entries': entries.map((e) => e.toJson()).toList(growable: false),
    'current_index': currentIndex,
    'position_ms': positionMs,
    'shuffle': shuffle.name,
    'repeat': repeat.name,
    'playback_mode': playbackMode,
    'volume': volume,
    'playback_rate': playbackRate,
    'balance': balance,
    'saved_at': savedAt.toUtc().toIso8601String(),
  };

  factory PlaybackSavepoint.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    final entries = rawEntries is List
        ? rawEntries
              .whereType<Map<String, dynamic>>()
              .map(SessionQueueEntry.fromJson)
              .toList(growable: false)
        : <SessionQueueEntry>[];
    return PlaybackSavepoint(
      version: (json['version'] as num?)?.toInt() ?? playbackSavepointVersion,
      entries: entries,
      currentIndex: (json['current_index'] as num?)?.toInt() ?? 0,
      positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
      shuffle: SessionShuffleMode.values.firstWhere(
        (mode) => mode.name == json['shuffle'],
        orElse: () => SessionShuffleMode.off,
      ),
      repeat: SessionRepeatMode.fromName(json['repeat']?.toString()),
      playbackMode: json['playback_mode']?.toString() ?? 'smart',
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      playbackRate: (json['playback_rate'] as num?)?.toDouble() ?? 1.0,
      balance: (json['balance'] as num?)?.toDouble() ?? 0.0,
      savedAt: DateTime.tryParse(json['saved_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

/// Identity of a track as observed by the player (used for per-track stats).
class TrackPlayIdentity {
  final String trackId;
  final String title;
  final String artist;
  final String album;

  const TrackPlayIdentity({
    required this.trackId,
    required this.title,
    required this.artist,
    this.album = '',
  });
}

/// Per-track listening record. Local only — never leaves the device.
class TrackPlayStat {
  final String trackId;
  final String title;
  final String artist;
  final String album;
  final int playCount;
  final int listenedMs;
  final DateTime? lastPlayedAt;

  const TrackPlayStat({
    required this.trackId,
    required this.title,
    required this.artist,
    this.album = '',
    this.playCount = 0,
    this.listenedMs = 0,
    this.lastPlayedAt,
  });

  TrackPlayStat recordPlay(DateTime at) => TrackPlayStat(
    trackId: trackId,
    title: title,
    artist: artist,
    album: album,
    playCount: playCount + 1,
    listenedMs: listenedMs,
    lastPlayedAt: at,
  );

  TrackPlayStat recordListen(Duration elapsed, DateTime at) =>
      TrackPlayStat(
        trackId: trackId,
        title: title,
        artist: artist,
        album: album,
        playCount: playCount,
        listenedMs: listenedMs + elapsed.inMilliseconds,
        lastPlayedAt: at,
      );

  Map<String, dynamic> toJson() => {
    'track_id': trackId,
    'title': title,
    'artist': artist,
    if (album.isNotEmpty) 'album': album,
    'play_count': playCount,
    'listened_ms': listenedMs,
    if (lastPlayedAt != null)
      'last_played_at': lastPlayedAt!.toUtc().toIso8601String(),
  };

  factory TrackPlayStat.fromJson(Map<String, dynamic> json) =>
      TrackPlayStat(
        trackId: json['track_id']?.toString() ?? '',
        title: json['title']?.toString() ?? 'Unknown title',
        artist: json['artist']?.toString() ?? 'Unknown artist',
        album: json['album']?.toString() ?? '',
        playCount: (json['play_count'] as num?)?.toInt() ?? 0,
        listenedMs: (json['listened_ms'] as num?)?.toInt() ?? 0,
        lastPlayedAt: DateTime.tryParse(json['last_played_at']?.toString() ?? ''),
      );
}

/// Very small listening-statistics accumulator backed by the settings store.
///
/// Privacy-first: never leaves the device, no account, no telemetry. The
/// tracker records only anonymous counters, UTC day buckets, and lightweight
/// per-track counts so the app can show Recently Played / Most Played without
/// uploading anything.
class ListeningStats {
  final int plays;
  final int skips;
  final int listenedMs;
  final Map<String, int> listenedMsPerDay;
  final Map<String, int> playsPerDay;
  final Map<String, TrackPlayStat> trackStats;
  final DateTime? lastPlayedAt;

  const ListeningStats({
    this.plays = 0,
    this.skips = 0,
    this.listenedMs = 0,
    this.listenedMsPerDay = const {},
    this.playsPerDay = const {},
    this.trackStats = const {},
    this.lastPlayedAt,
  });

  factory ListeningStats.empty() => const ListeningStats();

  static String dayKey(DateTime utc) =>
      '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';

  ListeningStats recordPlay({DateTime? at}) {
    final time = (at ?? DateTime.now()).toUtc();
    final day = dayKey(time);
    return ListeningStats(
      plays: plays + 1,
      skips: skips,
      listenedMs: listenedMs,
      listenedMsPerDay: listenedMsPerDay,
      playsPerDay: _increment(playsPerDay, day),
      trackStats: trackStats,
      lastPlayedAt: time,
    );
  }

  ListeningStats recordSkip({DateTime? at}) => ListeningStats(
    plays: plays,
    skips: skips + 1,
    listenedMs: listenedMs,
    listenedMsPerDay: listenedMsPerDay,
    playsPerDay: playsPerDay,
    trackStats: trackStats,
    lastPlayedAt: lastPlayedAt,
  );

  /// Accumulates listened time; never goes backwards on a seek.
  ListeningStats recordListen(Duration elapsed, {DateTime? at}) {
    if (elapsed <= Duration.zero) return this;
    final day = dayKey((at ?? DateTime.now()).toUtc());
    return ListeningStats(
      plays: plays,
      skips: skips,
      listenedMs: listenedMs + elapsed.inMilliseconds,
      // The per-day bucket holds milliseconds, matching the total: two 90s
      // listens must read as 180000 ms "today", not 2.
      listenedMsPerDay: _increment(
        listenedMsPerDay,
        day,
        elapsed.inMilliseconds,
      ),
      playsPerDay: playsPerDay,
      trackStats: trackStats,
      lastPlayedAt: lastPlayedAt,
    );
  }

  /// Records a track start (increments both the total and the per-track count).
  ListeningStats recordTrackPlay(
    TrackPlayIdentity identity, {
    DateTime? at,
  }) {
    final time = (at ?? DateTime.now()).toUtc();
    final base = recordPlay(at: time);
    final stat = _trackStat(identity).recordPlay(time);
    return base.copyWithTrackStats(_upsertTrack(stat));
  }

  /// Records listened time for a specific track.
  ListeningStats recordTrackListen(
    TrackPlayIdentity identity,
    Duration elapsed, {
    DateTime? at,
  }) {
    if (elapsed <= Duration.zero) return this;
    final time = (at ?? DateTime.now()).toUtc();
    final base = recordListen(elapsed, at: time);
    final stat = _trackStat(identity).recordListen(elapsed, time);
    return base.copyWithTrackStats(_upsertTrack(stat));
  }

  TrackPlayStat _trackStat(TrackPlayIdentity identity) =>
      trackStats[identity.trackId] ??
      TrackPlayStat(
        trackId: identity.trackId,
        title: identity.title,
        artist: identity.artist,
        album: identity.album,
      );

  Map<String, TrackPlayStat> _upsertTrack(TrackPlayStat stat) {
    final copy = Map<String, TrackPlayStat>.from(trackStats);
    copy[stat.trackId] = stat;
    return Map.unmodifiable(copy);
  }

  ListeningStats copyWithTrackStats(Map<String, TrackPlayStat> stats) =>
      ListeningStats(
        plays: plays,
        skips: skips,
        listenedMs: listenedMs,
        listenedMsPerDay: listenedMsPerDay,
        playsPerDay: playsPerDay,
        trackStats: stats,
        lastPlayedAt: lastPlayedAt,
      );

  /// Tracks ordered by most recently played (descending).
  List<TrackPlayStat> get recentTracks {
    final list = trackStats.values.toList(growable: false);
    list.sort((a, b) {
      final at = a.lastPlayedAt;
      final bt = b.lastPlayedAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return list;
  }

  /// Tracks ordered by play count (descending), then most recently played.
  List<TrackPlayStat> get mostPlayedTracks {
    final list = trackStats.values.toList(growable: false);
    list.sort((a, b) {
      final byCount = b.playCount.compareTo(a.playCount);
      if (byCount != 0) return byCount;
      final at = a.lastPlayedAt;
      final bt = b.lastPlayedAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return list;
  }

  /// Adds [amount] (default 1) to a per-day bucket. Callers pass their own
  /// unit: plays count by 1, listened time by milliseconds.
  static Map<String, int> _increment(
    Map<String, int> source,
    String day, [
    int amount = 1,
  ]) {
    if (amount <= 0) return source;
    final copy = Map<String, int>.from(source);
    copy[day] = (copy[day] ?? 0) + amount;
    return Map.unmodifiable(copy);
  }

  int get listenedTodayMs {
    final today = listenedMsPerDay[dayKey(DateTime.now().toUtc())] ?? 0;
    return today;
  }

  int get playsToday {
    final today = playsPerDay[dayKey(DateTime.now().toUtc())] ?? 0;
    return today;
  }

  /// Consecutive days (ending today or yesterday) with at least one play.
  int get streakDays {
    final keys = playsPerDay.keys.toSet();
    if (keys.isEmpty) return 0;
    var cursor = DateTime.now().toUtc();
    if (!keys.contains(dayKey(cursor))) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!keys.contains(dayKey(cursor))) return 0;
    }
    var streak = 0;
    while (keys.contains(dayKey(cursor))) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
      if (streak > 3650) break; // safety: corrupted data must not hang recovery
    }
    return streak;
  }

  Map<String, dynamic> toJson() => {
    'plays': plays,
    'skips': skips,
    'listened_ms': listenedMs,
    'listened_ms_per_day': listenedMsPerDay,
    'plays_per_day': playsPerDay,
    'track_stats': trackStats.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    if (lastPlayedAt != null)
      'last_played_at': lastPlayedAt!.toUtc().toIso8601String(),
  };

  factory ListeningStats.fromJson(Map<String, dynamic> json) {
    Map<String, int> readMap(String key) {
      final raw = json[key];
      if (raw is! Map) return const {};
      return Map<String, int>.unmodifiable({
        for (final entry in raw.entries)
          if (entry.value is num) entry.key.toString(): (entry.value as num).toInt(),
      });
    }

    Map<String, TrackPlayStat> readTracks() {
      final raw = json['track_stats'];
      if (raw is! Map) return const {};
      return Map<String, TrackPlayStat>.unmodifiable({
        for (final entry in raw.entries)
          if (entry.value is Map)
            entry.key: TrackPlayStat.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      });
    }

    return ListeningStats(
      plays: (json['plays'] as num?)?.toInt() ?? 0,
      skips: (json['skips'] as num?)?.toInt() ?? 0,
      listenedMs: (json['listened_ms'] as num?)?.toInt() ?? 0,
      listenedMsPerDay: readMap('listened_ms_per_day'),
      playsPerDay: readMap('plays_per_day'),
      trackStats: readTracks(),
      lastPlayedAt: DateTime.tryParse(json['last_played_at']?.toString() ?? ''),
    );
  }
}

/// Safe resume prompt state (the app must never auto-resume after a kill).
enum ResumeIntent { none, paused, resumePlaying }
