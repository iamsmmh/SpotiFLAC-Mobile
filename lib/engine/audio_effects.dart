import 'dart:convert';

/// Centre frequencies (Hz) of the 10 ISO octave bands exposed by the
/// equalizer. Native chains that do not offer exactly these bands map onto
/// them (see the Android controller).
const List<int> equalizerBandFrequencies = [
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

/// Gain range of one equalizer band in dB.
const double equalizerMinGainDb = -12;
const double equalizerMaxGainDb = 12;

double _clampGain(num value) =>
    value.toDouble().clamp(equalizerMinGainDb, equalizerMaxGainDb);

double _finite(Object? value, double fallback) {
  final parsed = value is num ? value.toDouble() : double.tryParse('$value');
  if (parsed == null || !parsed.isFinite) return fallback;
  return parsed;
}

/// Normalises any dynamic list to exactly ten finite, clamped gains.
List<double> normalizeBandGains(Object? raw) {
  final gains = List<double>.filled(equalizerBandFrequencies.length, 0);
  if (raw is List) {
    for (var i = 0; i < gains.length && i < raw.length; i++) {
      gains[i] = _clampGain(_finite(raw[i], 0));
    }
  }
  return gains;
}

/// Named set of ten band gains. Built-in presets are immutable; user presets
/// can be saved, renamed, deleted, imported and exported.
class EqualizerPreset {
  final String name;
  final List<double> gainsDb;
  final bool builtIn;

  EqualizerPreset({
    required this.name,
    required List<double> gainsDb,
    this.builtIn = false,
  }) : gainsDb = List<double>.unmodifiable(normalizeBandGains(gainsDb));

  Map<String, dynamic> toJson() => {'name': name, 'gains_db': gainsDb};

  /// Parses one preset; null when the entry is unusable (no name).
  static EqualizerPreset? fromJson(Object? raw, {bool builtIn = false}) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString().trim() ?? '';
    if (name.isEmpty || name.length > 40) return null;
    return EqualizerPreset(
      name: name,
      gainsDb: normalizeBandGains(raw['gains_db'] ?? raw['gains']),
      builtIn: builtIn,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EqualizerPreset &&
      other.name == name &&
      other.builtIn == builtIn &&
      _sameGains(other.gainsDb, gainsDb);

  @override
  int get hashCode => Object.hash(name, builtIn, Object.hashAll(gainsDb));

  static bool _sameGains(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 1e-9) return false;
    }
    return true;
  }

  static const String flatName = 'Flat';

  /// Factory presets. "Flat" is always first.
  static final List<EqualizerPreset> builtIns = List.unmodifiable([
    EqualizerPreset(
      name: flatName,
      gainsDb: const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Bass Boost',
      gainsDb: const [7, 6, 5, 3, 1, 0, 0, 0, 0, 0],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Treble Boost',
      gainsDb: const [0, 0, 0, 0, 0, 1, 3, 5, 6, 7],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Rock',
      gainsDb: const [5, 4, 3, 1, -1, -1, 1, 3, 4, 5],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Pop',
      gainsDb: const [-1, 0, 2, 4, 5, 4, 2, 0, -1, -1],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Jazz',
      gainsDb: const [4, 3, 1, 2, -1, -1, 0, 1, 3, 4],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Classical',
      gainsDb: const [5, 4, 3, 2, -1, -1, 0, 2, 3, 4],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Electronic',
      gainsDb: const [5, 4, 1, 0, -2, 2, 1, 2, 4, 5],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Hip-Hop',
      gainsDb: const [6, 5, 2, 3, -1, -1, 1, 0, 2, 3],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Vocal',
      gainsDb: const [-2, -3, -2, 1, 4, 5, 4, 2, 0, -1],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Acoustic',
      gainsDb: const [4, 4, 3, 1, 2, 2, 3, 4, 3, 2],
      builtIn: true,
    ),
    EqualizerPreset(
      name: 'Loudness',
      gainsDb: const [6, 5, 3, 0, -1, 0, 1, 3, 5, 6],
      builtIn: true,
    ),
  ]);
}

/// Complete DSP configuration: 10-band EQ, bass boost, virtualizer,
/// loudness enhancer, compressor and limiter. Everything is off by default so
/// an untouched install sounds exactly as before.
class AudioEffectsSettings {
  static const String storageKey = 'audio_effects_v1';

  /// Master switch. When off no native effect is attached at all.
  final bool enabled;

  /// Band gains in dB (`equalizerBandFrequencies` order).
  final List<double> bandGainsDb;

  /// Name of the preset the gains came from, or null for a manual curve.
  final String? presetName;

  /// 0–1 (maps to the platform's 0–1000 strength).
  final double bassBoost;

  /// 0–1 (maps to the platform's 0–1000 strength).
  final double virtualizer;

  /// Loudness enhancer target gain in dB (0–12).
  final double enhancerGainDb;

  final bool compressorEnabled;

  /// Compressor threshold in dBFS (−40…0).
  final double compressorThresholdDb;

