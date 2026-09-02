import 'package:flutter/material.dart';
import 'package:spotimusic/l10n/app_localizations.dart';
import 'package:spotimusic/utils/user_facing_error.dart';

export 'package:spotimusic/l10n/app_localizations.dart';

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  String friendlyError(
    Object? error, {
    String fallback = defaultUserFacingErrorMessage,
  }) => userFacingErrorMessage(error, fallback: fallback);
}
