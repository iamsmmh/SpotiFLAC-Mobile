/// English-first user-facing strings for the first-run setup flow, the
/// provider-accounts settings page, and the no-download-provider recovery UI.
///
/// These are staged for Crowdin: they intentionally live outside the generated
/// `AppLocalizations` set (which requires `flutter gen-l10n` to extend) so a
/// fresh install is fully usable before the next translation sync. When adding
/// them to `lib/l10n/arb/app_en.arb`, keep the same member names as the arb
/// keys and delete the entry here.
///
/// Precedent: several shipped surfaces already use inline English with the
/// same rationale (e.g. the queue share/import tooltips).
abstract final class StagedStrings {
  // Setup wizard — extensions step.
  static const String setupExtensionsTitle = 'Get music sources';
  static const String setupExtensionsDescription =
      'SpotiFLAC plays and downloads through provider extensions. '
      'Connect the official registry and install the recommended set to '
      'start immediately — or skip and do it later from the Store tab.';
  static const String setupExtensionsConnect = 'Connect & install recommended';
  static const String setupExtensionsConnecting = 'Connecting to registry…';
  static const String setupExtensionsInstalling = 'Installing recommended…';
  static const String setupExtensionsInstalled = 'Recommended extensions ready';
  static const String setupExtensionsPartial =
      'Some extensions failed — retry from the Store tab';
  static const String setupExtensionsSkip = 'Skip for now';
  static const String setupExtensionsRetry = 'Try again';
  static const String setupExtensionsOffline =
      'Could not reach the registry. Check your connection and try again.';

  // Store tab — recommended set.
  static const String recommendedPackTitle = 'Recommended starter pack';
  static const String recommendedPackMessage =
      'Search plus lossless and fallback downloads in one tap';
  static const String recommendedPackAction = 'Install all';
  static const String recommendedPackBusy = 'Installing…';
  static const String storeRecommendedDone = 'Recommended set installed';
  static const String storeRecommendedFailed =
      'Some recommended extensions failed to install';

  // Provider accounts.
  static const String providerAccountsTitle = 'Provider accounts';
  static const String providerAccountsSubtitle =
      'Streaming tokens for lossless providers';
  static const String providerAccountsDescription =
      'Providers marked with ★ need your own account token before they can '
      'resolve full-quality streams. Tokens are stored only in this device\'s '
      'encrypted keystore and are never uploaded anywhere.';
  static const String providerAccountsSave = 'Save';
  static const String providerAccountsClear = 'Clear';
  static const String providerAccountsSaved = 'Token saved';
  static const String providerAccountsCleared = 'Token cleared';
  static const String providerAccountsConfigured = 'Configured';
  static const String providerAccountsNotConfigured = 'Not set';
  static const String providerAccountsTestHint =
      'Saved tokens apply to the next stream immediately — no restart needed.';

  // No-download-provider recovery.
  static const String noProvidersTitle = 'No download providers';
  static const String noProvidersMessage =
      'Downloads need at least one enabled download extension. '
      'Open the Store to install one.';
  static const String noProvidersAction = 'Open Store';
  static const String noProvidersDialogMessage =
      'This download failed because no download extension is installed or '
      'enabled. Install one from the Store, then retry.';
}
