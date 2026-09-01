import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Download scheduling settings.
///
/// Independent of `AppSettings` so the JSON-serializable settings model does
/// not need regeneration on every scheduling tweak. Persisted under
/// `download_schedule_v1`.
class DownloadScheduleSettings {
  static const String storageKey = 'download_schedule_v1';

  /// Master switch. When off, downloads start immediately.
  final bool enabled;

  /// Start of the allowed download window (minutes since local midnight).
  final int startMinute;

  /// End of the allowed download window (minutes since local midnight).
  final int endMinute;

  const DownloadScheduleSettings({
    this.enabled = false,
    this.startMinute = 22 * 60, // 22:00
    this.endMinute = 7 * 60, // 07:00 (next day)
  });

  /// Whether a window that crosses midnight is active now.
  bool isWithinWindow(DateTime now) {
    final current = now.hour * 60 + now.minute;
    if (startMinute == endMinute) return true;
    if (startMinute < endMinute) {
      return current >= startMinute && current <= endMinute;
    }
    // Nightly window: start -> midnight OR midnight -> end.
    return current >= startMinute || current <= endMinute;
  }

  /// The next [DateTime] at which downloads may resume (null = already open).
  DateTime? nextOpenMoment(DateTime now) {
    if (isWithinWindow(now)) return null;
    if (startMinute <= endMinute) {
      return _atMinute(startMinute, now);
    }
    // Crosses midnight: if now is before end (morning), wait until tonight.
    if (now.hour * 60 + now.minute < endMinute) {
      return _atMinute(startMinute, now);
    }
    return _atMinute(startMinute, now);
  }

  DateTime _atMinute(int minute, DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return day.add(Duration(minutes: minute));
  }

  String get startLabel {
    final h = (startMinute ~/ 60).toString().padLeft(2, '0');
    final m = (startMinute % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  String get endLabel {
    final h = (endMinute ~/ 60).toString().padLeft(2, '0');
    final m = (endMinute % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  DownloadScheduleSettings copyWith({
    bool? enabled,
    int? startMinute,
    int? endMinute,
  }) => DownloadScheduleSettings(
    enabled: enabled ?? this.enabled,
    startMinute: (startMinute ?? this.startMinute).clamp(0, 1439),
    endMinute: (endMinute ?? this.endMinute).clamp(0, 1439),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'start_minute': startMinute,
    'end_minute': endMinute,
  };

  factory DownloadScheduleSettings.fromJson(Map<String, dynamic> json) =>
      DownloadScheduleSettings(
        enabled: json['enabled'] as bool? ?? false,
        startMinute: (json['start_minute'] as num?)?.toInt() ?? 22 * 60,
        endMinute: (json['end_minute'] as num?)?.toInt() ?? 7 * 60,
      );
}

DownloadScheduleSettings loadDownloadScheduleSettings(SharedPreferences prefs) {
  final raw = prefs.getString(DownloadScheduleSettings.storageKey);
  if (raw == null || raw.isEmpty) return const DownloadScheduleSettings();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return DownloadScheduleSettings.fromJson(decoded);
    }
  } catch (_) {
    // Corrupted store must never break startup.
  }
  return const DownloadScheduleSettings();
}

final downloadScheduleSettingsProvider = NotifierProvider<
    DownloadScheduleSettingsNotifier,
    DownloadScheduleSettings>(DownloadScheduleSettingsNotifier.new);

class DownloadScheduleSettingsNotifier
    extends Notifier<DownloadScheduleSettings> {
  SharedPreferences? _prefs;

  @override
  DownloadScheduleSettings build() => const DownloadScheduleSettings();

  Future<void> attach(SharedPreferences prefs) async {
    _prefs = prefs;
    state = loadDownloadScheduleSettings(prefs);
  }

  Future<void> _apply(DownloadScheduleSettings next) async {
    state = next;
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      _prefs = prefs;
      await prefs.setString(
        DownloadScheduleSettings.storageKey,
        jsonEncode(next.toJson()),
      );
    } catch (_) {
      // Persistence failure must not break the running session.
    }
  }

  Future<void> setEnabled(bool value) => _apply(state.copyWith(enabled: value));

  Future<void> setStartMinute(int value) =>
      _apply(state.copyWith(startMinute: value));

  Future<void> setEndMinute(int value) =>
      _apply(state.copyWith(endMinute: value));
}

final downloadScheduleEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(downloadScheduleSettingsProvider.select((s) => s.enabled)),
);
