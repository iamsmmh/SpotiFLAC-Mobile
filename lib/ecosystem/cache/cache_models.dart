/// Stream cache models (Feature Group 7).
///
/// The row shape mirrors the `ec_stream_cache` table (see
/// `ecosystem_database.dart`, schema v1 + v5) — one row per cached audio
/// artifact, keyed by the canonical track identity so any source that
/// resolved the same logical track shares one offline copy.
library;

/// Audio formats the cache understands. Sniffing is header-based and
/// deliberately cheap (16 bytes): cache entries are re-validated by digest
/// before promotion, so sniffing only steers file extensions and labels.
enum CachedAudioFormat {
  flac('FLAC', 'flac'),
  aac('AAC', 'aac'),
  mp3('MP3', 'mp3'),
  opus('Opus', 'opus'),
  ogg('Ogg Vorbis', 'ogg'),
  m4a('M4A', 'm4a'),
  wav('WAV', 'wav'),
  unknown('Unknown', 'bin');

  const CachedAudioFormat(this.label, this.fileExtension);

  final String label;
  final String fileExtension;

  static CachedAudioFormat fromName(Object? name) {
    final text = name?.toString().trim().toLowerCase() ?? '';
    for (final format in CachedAudioFormat.values) {
      if (format.name == text) return format;
    }
    return CachedAudioFormat.unknown;
  }

  /// Maps a provider codec/container label (`FLAC`, `mp4a.40.2`, `TS`, …).
  static CachedAudioFormat fromCodecLabel(Object? codec) {
    final text = codec?.toString().trim().toLowerCase() ?? '';
    if (text.isEmpty) return CachedAudioFormat.unknown;
    if (text.contains('flac')) return CachedAudioFormat.flac;
    if (text.contains('opus')) return CachedAudioFormat.opus;
    if (text.contains('vorbis')) return CachedAudioFormat.ogg;
    if (text.contains('mp3') || text.contains('mpeg')) {
      return CachedAudioFormat.mp3;
    }
    if (text.contains('mp4a') || text.contains('aac')) {
      return CachedAudioFormat.aac;
    }
    if (text.contains('m4a') || text.contains('mp4') ||
        text.contains('alac')) {
      return CachedAudioFormat.m4a;
    }
    if (text.contains('wav')) return CachedAudioFormat.wav;
    return CachedAudioFormat.unknown;
  }

  /// Magic-byte sniffing over the first bytes of a payload.
  static CachedAudioFormat sniff(List<int> head) {
    if (head.length >= 4) {
      // fLaC
      if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 &&
          head[3] == 0x43) {
        return CachedAudioFormat.flac;
      }
      // OggS (covers Vorbis and Opus; OpusHead disambiguates)
      if (head[0] == 0x4F && head[1] == 0x67 && head[2] == 0x67 &&
          head[3] == 0x53) {
        if (_contains(head, const [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61,
            0x64], 28)) {
          return CachedAudioFormat.opus;
        }
        return CachedAudioFormat.ogg;
      }
      // RIFF/WAVE
      if (head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 &&
          head[3] == 0x46) {
        return CachedAudioFormat.wav;
      }
    }
    if (head.length >= 3) {
      // ID3 tagged MP3 (or another ID3 container — MP3 is the common case).
      if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
        return CachedAudioFormat.mp3;
      }
      // ADTS AAC: 0xFF 0xF1 / 0xFF 0xF9 (sync words)
      if (head[0] == 0xFF && (head[1] == 0xF1 || head[1] == 0xF9)) {
        return CachedAudioFormat.aac;
      }
      // Raw MP3 frame sync (MPEG-1 layer III without ID3).
      if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
        return CachedAudioFormat.mp3;
      }
    }
    // ISO-BMFF: 'ftyp' at offset 4 (M4A / MP4 audio).
    if (head.length >= 8 &&
        head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 &&
        head[7] == 0x70) {
      return CachedAudioFormat.m4a;
    }
    return CachedAudioFormat.unknown;
  }

  static bool _contains(List<int> haystack, List<int> needle, int from) {
    if (haystack.length < from + needle.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[from + i] != needle[i]) return false;
    }
    return true;
  }
}

/// One cached stream artifact (row of `ec_stream_cache`).
class CacheEntry {
  const CacheEntry({
    required this.cacheKey,
    required this.trackKey,
    required this.title,
    required this.artist,
    required this.fileName,
    required this.audioFormat,
    required this.bytes,
    required this.durationMs,
    required this.createdAt,
    required this.lastAccessedAt,
    this.accessCount = 0,
    this.pinned = false,
    this.complete = false,
    this.sourceUrl,
    this.sha256 = '',
    this.encrypted = false,
    this.ivHex = '',
  });

