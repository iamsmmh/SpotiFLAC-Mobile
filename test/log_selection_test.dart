import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/l10n/l10n.dart';
import 'package:spotimusic/screens/settings/log_screen.dart';
import 'package:spotimusic/utils/logger.dart';

void main() {
  test('selected log export keeps chronological lines only', () {
    final entries = [
      LogEntry(
        timestamp: DateTime(2026, 8, 11, 10, 20, 30, 40),
        level: 'INFO',
        tag: 'Search',
        message: 'first',
      ),
      LogEntry(
        timestamp: DateTime(2026, 8, 11, 10, 20, 31, 50),
        level: 'ERROR',
        tag: 'Download',
        message: 'second',
        error: 'failed',
        isFromGo: true,
      ),
    ];

    expect(
      formatLogEntries(entries),
      '[10:20:30.040] [INFO] [Search] first\n'
      '[10:20:31.050] [ERROR] [Go] [Download] second | failed',
    );
  });

  testWidgets('long press selects multiple log rows for copying', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map<Object?, Object?>)['text']
              ?.toString();
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    LogBuffer().clear();
    addTearDown(LogBuffer().clear);
    LogBuffer().add(
      LogEntry(
        timestamp: DateTime(2026, 8, 11, 10),
        level: 'ERROR',
        tag: 'One',
        message: 'first selected message',
      ),
    );
    LogBuffer().add(
      LogEntry(
        timestamp: DateTime(2026, 8, 11, 10, 0, 1),
        level: 'ERROR',
        tag: 'Two',
        message: 'second selected message',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LogScreen(),
      ),
    );

    await tester.longPress(find.text('first selected message'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.ensureVisible(find.text('second selected message'));
    await tester.pump();
    await tester.tap(find.text('second selected message'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();

    expect(clipboardText, contains('first selected message'));
    expect(clipboardText, contains('second selected message'));
    expect(find.text('2 selected'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
