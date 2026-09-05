/// Rough "how big will this file be?" estimates for the download quality
/// picker (community request #550).
///
/// These are deliberately coarse averages, not promises: actual size depends
/// on the source recording, the extension's encoder settings, and whether the
/// provider serves true lossless or a transparent re-encode. The estimate is
/// only a label next to a quality option, so it errs toward typical
/// real-world bitrates rather than worst-case ones.
library;

/// Average bitrate in kbps used to estimate a track's final file size for a
/// quality id. Extension-declared ids that encode their bitrate in the name
/// (e.g. `MP3_320`, `OPUS_128`) are parsed instead of looked up.
const Map<String, int> typicalBitrateKbpsByQuality = <String, int>{
  'LOSSLESS': 1000, // 16-bit/44.1 kHz FLAC, content-dependent
  'FLAC': 1000,
  'HI_RES': 2200, // 24-bit/48 kHz FLAC
  'HI_RES_LOSSLESS': 4600, // 24-bit/96 kHz FLAC
  'HIRES': 2200,
  'LOSSY': 256,
  'M4A': 256,
  'AAC_256': 256,
  'OGG': 320,
};

/// Resolves the typical bitrate for a quality id, or null when unknown.
int? bitrateKbpsForQuality(String qualityId) {
  final normalized = qualityId.trim().toUpperCase();
  if (normalized.isEmpty) return null;

  final known = typicalBitrateKbpsByQuality[normalized];
  if (known != null) return known;

  // `CODEC_BITRATE` ids (MP3_320, OPUS_128, OGG_192, AAC_256 …).
  final underscore = normalized.lastIndexOf('_');
  if (underscore > 0 && underscore < normalized.length - 1) {
    final suffix = int.tryParse(normalized.substring(underscore + 1));
    if (suffix != null && suffix > 0 && suffix <= 9216) return suffix;
  }
  return null;
}

/// Estimated size in bytes of one track at [qualityId], or null when either
/// the duration or the bitrate is unknown.
int? estimateTrackBytes({int? durationSeconds, required String qualityId}) {
  final seconds = durationSeconds;
  if (seconds == null || seconds <= 0) return null;
  final kbps = bitrateKbpsForQuality(qualityId);
  if (kbps == null) return null;
  return (seconds * kbps * 1000) ~/ 8;
}

/// Compact human-readable byte count for labels, e.g. `18 MB` / `940 KB`.
String formatBytesShort(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Label shown next to a quality option, e.g. `≈ 18 MB` for one track or
/// `≈ 112 MB · 12 files` for a batch. Null when nothing could be estimated.
String? approxSizeLabel({int? durationSeconds, required String qualityId}) {
  final bytes = estimateTrackBytes(
    durationSeconds: durationSeconds,
    qualityId: qualityId,
  );
  if (bytes == null) return null;
  return '≈ ${formatBytesShort(bytes)}';
}
