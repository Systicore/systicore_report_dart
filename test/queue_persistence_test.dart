import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/delivery/persistent_report_queue.dart';
import 'package:systicore_report/src/delivery/queued_report.dart';
import 'package:systicore_report/src/delivery/report_dispatcher.dart';
import 'package:systicore_report/src/storage/memory_reporter_storage.dart';
import 'package:systicore_report/src/transport/ingest_outcome.dart';

import 'support/fakes.dart';
import 'support/reporter_harness.dart';

List<String> persistedMessages(Map<String, Object?> storedQueue) {
  final reports = storedQueue['reports']! as List<Object?>;
  return [
    for (final report in reports.cast<Map<String, Object?>>())
      ((report['payload']! as Map<String, Object?>)['error']!
          as Map<String, Object?>)['message']! as String,
  ];
}

Future<Map<String, Object?>> readStoredQueue(
    MemoryReporterStorage storage) async {
  final stored = await storage.read(PersistentReportQueue.storageKey);
  return jsonDecode(stored!) as Map<String, Object?>;
}

void main() {
  group('persistent queue', () {
    test('undelivered reports survive a restart and are replayed on init',
        () async {
      final storage = MemoryReporterStorage();
      final offline = ReporterHarness(
        storage: storage,
        transport: RecordingTransport(
          [const IngestTransientFailure('connectionError')],
        ),
      );
      await offline.start();
      offline.reporter
        ..report(code: 'FIRST', message: 'first', action: 'a')
        ..report(code: 'SECOND', message: 'second', action: 'a');
      await offline.reporter.flush();
      offline.reporter.dispose();

      expect(offline.transport.sent, hasLength(1));
      expect(persistedMessages(await readStoredQueue(storage)), [
        'first',
        'second',
      ]);

      final nextRun = ReporterHarness(storage: storage);
      await nextRun.start();

      expect(
        nextRun.transport.sent.map((sent) => sent.error['message']),
        ['first', 'second'],
      );
      expect(persistedMessages(await readStoredQueue(storage)), isEmpty);
      nextRun.reporter.dispose();
    });

    test('draining a backlog writes the queue once when the run ends',
        () async {
      final storage = CountingStorage();
      final clock = FakeClock();
      final queue = PersistentReportQueue(
        storage: storage,
        capacity: 50,
        clock: clock.call,
      );
      for (var index = 0; index < 10; index++) {
        queue.add(
          QueuedReport(
            id: 'report-$index',
            createdAt: clock(),
            payload: {
              'error': {'message': 'm$index'},
            },
          ),
        );
      }
      await queue.persistPending();
      final writesBeforeDrain = storage.writes;
      final dispatcher = ReportDispatcher(
        queue: queue,
        transport: RecordingTransport(),
        bearerTokenFor: (_) async => null,
        clock: clock.call,
        createTimer: ManualTimers().call,
      );

      await dispatcher.drain();
      await pumpEventQueue();

      expect(storage.writes - writesBeforeDrain, 1);
      expect(persistedMessages(await readStoredQueue(storage)), isEmpty);
    });

    test('the install id is kept across restarts', () async {
      final storage = MemoryReporterStorage();
      final firstRun = ReporterHarness(storage: storage);
      await firstRun.start();
      firstRun.reporter.report(code: 'X', message: 'one', action: 'a');
      await firstRun.reporter.flush();

      final secondRun = ReporterHarness(storage: storage);
      await secondRun.start();
      secondRun.reporter.report(code: 'X', message: 'two', action: 'a');
      await secondRun.reporter.flush();

      String installIdOf(RecordingTransport transport) =>
          (transport.sent.single.payload['device']!
              as Map<String, Object?>)['installId']! as String;
      expect(installIdOf(firstRun.transport), installIdOf(secondRun.transport));
    });

    test('a full queue drops the oldest report', () async {
      final storage = MemoryReporterStorage();
      final harness = ReporterHarness(
        storage: storage,
        transport: RecordingTransport(
          [const IngestTransientFailure('HTTP 503')],
        ),
      );
      await harness.start(testConfig(maxQueue: 3));

      for (var index = 1; index <= 5; index++) {
        harness.reporter
            .report(code: 'E$index', message: 'm$index', action: 'a');
      }
      await harness.reporter.flush();

      expect(persistedMessages(await readStoredQueue(storage)), [
        'm3',
        'm4',
        'm5',
      ]);
      harness.reporter.dispose();
    });

    test('reports captured before init are sent once init completes', () async {
      final harness = ReporterHarness();

      harness.reporter
          .report(code: 'EARLY', message: 'before init', action: 'boot');
      expect(harness.transport.sent, isEmpty);
      await harness.start();

      expect(harness.transport.sent.single.error['code'], 'EARLY');
      expect(
        harness.transport.sent.single.payload['release'],
        {'version': '1.4.2+17', 'commit': 'abc1234'},
      );
    });

    test('reports older than 72 hours are dropped unsent', () async {
      final storage = MemoryReporterStorage();
      final clock = FakeClock();
      final offline = ReporterHarness(
        storage: storage,
        clock: clock,
        transport: RecordingTransport(
          [const IngestTransientFailure('connectionError')],
        ),
      );
      await offline.start();
      offline.reporter.report(code: 'OLD', message: 'old', action: 'a');
      await offline.reporter.flush();
      offline.reporter.dispose();

      clock.advance(const Duration(hours: 73));
      final nextRun = ReporterHarness(storage: storage, clock: clock);
      await nextRun.start();

      expect(nextRun.transport.sent, isEmpty);
      expect(persistedMessages(await readStoredQueue(storage)), isEmpty);
    });
  });
}