  /// Compressor ratio (1…20).
  final double compressorRatio;

  final bool limiterEnabled;

  /// Limiter ceiling in dBFS (−12…0).
  final double limiterThresholdDb;

  AudioEffectsSettings({
    this.enabled = false,
    List<double>? bandGainsDb,
    this.presetName = EqualizerPreset.flatName,
    double bassBoost = 0,
    double virtualizer = 0,
    double enhancerGainDb = 0,
    this.compressorEnabled = false,
    double compressorThresholdDb = -18,
    double compressorRatio = 3,
    this.limiterEnabled = false,
    double limiterThresholdDb = -1,
  }) : bandGainsDb = List<double>.unmodifiable(normalizeBandGains(bandGainsDb)),
       bassBoost = bassBoost.clamp(0.0, 1.0),
       virtualizer = virtualizer.clamp(0.0, 1.0),
       enhancerGainDb = enhancerGainDb.clamp(0.0, 12.0),
       compressorThresholdDb = compressorThresholdDb.clamp(-40.0, 0.0),
       compressorRatio = compressorRatio.clamp(1.0, 20.0),
       limiterThresholdDb = limiterThresholdDb.clamp(-12.0, 0.0);

  bool get isEqualizerFlat => bandGainsDb.every((g) => g == 0);

  /// Whether any stage would audibly change the signal when enabled.
  bool get hasActiveStage =>
      !isEqualizerFlat ||
      bassBoost > 0 ||
      virtualizer > 0 ||
      enhancerGainDb > 0 ||
      compressorEnabled ||
      limiterEnabled;

  AudioEffectsSettings copyWith({
    bool? enabled,
    List<double>? bandGainsDb,
    Object? presetName = _unset,
    double? bassBoost,
    double? virtualizer,
    double? enhancerGainDb,
    bool? compressorEnabled,
    double? compressorThresholdDb,
    double? compressorRatio,
    bool? limiterEnabled,
    double? limiterThresholdDb,
  }) {
    return AudioEffectsSettings(
      enabled: enabled ?? this.enabled,
      bandGainsDb: bandGainsDb ?? this.bandGainsDb,
      presetName: identical(presetName, _unset)
          ? this.presetName
          : presetName as String?,
      bassBoost: bassBoost ?? this.bassBoost,
      virtualizer: virtualizer ?? this.virtualizer,
      enhancerGainDb: enhancerGainDb ?? this.enhancerGainDb,
      compressorEnabled: compressorEnabled ?? this.compressorEnabled,
      compressorThresholdDb:
          compressorThresholdDb ?? this.compressorThresholdDb,
      compressorRatio: compressorRatio ?? this.compressorRatio,
      limiterEnabled: limiterEnabled ?? this.limiterEnabled,
      limiterThresholdDb: limiterThresholdDb ?? this.limiterThresholdDb,
    );
  }

  static const Object _unset = Object();

  /// Applies [preset]'s curve and remembers its name.
  AudioEffectsSettings withPreset(EqualizerPreset preset) =>
      copyWith(bandGainsDb: preset.gainsDb, presetName: preset.name);

  /// Changes one band; the curve becomes "manual" unless it still matches
  /// the named preset exactly.
  AudioEffectsSettings withBandGain(int band, double gainDb) {
    if (band < 0 || band >= bandGainsDb.length) return this;
    final gains = List<double>.of(bandGainsDb);
    gains[band] = _clampGain(gainDb);
    return copyWith(bandGainsDb: gains, presetName: null);
  }

