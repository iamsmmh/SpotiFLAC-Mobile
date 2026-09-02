import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/theme/app_theme.dart';
import 'package:spotimusic/ui/widgets/liquid_glass_container.dart';
import 'package:spotimusic/ui/widgets/liquid_glass_player_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('LiquidGlassContainer', () {
    testWidgets('renders its child and the gradient border', (tester) async {
      await tester.pumpWidget(
        host(
          const LiquidGlassContainer(
            enableBlur: false,
            child: Text('glass card'),
          ),
        ),
      );
      expect(find.text('glass card'), findsOneWidget);
      expect(find.byType(LiquidGlassContainer), findsOneWidget);
    });

    testWidgets('LiquidGlassBackground renders descendants', (tester) async {
      await tester.pumpWidget(
        host(
          const LiquidGlassBackground(child: Text('aurora')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('aurora'), findsOneWidget);
    });
  });

  group('LiquidGlassPlayerSheet', () {
    const track = Track(
      id: 't1',
      name: 'Test Song',
      artistName: 'Test Artist',
      albumName: 'Test Album',
      duration: 210,
    );

    testWidgets('shows all eight provider chips and the FLAC button', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const LiquidGlassPlayerSheet(track: track)),
      );
      await tester.pump();

      expect(find.text('Stream provider'), findsOneWidget);
      expect(find.text('Offline mode'), findsOneWidget);
      expect(
        find.text('Download lossless FLAC for offline'),
        findsOneWidget,
      );
      // The eight provider chips.
      for (final name in [
        'Spotify',
        'YT Music',
        'Apple',
        'Tidal',
        'Qobuz',
        'Deezer',
        'Amazon',
        'SoundCloud',
      ]) {
        expect(find.text(name), findsOneWidget, reason: 'chip $name missing');
      }
    });

    testWidgets('exposes a lossless FLAC download action', (tester) async {
      await tester.pumpWidget(
        host(const LiquidGlassPlayerSheet(track: track)),
      );
      await tester.pump();

      final button = find.text('Download lossless FLAC for offline');
      expect(button, findsOneWidget);
      // The action renders as an enabled filled button.
      final filled = tester.widget<FilledButton>(
        find.ancestor(of: button, matching: find.byType(FilledButton)),
      );
      expect(filled.onPressed, isNotNull);
    });
  });
}
