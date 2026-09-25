import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/capture/reported_errors.dart';
import 'package:systicore_report/systicore_report.dart';

import 'support/fakes.dart';
import 'support/reporter_harness.dart';

class _ConstantFailure implements Exception {
  const _ConstantFailure();

  @override
  String toString() => 'constant failure';
}

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

  group('ReportedErrors', () {
    test('remembers errors by identity for the window', () {
      final clock = FakeClock();
      final reportedErrors = ReportedErrors(clock: clock.call);
      final reported = StateError('same text');

      reportedErrors.remember(reported);

      expect(reportedErrors.contains(reported), isTrue);
      expect(reportedErrors.contains(StateError('same text')), isFalse);
      clock.advance(const Duration(seconds: 59));
      expect(reportedErrors.contains(reported), isTrue);
      clock.advance(const Duration(seconds: 1));
      expect(reportedErrors.contains(reported), isFalse);
    });

    test('ignores values an Expando cannot carry', () {
      final reportedErrors = ReportedErrors(clock: FakeClock().call);
      final values = <Object>['thrown text', 42, 1.5, true, (1, 'record')];

      for (final value in values) {
        reportedErrors.remember(value);
        expect(reportedErrors.contains(value), isFalse, reason: '$value');
      }
    });
  });

  group('an error object is reported once', () {
    late ReporterHarness harness;
    late List<FlutterErrorDetails> frameworkErrorsSeenBefore;

    setUp(() async {
      frameworkErrorsSeenBefore = [];
      FlutterError.onError = frameworkErrorsSeenBefore.add;
      harness = ReporterHarness();
      await harness.start();
      harness.reporter.installHandlers();
    });

    tearDown(() => harness.reporter.dispose());

    test('captured, then escaping to PlatformDispatcher.onError', () async {
      final error = StateError('sync failed');

      final captured = harness.reporter.captureException(
        error,
        StackTrace.current,
        code: 'VAULT_SYNC_FAILED',
      );
      final handled =
          PlatformDispatcher.instance.onError!(error, StackTrace.current);
      await harness.reporter.flush();

      expect(captured, isTrue);
      expect(handled, isTrue);
      expect(harness.reporter.isReported(error), isTrue);
      expect(harness.transport.sent.single.error['code'], 'VAULT_SYNC_FAILED');
    });

    test('captured, then rethrown inside the framework', () async {
      final error = StateError('build failed');

      harness.reporter
          .captureException(error, StackTrace.current, code: 'BUILD_FAILED');
      FlutterError.onError!(FlutterErrorDetails(exception: error));
      await harness.reporter.flush();

      expect(frameworkErrorsSeenBefore, hasLength(1));
      expect(harness.transport.sent.single.error['code'], 'BUILD_FAILED');
    });

    test('markReported keeps the handlers quiet', () async {
      final error = StateError('reported elsewhere');
      harness.reporter.markReported(error);

      final handled =
          PlatformDispatcher.instance.onError!(error, StackTrace.current);
      FlutterError.onError!(FlutterErrorDetails(exception: error));
      await harness.reporter.flush();

      expect(handled, isTrue);
      expect(frameworkErrorsSeenBefore, hasLength(1));
      expect(harness.transport.sent, isEmpty);
    });

    test('an explicit captureException of a reported error is sent', () async {
      final error = StateError('reported elsewhere');
      harness.reporter.markReported(error);

      final captured = harness.reporter
          .captureException(error, StackTrace.current, code: 'SYNC_FAILED');
      await harness.reporter.flush();

      expect(captured, isTrue);
      expect(harness.transport.sent.single.error['code'], 'SYNC_FAILED');
    });

    test('the same error object captured under two codes is sent twice',
        () async {
      const error = _ConstantFailure();

      harness.reporter.captureException(error, null, code: 'FIRST_SITE');
      harness.reporter.captureException(error, null, code: 'SECOND_SITE');
      // An identical repeat is still merged by the duplicate filter.
      final repeated =
          harness.reporter.captureException(error, null, code: 'SECOND_SITE');
      PlatformDispatcher.instance.onError!(error, StackTrace.current);
      await harness.reporter.flush();

      expect(repeated, isTrue);
      expect(
        harness.transport.sent.map((sent) => sent.error['code']),
        ['FIRST_SITE', 'SECOND_SITE'],
      );
    });

    test('nothing counts as reported while reporting is disabled', () async {
      final error = StateError('reported before dispose');
      harness.reporter.markReported(error);
      harness.reporter.dispose();

      final handled =
          PlatformDispatcher.instance.onError!(error, StackTrace.current);

      expect(handled, isFalse);
    });

    test('the same const error is reported again after the window', () async {
      const error = _ConstantFailure();

      harness.reporter.captureException(error, null, code: 'FIRST');
      PlatformDispatcher.instance.onError!(error, StackTrace.current);
      harness.clock.advance(const Duration(minutes: 2));
      PlatformDispatcher.instance.onError!(error, StackTrace.current);
      await harness.reporter.flush();

      expect(
        harness.transport.sent.map((sent) => sent.error['code']),
        ['FIRST', 'UNHANDLED'],
      );
    });

    test('a thrown string is still reported by the handlers', () async {
      harness.reporter.captureException('plain text', null, code: 'MANUAL');
      PlatformDispatcher.instance.onError!('plain text', StackTrace.current);
      await harness.reporter.flush();

      expect(
        harness.transport.sent.map((sent) => sent.error['code']),
        ['MANUAL', 'UNHANDLED'],
      );
    });
  });

  group('a DioException reported by ReportingInterceptor', () {
    late ReporterHarness harness;
    late FakeHttpAdapter appBackend;
    late Dio appDio;

    setUp(() async {
      harness = ReporterHarness();
      await harness.start();
      harness.reporter.installHandlers();
      appBackend = FakeHttpAdapter();
      appDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = appBackend
        ..interceptors.add(ReportingInterceptor(reporter: harness.reporter));
    });

    tearDown(() => harness.reporter.dispose());

    Future<DioException> failingGet(String path) async {
      try {
        await appDio.get<String>(path);
      } on DioException catch (exception) {
        return exception;
      }
      fail('expected $path to fail');
    }

    test('is not reported again by PlatformDispatcher.onError', () async {
      appBackend.answerNext(
        const FakeHttpAnswer.failure(DioExceptionType.connectionError),
      );

      final exception = await failingGet('/api/sync');
      final handled =
          PlatformDispatcher.instance.onError!(exception, StackTrace.current);
      await harness.reporter.flush();

      expect(handled, isTrue);
      expect(harness.reporter.isReported(exception), isTrue);
      final error = harness.transport.sent.single.error;
      expect(error['code'], 'HTTP_CONNECTION_ERROR');
      expect(error['severity'], 'warning');
    });

    test('is not reported again when it escapes the guarded zone', () async {
      appBackend.answerNext(const FakeHttpAnswer.status(503));
      final requestFinished = Completer<void>();

      await harness.reporter.runGuarded(() {
        // An async onPressed without try/catch: the failure escapes.
        unawaited(
          appDio.get<String>('/api/sync').whenComplete(
                requestFinished.complete,
              ),
        );
      });
      await requestFinished.future;
      await pumpEventQueue();
      await harness.reporter.flush();

      expect(harness.transport.sent.single.error['code'], 'HTTP_503');
    });

    test('is still sent when the app captures it under its own code', () async {
      appBackend.answerNext(const FakeHttpAnswer.status(503));

      final exception = await failingGet('/api/sync');
      harness.reporter.captureException(
        exception,
        StackTrace.current,
        code: 'SYNC_FAILED',
      );
      PlatformDispatcher.instance.onError!(exception, StackTrace.current);
      await harness.reporter.flush();

      expect(
        harness.transport.sent.map((sent) => sent.error['code']),
        ['HTTP_503', 'SYNC_FAILED'],
      );
    });

    test('a 4xx the interceptor left alone is still reported uncaught',
        () async {
      appBackend.answerNext(const FakeHttpAnswer.status(404));

      final exception = await failingGet('/api/missing');
      expect(harness.reporter.isReported(exception), isFalse);
      PlatformDispatcher.instance.onError!(exception, StackTrace.current);
      await harness.reporter.flush();

      expect(harness.transport.sent.single.error['code'], 'UNHANDLED');
    });
  });
}
