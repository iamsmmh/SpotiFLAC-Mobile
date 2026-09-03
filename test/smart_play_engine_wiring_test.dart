import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/engine/audio_characteristics.dart';
import 'package:spotimusic/engine/smart_play.dart';
import 'package:spotimusic/engine/streaming_engine.dart';
import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/providers/engine_settings_provider.dart';
import 'package:spotimusic/providers/music_player_provider.dart';
import 'package:spotimusic/providers/streaming_engine_provider.dart';
import 'package:spotimusic/services/multi_provider_stream_service.dart';
import 'package:spotimusic/services/music_player_service.dart';

Track _track(String id, {String? isrc, int duration = 200}) => Track(
      id: id,
      name: 'Song $id',
      artistName: 'Artist $id',
      albumName: 'Album',
      isrc: isrc,
      duration: duration,
      source: 'app',
    );

ResolvedStream _fullStream({
  String uri = 'https://cdn.example.com/audio.opus',
  StreamProviderId provider = StreamProviderId.youtube,
  int bitrateKbps = 160,
  bool lossless = false,
  bool preview = false,
  DateTime? expiresAt,
}) =>
    ResolvedStream(
      uri: Uri.parse(uri),
      provider: provider,
      qualityLabel: 'Opus ${bitrateKbps}kbps',
      bitrateKbps: bitrateKbps,
      isLossless: lossless,
      isPreview: preview,
      codec: 'opus',
      expiresAt: expiresAt,
      matchedTitle: 'Song',
      matchedArtist: 'Artist',
    );

class _FakeAdapter implements StreamSourceAdapter {
  _FakeAdapter(this.sources);
  final List<StreamDescriptor> sources;
  int callCount = 0;

  @override
  String get id => 'fake';

  @override
  Future<List<StreamDescriptor>> candidatesFor(Track track) async {
    callCount += 1;
    return sources;
  }
}

class _ScriptedValidator implements StreamPreflightValidator {
  _ScriptedValidator(this.failUris);
  final Set<String> failUris;
  int callCount = 0;

  @override
  Future<StreamPreflightResult> validate(StreamDescriptor source) async {
    callCount += 1;
    if (failUris.contains(source.uri)) {
      return StreamPreflightResult.failure('HTTP 403');
    }
    return StreamPreflightResult.success(
      latencyMs: 42,
      contentType: 'audio/webm',
    );
  }
}

class _FakeNetworkMonitor extends NetworkStatusMonitor {
  final NetworkProfile profile;
  _FakeNetworkMonitor(this.profile);

  @override
  Future<NetworkProfile> current() async => profile;
}

/// Player controller stand-in: AudioService.init succeeds in the test VM
/// even without native plugins, so the real controller would start actual
/// playback and route the resulting MissingPluginException through the
/// engine's playback-failure hook, polluting provider health. The engine
/// tests exercise the engine, not the audio backend.
class _NoopPlayerController extends MusicPlayerController {
  @override
  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {}

  @override
  Future<void> addAllToQueue(List<PlayableMedia> items) async {}
}

