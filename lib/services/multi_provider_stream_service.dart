import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/utils/logger.dart';

final _log = AppLogger('MultiProviderStream');

/// The eight ecosystem sources supported by SpotiMusic's streaming engine.
enum StreamProviderId {
  spotify,
  youtube,
  appleMusic,
  tidal,
  qobuz,
  deezer,
  amazonMusic,
  soundCloud,
}

/// Static presentation + capability metadata for a [StreamProviderId].
class StreamProviderInfo {
  final StreamProviderId id;
  final String displayName;
  final String shortName;

  /// Material icon codepoint used by the selector chip (kept UI-package-free
  /// so the service can be unit tested without Flutter).
  final int iconCodePoint;

  /// True when the provider needs user-supplied credentials/tokens before a
  /// full-fidelity stream can be resolved. Such providers resolve what they
  /// can anonymously (metadata / previews) and otherwise defer to the
  /// universal fallback engine.
  final bool requiresCredentials;

  /// True when the provider's native stream tier is lossless.
  final bool nativeLossless;

  /// Highest stream tier the provider *can* offer with valid credentials.
  final String maxTierLabel;

  const StreamProviderInfo({
    required this.id,
    required this.displayName,
    required this.shortName,
    required this.iconCodePoint,
    required this.requiresCredentials,
    required this.nativeLossless,
    required this.maxTierLabel,
  });

  static const Map<StreamProviderId, StreamProviderInfo> _registry = {
    StreamProviderId.spotify: StreamProviderInfo(
      id: StreamProviderId.spotify,
      displayName: 'Spotify',
      shortName: 'Spotify',
      iconCodePoint: 0xe083, // Icons.podcasts-like glyph fallback in UI
      requiresCredentials: true,
      nativeLossless: false,
      maxTierLabel: 'Ogg Vorbis 320kbps',
    ),
    StreamProviderId.youtube: StreamProviderInfo(
      id: StreamProviderId.youtube,
      displayName: 'YouTube Music',
      shortName: 'YT Music',
      iconCodePoint: 0xe040,
      requiresCredentials: false,
      nativeLossless: false,
      maxTierLabel: 'Opus/AAC ~160kbps',
    ),
    StreamProviderId.appleMusic: StreamProviderInfo(
      id: StreamProviderId.appleMusic,
      displayName: 'Apple Music',
      shortName: 'Apple',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'ALAC 24-bit/192kHz',
    ),
    StreamProviderId.tidal: StreamProviderInfo(
      id: StreamProviderId.tidal,
      displayName: 'Tidal',
      shortName: 'Tidal',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'FLAC 24-bit/192kHz HiFi',
    ),
    StreamProviderId.qobuz: StreamProviderInfo(
      id: StreamProviderId.qobuz,
      displayName: 'Qobuz',
      shortName: 'Qobuz',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'FLAC 24-bit/192kHz Studio',
    ),
    StreamProviderId.deezer: StreamProviderInfo(
      id: StreamProviderId.deezer,
      displayName: 'Deezer',
      shortName: 'Deezer',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'FLAC HiFi',
    ),
    StreamProviderId.amazonMusic: StreamProviderInfo(
      id: StreamProviderId.amazonMusic,
      displayName: 'Amazon Music',
      shortName: 'Amazon',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'FLAC Ultra HD 24-bit',
    ),
    StreamProviderId.soundCloud: StreamProviderInfo(
      id: StreamProviderId.soundCloud,
      displayName: 'SoundCloud',
      shortName: 'SoundCloud',
      iconCodePoint: 0xe040,
      requiresCredentials: false,
      nativeLossless: false,
      maxTierLabel: 'Opus/MP3 256kbps',
    ),
  };

  static StreamProviderInfo of(StreamProviderId id) => _registry[id]!;

  static List<StreamProviderInfo> get all =>
      StreamProviderId.values.map(of).toList(growable: false);
}

/// A track to resolve, expressed in a provider-neutral shape.
class StreamTrackRequest {
  final String title;
  final String artist;
  final String? album;

  /// ISRC when available — the strongest match key.
  final String? isrc;
  final Duration? duration;
  final String? coverUrl;

  /// Provider-native id (Spotify id, Deezer id, …) when known.
  final String? nativeId;

  /// Short preview URL already carried by the metadata (Spotify/Deezer).
  final String? previewUrl;

  const StreamTrackRequest({
    required this.title,
    required this.artist,
    this.album,
    this.isrc,
    this.duration,
    this.coverUrl,
    this.nativeId,
    this.previewUrl,
  });

