import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/core/application/queue_engine.dart';
import 'package:spotimusic/core/application/retry_policy.dart';
import 'package:spotimusic/core/domain/core_errors.dart';
import 'package:spotimusic/core/domain/entities.dart';

const CoreError _networkError = CoreError(
  category: CoreErrorCategory.network,
  message: 'offline',
);

DownloadJobSpec _spec(
  String id, {
  JobPriority priority = JobPriority.normal,
}) => DownloadJobSpec(
  jobId: id,
  track: TrackRef(id: id, name: 'Track $id', artistName: 'Artist'),
  finalPath: '/out/$id.flac',
  priority: priority,
);

/// Runner that always fails with a retryable network error.
Future<QueueJobResult> _failing(QueueJobExecution execution) async {
  throw _networkError;
}

/// 0 = immediate … 3 = low (mirrors the spec helper's `i % 4` mapping).
int _laneOf(String id) => int.parse(id.substring(1)) % 4;

void main() {
  group('large playlist handling', () {
    test('enqueueAll keeps lanes and FIFO order for a 2,000-track import',
        () async {
      final engine = QueueEngine(
        runner: (execution) async => const QueueJobResult.success(),
        config: const QueueEngineConfig(maxConcurrent: 1),
      );
      addTearDown(engine.dispose);

      final specs = <DownloadJobSpec>[
        for (var i = 0; i < 2000; i++)
          _spec(
            't$i',
            priority: switch (i % 4) {
              0 => JobPriority.immediate,
              1 => JobPriority.high,
              2 => JobPriority.normal,
              _ => JobPriority.low,
            },
          ),
      ];
      final jobs = engine.enqueueAll(specs);
      expect(jobs, hasLength(2000));

      // One job already claimed the single worker slot; the rest are pending.
      final order = engine.pendingJobs.map((j) => j.id).toList(growable: false);
      expect(order, hasLength(1999));

      for (var i = 1; i < order.length; i++) {
        expect(
          _laneOf(order[i - 1]),
          lessThanOrEqualTo(_laneOf(order[i])),
          reason: 'lane order violated at $i: ${order[i - 1]} → ${order[i]}',
        );
        if (_laneOf(order[i - 1]) == _laneOf(order[i])) {
          // FIFO inside a lane: insertion order is preserved.
          expect(
            int.parse(order[i - 1].substring(1)),
            lessThan(int.parse(order[i].substring(1))),
          );
        }
      }
    });

    test('one-by-one enqueue matches the batch order', () async {
      final specs = <DownloadJobSpec>[
        _spec('a', priority: JobPriority.high),
        _spec('b', priority: JobPriority.low),
        _spec('c', priority: JobPriority.immediate),
        _spec('d', priority: JobPriority.normal),
        _spec('e', priority: JobPriority.high),
      ];

      // Both engines are gated so nothing starts: the comparison is then
      // purely about insertion order, not about which job claimed the slot.
      final batchEngine = QueueEngine(
        runner: (execution) async => const QueueJobResult.success(),
        config: const QueueEngineConfig(maxConcurrent: 1),
      );
      addTearDown(batchEngine.dispose);
      batchEngine.pauseAll();
      batchEngine.enqueueAll(specs);
      final batchOrder = batchEngine.pendingJobs.map((j) => j.id).toList();

      final singleEngine = QueueEngine(
        runner: (execution) async => const QueueJobResult.success(),
        config: const QueueEngineConfig(maxConcurrent: 1),
      );
      addTearDown(singleEngine.dispose);
      singleEngine.pauseAll();
      for (final spec in specs) {
        singleEngine.enqueue(spec);
      }

      // c (immediate) → a, e (high, FIFO) → d (normal) → b (low).
      expect(batchOrder, <String>['c', 'a', 'e', 'd', 'b']);
      expect(singleEngine.pendingJobs.map((j) => j.id).toList(), batchOrder);
    });
  });

  group('index integrity', () {
    test('a re-used job id survives clearFinished()', () async {
      final engine = QueueEngine(
        runner: (execution) async => const QueueJobResult.success(),
        config: const QueueEngineConfig(maxConcurrent: 1),
      );
      addTearDown(engine.dispose);

      final first = engine.enqueue(_spec('reused'));
      expect(first.lifecycle, JobLifecycle.pending);
      await engine.drained;
      expect(engine.jobById('reused')!.lifecycle, JobLifecycle.completed);

      // Re-enqueueing a finished id must install a *new* live entry and drop
      // the stale terminal row; otherwise clearFinished() (which removes
      // finished rows from the index by id) would delete the live job.
      final second = engine.enqueue(_spec('reused'));
      expect(second.lifecycle, JobLifecycle.pending);

      engine.clearFinished();
      expect(engine.jobById('reused'), isNotNull);
      expect(
        engine.jobById('reused')!.lifecycle,
        isNot(JobLifecycle.completed),
      );

      // The live job is still reachable by the command API. Cancellation of a
      // *running* job is cooperative: the token fires synchronously, then the
      // worker future unwinds and the engine settles the job as cancelled, so
      // wait for the drain instead of asserting an in-flight transition.
      engine.cancel('reused');
      await engine.drained;
      expect(engine.jobById('reused')!.lifecycle, JobLifecycle.cancelled);
    });

    test('a re-used job id survives finished-ring eviction', () async {
      final engine = QueueEngine(
        runner: (execution) async => const QueueJobResult.success(),
        config: const QueueEngineConfig(
          maxConcurrent: 1,
          finishedCapacity: 2,
        ),
      );
      addTearDown(engine.dispose);

      for (final id in <String>['a', 'b']) {
        engine.enqueue(_spec(id));
        await engine.drained;
      }
      // Revive 'a' and hold it so it stays non-terminal: the ring then holds
      // exactly one stale row for id 'a' plus the live entry. Pausing a
      // running job aborts the worker cooperatively, so let the engine settle
      // the job as held before asserting.
      engine.enqueue(_spec('a'));
      engine.pause('a');
      await Future<void>.delayed(Duration.zero);
      expect(engine.jobById('a')!.lifecycle, JobLifecycle.held);

      // Overflowing the ring evicts stale rows (b, and the pre-revival 'a'),
      // but never the live entry that shares an id with one of them.
      engine.enqueue(_spec('c'));
      await engine.drained;
      engine.enqueue(_spec('d'));
      await engine.drained;

      expect(engine.jobById('a'), isNotNull);
      expect(engine.jobById('a')!.lifecycle, JobLifecycle.held);
      // The held job can still be resumed: it was never evicted. Resuming
      // (re)queues it and the scheduler claims a free slot immediately, so the
      // job is running by the time the command returns.
      engine.resume('a');
      expect(engine.jobById('a')!.lifecycle, JobLifecycle.running);
    });

    test('enqueueing a live id never duplicates the job', () async {
      final engine = QueueEngine(
        runner: (execution) async => const QueueJobResult.success(),
        config: const QueueEngineConfig(maxConcurrent: 1),
      );
      addTearDown(engine.dispose);

      // Close the gate so the first job stays pending: the engine claims a
      // free worker slot synchronously on enqueue, so without the gate the
      // idempotency check would observe the job in `running`, not `pending`.
      engine.pauseAll();
      engine.enqueue(_spec('dup'));
      engine.enqueue(_spec('dup'));
      engine.enqueue(_spec('dup'));
      expect(engine.pendingJobs, hasLength(1));
      expect(engine.snapshot.where((j) => j.id == 'dup'), hasLength(1));
    });
  });

  group('drain and retry accounting', () {
    test('drained does not complete while a retry is backing off', () async {
      final gate = Completer<void>();
      var armed = false;
      final engine = QueueEngine(
        runner: _failing,
        config: QueueEngineConfig(
          maxConcurrent: 1,
          retryPolicy: const RetryPolicy(maxAttempts: 2),
          sleeper: (delay) async {
            armed = true;
            await gate.future;
          },
        ),
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await engine.dispose();
      });

      engine.enqueue(_spec('flaky'));
      for (var i = 0; i < 50 && !armed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(armed, isTrue, reason: 'the engine should have armed a retry');

      // Nothing is running and nothing is queued, yet the armed retry is
      // still outstanding work: `drained` must not resolve early.
      var drainedCompleted = false;
      unawaited(engine.drained.then((_) => drainedCompleted = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(drainedCompleted, isFalse);

      gate.complete();
      await engine.drained;
      expect(drainedCompleted, isTrue);
      expect(engine.jobById('flaky')!.lifecycle, JobLifecycle.failed);
    });

    test('the engine does not emit emptied while a retry is pending',
        () async {
      final gate = Completer<void>();
      var armed = false;
      final engine = QueueEngine(
        runner: _failing,
        config: QueueEngineConfig(
          maxConcurrent: 1,
          retryPolicy: const RetryPolicy(maxAttempts: 2),
          sleeper: (delay) async {
            armed = true;
            await gate.future;
          },
        ),
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await engine.dispose();
      });

      final events = <QueueEvent>[];
      final sub = engine.events.listen(events.add);
      addTearDown(sub.cancel);

      engine.enqueue(_spec('flaky'));
      for (var i = 0; i < 50 && !armed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(events.any((e) => e is QueueJobRetryScheduled), isTrue);
      expect(events.whereType<QueueEmptied>(), isEmpty);

      gate.complete();
      await engine.drained;
      // ignore: avoid_print
      print('[QDBG-TEST] job=${engine.jobById('flaky')} '
          'pending=${engine.pendingJobs.length} running=${engine.runningJobs.length} '
          'events=${events.map((e) => e.runtimeType.toString()).join(",")}');
      expect(events.whereType<QueueEmptied>(), isNotEmpty);
    });
  });

  group('progress reporting', () {
    test('a worker cannot rewind the reported progress', () async {
      final completer = Completer<QueueJobResult>();
      QueueJobExecution? execution;
      final engine = QueueEngine(
        runner: (exec) {
          execution = exec;
          return completer.future;
        },
        config: const QueueEngineConfig(maxConcurrent: 1),
      );
      addTearDown(engine.dispose);

      engine.enqueue(_spec('p'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      execution!.reportProgress(0.5);
      expect(engine.jobById('p')!.progress, 0.5);
      execution!.reportProgress(0.2); // rewind: ignored
      expect(engine.jobById('p')!.progress, 0.5);
      execution!.reportProgress(0.9);
      expect(engine.jobById('p')!.progress, 0.9);

      completer.complete(const QueueJobResult.success());
      await engine.drained;
      expect(engine.jobById('p')!.progress, 1.0);
    });
  });
}
