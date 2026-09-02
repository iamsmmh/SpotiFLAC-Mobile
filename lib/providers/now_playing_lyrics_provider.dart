import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';

final _log = AppLogger('NowPlayingLyrics');

/// Resolves the current track's lyrics into a [ParsedLyrics] for the
/// synchronized lyrics viewer.
///
/// Prefers embedded lyrics read back through the same metadata bridge the
/// classic Now Playing screen uses (`readPlaybackFileMetadataWithRetry`),
/// falling back to an empty result — the viewer renders a friendly
/// "no lyrics" state rather than throwing.
final nowPlayingLyricsProvider = FutureProvider.autoDispose<ParsedLyrics>((
  ref,
) async {
  final item = ref.watch(currentMediaItemProvider).value;
  if (item == null) return ParsedLyrics.empty;

  final path = _sourcePathFor(item);
  if (path.isEmpty) return ParsedLyrics.empty;

  // Streams have no embedded lyrics to probe; skip the native metadata read
  // for remote URLs (an extension could enrich these later, but the file
  // bridge only understands local paths).
  if (path.startsWith('http://') || path.startsWith('https://')) {
    return ParsedLyrics.empty;
  }

  try {
    final meta = await readPlaybackFileMetadataWithRetry(path);
    return LyricsParser.parse((meta['lyrics'] ?? '').toString());
  } catch (e) {
    _log.w('Failed to read lyrics for "${item.title}": $e');
    return ParsedLyrics.empty;
  }
});

/// Derives the concrete file/stream path whose metadata should be probed for
/// lyrics. Prefers the engine-resolved local source (an SAF URI is left as-is
/// and resolved by the platform bridge) over the raw queue source.
String _sourcePathFor(MediaItem item) {
  final extras = item.extras;
  if (extras == null) return '';
  final resolved = extras['resolvedSource']?.toString().trim() ?? '';
  if (resolved.isNotEmpty) return resolved;
  return extras['source']?.toString().trim() ?? '';
}