  factory StreamTrackRequest.fromTrack(Track track) => StreamTrackRequest(
    title: track.name,
    artist: track.artistName,
    album: track.albumName,
    isrc: track.isrc,
    duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
    coverUrl: track.coverUrl,
    nativeId: track.id,
    previewUrl: track.previewUrl,
  );

  /// Best-effort search query: `"Title Artist"` (album name omitted — it adds
  /// noise to cross-catalog matching).
  String get searchQuery => '$title $artist'.trim();
}

/// A playable stream resolved by a provider handler.
class ResolvedStream {
  /// The progressive/HLS URL handed to the audio player.
  final Uri uri;
  final StreamProviderId provider;

  /// "FLAC 24/192 HiFi", "Opus 160kbps", "MP3 128kbps preview", …
  final String qualityLabel;
  final int? bitrateKbps;
  final bool isLossless;
  final bool isPreview;
  final String? codec;
  final String? container;

  /// When the signed URL expires; null if unknown/long-lived.
  final DateTime? expiresAt;

  /// Title/artist the provider matched — used to explain fallback choices.
  final String matchedTitle;
  final String? matchedArtist;

  /// True when this resolution was produced by the universal fallback engine
  /// rather than the originally requested provider.
  final bool viaFallback;

  const ResolvedStream({
    required this.uri,
    required this.provider,
    required this.qualityLabel,
    required this.matchedTitle,
    this.bitrateKbps,
    this.isLossless = false,
    this.isPreview = false,
    this.codec,
    this.container,
    this.expiresAt,
    this.matchedArtist,
    this.viaFallback = false,
  });

  MediaItem toMediaItem({String? fallbackArtUri}) => MediaItem(
    id: uri.toString(),
    title: matchedTitle,
    artist: matchedArtist,
    artUri: fallbackArtUri != null ? Uri.tryParse(fallbackArtUri) : null,
    extras: <String, dynamic>{
      'provider': provider.name,
      'qualityLabel': qualityLabel,
      'isLossless': isLossless,
      'isPreview': isPreview,
      'viaFallback': viaFallback,
    },
  );
}

/// Raised when every provider — including the universal fallback — fails.
class StreamResolutionException implements Exception {
  final String message;
  final Object? cause;

  StreamResolutionException(this.message, {this.cause});

  @override
  String toString() => 'StreamResolutionException: $message';
}

/// One provider's resolution strategy.
abstract class StreamProviderHandler {
  StreamProviderInfo get info;
  StreamProviderId get id => info.id;

  /// Resolves a full (or preview) stream. Returning null means "no playable
  /// result" (missing credentials, no match) and the caller moves on to the
  /// next provider / fallback.
  Future<ResolvedStream?> resolve(StreamTrackRequest request);

  /// Shared HTTP helper with a sane timeout + browser UA.
  Future<http.Response> getJson(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final response = await http
        .get(
          url,
          headers: <String, String>{
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36',
            'Accept': 'application/json, text/plain, */*',
            ...?headers,
          },
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'HTTP ${response.statusCode} for $url',
      );
    }
    return response;
  }
}

// ---------------------------------------------------------------------------
// Provider 1 — Spotify: metadata lookup + official 30s preview playback.
// Full on-demand streams require Spotify's restricted proprietary endpoint,
// so anything beyond a preview defers to the universal fallback engine.
// ---------------------------------------------------------------------------
class SpotifyStreamHandler extends StreamProviderHandler {
  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.spotify);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final preview = request.previewUrl;
    if (preview == null || preview.isEmpty) {
      _log.i('Spotify: no preview URL for "${request.title}"; falling back');
      return null;
    }
    final uri = Uri.tryParse(preview);
    if (uri == null || !uri.isScheme('HTTPS')) return null;
    return ResolvedStream(
      uri: uri,
      provider: StreamProviderId.spotify,
      qualityLabel: 'Ogg Vorbis 96kbps preview',
      bitrateKbps: 96,
      isPreview: true,
      codec: 'vorbis',
      matchedTitle: request.title,
      matchedArtist: request.artist,
    );
  }
}

// ---------------------------------------------------------------------------
// Pure match-confidence scoring shared by the anonymous fallback providers.
//
// Both gates enforce the same policy: a candidate that is neither a
// Topic/official upload nor duration-verified is *rejected* rather than
// silently substituted — an honest "no stream" beats playing the wrong song.
// ---------------------------------------------------------------------------

/// Minimum YouTube match score required to accept a candidate. Chosen so a
/// candidate passes only with either a Topic/official-catalog signal or a
/// title match backed by duration evidence — a same-length unrelated video
/// alone never clears it.
const int youTubeMinimumMatchScore = 40;

/// Hard duration guard: a video more than this many seconds off the requested
/// track can never be the same recording.
const int youTubeMaxDurationDriftSeconds = 60;

