import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/reporter_harness.dart';

void main() {
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

  group('FlutterError.onError', () {
    test('reports the error and still calls the previous handler', () async {
      final previousCalls = <FlutterErrorDetails>[];
      FlutterError.onError = previousCalls.add;
      final harness = ReporterHarness();
      await harness.start();
      harness.reporter.installHandlers();

      final details = FlutterErrorDetails(
        exception: StateError('layout broke'),
        stack: StackTrace.current,
        library: 'rendering library',
      );
      FlutterError.onError!(details);
      await harness.reporter.flush();

      expect(previousCalls, [same(details)]);
      final error = harness.transport.sent.single.error;
      expect(error['type'], 'StateError');
      expect(error['code'], 'FLUTTER_ERROR');
      expect(error['action'], 'flutter/rendering library');
      expect(error['message'], contains('layout broke'));
    });

    test('silent errors reach the previous handler but are not reported',
        () async {
      final previousCalls = <FlutterErrorDetails>[];
      FlutterError.onError = previousCalls.add;
      final harness = ReporterHarness();
      await harness.start();
      harness.reporter.installHandlers();

      FlutterError.onError!(
        FlutterErrorDetails(exception: Exception('image 404'), silent: true),
      );
      await harness.reporter.flush();

      expect(previousCalls, hasLength(1));
      expect(harness.transport.sent, isEmpty);
    });

    test('installing twice does not report twice', () async {
      FlutterError.onError = null;
      final harness = ReporterHarness();
      await harness.start();
      harness.reporter
        ..installHandlers()
        ..installHandlers();

      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('once')),
      );
      await harness.reporter.flush();

      expect(harness.transport.sent, hasLength(1));
    });
  });

  group('PlatformDispatcher.onError', () {
    test('returns true only after reporting, and chains the previous handler',
        () async {
      final previousCalls = <Object>[];
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        previousCalls.add(error);
        return false;
      };
      final harness = ReporterHarness();
      await harness.start();
      harness.reporter.installHandlers();

      final handled = PlatformDispatcher.instance.onError!(
        StateError('async failure'),
        StackTrace.current,
      );
      await harness.reporter.flush();

      expect(handled, isTrue);
      expect(previousCalls, hasLength(1));
      final error = harness.transport.sent.single.error;
      expect(error['code'], 'UNHANDLED');
      expect(error['type'], 'StateError');
      expect(error['message'], 'Bad state: async failure');
    });

    test('returns the previous verdict when nothing was reported', () async {
      PlatformDispatcher.instance.onError = (error, stackTrace) => false;
      final harness = ReporterHarness();
      // Installed before init, as an app may do; init then disables.
      harness.reporter.installHandlers();
      await harness.start(testConfig(enabled: false));

      final handled = PlatformDispatcher.instance.onError!(
        StateError('not reported'),
        StackTrace.current,
      );

      expect(handled, isFalse);
      expect(harness.transport.sent, isEmpty);
    });

    test('a previous handler that handles the error keeps it handled',
        () async {
      PlatformDispatcher.instance.onError = (error, stackTrace) => true;
      final harness = ReporterHarness();
      harness.reporter.installHandlers();
      await harness.start(testConfig(enabled: false));

      final handled = PlatformDispatcher.instance.onError!(
        StateError('handled by the app'),
        StackTrace.current,
      );

      expect(handled, isTrue);
    });
  });

  group('runGuarded', () {
    test('reports errors escaping the guarded zone', () async {
      final harness = ReporterHarness();
      await harness.start();
      final asyncErrorRaised = Completer<void>();

      await harness.reporter.runGuarded(() {
        scheduleMicrotask(() {
          asyncErrorRaised.complete();
          throw StateError('zone failure');
        });
      });
      await asyncErrorRaised.future;
      await pumpEventQueue();
      await harness.reporter.flush();

      final error = harness.transport.sent.single.error;
      expect(error['code'], 'UNHANDLED');
      expect(error['message'], 'Bad state: zone failure');
    });

    test('an error thrown by appMain itself is reported and completes the run',
        () async {
      final harness = ReporterHarness();
      await harness.start();

      await harness.reporter.runGuarded(() async {
        throw StateError('main failed');
      });
      await pumpEventQueue();
      await harness.reporter.flush();

      expect(
        harness.transport.sent.single.error['message'],
        'Bad state: main failed',
      );
    });

    test('with reporting disabled the error goes to the surrounding zone',
        () async {
      final harness = ReporterHarness();
      await harness.start(testConfig(enabled: false));
      final errorsSeenOutside = <Object>[];

      await runZonedGuarded(
        () => harness.reporter.runGuarded(() {
          scheduleMicrotask(() => throw StateError('not swallowed'));
        }),
        (error, stackTrace) => errorsSeenOutside.add(error),
      );
      await pumpEventQueue();

      expect(errorsSeenOutside, hasLength(1));
      expect(harness.transport.sent, isEmpty);
    });
  });
}
