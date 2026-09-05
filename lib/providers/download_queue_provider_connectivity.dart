// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueueConnectivity on DownloadQueueNotifier {
  bool _hasWifiConnection(List<ConnectivityResult> results) {
    return NetworkSwitchPolicy.hasWifi(results.map(_connectivityTransport));
  }

  String _connectivityTransport(ConnectivityResult result) {
    return switch (result) {
      ConnectivityResult.wifi => NetworkTransport.wifi,
      ConnectivityResult.ethernet => NetworkTransport.ethernet,
      ConnectivityResult.vpn => NetworkTransport.vpn,
      ConnectivityResult.mobile => NetworkTransport.mobile,
      ConnectivityResult.none => NetworkTransport.none,
      _ => NetworkTransport.other,
    };
  }

  void _startConnectivityMonitoring() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _handleConnectivityResults,
      onError: (Object error, StackTrace stackTrace) {
        _log.w('Connectivity monitoring failed: $error');
      },
      cancelOnError: false,
    );
  }

  void _stopConnectivityMonitoring({bool clearNetworkPause = true}) {
    if (clearNetworkPause) {
      _networkPausedByWifiOnly = false;
    }
    // Keep listening while network-failed items remain so the reconnect
    // retry prompt can still fire when the queue is otherwise idle.
    if (_hasNetworkFailedItems) return;
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  bool get _hasNetworkFailedItems => state.items.any(
    (item) =>
        item.status == DownloadStatus.failed &&
        item.errorType == DownloadErrorType.network,
  );

  /// Offers a one-tap retry for network-failed items once connectivity
  /// returns, debounced so network flapping doesn't spam snackbars.
  void _maybeOfferRetryAfterReconnect(List<ConnectivityResult> results) {
    if (results.every((result) => result == ConnectivityResult.none)) return;
    final failedCount = state.items
        .where(
          (item) =>
              item.status == DownloadStatus.failed &&
              item.errorType == DownloadErrorType.network,
        )
        .length;
    if (failedCount == 0) return;
    final now = DateTime.now();
    if (now.difference(_lastReconnectRetryPromptAt) <
        NetworkSwitchPolicy.reconnectRetryPromptDebounce) {
      return;
    }
    _lastReconnectRetryPromptAt = now;

    final context = AppNavigationService.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final l10n = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.queueNetworkFailedOffline(failedCount)),
        action: SnackBarAction(
          label: l10n.dialogRetry,
          onPressed: () => retryAllFailed(networkOnly: true),
        ),
      ),
    );
  }

  void _handleDownloadNetworkModeChanged(String mode) {
    if (mode == 'wifi_only') {
      if (state.isProcessing || _networkPausedByWifiOnly) {
        _startConnectivityMonitoring();
      }
      return;
    }

    final shouldResume = _networkPausedByWifiOnly && state.isPaused;
    // Keep monitoring active in every mode while downloading so idle
    // connections are still recycled when the network switches.
    if (state.isProcessing) {
      _networkPausedByWifiOnly = false;
      _startConnectivityMonitoring();
    } else {
      _stopConnectivityMonitoring();
    }
    if (shouldResume) {
      resumeQueue();
    }
  }

  /// Closes idle backend HTTP connections when the connectivity set changes
  /// (e.g. WiFi <-> cellular). Stale sockets bound to the old interface would
  /// otherwise be reused, stalling the first request after a network switch.
  /// Applies to every download network mode. Fire-and-forget with a light
  /// debounce so network flapping does not spam the bridge.
  void _maybeCleanupOnNetworkChange(NetworkSwitchDecision decision) {
    if (decision.action != NetworkSwitchAction.recycleConnections) return;
    _lastConnectionCleanupAt = DateTime.now();
    _log.i('Network changed, closing idle backend connections');
    unawaited(
      PlatformBridge.cleanupConnections().catchError((Object e) {
        _log.w('Failed to clean up connections after network change: $e');
      }),
    );
  }

  void _handleConnectivityResults(List<ConnectivityResult> results) {
    final previous = _lastConnectivityResults;
    final settings = ref.read(settingsProvider);
    final decision = NetworkSwitchPolicy.decide(
      current: results.map(_connectivityTransport),
      previous: previous?.map(_connectivityTransport),
      now: DateTime.now(),
      lastCleanupAt: _lastConnectionCleanupAt,
      wifiOnlyMode: settings.downloadNetworkMode == 'wifi_only',
      queueProcessing: state.isProcessing && !state.isPaused,
      queuePausedForWifi: _networkPausedByWifiOnly,
    );
    _lastConnectivityResults = List<ConnectivityResult>.unmodifiable(results);

    _maybeCleanupOnNetworkChange(decision);
    _maybeOfferRetryAfterReconnect(results);

    // The schedule's own WiFi condition reacts to network changes immediately
    // instead of waiting for the next periodic re-evaluation.
    if (_scheduleSettings.enabled && _scheduleSettings.requireWifi) {
      unawaited(_applyScheduleGate());
    }

    if (decision.shouldResumeWifiOnlyQueue && state.isPaused) {
      _networkPausedByWifiOnly = false;
      _log.i('WiFi restored, resuming network-paused queue');
      resumeQueue();
      return;
    }

    if (decision.shouldPauseWifiOnlyQueue) {
      _networkPausedByWifiOnly = true;
      _log.w('WiFi connection lost, pausing active queue');
      pauseQueue(persistAcrossRestarts: false);
    }
  }
}