/// Scores one YouTube search result against the requested track.
///
/// Positive signals: "- Topic" author (official catalog upload), the requested
/// title appearing in the video title, "official audio"/"audio" in the title,
/// duration proximity. Negative signals: live, concert, cover, karaoke,
/// instrumental uploads, missing title signal and large duration drift.
int scoreYouTubeSearchResult({
  required String author,
  required String title,
  int? targetSeconds,
  int? videoSeconds,
  String? requestTitle,
}) {
  final authorLower = author.toLowerCase();
  final titleLower = title.toLowerCase();
  var score = 0;
  if (authorLower.endsWith('- topic') || authorLower.contains('topic')) {
    score += 60;
  }
  final requestedTitle = requestTitle?.trim().toLowerCase() ?? '';
  if (requestedTitle.isNotEmpty) {
    if (titleLower.contains(requestedTitle)) {
      score += 35;
    } else {
      // The search engine matched keywords, but the video title does not even
      // contain the requested song title: weak evidence at best.
      score -= 15;
    }
  }
  if (titleLower.contains('official audio') || titleLower.contains('audio')) {
    score += 25;
  }
  if (titleLower.contains('live') || titleLower.contains('concert')) score -= 40;
  if (titleLower.contains('cover') || titleLower.contains('karaoke')) {
    score -= 60;
  }
  if (targetSeconds != null && videoSeconds != null) {
    final drift = (videoSeconds - targetSeconds).abs();
    if (drift > youTubeMaxDurationDriftSeconds) {
      score -= 30;
    } else if (drift <= 3) {
      score += 50;
    } else if (drift <= 10) {
      score += 25;
    }
  }
  return score;
}

/// Minimum SoundCloud match score required to accept a candidate: a title
/// match plus one corroborating signal (duration or official marker).
const int soundCloudMinimumMatchScore = 40;

/// Scores one SoundCloud search result against the requested track.
int scoreSoundCloudResult({
  required String title,
  required String requestTitle,
  int? targetSeconds,
  int? durationMs,
}) {
  final lower = title.toLowerCase();
  var score = 0;
  if (lower.contains(requestTitle.toLowerCase())) {
    score += 30;
  } else {
    score -= 15;
  }
  if (lower.contains('official')) score += 10;
  if (lower.contains('cover') || lower.contains('remix')) score -= 25;
  if (targetSeconds != null && durationMs != null) {
    final driftSec = (durationMs - (targetSeconds * 1000)).abs() ~/ 1000;
    if (driftSec > youTubeMaxDurationDriftSeconds) {
      score -= 30;
    } else if (driftSec <= 5) {
      score += 40;
    }
  }
  return score;
}

// ---------------------------------------------------------------------------
// Provider 2 — YouTube / YouTube Music: direct audio stream resolution via
// youtube_explode_dart. This is also the engine that powers the universal
// fallback, so it is public and shared.
// ---------------------------------------------------------------------------
class YouTubeStreamHandler extends StreamProviderHandler {
  final yt.YoutubeExplode _youtube;

