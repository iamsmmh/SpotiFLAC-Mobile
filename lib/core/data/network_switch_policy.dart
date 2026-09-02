/// Wi-Fi ↔ cellular (and offline) switch handling for downloads + streaming.
///
/// A network change must:
///  1. Close idle HTTP/2 sockets bound to the old interface (otherwise the
///     first request after a switch stalls on a dead connection).
///  2. Pause a wifi-only download queue when Wi-Fi disappears, and resume
///     it when Wi-Fi returns.
///  3. Debounce flaps so a bouncing radio does not thrash the Go backend.
library;

/// Connectivity tokens understood by the production policy. Kept as strings
/// so tests do not have to import connectivity_plus.
abstract final class NetworkTransport {
  static const String wifi = 'wifi';
  static const String ethernet = 'ethernet';
  static const String vpn = 'vpn';
  static const String mobile = 'mobile';
  static const String other = 'other';
  static const String none = 'none';
}

enum NetworkSwitchAction {
  /// First observation after process start — record, do not cleanup.
  observe,

  /// Same transport set as last time — no-op.
  ignore,

  /// Transports changed inside the debounce window — skip cleanup.
  debounce,

  /// Transports changed and the debounce elapsed — recycle sockets.
  recycleConnections,
}

class NetworkSwitchDecision {
  const NetworkSwitchDecision({
    required this.action,
    required this.hasWifi,
    required this.isOffline,
    required this.shouldPauseWifiOnlyQueue,
    required this.shouldResumeWifiOnlyQueue,
  });

  final NetworkSwitchAction action;
  final bool hasWifi;
  final bool isOffline;
  final bool shouldPauseWifiOnlyQueue;
  final bool shouldResumeWifiOnlyQueue;
}

abstract final class NetworkSwitchPolicy {
  static const Duration connectionCleanupDebounce = Duration(seconds: 2);
  static const Duration reconnectRetryPromptDebounce = Duration(minutes: 1);

  static bool hasWifi(Iterable<String> transports) {
    final set = transports.map((t) => t.toLowerCase()).toSet();
    return set.contains(NetworkTransport.wifi) ||
        set.contains(NetworkTransport.ethernet);
  }

  static bool isOffline(Iterable<String> transports) {
    final set = transports.map((t) => t.toLowerCase()).toSet();
    if (set.isEmpty) return true;
    return set.length == 1 && set.contains(NetworkTransport.none);
  }

  static bool sameTransportSet(Iterable<String> a, Iterable<String> b) {
    final setA = a.map((t) => t.toLowerCase()).toSet();
    final setB = b.map((t) => t.toLowerCase()).toSet();
    return setA.length == setB.length && setA.containsAll(setB);
  }

  /// Decide what the queue / engine should do on a connectivity callback.
  static NetworkSwitchDecision decide({
    required Iterable<String> current,
    Iterable<String>? previous,
    required DateTime now,
    required DateTime lastCleanupAt,
    required bool wifiOnlyMode,
    required bool queueProcessing,
    required bool queuePausedForWifi,
  }) {
    final wifi = hasWifi(current);
    final offline = isOffline(current);

    final NetworkSwitchAction action;
    if (previous == null) {
      action = NetworkSwitchAction.observe;
    } else if (sameTransportSet(previous, current)) {
      action = NetworkSwitchAction.ignore;
    } else if (now.difference(lastCleanupAt) < connectionCleanupDebounce) {
      action = NetworkSwitchAction.debounce;
    } else {
      action = NetworkSwitchAction.recycleConnections;
    }

    final shouldPause =
        wifiOnlyMode && queueProcessing && !wifi && !queuePausedForWifi;
    final shouldResume = wifiOnlyMode && queuePausedForWifi && wifi;

    return NetworkSwitchDecision(
      action: action,
      hasWifi: wifi,
      isOffline: offline,
      shouldPauseWifiOnlyQueue: shouldPause,
      shouldResumeWifiOnlyQueue: shouldResume,
    );
  }
}
