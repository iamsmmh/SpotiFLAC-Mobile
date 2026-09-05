/// Offline download registry ("ledger").
///
/// A ledger is a *file list without files*: one JSON record per downloaded
/// track (ISRC / Spotify id / artist-title key, no audio). It lets a user
/// carry their download identity across devices and answer "which tracks from
/// this list do I not have here yet?" — the ask in issue #516. Diffing runs
/// purely on these records; enqueuing a missing track reuses the normal
/// search/download pipeline via the entry's link.
///
/// Format is stable and hand-rolled (no codegen): `{version, exportedAt,
/// entries[]}`. Unknown fields are ignored on read, so the format can grow.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LedgerEntry {
  final String? isrc;
  final String? spotifyId;
  final String title;
  final String artist;
  final String album;
  final int? durationSeconds;
  final String? quality;
  final String? downloadedAt;

  const LedgerEntry({
    required this.title,
    required this.artist,
    this.isrc,
    this.spotifyId,
    this.album = '',
    this.durationSeconds,
    this.quality,
    this.downloadedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (isrc != null && isrc!.isNotEmpty) 'isrc': isrc,
    if (spotifyId != null && spotifyId!.isNotEmpty) 'spotify_id': spotifyId,
    'title': title,
    'artist': artist,
    if (album.isNotEmpty) 'album': album,
    if (durationSeconds != null) 'duration_s': durationSeconds,
    if (quality != null && quality!.isNotEmpty) 'quality': quality,
    if (downloadedAt != null) 'downloaded_at': downloadedAt,
  };

  static LedgerEntry fromJson(Map<String, dynamic> json) {
    return LedgerEntry(
      title: (json['title'] ?? '').toString(),
      artist: (json['artist'] ?? '').toString(),
      isrc: json['isrc']?.toString(),
      spotifyId: json['spotify_id']?.toString(),
      album: (json['album'] ?? '').toString(),
      durationSeconds: json['duration_s'] is num
          ? (json['duration_s'] as num).toInt()
          : null,
      quality: json['quality']?.toString(),
      downloadedAt: json['downloaded_at']?.toString(),
    );
  }

  /// Canonical match key, strongest identity first.
  String get matchKey {
    final normalizedIsrc = (isrc ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (normalizedIsrc.length >= 12) return 'isrc:$normalizedIsrc';
    final id = (spotifyId ?? '').trim();
    if (id.isNotEmpty && id.length >= 22 && RegExp(r'^[A-Za-z0-9]+$').hasMatch(id)) {
      return 'sp:$id';
    }
    return 'ta:${_normalizeKeyPart(artist)}|${_normalizeKeyPart(title)}';
  }

  String get displayLabel => artist.isEmpty
      ? title
      : '$artist \u2013 $title';

  String? get openableUrl {
    final id = (spotifyId ?? '').trim();
    if (id.isNotEmpty && RegExp(r'^[A-Za-z0-9]+$').hasMatch(id)) {
      return 'https://open.spotify.com/track/$id';
    }
    return null;
  }

  static String _normalizeKeyPart(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r"[\u2018\u2019']"), '')
      .replaceAll(RegExp(r'\(feat\.?.*?\)|\[feat\.?.*?\]', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
}

abstract final class LibraryLedgerService {
  static const int formatVersion = 1;

  /// Builds ledger entries from raw `history` rows (HistoryDatabase.getAll).
  static List<LedgerEntry> entriesFromHistoryRows(
    List<Map<String, dynamic>> rows,
  ) {
    final seen = <String>{};
    final entries = <LedgerEntry>[];
    for (final row in rows) {
      final entry = LedgerEntry(
        title: (row['track_name'] ?? '').toString(),
        artist: (row['artist_name'] ?? '').toString(),
        album: (row['album_name'] ?? '').toString(),
        isrc: row['isrc']?.toString(),
        spotifyId: row['spotify_id']?.toString(),
        quality: row['quality']?.toString(),
        downloadedAt: row['downloaded_at']?.toString(),
        durationSeconds: row['duration'] is num
            ? (row['duration'] as num).toInt()
            : null,
      );
      if (entry.title.isEmpty) continue;
      // Newest row wins for duplicate identities (a re-download at higher
      // quality is not "missing" from the older device).
      if (!seen.add(entry.matchKey)) continue;
      entries.add(entry);
    }
    entries.sort((a, b) => a.displayLabel.toLowerCase().compareTo(
          b.displayLabel.toLowerCase(),
        ));
    return entries;
  }

  static String encodeLedger(List<LedgerEntry> entries) {
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'format': 'spotiflac-ledger',
      'version': formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'count': entries.length,
      'entries': entries.map((e) => e.toJson()).toList(growable: false),
    });
  }

  /// Returns null for anything that is not a readable ledger (wrong JSON,
  /// wrong format tag, no entries array). Accepts future `version`s.
  static List<LedgerEntry>? decodeLedger(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['format'] != 'spotiflac-ledger') return null;
      final entriesJson = decoded['entries'];
      if (entriesJson is! List) return null;
      return entriesJson
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => LedgerEntry.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.title.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return null;
    }
  }

  /// Entries of an imported ledger that this device does not have yet.
  static List<LedgerEntry> missingEntries({
    required List<LedgerEntry> imported,
    required List<LedgerEntry> local,
  }) {
    final localKeys = local.map((e) => e.matchKey).toSet();
    final emitted = <String>{};
    final missing = <LedgerEntry>[];
    for (final entry in imported) {
      if (localKeys.contains(entry.matchKey)) continue;
      if (!emitted.add(entry.matchKey)) continue;
      missing.add(entry);
    }
    return missing;
  }

  /// Writes the ledger next to backups so "Files"/SAF can reach it, and the
  /// share sheet can attach it. Name sorts chronologically.
  static Future<File> writeLedgerFile(String encoded) async {
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}${Platform.pathSeparator}ledgers');
    await outDir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
    final file = File('${outDir.path}${Platform.pathSeparator}spotiflac-ledger-$stamp.json');
    await file.writeAsString(encoded, flush: true);
    return file;
  }
}
