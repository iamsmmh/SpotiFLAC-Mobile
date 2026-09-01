// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueueSchedule on DownloadQueueNotifier {
  DownloadScheduleSettings get _scheduleSettings =>
      ref.read(downloadScheduleSettingsProvider);

  /// Whether the configured time window (when enabled) currently blocks the
  /// queue from processing.
  bool get _scheduleBlocked {
    final settings = _scheduleSettings;
    if (!settings.enabled) return false;
    return !settings.isWithinWindow(DateTime.now());
  }

  /// Pauses the queue when the schedule window is closed and arms a monitor
  /// that resumes it once the window reopens.
  Future<void> _applyScheduleGate() async {
    if (!_scheduleSettings.enabled) {
      _stopScheduleMonitor();
      return;
    }
    if (_scheduleBlocked) {
      _schedulePausedByWindow = true;
      if (state.isProcessing && !state.isPaused) {
        _log.i('Download schedule window closed; pausing queue');
        pauseQueue(persistAcrossRestarts: false);
      } else if (state.queuedCount > 0 && !state.isProcessing) {
        state = state.copyWith(isProcessing: false, isPaused: true);
      }
      _startScheduleMonitor();
      return;
    }
    _stopScheduleMonitor();
    if (_schedulePausedByWindow && state.isPaused && state.queuedCount > 0) {
      _schedulePausedByWindow = false;
      _log.i('Download schedule window reopened; resuming queue');
      resumeQueue();
    }
  }

  void _startScheduleMonitor() {
    if (_scheduleTimer != null) return;
    _scheduleTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_scheduleBlocked) return;
      if (_schedulePausedByWindow && state.isPaused) {
        _schedulePausedByWindow = false;
        resumeQueue();
      }
    });
  }

  void _stopScheduleMonitor() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
  }
}
