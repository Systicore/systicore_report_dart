// Uses only the public libraries, as an app's own test would: no src/
// import, so the implementation_imports lint stays quiet.
import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/systicore_report.dart';
import 'package:systicore_report/testing.dart';

void main() {
  group('package:systicore_report/testing.dart', () {
    ReporterConfig appConfig() => ReporterConfig(
          enabled: true,
          baseUrl: 'https://reports.example.test',
          ingestKey: '${ReporterConfig.publicKeyPrefix}test_${'0' * 32}',
          source: 'example_mobile',
          environment: 'production',
          userIdProvider: () => '42',
          userIssuer: 'https://auth.example.test',
        );

    SysticoreReporter reporterOn(RecordingIngestTransport transport) {
      return SysticoreReporter.withDependencies(
        ReporterDependencies(
          storage: MemoryReporterStorage(),
          transportFactory: (baseUri, ingestKey) => transport,
          deviceContextLoader: const FixedDeviceContextLoader(),
          clock: () => DateTime.utc(2026, 9, 25, 12),
        ),
      );
    }

    test('records what the reporter would send', () async {
      final transport = RecordingIngestTransport();
      final reporter = reporterOn(transport);
      await reporter.init(appConfig());

      reporter.captureException(
        StateError('vault locked'),
        StackTrace.current,
        action: 'VaultSync',
      );
      await reporter.flush();
      reporter.dispose();

      final request = transport.sent.single;
      expect(request.error['type'], 'StateError');
      expect(request.error['action'], 'VaultSync');
      expect(request.bearerToken, isNull);
      expect(request.payload['user'], {
        'id': '42',
        'issuer': 'https://auth.example.test',
      });
      expect(request.payload['release'], {'version': '1.0.0+1'});
      final device = request.payload['device']! as Map<String, Object?>;
      expect(device['brand'], 'Test');
      expect(device['model'], 'Test device');
    });

    test('answers with scripted outcomes, then accepts', () async {
      final rejecting = RecordingIngestTransport([const IngestRejected(400)]);
      final rejectingReporter = reporterOn(rejecting);
      await rejectingReporter.init(appConfig());

      rejectingReporter.report(code: 'FIRST', message: 'm', action: 'a');
      await rejectingReporter.flush();
      rejectingReporter.report(code: 'SECOND', message: 'm', action: 'a');
      await rejectingReporter.flush();
      rejectingReporter.dispose();

      expect(
        rejecting.sent.map((request) => request.error['code']),
        ['FIRST', 'SECOND'],
      );
      expect(rejecting.isClosed, isTrue);
    });

    test('lets an app implement its own transport', () async {
      final ownTransport = _CountingTransport();
      final ownReporter = SysticoreReporter.withDependencies(
        ReporterDependencies(
          storage: MemoryReporterStorage(),
          transportFactory: (baseUri, ingestKey) => ownTransport,
          deviceContextLoader: const FixedDeviceContextLoader(),
        ),
      );
      await ownReporter.init(appConfig());

      ownReporter.report(code: 'X', message: 'm', action: 'a');
      await ownReporter.flush();
      ownReporter.dispose();

      expect(ownTransport.sendCount, 1);
    });
  });
}

class _CountingTransport implements IngestTransport {
  int sendCount = 0;

  @override
  Future<IngestOutcome> send(
    Map<String, Object?> payload, {
    String? bearerToken,
  }) async {
    sendCount++;
    return const IngestAccepted();
  }

  @override
  void close() {}
}