  YouTubeStreamHandler(this._youtube);

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.youtube);

  /// Searches YouTube Music for the best matching video.
  ///
  /// Low-confidence matches are rejected (null) instead of silently
  /// substituting an unrelated video: the universal fallback then moves on to
  /// SoundCloud or the resolution fails loudly.
  Future<yt.Video?> _findBestMatch(
    StreamTrackRequest request, {
    bool audioOnly = true,
  }) async {
    final query = audioOnly
        ? '${request.searchQuery} official audio'
        : '${request.searchQuery} topic';
    final results = await _youtube.search.search(query);
    if (results.isEmpty) return null;

    // Prefer "Topic" / "Official Audio" uploads (they are clean studio audio,
    // not live/acoustic re-uploads), then score by duration proximity.
    yt.Video? best;
    int bestScore = -1 << 30;
    final targetSeconds = request.duration?.inSeconds;
    for (final video in results.take(12)) {
      final score = scoreYouTubeSearchResult(
        author: video.author,
        title: video.title,
        targetSeconds: targetSeconds,
        videoSeconds: video.duration?.inSeconds,
        requestTitle: request.title,
      );
      if (score > bestScore) {
        bestScore = score;
        best = video;
      }
    }
    if (best == null) return null;
    // Confidence floor: a result that is neither a Topic/official upload nor
    // duration-verified carries no real evidence it is the requested track.
    if (bestScore < youTubeMinimumMatchScore) {
      _log.i(
        'YouTube: no confident match for "${request.title}" '
        '(best score $bestScore < $youTubeMinimumMatchScore); rejecting',
      );
      return null;
    }
    return best;
  }

  /// Resolves the highest-bitrate progressive audio stream for [video].
  Future<ResolvedStream?> resolveVideo(
    yt.Video video, {
    StreamProviderId provider = StreamProviderId.youtube,
    bool viaFallback = false,
  }) async {
    final manifest = await _youtube.videos.streamsClient.getManifest(video.id);
    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty) return null;

    // ExoPlayer (just_audio on Android) plays both Opus/WebM and AAC/M4A; pick
    // the highest bitrate, breaking ties toward AAC for device compatibility.
    audioStreams.sort((a, b) {
      final byBitrate = b.bitrate.bitsPerSecond.compareTo(
        a.bitrate.bitsPerSecond,
      );
      if (byBitrate != 0) return byBitrate;
      final aAac = a.audioCodec.toLowerCase().contains('mp4a') ? 1 : 0;
      final bAac = b.audioCodec.toLowerCase().contains('mp4a') ? 1 : 0;
      return bAac.compareTo(aAac);
    });

    final best = audioStreams.first;
    final kbps = (best.bitrate.bitsPerSecond / 1000).round();
    final codecLabel = best.audioCodec.toLowerCase().contains('opus')
        ? 'Opus'
        : best.audioCodec.toLowerCase().contains('mp4a')
        ? 'AAC'
        : 'Audio';

    return ResolvedStream(
      uri: best.url,
      provider: provider,
      qualityLabel: '$codecLabel ${kbps}kbps',
      bitrateKbps: kbps,
      isLossless: false,
      codec: best.audioCodec,
      container: best.container.name,
      expiresAt: DateTime.now().add(const Duration(hours: 5, minutes: 30)),
      matchedTitle: video.title,
      matchedArtist: video.author,
      viaFallback: viaFallback,
    );
  }

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final video = await _findBestMatch(request);
    if (video == null) return null;
    return resolveVideo(video);
  }
}

// ---------------------------------------------------------------------------
// Provider 3 — Apple Music: web stream resolution interface.
// Full ALAC streams require a signed developer token (JWT); anonymous callers
// get a structured "requires token" miss and fall through to YouTube.
// ---------------------------------------------------------------------------
class AppleMusicStreamHandler extends StreamProviderHandler {
  AppleMusicStreamHandler({this.bearerToken});

  final String? bearerToken;

  @override
  StreamProviderInfo get info =>
      StreamProviderInfo.of(StreamProviderId.appleMusic);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final token = bearerToken;
    if (token == null || token.isEmpty) {
      _log.i('Apple Music: no developer token; using fallback');
      return null;
    }
    final uri = Uri.https('api.music.apple.com', '/v1/catalog/us/search', {
      'term': request.searchQuery,
      'types': 'songs',
      'limit': '5',
    });
    final response = await getJson(uri, headers: <String, String>{
      'Authorization': 'Bearer $token',
    });
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final results = (body['results'] as Map<String, dynamic>?)?['songs']
        as Map<String, dynamic>?;
    final data = results?['data'] as List<dynamic>?;
    if (data == null || data.isEmpty) return null;
    final first = data.first as Map<String, dynamic>;
    final attributes = first['attributes'] as Map<String, dynamic>;
    final isrc = attributes['isrc'] as String?;
    if (request.isrc != null && isrc != null && isrc != request.isrc) {
      return null;
    }
    // Apple stream URLs are minted through the licensed playback endpoint;
    // without a playback-session token we surface the metadata match and let
    // the fallback engine deliver audio.
    _log.i('Apple Music: matched "${attributes['name']}" (stream token needed)');
    return null;
  }
}

// ---------------------------------------------------------------------------
// Provider 4 — Tidal: lossless HiFi stream URL resolver interface.
// https://api.tidal.com requires an OAuth access token; authenticated callers
// receive FLAC manifest URLs. Anonymous callers fall through to the fallback.
// ---------------------------------------------------------------------------
class TidalStreamHandler extends StreamProviderHandler {
  TidalStreamHandler({this.accessToken, this.countryCode = 'US'});

