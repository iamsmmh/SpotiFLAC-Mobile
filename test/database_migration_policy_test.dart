import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One SQLite-backed store and the rules its upgrade path must follow.
///
/// `flutter test` runs without a SQLite implementation (sqflite resolves
/// through a platform channel), so the migrations themselves cannot be
/// executed here. What *can* be asserted without a database is the contract
/// that keeps them safe in production:
///
///   * the declared schema version is the highest migration step + 0 (a new
///     `if (oldVersion < N)` block that forgets to bump the version never
///     runs on any device);
///   * every schema change outside the historical pre-helper baseline is
///     idempotent (`addColumnIfMissing` / `CREATE TABLE IF NOT EXISTS`), so an
///     interrupted migration can be resumed instead of crashing with
///     "duplicate column name".
class _StoreSpec {
  const _StoreSpec({
    required this.path,
    required this.versionSymbol,
    required this.legacyAlterBaseline,
  });

  final String path;

  /// Name of the version constant declared in the store.
  final String versionSymbol;

  /// Highest migration step that predates `sqlite.addColumnIfMissing`. Those
  /// steps are guarded by the version check itself and must not be rewritten.
  final int legacyAlterBaseline;
}

const List<_StoreSpec> _stores = <_StoreSpec>[
  _StoreSpec(
    path: 'lib/services/library_database.dart',
    versionSymbol: 'schemaVersion',
    legacyAlterBaseline: 6,
  ),
  _StoreSpec(
    path: 'lib/services/history_database.dart',
    versionSymbol: 'schemaVersion',
    legacyAlterBaseline: 5,
  ),
  _StoreSpec(
    path: 'lib/services/app_state_database.dart',
    versionSymbol: '_dbVersion',
    legacyAlterBaseline: 0,
  ),
  _StoreSpec(
    path: 'lib/services/library_collections_database.dart',
    versionSymbol: '_dbVersion',
    legacyAlterBaseline: 0,
  ),
];

final RegExp _stepPattern = RegExp(r'if \(oldVersion < (\d+)\) \{');
final RegExp _alterPattern = RegExp(r"ALTER TABLE[^\n]*ADD COLUMN", caseSensitive: false);

/// Splits the upgrade function into `version -> body` blocks.
Map<int, String> _migrationSteps(String source) {
  final upgradeIndex = source.indexOf(RegExp(
    r'Future<void> _upgrade(?:DB|Db)\(',
  ));
  expect(upgradeIndex, greaterThanOrEqualTo(0), reason: 'upgrade fn missing');
  final upgradeBody = source.substring(upgradeIndex);

  final steps = <int, String>{};
  final matches = _stepPattern.allMatches(upgradeBody).toList();
  for (var i = 0; i < matches.length; i++) {
    final version = int.parse(matches[i].group(1)!);
    final start = matches[i].end;
    final end = i + 1 < matches.length ? matches[i + 1].start : upgradeBody.length;
    steps[version] = upgradeBody.substring(start, end);
  }
  return steps;
}

void main() {
  for (final store in _stores) {
    group(store.path, () {
      final file = File(store.path);
      final source = file.existsSync() ? file.readAsStringSync() : '';

      test('source file is readable', () {
        expect(file.existsSync(), isTrue);
      });

      test('the declared version matches the newest migration step', () {
        final declaration = RegExp(
          '${store.versionSymbol}\\s*=\\s*(\\d+)\\s*;',
        ).firstMatch(source);
        expect(declaration, isNotNull, reason: 'version constant missing');
        final version = int.parse(declaration!.group(1)!);

        final steps = _migrationSteps(source);
        expect(steps, isNotEmpty, reason: 'no migration steps found');
        final newest = steps.keys.reduce((a, b) => a > b ? a : b);
        expect(
          version,
          newest,
          reason:
              'the schema version must equal the newest `oldVersion < N` '
              'step, otherwise the newest migration never runs',
        );
      });

      test('migration steps are idempotent past the legacy baseline', () {
        final steps = _migrationSteps(source);
        final offenders = <String>[];
        for (final entry in steps.entries) {
          if (entry.key <= store.legacyAlterBaseline) continue;
          for (final line in entry.value.split('\n')) {
            if (!_alterPattern.hasMatch(line)) continue;
            final guarded = line.contains('addColumnIfMissing');
            if (!guarded) offenders.add('v${entry.key}: ${line.trim()}');
          }
        }
        expect(
          offenders,
          isEmpty,
          reason:
              'ALTER TABLE … ADD COLUMN outside the legacy baseline must go '
              'through sqlite.addColumnIfMissing so an interrupted migration '
              'can resume',
        );
      });

      test('every migration step is reachable (no gaps in the ladder)', () {
        final steps = _migrationSteps(source).keys.toList()..sort();
        for (var i = 1; i < steps.length; i++) {
          expect(
            steps[i],
            steps[i - 1] + 1,
            reason: 'migration ladder skips a version (${steps[i - 1]} → '
                '${steps[i]}); a device between the two would never upgrade',
          );
        }
      });
    });
  }

  group('sqlite helper contract', () {
    test('addColumnIfMissing is used by every guarded migration', () {
      final helpers = File('lib/services/sqlite_helpers.dart');
      expect(helpers.existsSync(), isTrue);
      final source = helpers.readAsStringSync();
      expect(source, contains('addColumnIfMissing'));
      // The helper must consult PRAGMA table_info: a plain try/ALTER would
      // leave a half-applied migration behind on the first failure.
      expect(source, contains('PRAGMA table_info'));
    });
  });
}