  final String cacheKey;
  final String trackKey;
  final String title;
  final String artist;

  /// File name inside the cache directory (not a full path).
  final String fileName;
  final CachedAudioFormat audioFormat;
  final int bytes;
  final int durationMs;
  final DateTime createdAt;
  final DateTime lastAccessedAt;
  final int accessCount;
  final bool pinned;

  /// False while the background fetch is still running.
  final bool complete;
  final String? sourceUrl;

  /// Hex digest recorded at completion; empty for unverified entries.
  final String sha256;

  /// At-rest encryption marker; the IV lives in [ivHex].
  final bool encrypted;
  final String ivHex;

  bool get isPlayable => complete && fileName.isNotEmpty;

  CacheEntry copyWith({
    int? bytes,
    int? durationMs,
    DateTime? lastAccessedAt,
    int? accessCount,
    bool? pinned,
    bool? complete,
    String? sha256,
    String? ivHex,
    CachedAudioFormat? audioFormat,
    String? fileName,
  }) => CacheEntry(
    cacheKey: cacheKey,
    trackKey: trackKey,
    title: title,
    artist: artist,
    fileName: fileName ?? this.fileName,
    audioFormat: audioFormat ?? this.audioFormat,
    bytes: bytes ?? this.bytes,
    durationMs: durationMs ?? this.durationMs,
    createdAt: createdAt,
    lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    accessCount: accessCount ?? this.accessCount,
    pinned: pinned ?? this.pinned,
    complete: complete ?? this.complete,
    sourceUrl: sourceUrl,
    sha256: sha256 ?? this.sha256,
    encrypted: encrypted,
    ivHex: ivHex ?? this.ivHex,
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'cache_key': cacheKey,
    'track_key': trackKey,
    'title': title,
    'artist': artist,
    'file_name': fileName,
    'audio_format': audioFormat.name,
    'bytes': bytes,
    'duration_ms': durationMs,
    'source_url': sourceUrl,
    'created_at': createdAt.toUtc().toIso8601String(),
    'last_accessed_at': lastAccessedAt.toUtc().toIso8601String(),
    'access_count': accessCount,
    'pinned': pinned ? 1 : 0,
    'complete': complete ? 1 : 0,
    'sha256': sha256,
    'encrypted': encrypted ? 1 : 0,
    'iv_hex': ivHex,
  };

  static CacheEntry fromRow(Map<String, Object?> row) => CacheEntry(
    cacheKey: row['cache_key']?.toString() ?? '',
    trackKey: row['track_key']?.toString() ?? '',
    title: row['title']?.toString() ?? '',
    artist: row['artist']?.toString() ?? '',
    fileName: row['file_name']?.toString() ?? '',
    audioFormat: CachedAudioFormat.fromName(row['audio_format']),
    bytes: (row['bytes'] as num?)?.toInt() ?? 0,
    durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
    sourceUrl: row['source_url']?.toString(),
    createdAt:
        DateTime.tryParse(row['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    lastAccessedAt:
        DateTime.tryParse(row['last_accessed_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    accessCount: (row['access_count'] as num?)?.toInt() ?? 0,
    pinned: row['pinned'] == 1 || row['pinned'] == true,
    complete: row['complete'] == 1 || row['complete'] == true,
    sha256: row['sha256']?.toString() ?? '',
    encrypted: row['encrypted'] == 1 || row['encrypted'] == true,
    ivHex: row['iv_hex']?.toString() ?? '',
  );
}

/// A cache hit ready for playback.
class CacheHit {
  const CacheHit({required this.entry, required this.filePath});

  final CacheEntry entry;

  /// Absolute path of a *playable* file (decrypted copy when the entry is
  /// encrypted at rest — the decrypted temp file is managed by the cache
  /// manager and swept on stop).
  final String filePath;
}

/// Everything the manager needs to fetch one artifact in the background.
class CacheFetchRequest {
  const CacheFetchRequest({
    required this.trackKey,
    required this.title,
    required this.artist,
    required this.url,
    this.headers = const <String, String>{},
    this.formatHint,
    this.bitrateKbps = 0,
    this.durationMs = 0,
    this.sourceUrl,
  });

  final String trackKey;
  final String title;
  final String artist;
  final String url;
  final Map<String, String> headers;
  final CachedAudioFormat? formatHint;
  final int bitrateKbps;
  final int durationMs;
  final String? sourceUrl;
}