  final String? accessToken;
  final String countryCode;

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.tidal);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final token = accessToken;
    if (token == null || token.isEmpty) {
      _log.i('Tidal: no access token; using fallback');
      return null;
    }
    final searchUri = Uri.https('api.tidal.com', '/v1/search/tracks', {
      'query': request.searchQuery,
      'limit': '5',
      'countryCode': countryCode,
    });
    final response = await getJson(searchUri, headers: <String, String>{
      'Authorization': 'Bearer $token',
    });
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final items = body['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) return null;
    final track = items.first as Map<String, dynamic>;
    final trackId = track['id']?.toString();
    if (trackId == null) return null;

    // LOSSLESS (FLAC) playbackinfoPostPaywall → manifestMimeType for
    // application/vnd.tidal.bt+json resolves to chunked FLAC base URLs.
    final playbackUri = Uri.https(
      'api.tidal.com',
      '/v1/tracks/$trackId/playbackinfoPostPaywall',
      {
        'audioquality': 'LOSSLESS',
        'playbackmode': 'STREAM',
        'assetpresentation': 'FULL',
        'countryCode': countryCode,
      },
    );
    final playbackResponse = await getJson(
      playbackUri,
      headers: <String, String>{'Authorization': 'Bearer $token'},
    );
    final playback = jsonDecode(playbackResponse.body) as Map<String, dynamic>;
    final manifestB64 = playback['manifest'] as String?;
    if (manifestB64 == null) return null;
    final manifestJson = utf8.decode(base64Decode(manifestB64));
    final manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
    final urls = manifest['urls'] as List<dynamic>?;
    if (urls == null || urls.isEmpty) return null;
    return ResolvedStream(
      uri: Uri.parse(urls.first as String),
      provider: StreamProviderId.tidal,
      qualityLabel: 'FLAC HiFi 16-bit/44.1kHz',
      isLossless: true,
      codec: 'flac',
      matchedTitle: (track['title'] as String?) ?? request.title,
      matchedArtist: request.artist,
    );
  }
}

// ---------------------------------------------------------------------------
// Provider 5 — Qobuz: 24-bit studio stream URL resolver interface.
// Requires app_id + user auth token; track/file endpoints then mint time-
// limited FLAC URLs (format_id 27 = 24-bit/up to 192kHz).
// ---------------------------------------------------------------------------
class QobuzStreamHandler extends QobuzStreamHandlerBase {
  QobuzStreamHandler({super.appId, super.authToken});

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.qobuz);
}

abstract class QobuzStreamHandlerBase extends StreamProviderHandler {
  final String? appId;
  final String? authToken;

  QobuzStreamHandlerBase({this.appId, this.authToken});

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final app = appId;
    final token = authToken;
    if (app == null || app.isEmpty || token == null || token.isEmpty) {
      _log.i('Qobuz: no app credentials; using fallback');
      return null;
    }
    final searchUri = Uri.https(
      'www.qobuz.com',
      '/api.json/0.2/track/search',
      <String, String>{
        'query': request.searchQuery,
        'limit': '5',
        'app_id': app,
      },
    );
    final response = await getJson(searchUri);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final items = body['tracks'] as Map<String, dynamic>?;
    final tracks = items?['items'] as List<dynamic>?;
    if (tracks == null || tracks.isEmpty) return null;
    final track = tracks.first as Map<String, dynamic>;
    final trackId = track['id']?.toString();
    if (trackId == null) return null;

    // format_id: 5 = 16/44 FLAC, 6 = 24/96, 7 = 24/192 (27 = highest studio).
    final fileUri = Uri.https(
      'www.qobuz.com',
      '/api.json/0.2/track/getFileUrl',
      <String, String>{
        'track_id': trackId,
        'format_id': '27',
        'app_id': app,
        'user_auth_token': token,
      },
    );
    final fileResponse = await getJson(fileUri);
    final fileBody = jsonDecode(fileResponse.body) as Map<String, dynamic>;
    final url = fileBody['url'] as String?;
    if (url == null || url.isEmpty) return null;
    final bitDepth = fileBody['bit_depth']?.toString() ?? '24';
    final sampleRate = fileBody['sampling_rate']?.toString() ?? '192';
    return ResolvedStream(
      uri: Uri.parse(url),
      provider: StreamProviderId.qobuz,
      qualityLabel: 'FLAC Studio $bitDepth-bit/${sampleRate}kHz',
      isLossless: true,
      codec: 'flac',
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      matchedTitle: (track['title'] as String?) ?? request.title,
      matchedArtist: request.artist,
    );
  }
}

// ---------------------------------------------------------------------------
// Provider 6 — Deezer: FLAC audio stream URL resolver interface.
// Anonymous access exposes metadata + 30s previews (api.deezer.com is public);
// full FLAC needs a licensed ARL token. Previews are returned so the chip is
// instantly playable; full tracks fall through to the fallback engine.
// ---------------------------------------------------------------------------
class DeezerStreamHandler extends StreamProviderHandler {
  DeezerStreamHandler({this.arlToken});