ProviderContainer _container({
  List<StreamSourceAdapter> adapters = const [],
  StreamPreflightValidator? validator,
  EngineSettings settings = const EngineSettings(bufferPreviewStreams: false),
  NetworkProfile network = NetworkProfile.wifi,
}) {
  final container = ProviderContainer(
    overrides: [
      streamSourceAdaptersProvider.overrideWith((ref) => adapters),
      if (validator != null)
        streamPreflightValidatorProvider.overrideWith((ref) => validator),
      initialEngineSettingsProvider.overrideWith((ref) => settings),
      networkStatusMonitorProvider.overrideWith(
        (ref) => _FakeNetworkMonitor(network),
      ),
      musicPlayerControllerProvider.overrideWith(
        (ref) => _NoopPlayerController(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Engine environment canary', () {
    test('decide() completes with a valid decision under test bindings',
        () async {
      final container = _container(adapters: const []);
      final monitor = container.read(networkStatusMonitorProvider);
      expect(monitor, isA<_FakeNetworkMonitor>());
      expect(await monitor.current(), NetworkProfile.wifi);
      expect(container.read(initialEngineSettingsProvider).offlineMode,
          isFalse);
      final engine = container.read(streamingEngineControllerProvider);
      final decision = await engine.decide(_track('canary'));
      // No local file, no adapters, streaming enabled -> the smart ladder
      // must end at download&play (download subsystem available), never
      // throw. The reason dumps the full decision trace on failure.
      expect(decision.mode, SmartPlayMode.downloadAndPlay,
          reason: decision.steps
              .map((s) => '${s.check}=${s.passed}(${s.detail})')
              .join(' | '));
      expect(decision.networkProfile, NetworkProfile.wifi);
    });
  });

  group('Provider match-confidence gates', () {
    test('YouTube: official Topic upload with close duration scores high', () {
      final score = scoreYouTubeSearchResult(
        author: 'Artist - Topic',
        title: 'Song (Official Audio)',
        targetSeconds: 200,
        videoSeconds: 201,
        requestTitle: 'Song',
      );
      expect(score, greaterThanOrEqualTo(youTubeMinimumMatchScore));
    });

    test('YouTube: unrelated result with no signal is rejected', () {
      final score = scoreYouTubeSearchResult(
        author: 'Random Channel',
        title: 'totally different thing',
        targetSeconds: 200,
        videoSeconds: 205,
        requestTitle: 'Song',
      );
      // No Topic/official marker, title does not contain the request, and
      // only weak duration evidence: must stay below the floor.
      expect(score, lessThan(youTubeMinimumMatchScore));
    });

    test('YouTube: same-length unrelated video alone never clears the floor',
        () {
      final score = scoreYouTubeSearchResult(
        author: 'Random Channel',
        title: 'another tune completely',
        targetSeconds: 200,
        videoSeconds: 200,
        requestTitle: 'Song',
      );
      expect(score, lessThan(youTubeMinimumMatchScore));
    });

    test('YouTube: huge duration drift is penalized hard', () {
      final close = scoreYouTubeSearchResult(
        author: 'Artist - Topic',
        title: 'Song (Official Audio)',
        targetSeconds: 200,
        videoSeconds: 200,
        requestTitle: 'Song',
      );
      final drifted = scoreYouTubeSearchResult(
        author: 'Artist - Topic',
        title: 'Song (Official Audio)',
        targetSeconds: 200,
        videoSeconds: 200 + youTubeMaxDurationDriftSeconds + 30,
        requestTitle: 'Song',
      );
      expect(drifted, lessThan(close));
    });

    test('YouTube: cover/karaoke uploads score below the floor', () {
      final score = scoreYouTubeSearchResult(
        author: 'Cover Band',
        title: 'Song (karaoke cover)',
        targetSeconds: 200,
        videoSeconds: 200,
        requestTitle: 'Song',
      );
      expect(score, lessThan(youTubeMinimumMatchScore));
    });

    test('SoundCloud: title + duration match passes the floor', () {
      final score = scoreSoundCloudResult(
        title: 'Song',
        requestTitle: 'Song',
        targetSeconds: 200,
        durationMs: 201000,
      );
      expect(score, greaterThanOrEqualTo(soundCloudMinimumMatchScore));
    });

    test('SoundCloud: unrelated title without duration info is rejected', () {
      final score = scoreSoundCloudResult(
        title: 'Unrelated Remix',
        requestTitle: 'Song',
        targetSeconds: null,
        durationMs: null,
      );
      expect(score, lessThan(soundCloudMinimumMatchScore));
    });
  });

  group('MultiProviderStreamAdapter', () {
    test('maps a full stream to a ranked StreamDescriptor', () async {
      final service = MultiProviderStreamService();
      addTearDown(service.dispose);
      final adapter = MultiProviderStreamAdapter(
        service: service,
        preferredProvider: StreamProviderId.youtube,
        resolveOverride: (request, preferred) async => _fullStream(
          expiresAt: DateTime.now().add(const Duration(hours: 5)),
        ),
      );
      final candidates = await adapter.candidatesFor(_track('t1'));
      expect(candidates, hasLength(1));
      final descriptor = candidates.single;
      expect(descriptor.providerId, 'youtube');
      expect(descriptor.kind, StreamSourceKind.httpStream);
      expect(descriptor.quality, AudioQualityLevel.normal); // 160kbps
      expect(descriptor.characteristics.bitrateKbps, 160);
      expect(descriptor.expiresAt, isNotNull);
      expect(descriptor.cachePermitted, isFalse);
      expect(descriptor.isExpired, isFalse);
    });

    test('previews are demoted below full streams', () async {
      final service = MultiProviderStreamService();
      addTearDown(service.dispose);
      final adapter = MultiProviderStreamAdapter(
        service: service,
        resolveOverride: (request, preferred) async =>
            _fullStream(preview: true, bitrateKbps: 128),
      );
      final candidates = await adapter.candidatesFor(_track('t1'));
      final descriptor = candidates.single;
      expect(descriptor.quality, AudioQualityLevel.low);
      expect(descriptor.priority, greaterThan(5)); // full streams use 5
    });

    test('resolution failure yields no candidates instead of throwing',
        () async {
      final service = MultiProviderStreamService();
      addTearDown(service.dispose);
      final adapter = MultiProviderStreamAdapter(
        service: service,
        resolveOverride: (request, preferred) async {
          throw StreamResolutionException('no stream anywhere');
        },
      );
      final candidates = await adapter.candidatesFor(_track('t1'));
      expect(candidates, isEmpty);
    });
  });

  group('Deferred stream queue items', () {
    test('URI round-trips and is recognized by the player', () {
      final uri = PlayableMedia.deferredStreamUriFor('spotify:abc def');
      expect(uri.startsWith('${PlayableMedia.deferredStreamScheme}://'),
          isTrue);
      final media = PlayableMedia(
        id: 'spotify:abc def',
        source: uri,
        title: 'Song',
        artist: 'Artist',
      );
      expect(media.isDeferredStream, isTrue);
      expect(media.isContentUri, isFalse);
      expect(media.isRemoteHttp, isFalse);
    });

    test('survives JSON serialization (session persistence)', () {
      final media = PlayableMedia(
        id: 't1',
        source: PlayableMedia.deferredStreamUriFor('t1'),
        title: 'Song',
        artist: 'Artist',
        playbackMode: 'stream',
      );
      final json = media.toJson();
      final restored = PlayableMedia.fromJson(
        Map<String, dynamic>.from(json as Map<dynamic, dynamic>),
      );
      expect(restored, isNotNull);
      expect(restored!.isDeferredStream, isTrue);
    });
  });

  group('StreamingEngineController preflight failover', () {
    test('falls back to the next ranked provider when preflight fails',
        () async {
      final bad = StreamDescriptor(
        id: 'bad',
        providerId: 'providerA',
        kind: StreamSourceKind.httpStream,
        uri: 'https://a.example.com/stream',
        quality: AudioQualityLevel.high,
      );
      final good = StreamDescriptor(
        id: 'good',
        providerId: 'providerB',
        kind: StreamSourceKind.httpStream,
        uri: 'https://b.example.com/stream',
        quality: AudioQualityLevel.normal,
      );
      final adapter = _FakeAdapter([bad, good]);
      final validator = _ScriptedValidator({bad.uri});
      final container = _container(
        adapters: [adapter],
        validator: validator,
      );
      final engine = container.read(streamingEngineControllerProvider);

      final result = await engine.playTrack(_track('t1'));

      expect(result.started, isTrue, reason: result.message ?? '');
      // First resolve + one re-query after the failure.
      expect(adapter.callCount, greaterThanOrEqualTo(2));
      final integrityDump = engine.integrityLog.records
          .map((r) => '${r.outcome.name}:${r.providerId}:${r.category}')
          .join(' | ');
      final healthDump = engine.providerHealth
          .snapshot()
          .map((h) => '${h.providerId}(f=${h.failureCount},s=${h.successCount})')
          .join(' | ');
      expect(validator.callCount, 2, reason: integrityDump);
      expect(
        engine.integrityLog.countOutcome(StreamIntegrityOutcome.failure),
        1,
        reason: integrityDump,
      );
      expect(
        engine.integrityLog.countOutcome(StreamIntegrityOutcome.success),
        1,
        reason: integrityDump,
      );
      final failedHealth = engine.providerHealth.healthOf('providerA');
      expect(failedHealth.failureCount, 1, reason: healthDump);
      final context = container.read(enginePlayContextProvider);
      expect(context?.providerId, 'providerB');
    });

    test('exhausted chain reports failure without endless retries', () async {
      final bad1 = StreamDescriptor(
        id: 'b1',
        providerId: 'providerA',
        kind: StreamSourceKind.httpStream,
        uri: 'https://a.example.com/1',
        quality: AudioQualityLevel.high,
      );
      final bad2 = StreamDescriptor(
        id: 'b2',
        providerId: 'providerB',
        kind: StreamSourceKind.httpStream,
        uri: 'https://b.example.com/2',
        quality: AudioQualityLevel.normal,
      );
      final adapter = _FakeAdapter([bad1, bad2]);
      final validator = _ScriptedValidator({bad1.uri, bad2.uri});
      final container = _container(
        adapters: [adapter],
        validator: validator,
      );
      final engine = container.read(streamingEngineControllerProvider);

      final result = await engine.playTrack(_track('t2'));

      expect(result.started, isFalse);
      expect(result.failure, EnginePlayFailureKind.streamFailed);
      expect(result.message, contains('provider'));
      // maxStreamAttempts=3, but only 2 distinct URIs exist: the tried-set
      // must stop re-selection instead of looping forever.
      expect(validator.callCount, 2);
    });
  });

  group('StreamingEngineController queue building', () {
    test('playTracks queues local copies directly and defers the rest',
        () async {
      final good = StreamDescriptor(
        id: 's1',
        providerId: 'providerB',
        kind: StreamSourceKind.httpStream,
        uri: 'https://b.example.com/stream',
        quality: AudioQualityLevel.normal,
      );
      final adapter = _FakeAdapter([good]);
      final container = _container(
        adapters: [adapter],
        validator: _ScriptedValidator(const <String>{}),
      );
      final engine = container.read(streamingEngineControllerProvider);

      final t1 = _track('t1');
      final t2 = _track('t2');
      final t3 = _track('t3');
      final result = await engine.playTracks(
        [t1, t2, t3],
        startIndex: 0,
        resolvedPaths: [null, '/music/t2.flac', null],
      );

      expect(result.started, isTrue, reason: result.message ?? '');
      // All queued tracks are registered so deferred items can resolve later.
      expect(engine.trackFor('t2'), isNotNull);
      expect(engine.trackFor('t3'), isNotNull);
      // The played media is registered too.
      expect(engine.trackFor('t1'), isNotNull);
    });

    test('startIndex rotation reorders both tracks and pre-resolved paths',
        () async {
      final good = StreamDescriptor(
        id: 's1',
        providerId: 'providerB',
        kind: StreamSourceKind.httpStream,
        uri: 'https://b.example.com/stream',
        quality: AudioQualityLevel.normal,
      );
      final adapter = _FakeAdapter([good]);
      final container = _container(
        adapters: [adapter],
        validator: _ScriptedValidator(const <String>{}),
      );
      final engine = container.read(streamingEngineControllerProvider);

      final result = await engine.playTracks(
        [_track('t1'), _track('t2'), _track('t3')],
        startIndex: 2,
        resolvedPaths: ['/music/t1.flac', null, null],
      );

      expect(result.started, isTrue, reason: result.message ?? '');
      // t3 was tapped: it started (streamed); t1 kept its local path in the
      // remainder queue, t2 is deferred. Both are registered for resolution.
      expect(engine.trackFor('t1'), isNotNull);
      expect(engine.trackFor('t2'), isNotNull);
      expect(engine.trackFor('t3'), isNotNull);
    });
  });

  group('StreamingEngineController.resolveDeferredSource', () {
    test('resolves to a preflighted stream URL for a registered track',
        () async {
      final good = StreamDescriptor(
        id: 's1',
        providerId: 'providerB',
        kind: StreamSourceKind.httpStream,
        uri: 'https://b.example.com/stream',
        quality: AudioQualityLevel.normal,
      );
      final adapter = _FakeAdapter([good]);
      final container = _container(
        adapters: [adapter],
        validator: _ScriptedValidator(const <String>{}),
      );
      final engine = container.read(streamingEngineControllerProvider);
      engine.ensureFailureHook();
      addTearDown(() => setDeferredStreamResolver(null));

      final track = _track('t9');
      final result = await engine.playTrack(track);
      expect(result.started, isTrue);

      final deferredMedia = PlayableMedia(
        id: track.id,
        source: PlayableMedia.deferredStreamUriFor(track.id),
        title: track.name,
        artist: track.artistName,
      );
      final resolved = await engine.resolveDeferredSource(deferredMedia);
      final eventDump = engine.eventLog.events
          .map((e) => '${e.category}:${e.message}')
          .join(' | ');
      expect(resolved, 'https://b.example.com/stream', reason: eventDump);
    });

    test('returns null (never throws) when no source exists', () async {
      // Streaming disabled: the ladder must end at "unavailable" without
      // touching the download queue or the app settings provider.
      final container = _container(
        adapters: const [],
        settings: const EngineSettings(
          streamingEnabled: false,
          bufferPreviewStreams: false,
        ),
      );
      final engine = container.read(streamingEngineControllerProvider);
      engine.ensureFailureHook();
      addTearDown(() => setDeferredStreamResolver(null));

      final media = PlayableMedia(
        id: 'unknown-track',
        source: PlayableMedia.deferredStreamUriFor('unknown-track'),
        title: 'Nowhere',
        artist: 'Nobody',
      );
      final resolved = await engine.resolveDeferredSource(media);
      expect(resolved, isNull);
    });
  });
}
