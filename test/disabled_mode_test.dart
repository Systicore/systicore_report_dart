import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/reporter_harness.dart';

void main() {
  group('disabled reporter is a no-op', () {
    late FlutterExceptionHandler? flutterHandlerBefore;
    late bool Function(Object, StackTrace)? platformHandlerBefore;

    setUp(() {
      flutterHandlerBefore = FlutterError.onError;
      platformHandlerBefore = PlatformDispatcher.instance.onError;
    });

    tearDown(() {
      FlutterError.onError = flutterHandlerBefore;
      PlatformDispatcher.instance.onError = platformHandlerBefore;
    });

    final disabledConfigurations = {
      'REPORTS_ENABLED=false': testConfig(enabled: false),
      'empty REPORTS_KEY': testConfig(ingestKey: '  '),
      'secret scsk_ REPORTS_KEY': testConfig(ingestKey: testSecretIngestKey),
      'REPORTS_KEY without the scpk_ prefix':
          testConfig(ingestKey: 'test_$testKeyRandomPart'),
      'empty REPORTS_URL': testConfig(baseUrl: ''),
      'unparseable REPORTS_URL': testConfig(baseUrl: 'not a url'),
    };

    disabledConfigurations.forEach((name, config) {
      test(name, () async {
        final storage = CountingStorage();
        final harness = ReporterHarness(storage: storage);
        final reporter = harness.reporter;

        await reporter.init(config);
        reporter
          ..setUser('42')
          ..addBreadcrumb('ignored')
          ..report(code: 'X', message: 'm', action: 'a')
          ..installHandlers();
        final captured =
            reporter.captureException(StateError('boom'), StackTrace.current);
        await reporter.flush();

        expect(reporter.isActive, isFalse);
        expect(captured, isFalse);
        expect(harness.transportCreations, 0);
        expect(harness.transport.sent, isEmpty);
        expect(harness.deviceContextLoader.loads, 0);
        expect(storage.reads, 0);
        expect(storage.writes, 0);
        expect(FlutterError.onError, same(flutterHandlerBefore));
        expect(
          PlatformDispatcher.instance.onError,
          same(platformHandlerBefore),
        );
      });
    });

    test('reports buffered before a disabling init are discarded', () async {
      final harness = ReporterHarness();
      final reporter = harness.reporter;

      reporter.report(code: 'EARLY', message: 'before init', action: 'boot');
      await reporter.init(testConfig(enabled: false));
      await reporter.flush();

      expect(harness.transport.sent, isEmpty);
      expect(harness.transportCreations, 0);
    });
  });
}
