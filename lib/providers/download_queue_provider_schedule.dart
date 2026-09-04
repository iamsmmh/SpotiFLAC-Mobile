// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueueSchedule on DownloadQueueNotifier {
  DownloadScheduleSettings get _scheduleSettings =>
      ref.read(downloadScheduleSettingsProvider);

  /// Whether the configured time window (when enabled) currently blocks the
  /// queue from processing. Device conditions are evaluated separately by
  /// [_scheduleConditionBlockedReason] because they need async platform
  /// reads.
  bool get _scheduleBlocked {
    final settings = _scheduleSettings;
    if (!settings.enabled) return false;
    return !settings.isWithinWindow(DateTime.now());
  }

  /// Whether the device conditions (charging / battery / WiFi) currently
  /// block the queue. Null = downloads may run. Never throws.
  Future<String?> _scheduleConditionBlockedReason() async {
    final settings = _scheduleSettings;
    if (!settings.enabled || !settings.hasDeviceConditions) return null;
    var onWifi = true;
    if (settings.requireWifi) {
      try {
        onWifi = _hasWifiConnection(await Connectivity().checkConnectivity());
      } catch (_) {
        onWifi = false;
      }
    }
    final power = (settings.requireCharging || settings.minBatteryPercent > 0)
        ? await PlatformBridge.getPowerStatus()
        : PowerStatus.unknown;
    return settings.blockedReason(
      charging: power.charging,
      batteryLevel: power.level,
      powerKnown: power.known,
      onWifi: onWifi,
    );
  }

  /// Pauses the queue when the schedule (time window *or* device conditions)
  /// blocks downloads and arms a monitor that resumes it once it opens.
  /// Returns true when the queue is currently blocked by the schedule.
  Future<bool> _applyScheduleGate() async {
    final settings = _scheduleSettings;
    if (!settings.enabled) {
      _stopScheduleMonitor();
      if (_schedulePausedByWindow && state.isPaused) {
        _schedulePausedByWindow = false;
        _scheduleBlockReason = null;
        if (state.queuedCount > 0) resumeQueue();
      }
      if (state.scheduleHoldReason != null) {
        state = state.copyWith(scheduleHoldReason: null);
      }
      return false;
    }
    final reason = _scheduleBlocked
        ? 'outside the download window'
        : await _scheduleConditionBlockedReason();
    if (reason != null) {
      if (_scheduleBlockReason != reason) {
        _log.i('Download schedule: $reason; holding queue');
      }
      _scheduleBlockReason = reason;
      _schedulePausedByWindow = true;
      if (state.isProcessing && !state.isPaused) {
        pauseQueue(persistAcrossRestarts: false);
      } else if (state.queuedCount > 0 && !state.isProcessing) {
        state = state.copyWith(isProcessing: false, isPaused: true);
      }
      if (state.scheduleHoldReason != reason) {
        state = state.copyWith(scheduleHoldReason: reason);
      }
      _startScheduleMonitor();
      return true;
    }
    _scheduleBlockReason = null;
    if (state.scheduleHoldReason != null) {
      state = state.copyWith(scheduleHoldReason: null);
    }
    // Keep monitoring while conditions are configured: a charger being
    // unplugged mid-batch must pause the queue, not only block its start.
    if (settings.hasDeviceConditions && state.queuedCount > 0) {
      _startScheduleMonitor();
    } else {
      _stopScheduleMonitor();
    }
    if (_schedulePausedByWindow && state.isPaused && state.queuedCount > 0) {
      _schedulePausedByWindow = false;
      _log.i('Download schedule reopened; resuming queue');
      resumeQueue();
    }
    return false;
  }

  void _startScheduleMonitor() {
    if (_scheduleTimer != null) return;
    _scheduleTimer = Timer.periodic(_scheduleMonitorInterval, (_) {
      if (_scheduleGateInFlight) return;
      _scheduleGateInFlight = true;
      _applyScheduleGate().whenComplete(() => _scheduleGateInFlight = false);
    });
  }

  void _stopScheduleMonitor() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
  }
}
