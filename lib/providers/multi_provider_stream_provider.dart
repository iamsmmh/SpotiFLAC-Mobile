import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spotimusic/services/multi_provider_stream_service.dart';

/// App-wide [MultiProviderStreamService] instance (YouTube Explode + HTTP are
/// kept for the app lifetime and disposed only with the provider container).
final multiProviderStreamServiceProvider =
    Provider<MultiProviderStreamService>((ref) {
      final service = MultiProviderStreamService();
      ref.onDispose(service.dispose);
      return service;
    });

/// The currently selected streaming provider chip. Persisted across launches.
class ActiveStreamProviderNotifier extends Notifier<StreamProviderId> {
  static const String _prefsKey = 'spotimusic.active_stream_provider';

  @override
  StreamProviderId build() {
    // YouTube is always playable without credentials, so it is the safe
    // default until the persisted choice is restored (via [load] at startup
    // or lazily on first access).
    unawaited(load());
    return StreamProviderId.youtube;
  }

  Future<void> select(StreamProviderId provider) async {
    state = provider;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, provider.name);
  }

  /// Restores the persisted choice (called during eager startup).
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    final parsed = _parseProvider(stored);
    if (parsed != null) state = parsed;
  }
}

final activeStreamProviderProvider = NotifierProvider<
    ActiveStreamProviderNotifier,
    StreamProviderId>(ActiveStreamProviderNotifier.new);

StreamProviderId? _parseProvider(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  for (final id in StreamProviderId.values) {
    if (id.name == raw) return id;
  }
  return null;
}
