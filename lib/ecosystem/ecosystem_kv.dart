/// Tiny key/value port shared by the ecosystem modules.
///
/// Existing settings surfaces own their own persistence
/// (`AppSettings`, `EngineSettings`, per-service prefs). New modules use this
/// port instead so their controllers are unit-testable without a plugin
/// channel, and so a future "sync these settings" pass has one seam.
library;

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class KeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);
}

/// [SharedPreferences]-backed implementation.
class PreferencesKeyValueStore implements KeyValueStore {
  PreferencesKeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<PreferencesKeyValueStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return PreferencesKeyValueStore(prefs);
  }

  @override
  Future<String?> read(String key) async => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }
}

/// [SharedPreferences] awaited lazily, so a controller can be constructed
/// synchronously without waiting for the plugin channel.
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore(this._future);

  final Future<SharedPreferences> _future;

  @override
  Future<String?> read(String key) async => (await _future).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await _future).setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await (await _future).remove(key);
  }
}

/// In-memory implementation for tests and for "settings not loaded yet".
class MemoryKeyValueStore implements KeyValueStore {
  MemoryKeyValueStore([Map<String, String>? initial])
    : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }
}

/// Namespaced view over a [KeyValueStore] so modules cannot collide.
class NamespacedKeyValueStore implements KeyValueStore {
  const NamespacedKeyValueStore(this._delegate, this._prefix);

  final KeyValueStore _delegate;
  final String _prefix;

  String _key(String key) => '$_prefix$key';

  @override
  Future<String?> read(String key) => _delegate.read(_key(key));

  @override
  Future<void> write(String key, String value) =>
      _delegate.write(_key(key), value);

  @override
  Future<void> remove(String key) => _delegate.remove(_key(key));
}