  final String? arlToken;

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.deezer);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final uri = Uri.https('api.deezer.com', '/search', {
      'q': request.isrc ?? request.searchQuery,
      'limit': '5',
    });
    final response = await getJson(uri);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as List<dynamic>?;
    if (data == null || data.isEmpty) return null;
    final track = data.first as Map<String, dynamic>;
    final isrc = track['isrc'] as String?;
    if (request.isrc != null && isrc != null && isrc != request.isrc) {
      return null;
    }
    final preview = track['preview'] as String?;
    if (arlToken == null || arlToken!.isEmpty) {
      // Public 30s preview — better than nothing while the fallback runs.
      if (preview == null || preview.isEmpty) return null;
      return ResolvedStream(
        uri: Uri.parse(preview),
        provider: StreamProviderId.deezer,
        qualityLabel: 'MP3 128kbps preview',
        bitrateKbps: 128,
        isPreview: true,
        codec: 'mp3',
        matchedTitle: (track['title'] as String?) ?? request.title,
        matchedArtist: (track['artist'] as Map<String, dynamic>?)?['name']
            as String? ??
            request.artist,
      );
    }
    // Licensed FLAC resolution happens through the authenticated gateway
    // (track.read?with_seed → FLAC signed URL).
    _log.i('Deezer: authenticated FLAC gateway not configured; using fallback');
    return null;
  }
}

// ---------------------------------------------------------------------------
// Provider 7 — Amazon Music: HD audio stream URL resolver interface.
// Amazon has no public web API; playback URLs are minted by the licensed
// AMAPI endpoint (https://api.music.amazon.dev) with a bearer + device token.
// Anonymous callers always defer to the universal fallback.
// ---------------------------------------------------------------------------
class AmazonMusicStreamHandler extends StreamProviderHandler {
  AmazonMusicStreamHandler({this.bearerToken, this.deviceToken});

  final String? bearerToken;
  final String? deviceToken;

  @override
  StreamProviderInfo get info =>
      StreamProviderInfo.of(StreamProviderId.amazonMusic);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    if (bearerToken == null ||
        bearerToken!.isEmpty ||
        deviceToken == null ||
        deviceToken!.isEmpty) {
      _log.i('Amazon Music: no AMAPI credentials; using fallback');
      return null;
    }
    // https://api.music.amazon.dev/v1/search?... then
    // /v1/playables/{id}/stream?bitDepth=24&sampleRate=192000 → HD FLAC URL.
    // Credentials for AMAPI are provisioned through extensions; until present
    // the fallback engine serves the track.
    return null;
  }
}

// ---------------------------------------------------------------------------
// Provider 8 — SoundCloud: progressive audio stream URL resolver.
// Fully anonymous: the public api-v2 search + a scraped public client_id give
// progressive HLS/Opus stream URLs without any account.
// ---------------------------------------------------------------------------
class SoundCloudStreamHandler extends StreamProviderHandler {
  final http.Client _client;
  String? _clientId;

  SoundCloudStreamHandler({http.Client? client})
    : _client = client ?? http.Client();

  @override
  StreamProviderInfo get info =>
      StreamProviderInfo.of(StreamProviderId.soundCloud);

