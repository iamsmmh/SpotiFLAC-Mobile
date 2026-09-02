/// Storage / notification permission matrix for Android 13–16+ (API 33–36+).
///
/// Downloads themselves go through SAF (`ACTION_OPEN_DOCUMENT_TREE`) and do
/// not need `MANAGE_EXTERNAL_STORAGE`. What *does* change across SDK levels:
///  * API 33+ (Android 13) — `READ_MEDIA_AUDIO` replaces `READ_EXTERNAL_STORAGE`
///    for library scans; `POST_NOTIFICATIONS` is a runtime permission.
///  * API 34+ (Android 14) — partial photo/audio access; we still request the
///    full audio grant because a music library is not a picker-sized set.
///  * API 35–36 (Android 15–16) — `READ_MEDIA_AUDIO` remains the grant; the
///    `dataSync` FGS 6h/24h budget is a *service* constraint, not a permission.
library;

enum AndroidStoragePermission {
  readExternalStorage,
  writeExternalStorage,
  readMediaAudio,
  manageExternalStorage,
  postNotifications,
}

class AndroidPermissionSet {
  const AndroidPermissionSet({
    required this.sdk,
    required this.runtime,
    required this.optional,
    required this.usesSafForDownloads,
    required this.notificationsAreRuntime,
  });

  final int sdk;
  final List<AndroidStoragePermission> runtime;
  final List<AndroidStoragePermission> optional;
  final bool usesSafForDownloads;
  final bool notificationsAreRuntime;
}

abstract final class AndroidStoragePermissionPolicy {
  /// First SDK that introduced the granular media permissions + notification
  /// runtime grant (Android 13).
  static const int granularMediaSdk = 33;

  /// Scoped-storage enforcement (Android 10). Below this, legacy
  /// `WRITE_EXTERNAL_STORAGE` still applies.
  static const int scopedStorageSdk = 29;

  /// Android 11 — `MANAGE_EXTERNAL_STORAGE` exists but is optional here
  /// because SAF is the supported download destination.
  static const int allFilesAccessSdk = 30;

  /// Android 15 — `dataSync` FGS 6h/24h budget begins.
  static const int dataSyncBudgetSdk = 35;

  static AndroidPermissionSet forSdk(int sdk) {
    if (sdk >= granularMediaSdk) {
      return AndroidPermissionSet(
        sdk: sdk,
        runtime: const <AndroidStoragePermission>[
          AndroidStoragePermission.readMediaAudio,
          AndroidStoragePermission.postNotifications,
        ],
        optional: const <AndroidStoragePermission>[
          AndroidStoragePermission.manageExternalStorage,
        ],
        usesSafForDownloads: true,
        notificationsAreRuntime: true,
      );
    }
    if (sdk >= allFilesAccessSdk) {
      return AndroidPermissionSet(
        sdk: sdk,
        runtime: const <AndroidStoragePermission>[
          AndroidStoragePermission.manageExternalStorage,
        ],
        optional: const <AndroidStoragePermission>[],
        usesSafForDownloads: true,
        notificationsAreRuntime: false,
      );
    }
    return AndroidPermissionSet(
      sdk: sdk,
      runtime: const <AndroidStoragePermission>[
        AndroidStoragePermission.readExternalStorage,
        AndroidStoragePermission.writeExternalStorage,
      ],
      optional: const <AndroidStoragePermission>[],
      usesSafForDownloads: sdk >= scopedStorageSdk,
      notificationsAreRuntime: false,
    );
  }

  /// Library scan permission for this SDK. Downloads themselves never need
  /// this — they write through SAF or the app-specific directory.
  static AndroidStoragePermission libraryScanPermission(int sdk) {
    if (sdk >= granularMediaSdk) {
      return AndroidStoragePermission.readMediaAudio;
    }
    if (sdk >= allFilesAccessSdk) {
      return AndroidStoragePermission.manageExternalStorage;
    }
    return AndroidStoragePermission.readExternalStorage;
  }

  static bool requiresNotificationRuntimeGrant(int sdk) =>
      sdk >= granularMediaSdk;

  static bool usesSafForDownloads(int sdk) => sdk >= scopedStorageSdk;

  static bool hasDataSyncForegroundBudget(int sdk) =>
      sdk >= dataSyncBudgetSdk;
}
