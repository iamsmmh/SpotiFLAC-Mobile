/// SpotiFLAC core engine — Stage 2 layered architecture.
///
/// Layering contract (dependencies point inward only):
///  - `domain/`: pure entities, error taxonomy, cancellation, ports
///    (interfaces). No Flutter, no platform channels.
///  - `application/`: scheduling + orchestration (queue engine, retry policy,
///    transactional download manager, extension priority engine).
///  - `data/`: platform adapters (gomobile bridge, FFmpeg, channel contracts,
///    atomic file transactions, SHA-256).
///  - `presentation/`: Riverpod wiring so UI consumes domain ports and never
///    touches platform channels.
///
/// Import this barrel from UI/application code; reach into sublayers only for
/// tests.
library;

export 'package:spotimusic/core/domain/cancellation_token.dart';
export 'package:spotimusic/core/domain/core_errors.dart';
export 'package:spotimusic/core/domain/entities.dart';
export 'package:spotimusic/core/domain/ports.dart';
export 'package:spotimusic/core/application/download_manager.dart';
export 'package:spotimusic/core/application/extension_engine.dart';
export 'package:spotimusic/core/application/queue_engine.dart';
export 'package:spotimusic/core/application/retry_policy.dart';
export 'package:spotimusic/core/data/android_storage_permission_policy.dart';
export 'package:spotimusic/core/data/background_playback_policy.dart';
export 'package:spotimusic/core/data/cold_start_policy.dart';
export 'package:spotimusic/core/data/network_switch_policy.dart';
export 'package:spotimusic/core/data/release_artifact_policy.dart';
export 'package:spotimusic/core/data/secure_store.dart';
export 'package:spotimusic/core/data/session_resource_budget.dart';