  /// Current curve as an (unsaved) preset.
  EqualizerPreset asPreset(String name) =>
      EqualizerPreset(name: name, gainsDb: bandGainsDb);

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'band_gains_db': bandGainsDb,
    'preset_name': presetName,
    'bass_boost': bassBoost,
    'virtualizer': virtualizer,
    'enhancer_gain_db': enhancerGainDb,
    'compressor_enabled': compressorEnabled,
    'compressor_threshold_db': compressorThresholdDb,
    'compressor_ratio': compressorRatio,
    'limiter_enabled': limiterEnabled,
    'limiter_threshold_db': limiterThresholdDb,
  };

  factory AudioEffectsSettings.fromJson(Map<String, dynamic> json) {
    final presetRaw = json['preset_name'];
    return AudioEffectsSettings(
      enabled: json['enabled'] as bool? ?? false,
      bandGainsDb: normalizeBandGains(json['band_gains_db']),
      presetName: presetRaw == null ? null : presetRaw.toString(),
      bassBoost: _finite(json['bass_boost'], 0),
      virtualizer: _finite(json['virtualizer'], 0),
      enhancerGainDb: _finite(json['enhancer_gain_db'], 0),
      compressorEnabled: json['compressor_enabled'] as bool? ?? false,
      compressorThresholdDb: _finite(json['compressor_threshold_db'], -18),
      compressorRatio: _finite(json['compressor_ratio'], 3),
      limiterEnabled: json['limiter_enabled'] as bool? ?? false,
      limiterThresholdDb: _finite(json['limiter_threshold_db'], -1),
    );
  }

  /// Payload handed to the platform controller. Every stage is expressed in
  /// platform-neutral units (dB, 0–1 strengths); when the master switch is
  /// off the whole chain is reported disabled so native code detaches.
  Map<String, dynamic> toPlatformMap() => {
    'enabled': enabled,
    'band_frequencies_hz': equalizerBandFrequencies,
    'band_gains_db': bandGainsDb,
    'bass_boost': bassBoost,
    'virtualizer': virtualizer,
    'enhancer_gain_db': enhancerGainDb,
    'compressor_enabled': compressorEnabled,
    'compressor_threshold_db': compressorThresholdDb,
    'compressor_ratio': compressorRatio,
    'limiter_enabled': limiterEnabled,
    'limiter_threshold_db': limiterThresholdDb,
  };

  @override
  bool operator ==(Object other) =>
      other is AudioEffectsSettings &&
      other.enabled == enabled &&
      EqualizerPreset._sameGains(other.bandGainsDb, bandGainsDb) &&
      other.presetName == presetName &&
      other.bassBoost == bassBoost &&
      other.virtualizer == virtualizer &&
      other.enhancerGainDb == enhancerGainDb &&
      other.compressorEnabled == compressorEnabled &&
      other.compressorThresholdDb == compressorThresholdDb &&
      other.compressorRatio == compressorRatio &&
      other.limiterEnabled == limiterEnabled &&
      other.limiterThresholdDb == limiterThresholdDb;

  @override
  int get hashCode => Object.hash(
    enabled,
    Object.hashAll(bandGainsDb),
    presetName,
    bassBoost,
    virtualizer,
    enhancerGainDb,
    compressorEnabled,
    compressorThresholdDb,
    compressorRatio,
    limiterEnabled,
    limiterThresholdDb,
  );
}

/// What the running platform can actually do. Reported by the native
/// controller so the UI can grey out unsupported stages instead of showing
/// controls that silently do nothing.
class AudioEffectsCapabilities {
  final bool equalizer;
  final bool bassBoost;
  final bool virtualizer;
  final bool enhancer;
  final bool compressor;
  final bool limiter;

  /// Human-readable engine description (e.g. "DynamicsProcessing 10-band").
  final String engine;

  const AudioEffectsCapabilities({
    required this.equalizer,
    required this.bassBoost,
    required this.virtualizer,
    required this.enhancer,
    required this.compressor,
    required this.limiter,
    required this.engine,
  });

  static const AudioEffectsCapabilities none = AudioEffectsCapabilities(
    equalizer: false,
    bassBoost: false,
    virtualizer: false,
    enhancer: false,
    compressor: false,
    limiter: false,
    engine: 'unavailable',
  );

  bool get any =>
      equalizer ||
      bassBoost ||
      virtualizer ||
      enhancer ||
      compressor ||
      limiter;

  factory AudioEffectsCapabilities.fromMap(Map<String, dynamic> map) {
    bool flag(String key) => map[key] == true;
    return AudioEffectsCapabilities(
      equalizer: flag('equalizer'),
      bassBoost: flag('bass_boost'),
      virtualizer: flag('virtualizer'),
      enhancer: flag('enhancer'),
      compressor: flag('compressor'),
      limiter: flag('limiter'),
      engine: map['engine']?.toString() ?? 'unknown',
    );
  }
}

/// Import/export format for user presets: a small JSON envelope that older
/// and newer app versions can both read.
class EqualizerPresetCodec {
  static const String type = 'spotiflac-eq-presets';
  static const int version = 1;
  static const String fileExtension = 'eqpresets.json';

  /// Maximum presets accepted from one import (guards against junk files).
  static const int maxPresets = 200;

  static String encode(Iterable<EqualizerPreset> presets) {
    return const JsonEncoder.withIndent('  ').convert({
      'type': type,
      'version': version,
      'bands_hz': equalizerBandFrequencies,
      'presets': [for (final preset in presets) preset.toJson()],
    });
  }

  /// Parses an export. Accepts the envelope, a bare list of presets, or a
  /// single preset object. Returns an empty list for anything unusable;
  /// never throws.
  static List<EqualizerPreset> decode(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const [];
    }
    Object? entries;
    if (decoded is Map) {
      if (decoded.containsKey('presets')) {
        if (decoded['type'] != null && decoded['type'] != type) {
          return const [];
        }
        entries = decoded['presets'];
      } else {
        entries = [decoded];
      }
    } else {
      entries = decoded;
    }
    if (entries is! List) return const [];
    final seen = <String>{};
    final presets = <EqualizerPreset>[];
    for (final entry in entries) {
      if (presets.length >= maxPresets) break;
      final preset = EqualizerPreset.fromJson(entry);
      if (preset == null) continue;
      if (!seen.add(preset.name.toLowerCase())) continue;
      presets.add(preset);
    }
    return presets;
  }
}
