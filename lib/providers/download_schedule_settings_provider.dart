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

  /// Only download while the device is plugged in (charging or full).
  final bool requireCharging;

  /// Do not start/continue downloads below this battery percentage
  /// (0 = disabled). Ignored while charging.
  final int minBatteryPercent;

  /// Only download on WiFi/ethernet while scheduling is enabled. Independent
  /// of the global "WiFi only" download network mode so a nightly window can
  /// be WiFi-gated without changing daytime behavior.
  final bool requireWifi;

  const DownloadScheduleSettings({
    this.enabled = false,
    this.startMinute = 22 * 60, // 22:00
    this.endMinute = 7 * 60, // 07:00 (next day)
    this.requireCharging = false,
    this.minBatteryPercent = 0,
    this.requireWifi = false,
  });

  /// Whether the time window is the "whole day" (start == end), i.e. the
  /// schedule consists only of device conditions.
  bool get allDay => startMinute == endMinute;

  /// Whether any device condition (charging/battery/WiFi) is configured.
  bool get hasDeviceConditions =>
      requireCharging || minBatteryPercent > 0 || requireWifi;

  /// Evaluates the device conditions against a live snapshot. Unknown power
  /// information never blocks (the platform could not tell, so the user's
  /// intent cannot be honored either way and downloads must not silently
  /// stall forever); an unknown network is treated as "not WiFi".
  ///
  /// Returns null when downloads may run, otherwise a short reason.
  String? blockedReason({
    required bool charging,
    required int batteryLevel,
    required bool powerKnown,
    required bool onWifi,
  }) {
    if (requireWifi && !onWifi) return 'waiting for WiFi';
    if (powerKnown) {
      if (requireCharging && !charging) return 'waiting for charger';
      if (minBatteryPercent > 0 &&
          !charging &&
          batteryLevel >= 0 &&
          batteryLevel < minBatteryPercent) {
        return 'battery below $minBatteryPercent%';
      }
    }
    return null;
  }

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
  ///
  /// Always returns a moment strictly after [now]: a same-day window that
  /// already closed today (e.g. 10:00–14:00 and it is 16:00) resumes
  /// *tomorrow* at the start minute, never at a time in the past.
  DateTime? nextOpenMoment(DateTime now) {
    if (isWithinWindow(now)) return null;
    final candidate = _atMinute(startMinute, now);
    if (candidate.isAfter(now)) return candidate;
    // Start minute already passed today (closed window or a nightly window
    // that opened before midnight and ended this morning): resume tomorrow.
    return candidate.add(const Duration(days: 1));
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
    bool? requireCharging,
    int? minBatteryPercent,
    bool? requireWifi,
  }) => DownloadScheduleSettings(
    enabled: enabled ?? this.enabled,
    startMinute: (startMinute ?? this.startMinute).clamp(0, 1439),
    endMinute: (endMinute ?? this.endMinute).clamp(0, 1439),
    requireCharging: requireCharging ?? this.requireCharging,
    minBatteryPercent: (minBatteryPercent ?? this.minBatteryPercent).clamp(
      0,
      100,
    ),
    requireWifi: requireWifi ?? this.requireWifi,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'start_minute': startMinute,
    'end_minute': endMinute,
    'require_charging': requireCharging,
    'min_battery_percent': minBatteryPercent,
    'require_wifi': requireWifi,
  };

  /// Older stores (v1 without device conditions) decode with the conditions
  /// off, so an existing nightly window keeps behaving exactly as before.
  factory DownloadScheduleSettings.fromJson(Map<String, dynamic> json) =>
      DownloadScheduleSettings(
        enabled: json['enabled'] as bool? ?? false,
        startMinute:
            ((json['start_minute'] as num?)?.toInt() ?? 22 * 60).clamp(0, 1439),
        endMinute:
            ((json['end_minute'] as num?)?.toInt() ?? 7 * 60).clamp(0, 1439),
        requireCharging: json['require_charging'] as bool? ?? false,
        minBatteryPercent:
            ((json['min_battery_percent'] as num?)?.toInt() ?? 0).clamp(0, 100),
        requireWifi: json['require_wifi'] as bool? ?? false,
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

  Future<void> setRequireCharging(bool value) =>
      _apply(state.copyWith(requireCharging: value));

  Future<void> setMinBatteryPercent(int value) =>
      _apply(state.copyWith(minBatteryPercent: value));

  Future<void> setRequireWifi(bool value) =>
      _apply(state.copyWith(requireWifi: value));

  /// One-tap presets shown in the scheduling page.
  Future<void> applyNightPreset() => _apply(
    state.copyWith(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60),
  );

  Future<void> applyChargingWifiPreset() => _apply(
    state.copyWith(
      enabled: true,
      startMinute: 0,
      endMinute: 0,
      requireCharging: true,
      requireWifi: true,
    ),
  );
}

final downloadScheduleEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(downloadScheduleSettingsProvider.select((s) => s.enabled)),
);
