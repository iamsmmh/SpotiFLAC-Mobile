import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/utils/deep_link.dart';

void main() {
  group('parseSpotiFlacDeepLink', () {
    test('open?url= resolves to the encoded link', () {
      final action = parseSpotiFlacDeepLink(
        'spotimusic://open?url=https%3A%2F%2Fopen.spotify.com%2Ftrack%2F4cOdK2wGLETKBW3PvgPWqT',
      );
      expect(action, isNotNull);
      expect(action!.kind, DeepLinkKind.openUrl);
      expect(
        action.payload,
        'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT',
      );
    });

    test('search?q= and search/<text> both produce a search action', () {
      final viaQuery = parseSpotiFlacDeepLink(
        'spotimusic://search?q=daftpunk%20discovery',
      );
      expect(viaQuery!.kind, DeepLinkKind.search);
      expect(viaQuery.payload, 'daftpunk discovery');

      final viaPath = parseSpotiFlacDeepLink('spotimusic://search/daft%20punk');
      expect(viaPath!.kind, DeepLinkKind.search);
      expect(viaPath.payload, 'daft punk');
    });

    test('canonical ids build provider links', () {
      final action = parseSpotiFlacDeepLink(
        'spotimusic://track?spotify=4cOdK2wGLETKBW3PvgPWqT',
      );
      expect(action!.kind, DeepLinkKind.openUrl);
      expect(
        action.payload,
        'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT',
      );
    });

    test('passthrough https remainder is treated as a link', () {
      final action = parseSpotiFlacDeepLink(
        'spotimusic://open.spotify.com/album/1234567890abcdef',
      );
      expect(action!.kind, DeepLinkKind.openUrl);
      expect(action.payload, 'open.spotify.com/album/1234567890abcdef');
    });

    test('non-deep-link input returns null', () {
      expect(parseSpotiFlacDeepLink('https://open.spotify.com/track/x'), isNull);
      expect(parseSpotiFlacDeepLink('spotimusic://'), isNull);
      expect(parseSpotiFlacDeepLink('spotimusic://search'), isNull);
    });
  });

  test('looksLikeMediaLink accepts provider links and URIs', () {
    expect(looksLikeMediaLink('https://example.com/a'), isTrue);
    expect(looksLikeMediaLink('spotify:track:abc'), isTrue);
    expect(looksLikeMediaLink('just words'), isFalse);
  });
}
