/// Music recognition domain values (Feature Group 10).
///
/// Pure data shared by the fingerprint engine, the provider adapters and the
/// history repository. Maps onto the `ec_recognition_history` table declared in
/// schema v1, so recognition needs no migration.
library;

import 'dart:convert';

/// An acoustic fingerprint plus the metadata a provider needs to match it.
class AudioFingerprint {
  const AudioFingerprint({
    required this.fingerprint,
    required this.duration,
    this.algorithm = 'chromaprint',
    this.sampleRate = 44100,
    this.channels = 1,
  });

  /// Provider-specific encoded fingerprint (base64 for Chromaprint).
  final String fingerprint;

  /// Duration of the analysed audio — matchers weight this heavily.
  final Duration duration;

  final String algorithm;
  final int sampleRate;
  final int channels;

  bool get isEmpty => fingerprint.isEmpty || duration <= Duration.zero;
}

/// A candidate identification.
class RecognitionResult {
  const RecognitionResult({
    required this.resultId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.providerId = '',
    this.confidence = 0,
    this.artworkUrl,
    this.releaseDate,
    this.isrc,
    this.externalIds = const <String, String>{},
    required this.identifiedAt,
  });

  /// Stable id: provider-scoped so two backends can both store a hit for the
  /// same song without overwriting each other.
  final String resultId;

  final String title;
  final String artist;
  final String album;
  final String providerId;

  /// 0..1 match score.
  final double confidence;

  final String? artworkUrl;
  final String? releaseDate;

  /// Recording identifier, when the provider supplies one — this is what lets
  /// "add to library" find a real downloadable track.
  final String? isrc;

  /// Provider-native ids (`musicbrainz`, `acoustid`, `spotify`, ...) used to
  /// deep-link into search or an extension.
  final Map<String, String> externalIds;

  final DateTime identifiedAt;

  /// A single-line label for the UI and for seeding a catalogue search.
  String get displayLabel =>
      artist.isEmpty ? title : '$artist \u2013 $title';

  /// Query string used when handing the result to the app's search.
  String get searchQuery => <String>[
    artist,
    title,
  ].where((part) => part.isNotEmpty).join(' ').trim();

  Map<String, Object?> toRow() => <String, Object?>{
    'result_id': resultId,
    'title': title,
    'artist': artist,
    'album': album,
    'provider_id': providerId,
    'confidence': confidence,
    'identified_at': identifiedAt.toUtc().toIso8601String(),
    'payload_json': jsonEncode(<String, Object?>{
      if (artworkUrl != null) 'artworkUrl': artworkUrl,
      if (releaseDate != null) 'releaseDate': releaseDate,
      if (isrc != null) 'isrc': isrc,
      'externalIds': externalIds,
    }),
  };

  static RecognitionResult fromRow(Map<String, Object?> row) {
    final payload = _decodePayload(row['payload_json']);
    final rawExternal = payload['externalIds'];
    return RecognitionResult(
      resultId: row['result_id']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      artist: row['artist']?.toString() ?? '',
      album: row['album']?.toString() ?? '',
      providerId: row['provider_id']?.toString() ?? '',
      confidence: row['confidence'] is num
          ? (row['confidence']! as num).toDouble()
          : 0,
      artworkUrl: payload['artworkUrl']?.toString(),
      releaseDate: payload['releaseDate']?.toString(),
      isrc: payload['isrc']?.toString(),
      externalIds: rawExternal is Map
          ? Map<String, Object?>.from(rawExternal).map(
              (key, value) => MapEntry(key, value?.toString() ?? ''),
            )
          : const <String, String>{},
      identifiedAt:
          DateTime.tryParse(row['identified_at']?.toString() ?? '')?.toUtc() ??
              DateTime.now().toUtc(),
    );
  }

  static Map<String, Object?> _decodePayload(Object? raw) {
    final text = raw?.toString();
    if (text == null || text.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      // Corrupt payload should never break history rendering.
    }
    return const <String, Object?>{};
  }
}

/// Why a recognition attempt ended the way it did.
enum RecognitionOutcome {
  /// At least one candidate was returned.
  matched,

  /// The provider answered but recognised nothing.
  noMatch,

  /// The provider is not usable (missing key, unreachable, quota).
  unavailable,

  /// Fingerprinting failed before any provider was queried.
  fingerprintFailed,

  /// The user cancelled.
  cancelled,
}

/// Outcome of one identification attempt.
class RecognitionAttempt {
  const RecognitionAttempt({
    required this.outcome,
    this.results = const <RecognitionResult>[],
    this.providerId = '',
    this.message,
  });

  final RecognitionOutcome outcome;

  /// Best match first.
  final List<RecognitionResult> results;

  final String providerId;
  final String? message;

  bool get isMatch =>
      outcome == RecognitionOutcome.matched && results.isNotEmpty;

  RecognitionResult? get best => results.isEmpty ? null : results.first;

  static const RecognitionAttempt noMatch =
      RecognitionAttempt(outcome: RecognitionOutcome.noMatch);
}

/// Raw captured audio handed to the fingerprint engine.
class RecognitionSample {
  const RecognitionSample({
    required this.filePath,
    required this.duration,
    this.sampleRate = 44100,
    this.channels = 1,
  });

  /// Path to a decoded/temporary audio file on disk.
  final String filePath;
  final Duration duration;
  final int sampleRate;
  final int channels;
}
