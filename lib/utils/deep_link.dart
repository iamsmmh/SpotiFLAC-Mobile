/// `spotimusic://` deep-link parsing.
///
/// Accepted shapes (extra query params are ignored):
///   spotimusic://open?url=https%3A%2F%2Fopen.spotify.com%2Ftrack%2F…
///   spotimusic://open?link=…            (alias)
///   spotimusic://search?q=artist%20title
///   spotimusic://search/artist%20title
///   spotimusic://track?spotify=ID  /  album?spotify=ID  /  playlist?spotify=ID
///   spotimusic://<raw https-or-spotify-URI>          (passthrough)
///
/// Anything that cannot be parsed is simply *not* a deep link (null) so the
/// caller can fall back to the normal shared-URL pipeline.
library;

enum DeepLinkKind { openUrl, search }

class DeepLinkAction {
  const DeepLinkAction(this.kind, this.payload);

  final DeepLinkKind kind;

  /// For [DeepLinkKind.openUrl] a resolvable media link; for
  /// [DeepLinkKind.search] the plain query text.
  final String payload;
}

const List<String> _urlParams = <String>['url', 'link', 'to'];
const List<String> _searchParams = <String>['q', 'query', 'text'];

bool looksLikeMediaLink(String value) {
  final lowered = value.toLowerCase();
  return lowered.startsWith('http://') ||
      lowered.startsWith('https://') ||
      lowered.startsWith('spotify:') ||
      lowered.startsWith('deezer:') ||
      lowered.startsWith('tidal:');
}

DeepLinkAction? parseSpotiFlacDeepLink(String input) {
  final trimmed = input.trim();
  final lowered = trimmed.toLowerCase();
  if (!lowered.startsWith('spotimusic://') && !lowered.startsWith('spotimusic:')) {
    return null;
  }
  if (trimmed.length < 'spotimusic:'.length) return null;

  Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } on FormatException {
    return null;
  }
  if (uri.scheme.toLowerCase() != 'spotimusic') return null;

  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments
      .where((s) => s.trim().isNotEmpty)
      .toList(growable: false);

  // Explicit open-with-url.
  for (final param in _urlParams) {
    final value = uri.queryParameters[param]?.trim();
    if (value != null && value.isNotEmpty) {
      return DeepLinkAction(DeepLinkKind.openUrl, value);
    }
  }

  // Explicit search.
  for (final param in _searchParams) {
    final value = uri.queryParameters[param]?.trim();
    if (value != null && value.isNotEmpty) {
      return DeepLinkAction(DeepLinkKind.search, value);
    }
  }
  if (host == 'search') {
    final query = segments.join(' ').trim();
    if (query.isEmpty) return null;
    return DeepLinkAction(DeepLinkKind.search, query);
  }

  // Canonical provider entity ids: spotimusic://track?spotify=<id>.
  if (host == 'track' || host == 'album' || host == 'playlist') {
    final id = uri.queryParameters['spotify']?.trim();
    if (id != null && RegExp(r'^[A-Za-z0-9]{20,30}$').hasMatch(id)) {
      return DeepLinkAction(
        DeepLinkKind.openUrl,
        'https://open.spotify.com/$host/$id',
      );
    }
  }

  // Passthrough: spotimusic:// followed directly by an encoded media link,
  // e.g. spotimusic://open.spotify.com/track/ID (query kept intact).
  final remainder = trimmed.substring('spotimusic:'.length).replaceFirst('//', '');
  if (looksLikeMediaLink(remainder)) {
    return DeepLinkAction(DeepLinkKind.openUrl, remainder);
  }
  // A dotted host with at least one path segment is an URL without scheme.
  if (host.contains('.') && segments.isNotEmpty) {
    return DeepLinkAction(DeepLinkKind.openUrl, remainder);
  }

  // Last resort: non-empty rest of the URI is treated as a search query.
  final fallback = <String>[host, ...segments].join(' ').trim();
  if (fallback.isEmpty) return null;
  return DeepLinkAction(DeepLinkKind.search, fallback);
}
