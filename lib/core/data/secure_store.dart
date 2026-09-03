/// Production secure storage for secrets, tokens, and extension signatures.
///
/// Backends:
///  * Android — encrypted preferences via flutter_secure_storage (v10+ always
///    encrypts values under a Keystore-backed master key).
///  * iOS / macOS — Keychain with `first_unlock_this_device` accessibility
///    so items survive background playback but never leave the device via
///    iCloud Keychain sync.
///
/// Keys are namespaced so a leaked token cannot collide with a signature, and
/// retired secrets (the old Spotify client secret) are wiped on boot.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Well-known keys. Keep spellings stable: a rename orphans Keychain items.
abstract final class SecureStoreKeys {
  static const String schemaVersion = 'spotiflac.secure.schema_version';
  static const String spotifyClientSecret = 'spotify_client_secret';

  static const String tokenPrefix = 'spotiflac.token.';
  static const String secretPrefix = 'spotiflac.secret.';
  static const String signaturePrefix = 'spotiflac.extsig.';

  static String token(String name) => '$tokenPrefix$name';
  static String secret(String name) => '$secretPrefix$name';
  static String extensionSignature(String extensionId) =>
      '$signaturePrefix$extensionId';
}

/// Key-shape rules shared with the native EncryptedSharedPreferences store.
abstract final class SecureStorePolicy {
  static const int currentSchemaVersion = 1;
  static const int maxKeyLength = 128;
  static const int maxValueBytes = 16 * 1024;

  /// Retry cap for boot-time initialization against a flaky secure-storage
  /// backend; after this many failures the store is treated as initialized
  /// (best-effort) so boot cannot loop on retrying forever.
  static const int maxInitAttempts = 3;

  static const Set<String> allowedPrefixes = <String>{
    SecureStoreKeys.tokenPrefix,
    SecureStoreKeys.secretPrefix,
    SecureStoreKeys.signaturePrefix,
  };

  static const Set<String> retiredKeys = <String>{
    SecureStoreKeys.spotifyClientSecret,
  };

  /// True when [key] is a namespaced production key or a known retired key
  /// that we still need to be able to delete.
  static bool isAllowedKey(String key) {
    // Check the raw key for control characters BEFORE trimming, so a
    // trailing "\n" cannot be silently stripped into a valid key. Mirrors
    // NativeSecureStorePolicy.isAllowedKey on Android.
    if (key.contains('\n') || key.contains('\u0000')) return false;
    final trimmed = key.trim();
    if (trimmed.isEmpty || trimmed.length > maxKeyLength) return false;
    if (trimmed == SecureStoreKeys.schemaVersion) return true;
    if (retiredKeys.contains(trimmed)) return true;
    for (final prefix in allowedPrefixes) {
      if (trimmed.startsWith(prefix) && trimmed.length > prefix.length) {
        return true;
      }
    }
    return false;
  }

  static bool isAllowedValue(String value) {
    return value.length <= maxValueBytes;
  }
}

/// Thin, injectable facade over [FlutterSecureStorage]. Tests pass a fake.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? _platformStorage;

  static final SecureStore instance = SecureStore();

  static const FlutterSecureStorage _platformStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  final FlutterSecureStorage _storage;
  bool _initialized = false;
  int _initAttempts = 0;

  /// Writes the schema version on first use and wipes retired secrets.
  /// Plugin-missing / Keychain failures are swallowed so a cold start never
  /// dies on the secure-storage path (the next write will retry).
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      final stored = await _storage.read(key: SecureStoreKeys.schemaVersion);
      if (stored != '${SecureStorePolicy.currentSchemaVersion}') {
        await _storage.write(
          key: SecureStoreKeys.schemaVersion,
          value: '${SecureStorePolicy.currentSchemaVersion}',
        );
      }
      await deleteRetiredSecrets();
      _initialized = true;
    } catch (_) {
      // MissingPluginException in tests, or a Keychain/EncryptedSharedPreferences
      // outage on a locked device. Non-fatal — and crucially NOT marked
      // initialized, so the next boot-time call retries instead of skipping
      // schema migration/secret cleanup forever. A retry cap avoids log spam
      // from a persistently failing backend.
      _initAttempts += 1;
      if (_initAttempts >= SecureStorePolicy.maxInitAttempts) {
        _initialized = true;
      }
    }
  }

  Future<String?> read(String key) async {
    _assertKey(key);
    return _storage.read(key: key);
  }

  Future<void> write(String key, String value) async {
    _assertKey(key);
    if (!SecureStorePolicy.isAllowedValue(value)) {
      throw ArgumentError.value(value.length, 'value', 'exceeds size cap');
    }
    await _storage.write(key: key, value: value);
  }

  Future<void> delete(String key) async {
    _assertKey(key);
    await _storage.delete(key: key);
  }

  Future<void> writeToken(String name, String value) =>
      write(SecureStoreKeys.token(name), value);

  Future<String?> readToken(String name) => read(SecureStoreKeys.token(name));

  Future<void> deleteToken(String name) => delete(SecureStoreKeys.token(name));

  Future<void> writeSecret(String name, String value) =>
      write(SecureStoreKeys.secret(name), value);

  Future<String?> readSecret(String name) =>
      read(SecureStoreKeys.secret(name));

  Future<void> writeExtensionSignature(String extensionId, String hex) =>
      write(SecureStoreKeys.extensionSignature(extensionId), hex);

  Future<String?> readExtensionSignature(String extensionId) =>
      read(SecureStoreKeys.extensionSignature(extensionId));

  Future<void> deleteExtensionSignature(String extensionId) =>
      delete(SecureStoreKeys.extensionSignature(extensionId));

  /// Best-effort wipe of keys that used to live in plaintext prefs.
  Future<void> deleteRetiredSecrets() async {
    for (final key in SecureStorePolicy.retiredKeys) {
      try {
        final stored = await _storage.read(key: key);
        if (stored != null && stored.isNotEmpty) {
          await _storage.delete(key: key);
        }
      } catch (_) {
        // A Keychain/EncryptedSharedPreferences miss is not fatal at boot.
      }
    }
  }

  void _assertKey(String key) {
    if (!SecureStorePolicy.isAllowedKey(key)) {
      throw ArgumentError.value(key, 'key', 'rejected by SecureStorePolicy');
    }
  }
}
