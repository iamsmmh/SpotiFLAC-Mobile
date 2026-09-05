/// Podcast domain values (Feature Group 9).
///
/// Pure data: no Flutter, no SQLite, no HTTP. The repository maps these to the
/// `ec_podcast_subscriptions` / `ec_podcast_episodes` rows declared in
/// `ecosystem_database.dart`, and [RssProvider] builds them from feed XML.
///
/// Row shape is authoritative — every field here maps to a column that already
/// exists in schema v4, so podcasts need no new migration.
library;

/// Where an episode's audio currently lives.
enum EpisodeDownloadState {
  /// Stream-only; no local artifact.
  none,

  /// Queued for download but not started.
  queued,

  /// Bytes are being fetched.
  downloading,

  /// A complete local file exists at `filePath`.
  downloaded,

  /// The last attempt failed; retryable.
  failed;

  static EpisodeDownloadState parse(Object? raw) {
    final value = raw?.toString();
    for (final state in EpisodeDownloadState.values) {
      if (state.name == value) return state;
    }
    return EpisodeDownloadState.none;
  }
}

/// A subscribed podcast feed.
class PodcastSubscription {
  const PodcastSubscription({
    required this.feedUrl,
    required this.title,
    this.author = '',
    this.description = '',
    this.imageUrl,
    this.categories = const <String>[],
    required this.addedAt,
    this.lastCheckedAt,
    this.autoDownload = false,
    this.keepEpisodes = 3,
    this.notifyNew = true,
  });

  /// Canonical feed URL — the primary key.
  final String feedUrl;
  final String title;
  final String author;
  final String description;
  final String? imageUrl;
  final List<String> categories;
  final DateTime addedAt;

  /// Last successful refresh, or null if never fetched since subscribing.
  final DateTime? lastCheckedAt;

  /// Fetch new episodes automatically as they appear.
  final bool autoDownload;

  /// How many downloaded episodes to retain per feed (retention window).
  final int keepEpisodes;

  final bool notifyNew;

  PodcastSubscription copyWith({
    String? title,
    String? author,
    String? description,
    String? imageUrl,
    List<String>? categories,
    DateTime? lastCheckedAt,
    bool? autoDownload,
    int? keepEpisodes,
    bool? notifyNew,
  }) {
    return PodcastSubscription(
      feedUrl: feedUrl,
      title: title ?? this.title,
      author: author ?? this.author,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      categories: categories ?? this.categories,
      addedAt: addedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      autoDownload: autoDownload ?? this.autoDownload,
      keepEpisodes: keepEpisodes ?? this.keepEpisodes,
      notifyNew: notifyNew ?? this.notifyNew,
    );
  }

  Map<String, Object?> toRow() => <String, Object?>{
    'feed_url': feedUrl,
    'title': title,
    'author': author,
    'description': description,
    'image_url': imageUrl,
    'categories': categories.join('\u001f'),
    'added_at': addedAt.toUtc().toIso8601String(),
    'last_checked_at': lastCheckedAt?.toUtc().toIso8601String(),
    'auto_download': autoDownload ? 1 : 0,
    'keep_episodes': keepEpisodes,
    'notify_new': notifyNew ? 1 : 0,
  };

  static PodcastSubscription fromRow(Map<String, Object?> row) {
    final rawCategories = row['categories']?.toString() ?? '';
    return PodcastSubscription(
      feedUrl: row['feed_url']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      author: row['author']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      imageUrl: _nullableString(row['image_url']),
      categories: rawCategories.isEmpty
          ? const <String>[]
          : rawCategories.split('\u001f'),
      addedAt: _parseDate(row['added_at']) ?? DateTime.now().toUtc(),
      lastCheckedAt: _parseDate(row['last_checked_at']),
      autoDownload: _parseBool(row['auto_download']),
      keepEpisodes: _parseInt(row['keep_episodes'], fallback: 3),
      notifyNew: _parseBool(row['notify_new'], fallback: true),
    );
  }
}

/// One episode of a subscribed feed.
class PodcastEpisode {
  const PodcastEpisode({
    required this.episodeKey,
    required this.feedUrl,
    required this.guid,
    required this.title,
    this.description = '',
    required this.audioUrl,
    this.imageUrl,
    this.duration = Duration.zero,
    this.publishedAt,
    this.filePath,
    this.playedPosition = Duration.zero,
    this.isPlayed = false,
    this.downloadState = EpisodeDownloadState.none,
    required this.addedAt,
  });

  /// Stable identity: `sha`-free composite of feed + guid, built by
  /// [buildEpisodeKey] so the same episode never duplicates across refreshes.
  final String episodeKey;
  final String feedUrl;
  final String guid;
  final String title;
  final String description;
  final String audioUrl;
  final String? imageUrl;
  final Duration duration;
  final DateTime? publishedAt;

  /// Absolute path to the downloaded artifact, when [downloadState] is
  /// [EpisodeDownloadState.downloaded].
  final String? filePath;

  /// Resume point.
  final Duration playedPosition;
  final bool isPlayed;
  final EpisodeDownloadState downloadState;
  final DateTime addedAt;

  bool get isDownloaded =>
      downloadState == EpisodeDownloadState.downloaded &&
      (filePath?.isNotEmpty ?? false);

  /// What the player should open: the local file when present, else the
  /// remote URL. This is the single seam that makes offline playback work.
  String get playbackSource => isDownloaded ? filePath! : audioUrl;