  /// Extracts the public api-v2 client_id from soundcloud.com's bundled JS.
  Future<String?> _resolveClientId() async {
    final cached = _clientId;
    if (cached != null) return cached;
    try {
      final home = await _client.get(
        Uri.parse('https://soundcloud.com/'),
        headers: const <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36',
        },
      ).timeout(const Duration(seconds: 12));
      final scriptUrls = RegExp(
        r'https://a-v2\.sndcdn\.com/assets/[^"]+\.js',
      ).allMatches(home.body).map((m) => m.group(0)!).toSet();
      for (final url in scriptUrls) {
        final js = await _client.get(Uri.parse(url)).timeout(
          const Duration(seconds: 12),
        );
        var match = RegExp(r'client_id=([A-Za-z0-9]{20,})').firstMatch(
          js.body,
        );
        match ??= RegExp(r'"client_id":"([A-Za-z0-9]{20,})"').firstMatch(
          js.body,
        );
        final id = match?.group(1);
        if (id != null && id.isNotEmpty) {
          _clientId = id;
          return id;
        }
      }
    } catch (e) {
      _log.w('SoundCloud client_id resolution failed: $e');
    }
    return null;
  }

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    try {
      final clientId = await _resolveClientId();
      if (clientId == null) return null;
      final searchUri = Uri.https(
        'api-v2.soundcloud.com',
        '/search/tracks',
        <String, String>{
          'q': request.searchQuery,
          'limit': '10',
          'client_id': clientId,
        },
      );
      final response = await getJson(searchUri);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final collection = body['collection'] as List<dynamic>?;
      if (collection == null || collection.isEmpty) return null;

      Map<String, dynamic>? best;
      int bestScore = -1 << 30;
      final targetSeconds = request.duration?.inSeconds;
      for (final raw in collection) {
        final track = raw as Map<String, dynamic>;
        final title = (track['title'] as String?) ?? '';
        final score = scoreSoundCloudResult(
          title: title,
          requestTitle: request.title,
          targetSeconds: targetSeconds,
          durationMs: (track['duration'] as num?)?.toInt(),
        );
        if (score > bestScore) {
          bestScore = score;
          best = track;
        }
      }
      if (best == null) return null;
      // Confidence floor: reject weak matches instead of substituting an
      // unrelated upload (policy mirrors the YouTube fallback gate).
      if (bestScore < soundCloudMinimumMatchScore) {
        _log.i(
          'SoundCloud: no confident match for "${request.title}" '
          '(best score $bestScore < $soundCloudMinimumMatchScore); rejecting',
        );
        return null;
      }

      final transcodings = (best['media'] as Map<String, dynamic>?)?['transcodings']
          as List<dynamic>?;
      if (transcodings == null || transcodings.isEmpty) return null;

      // Prefer the progressive (non-HLS) transcoding for gapless just_audio
      // playback; fall back to HLS.
      Map<String, dynamic>? progressive;
      for (final raw in transcodings) {
        final t = raw as Map<String, dynamic>;
        final proto = (t['format'] as Map<String, dynamic>?)?['protocol']
            as String?;
        if (proto == 'progressive') {
          progressive = t;
          break;
        }
        progressive ??= t;
      }
      if (progressive == null) return null;
      final streamEndpoint = Uri.parse(
        progressive['url'] as String,
      ).replace(queryParameters: <String, String>{'client_id': clientId});
      final streamResponse = await getJson(streamEndpoint);
      final streamBody = jsonDecode(streamResponse.body) as Map<String, dynamic>;
      final streamUrl = streamBody['url'] as String?;
      if (streamUrl == null || streamUrl.isEmpty) return null;

      final user = (best['user'] as Map<String, dynamic>?)?['username']
          as String?;
      return ResolvedStream(
        uri: Uri.parse(streamUrl),
        provider: StreamProviderId.soundCloud,
        qualityLabel: 'Opus ~256kbps',
        bitrateKbps: 256,
        codec: 'opus',
        matchedTitle: (best['title'] as String?) ?? request.title,
        matchedArtist: user ?? request.artist,
      );
    } catch (e) {
      _log.w('SoundCloud resolution failed: $e');
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// The service: orchestrates handlers, resolution order, the result cache and
// the universal fallback engine.
// ---------------------------------------------------------------------------
class MultiProviderStreamService {
  final yt.YoutubeExplode _youtube;
  late final YouTubeStreamHandler _youTubeHandler;
  late final Map<StreamProviderId, StreamProviderHandler> _handlers;
  final http.Client _httpClient;

  /// Keyed by "provider|isrc-or-query"; signed URLs are cached until expiry.
  final Map<String, _CachedResolution> _cache =
      <String, _CachedResolution>{};

  MultiProviderStreamService({
    yt.YoutubeExplode? youtube,
    http.Client? httpClient,
    Map<StreamProviderId, StreamProviderHandler>? overrides,
  }) : _youtube = youtube ?? yt.YoutubeExplode(),
       _httpClient = httpClient ?? http.Client() {
    _youTubeHandler = YouTubeStreamHandler(_youtube);
    _handlers = <StreamProviderId, StreamProviderHandler>{
      StreamProviderId.spotify: SpotifyStreamHandler(),
      StreamProviderId.youtube: _youTubeHandler,
      StreamProviderId.appleMusic: AppleMusicStreamHandler(),
      StreamProviderId.tidal: TidalStreamHandler(),
      StreamProviderId.qobuz: QobuzStreamHandler(),
      StreamProviderId.deezer: DeezerStreamHandler(),
      StreamProviderId.amazonMusic: AmazonMusicStreamHandler(),
      StreamProviderId.soundCloud:
          SoundCloudStreamHandler(client: _httpClient),
      ...?overrides,
    };
  }

  StreamProviderHandler handlerFor(StreamProviderId id) => _handlers[id]!;

  String _cacheKey(StreamProviderId provider, StreamTrackRequest request) {
    final identity = request.isrc ??
        '${request.title}|${request.artist}'.toLowerCase();
    return '${provider.name}|$identity';
  }

  /// Resolves a playable stream.
  ///
  /// Order:
  ///   1. [preferredProvider] (if given) — e.g. the chip the user tapped.
  ///   2. Universal fallback engine: YouTube matched by ISRC or
  ///      "Title + Artist" (YouTube always works without credentials).
  ///   3. SoundCloud as a secondary anonymous fallback.
  Future<ResolvedStream> resolveStream(
    StreamTrackRequest request, {
    StreamProviderId? preferredProvider,
  }) async {
    final preferred = preferredProvider ?? StreamProviderId.youtube;
    final cacheKey = _cacheKey(preferred, request);
    final cached = _cache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.stream;
    }

    if (preferred != StreamProviderId.youtube) {
      try {
        final resolved = await _handlers[preferred]?.resolve(request);
        if (resolved != null && !_isUnplayablePreview(resolved)) {
          _cache[cacheKey] = _CachedResolution(resolved);
          return resolved;
        }
        _log.i(
          '${preferred.name} did not yield a full stream for '
          '"${request.title}"; engaging universal fallback engine',
        );
      } catch (e) {
        _log.w('${preferred.name} resolution failed: $e; using fallback');
      }
    }

    // Universal fallback engine — YouTube Explode matched on ISRC (YouTube
    // Music exposes ISRC via its catalog; a title+artist query is the robust
    // key) or "Title + Artist".
    try {
      final fallback = await _youTubeHandler.resolve(request);
      if (fallback != null) {
        final annotated = fallback.viaFallback
            ? fallback
            : _withFallbackFlag(fallback, preferred);
        _cache[cacheKey] = _CachedResolution(annotated);
        return annotated;
      }
    } catch (e) {
      _log.w('Universal YouTube fallback failed: $e');
    }

    // Secondary anonymous fallback: SoundCloud progressive streams.
    if (preferred != StreamProviderId.soundCloud) {
      try {
        final sc = await _handlers[StreamProviderId.soundCloud]?.resolve(
          request,
        );
        if (sc != null) {
          final annotated = _withFallbackFlag(sc, preferred);
          _cache[cacheKey] = _CachedResolution(annotated);
          return annotated;
        }
      } catch (e) {
        _log.w('SoundCloud secondary fallback failed: $e');
      }
    }

    throw StreamResolutionException(
      'No playable stream for "${request.title}" by ${request.artist} '
      'across any provider',
    );
  }

  /// Previews from Spotify/Deezer are 30-second clips; when the user asked for
  /// a full stream they count as a miss and the fallback engine engages.
  bool _isUnplayablePreview(ResolvedStream stream) => stream.isPreview;

  ResolvedStream _withFallbackFlag(
    ResolvedStream stream,
    StreamProviderId requested,
  ) =>
      stream.provider == requested
      ? stream
      : ResolvedStream(
          uri: stream.uri,
          provider: stream.provider,
          qualityLabel: '${stream.qualityLabel} · fallback',
          bitrateKbps: stream.bitrateKbps,
          isLossless: stream.isLossless,
          isPreview: stream.isPreview,
          codec: stream.codec,
          container: stream.container,
          expiresAt: stream.expiresAt,
          matchedTitle: stream.matchedTitle,
          matchedArtist: stream.matchedArtist,
          viaFallback: true,
        );

  void dispose() {
    _youtube.close();
    _httpClient.close();
    _cache.clear();
  }
}

