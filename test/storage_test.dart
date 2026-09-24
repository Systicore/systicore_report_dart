import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/context/install_id_repository.dart';
import 'package:systicore_report/src/delivery/persistent_report_queue.dart';
import 'package:systicore_report/src/delivery/queued_report.dart';
import 'package:systicore_report/src/storage/file_reporter_storage.dart';
import 'package:systicore_report/src/storage/memory_reporter_storage.dart';
import 'package:systicore_report/src/support/uuid.dart';

import 'support/fakes.dart';

QueuedReport queuedReport(String id) => QueuedReport(
      id: id,
      createdAt: DateTime.utc(2026, 9, 24),
      payload: {
        'error': {'code': id},
      },
    );

void main() {
  group('PersistentReportQueue', () {
    test('writes every change and restores it in order', () async {
      final storage = MemoryReporterStorage();
      final queue = PersistentReportQueue(storage: storage, capacity: 50)
        ..add(queuedReport('a'))
        ..add(queuedReport('b'))
        ..add(queuedReport('c'))
        ..remove('b');
      await queue.persistPending();

      final restored = PersistentReportQueue(storage: storage, capacity: 50);
      await restored.load();

      expect(restored.reports.map((report) => report.id), ['a', 'c']);
    });

    test('stores the same document jsonEncode would produce', () async {
      final storage = MemoryReporterStorage();
      final queue = PersistentReportQueue(storage: storage, capacity: 50)
        ..add(queuedReport('a'))
        ..add(queuedReport('b'));
      await queue.persistPending();

      final stored = await storage.read(PersistentReportQueue.storageKey);
      expect(jsonDecode(stored!), {
        'version': 1,
        'reports': [queuedReport('a').toJson(), queuedReport('b').toJson()],
      });
    });

    test('writes a new report right away and removals at most every 2 s',
        () async {
      final storage = CountingStorage();
      final clock = FakeClock();
      final queue = PersistentReportQueue(
        storage: storage,
        capacity: 50,
        clock: clock.call,
      )
        ..add(queuedReport('a'))
        ..add(queuedReport('b'))
        ..add(queuedReport('c'));
      await pumpEventQueue();
      expect(storage.writes, 1);

      queue
        ..remove('a')
        ..remove('b');
      await pumpEventQueue();
      expect(storage.writes, 1);

      await queue.persistPending();
      expect(storage.writes, 2);
      final afterBatch = PersistentReportQueue(storage: storage, capacity: 50);
      await afterBatch.load();
      expect(afterBatch.reports.map((report) => report.id), ['c']);

      clock.advance(const Duration(seconds: 2));
      queue.remove('c');
      await pumpEventQueue();
      expect(storage.writes, 3);

      queue.add(queuedReport('d'));
      await pumpEventQueue();
      expect(storage.writes, 4);
    });

    test('drops the oldest entries beyond its capacity', () async {
      final queue =
          PersistentReportQueue(storage: MemoryReporterStorage(), capacity: 2)
            ..add(queuedReport('a'))
            ..add(queuedReport('b'))
            ..add(queuedReport('c'));

      expect(queue.reports.map((report) => report.id), ['b', 'c']);
    });

    test('unreadable stored data yields an empty queue', () async {
      final storage = MemoryReporterStorage();
      await storage.write(PersistentReportQueue.storageKey, '{not json');
      final queue = PersistentReportQueue(storage: storage, capacity: 50);

      await queue.load();

      expect(queue.isEmpty, isTrue);
    });

    test('malformed entries are skipped, valid ones kept', () async {
      final storage = MemoryReporterStorage();
      await storage.write(
        PersistentReportQueue.storageKey,
        jsonEncode({
          'version': 1,
          'reports': [
            {'id': 'broken'},
            queuedReport('valid').toJson(),
          ],
        }),
      );
      final queue = PersistentReportQueue(storage: storage, capacity: 50);

      await queue.load();

      expect(queue.reports.map((report) => report.id), ['valid']);
    });
  });

  group('InstallIdRepository', () {
    test('creates a random UUID once and then reuses it', () async {
      final storage = MemoryReporterStorage();

      final first = await InstallIdRepository(storage).loadOrCreate();
      final second = await InstallIdRepository(storage).loadOrCreate();

      expect(isUuidV4(first), isTrue);
      expect(second, first);
    });

    test('replaces a stored value that is not a UUID', () async {
      final storage = MemoryReporterStorage();
      await storage.write(InstallIdRepository.storageKey, 'DESKTOP-JANE');

      final installId = await InstallIdRepository(storage).loadOrCreate();

      expect(isUuidV4(installId), isTrue);
    });
  });

  group('FileReporterStorage', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('systicore_report_');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('reads what it wrote and replaces existing content', () async {
      final storage = FileReporterStorage(
        () async => Directory('${directory.path}/nested'),
      );

      expect(await storage.read('queue.json'), isNull);
      await storage.write('queue.json', 'first');
      await storage.write('queue.json', 'second');

      expect(await storage.read('queue.json'), 'second');
      expect(
        File('${directory.path}/nested/queue.json.tmp').existsSync(),
        isFalse,
      );
    });
  });
}
