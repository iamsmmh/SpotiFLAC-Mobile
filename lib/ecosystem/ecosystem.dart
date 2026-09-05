/// SpotiFLAC **ecosystem** barrel (Feature Groups 1–12).
///
/// Import this from application code (providers, screens, `main.dart`) instead
/// of reaching into subfolders, so the module keeps one public surface:
///
///   * `account/`          — pluggable cloud accounts (Group 1)
///   * `sync/`             — sync payloads, backend adapters, engine (Group 2)
///   * `favorites/`        — unified favorites index (Group 3)
///   * `history/`          — listening history + insights (Groups 4 & 12)
///   * `recommendations/`  — cloud + similarity + daily-mix providers (Group 5)
///   * `smart_playlists/`  — auto-updating playlists (Group 6)
///   * `cache/`            — streaming cache (Group 7)
///   * `offline/`          — smart offline mode (Group 8)
///   * `podcasts/`         — RSS platform (Group 9)
///   * `recognition/`      — music identification (Group 10)
///   * `social/`           — optional social layer (Group 11)
///
/// Layering follows the same rule as `core/`: dependencies point inward —
/// domain values know nothing about Flutter, adapters know nothing about UI,
/// UI talks to ports through Riverpod.
library;

export 'package:spotimusic/ecosystem/ecosystem_database.dart';
export 'package:spotimusic/ecosystem/ecosystem_kv.dart';

export 'package:spotimusic/ecosystem/account/account_models.dart';
export 'package:spotimusic/ecosystem/account/account_service.dart';
export 'package:spotimusic/ecosystem/account/auth_adapters.dart';
export 'package:spotimusic/ecosystem/account/auth_provider.dart';
export 'package:spotimusic/ecosystem/account/token_store.dart';

export 'package:spotimusic/ecosystem/sync/cloud_sync_adapters.dart';
export 'package:spotimusic/ecosystem/sync/sync_engine.dart';
export 'package:spotimusic/ecosystem/sync/sync_payloads.dart';

export 'package:spotimusic/ecosystem/favorites/favorite_playlists_repository.dart';
export 'package:spotimusic/ecosystem/favorites/favorites.dart';

export 'package:spotimusic/ecosystem/history/listening_history.dart';
export 'package:spotimusic/ecosystem/history/listening_insights.dart';

export 'package:spotimusic/ecosystem/recommendations/recommendation_providers.dart';

export 'package:spotimusic/ecosystem/podcasts/podcast_library.dart';
export 'package:spotimusic/ecosystem/podcasts/podcast_models.dart';
export 'package:spotimusic/ecosystem/podcasts/podcast_player.dart';
export 'package:spotimusic/ecosystem/podcasts/podcast_repository.dart';
export 'package:spotimusic/ecosystem/podcasts/podcast_search.dart';
export 'package:spotimusic/ecosystem/podcasts/rss_provider.dart';

export 'package:spotimusic/ecosystem/recognition/fingerprint_engine.dart';
export 'package:spotimusic/ecosystem/recognition/recognition_models.dart';
export 'package:spotimusic/ecosystem/recognition/recognition_provider.dart';
export 'package:spotimusic/ecosystem/recognition/recognition_service.dart';

export 'package:spotimusic/ecosystem/social/social_models.dart';
export 'package:spotimusic/ecosystem/social/social_service.dart';