  /// Fraction of the episode already heard, clamped to 0..1. Returns 0 when
  /// the feed advertises no duration.
  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    final ratio = playedPosition.inMilliseconds / total;
    if (ratio.isNaN || ratio <= 0) return 0;
    return ratio >= 1 ? 1 : ratio;
  }

  /// How much is left to play.
  Duration get remaining {
    final left = duration - playedPosition;
    return left.isNegative ? Duration.zero : left;
  }

  PodcastEpisode copyWith({
    String? title,
    String? description,
    String? audioUrl,
    String? imageUrl,
    Duration? duration,
    DateTime? publishedAt,
    String? filePath,
    bool clearFilePath = false,
    Duration? playedPosition,
    bool? isPlayed,
    EpisodeDownloadState? downloadState,
  }) {
    return PodcastEpisode(
      episodeKey: episodeKey,
      feedUrl: feedUrl,
      guid: guid,
      title: title ?? this.title,
      description: description ?? this.description,
      audioUrl: audioUrl ?? this.audioUrl,
      imageUrl: imageUrl ?? this.imageUrl,
      duration: duration ?? this.duration,
      publishedAt: publishedAt ?? this.publishedAt,
      filePath: clearFilePath ? null : (filePath ?? this.filePath),
      playedPosition: playedPosition ?? this.playedPosition,
      isPlayed: isPlayed ?? this.isPlayed,
      downloadState: downloadState ?? this.downloadState,
      addedAt: addedAt,
    );
  }

  Map<String, Object?> toRow() => <String, Object?>{
    'episode_key': episodeKey,
    'feed_url': feedUrl,
    'guid': guid,
    'title': title,
    'description': description,
    'audio_url': audioUrl,
    'image_url': imageUrl,
    'duration_seconds': duration.inSeconds,
    'published_at': publishedAt?.toUtc().toIso8601String(),
    'file_path': filePath,
    'played_seconds': playedPosition.inSeconds,
    'is_played': isPlayed ? 1 : 0,
    'download_state': downloadState.name,
    'added_at': addedAt.toUtc().toIso8601String(),
  };

  static PodcastEpisode fromRow(Map<String, Object?> row) {
    return PodcastEpisode(
      episodeKey: row['episode_key']?.toString() ?? '',
      feedUrl: row['feed_url']?.toString() ?? '',
      guid: row['guid']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      audioUrl: row['audio_url']?.toString() ?? '',
      imageUrl: _nullableString(row['image_url']),
      duration: Duration(seconds: _parseInt(row['duration_seconds'])),
      publishedAt: _parseDate(row['published_at']),
      filePath: _nullableString(row['file_path']),
      playedPosition: Duration(seconds: _parseInt(row['played_seconds'])),
      isPlayed: _parseBool(row['is_played']),
      downloadState: EpisodeDownloadState.parse(row['download_state']),
      addedAt: _parseDate(row['added_at']) ?? DateTime.now().toUtc(),
    );
  }
}

/// A parsed feed: channel metadata plus its episodes. Produced by
/// [RssProvider.parse], consumed by [PodcastRepository.refresh].
class PodcastFeed {
  const PodcastFeed({
    required this.feedUrl,
    required this.title,
    this.author = '',
    this.description = '',
    this.imageUrl,
    this.categories = const <String>[],
    this.episodes = const <PodcastEpisode>[],
  });

  final String feedUrl;
  final String title;
  final String author;
  final String description;
  final String? imageUrl;
  final List<String> categories;

  /// Newest first.
  final List<PodcastEpisode> episodes;

  bool get isEmpty => title.isEmpty && episodes.isEmpty;

  /// Builds the subscription record for a first-time subscribe.
  PodcastSubscription toSubscription({
    required DateTime now,
    bool autoDownload = false,
    int keepEpisodes = 3,
    bool notifyNew = true,
  }) {
    return PodcastSubscription(
      feedUrl: feedUrl,
      title: title,
      author: author,
      description: description,
      imageUrl: imageUrl,
      categories: categories,
      addedAt: now,
      lastCheckedAt: now,
      autoDownload: autoDownload,
      keepEpisodes: keepEpisodes,
      notifyNew: notifyNew,
    );
  }
}

/// Result of a feed refresh: which episodes are genuinely new.
class PodcastRefreshResult {
  const PodcastRefreshResult({
    required this.feedUrl,
    this.newEpisodes = const <PodcastEpisode>[],
    this.totalEpisodes = 0,
    this.failed = false,
    this.error,
  });

  final String feedUrl;
  final List<PodcastEpisode> newEpisodes;
  final int totalEpisodes;
  final bool failed;
  final String? error;

  bool get hasNewEpisodes => newEpisodes.isNotEmpty;
}

/// Stable per-episode identity.
///
/// Feeds are inconsistent: some rotate `guid`s, some omit them entirely. We
/// prefer the guid, fall back to the enclosure URL, and finally to the title,
/// always namespaced by the feed so two podcasts can never collide.
String buildEpisodeKey({
  required String feedUrl,
  String guid = '',
  String audioUrl = '',
  String title = '',
}) {
  final discriminator = <String>[guid, audioUrl, title]
      .map((value) => value.trim())
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');
  return '$feedUrl\u001f$discriminator';
}

// ---------------------------------------------------------------------------
// Row coercion helpers (SQLite returns loosely typed values)
// ---------------------------------------------------------------------------

String? _nullableString(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return null;
  return text;
}

DateTime? _parseDate(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text)?.toUtc();
}

int _parseInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _parseBool(Object? value, {bool fallback = false}) {
  if (value is num) return value != 0;
  if (value is bool) return value;
  final text = value?.toString();
  if (text == null || text.isEmpty) return fallback;
  return text == '1' || text.toLowerCase() == 'true';
}
