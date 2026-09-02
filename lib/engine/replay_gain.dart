import 'dart:math' as math;

/// ReplayGain / EBU R128 loudness normalization for real-time playback.
///
/// ReplayGain tags store a *gain* in dB that must be applied to bring a track
/// (or album) to the reference loudness of -18 LUFS / 89 dB SPL. Almost every
/// commercial master is louder than the reference, so the gain is negative and
/// the player attenuates. The platform volume control can only attenuate
/// (0.0 .. 1.0); a positive gain (a quiet recording) therefore clamps to 1.0.
///
/// This module is pure Dart and deliberately transport-agnostic: the audio
/// service feeds it tags probed from local files, while the streaming engine
/// feeds it gain metadata carried by the extension adapter on a
/// `StreamDescriptor`.
class ReplayGain {
  const ReplayGain._();

  /// Reference loudness used by ReplayGain 2.0 (informative only).
  static const double referenceLufs = -18.0;

  /// Converts a gain in dB to a linear amplitude multiplier.
  static double dbToLinear(double gainDb) =>
      math.pow(10.0, gainDb / 20.0).toDouble();

  /// Converts a linear amplitude multiplier back to dB.
  static double linearToDb(double linear) =>
      20.0 * math.log(math.max(linear, 1e-9)) / math.ln10;

  /// Parses a ReplayGain gain tag (`"+3.42 dB"`, `"-7.21 dB"`, `"3.42"`).
  /// Returns null for empty, malformed, or `"N/A"` values.
  static double? parseGainDb(Object? raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;
    final lowered = text.toLowerCase();
    if (lowered == 'n/a' || lowered == 'na' || lowered == 'none') {
      return null;
    }
    final match = RegExp(r'[+-]?\d+(\.\d+)?').firstMatch(text);
    if (match == null) return null;
    return double.tryParse(match.group(0)!);
  }

  /// Parses a ReplayGain peak tag (`"0.987654"`). Returns null when absent or
  /// when the value is not a non-negative number.
  static double? parsePeak(Object? raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null || value < 0.0) return null;
    return value;
  }

  /// Selects which gain to apply under the given mode. The default prefers the
  /// track gain (per-track normalization); album mode prefers the album gain so
  /// an album keeps its relative dynamics.
  static double? selectGain({
    double? trackGainDb,
    double? albumGainDb,
    bool preferAlbumGain = false,
  }) => preferAlbumGain
      ? (albumGainDb ?? trackGainDb)
      : (trackGainDb ?? albumGainDb);

  /// The volume multiplier (0.0 .. 1.0) to apply for the given tags.
  ///
  /// * Returns 1.0 when there are no tags or when the selected gain is null.
  /// * Negative gains attenuate (the normal case).
  /// * Positive gains would require amplification, which the platform volume
  ///   cannot provide, so they clamp to 1.0.
  /// * When [preventClipping] is on and a source peak above full scale is
  ///   reported, the volume is reduced further so the peak lands on 1.0.
  static double volume({
    double? trackGainDb,
    double? albumGainDb,
    double? trackPeak,
    double? albumPeak,
    bool preferAlbumGain = false,
    double preAmpDb = 0.0,
    bool preventClipping = true,
  }) {
    final gainDb = selectGain(
      trackGainDb: trackGainDb,
      albumGainDb: albumGainDb,
      preferAlbumGain: preferAlbumGain,
    );
    if (gainDb == null) return 1.0;

    var volume = dbToLinear(gainDb + preAmpDb).clamp(0.0, 1.0);
    if (preventClipping && volume >= 1.0) {
      final peak = trackPeak ?? albumPeak;
      if (peak != null && peak > 1.0) {
        volume = (1.0 / peak).clamp(0.0, 1.0);
      }
    }
    return volume;
  }
}