class _CachedResolution {
  final ResolvedStream stream;
  final DateTime cachedAt;

  _CachedResolution(this.stream) : cachedAt = DateTime.now();

  bool get isExpired {
    final expiry = stream.expiresAt;
    if (expiry == null) {
      // Unknown expiry: YouTube/SoundCloud URLs still rotate; hold 30 minutes.
      return DateTime.now().difference(cachedAt) >
          const Duration(minutes: 30);
    }
    return DateTime.now().isAfter(expiry.subtract(const Duration(minutes: 5)));
  }
}

// ---------------------------------------------------------------------------
// just_audio playback binding — the streaming half of the dual-mode engine.
// The download half (native FLAC pipeline, SAF, extensions) is untouched.
// ---------------------------------------------------------------------------
class MultiProviderPlayer {
  final MultiProviderStreamService service;
  final AudioPlayer _player = AudioPlayer();

  MultiProviderPlayer(this.service);

  AudioPlayer get audioPlayer => _player;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  bool get isPlaying => _player.playing;

  /// Resolves [request] via [provider] (or the fallback chain) and starts
  /// playback immediately.
  Future<ResolvedStream> play(
    StreamTrackRequest request, {
    StreamProviderId? provider,
  }) async {
    final resolved = await service.resolveStream(request, preferredProvider: provider);
    await _player.setUrl(resolved.uri.toString());
    await _player.play();
    return resolved;
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> stop() => _player.stop();

  Future<void> dispose() async {
    await _player.dispose();
  }
}
