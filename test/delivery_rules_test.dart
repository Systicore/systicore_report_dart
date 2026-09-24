import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/transport/ingest_outcome.dart';

import 'support/fakes.dart';
import 'support/reporter_harness.dart';

void main() {
  group('circuit breaker after 401/403', () {
    for (final statusCode in [401, 403]) {
      test('HTTP $statusCode drops the report and pauses sending for 5 minutes',
          () async {
        final harness = ReporterHarness(
          transport: RecordingTransport([IngestRejected(statusCode)]),
        );
        await harness.start();
        final reporter = harness.reporter;

        reporter.report(code: 'REFUSED', message: 'refused', action: 'a');
        await reporter.flush();
        reporter.report(code: 'WAITING', message: 'waiting', action: 'a');
        await reporter.flush();

        expect(harness.transport.sent.map((sent) => sent.error['code']), [
          'REFUSED',
        ]);
        expect(harness.timers.scheduledDelays.last, const Duration(minutes: 5));

        harness.clock.advance(const Duration(minutes: 4, seconds: 59));
        await reporter.flush();
        expect(harness.transport.sent, hasLength(1));

        harness.clock.advance(const Duration(seconds: 1));
        await reporter.flush();
        expect(harness.transport.sent.map((sent) => sent.error['code']), [
          'REFUSED',
          'WAITING',
        ]);
        reporter.dispose();
      });
    }

    for (final statusCode in [400, 413]) {
      test('HTTP $statusCode drops the report without pausing', () async {
        final harness = ReporterHarness(
          transport: RecordingTransport([IngestRejected(statusCode)]),
        );
        await harness.start();

        harness.reporter
          ..report(code: 'INVALID', message: 'invalid', action: 'a')
          ..report(code: 'NEXT', message: 'next', action: 'a');
        await harness.reporter.flush();

        expect(harness.transport.sent.map((sent) => sent.error['code']), [
          'INVALID',
          'NEXT',
        ]);
        expect(harness.timers.scheduledDelays, isEmpty);
      });
    }
  });

  group('429 Retry-After', () {
    test('nothing is sent before Retry-After has passed', () async {
      final harness = ReporterHarness(
        transport: RecordingTransport(
          [const IngestRateLimited(Duration(seconds: 120))],
        ),
      );
      await harness.start();
      final reporter = harness.reporter;

      reporter.report(code: 'LIMITED', message: 'limited', action: 'a');
      await reporter.flush();
      expect(harness.transport.sent, hasLength(1));
      expect(harness.timers.scheduledDelays.last, const Duration(seconds: 120));

      harness.clock.advance(const Duration(seconds: 119));
      await reporter.flush();
      expect(harness.transport.sent, hasLength(1));

      harness.clock.advance(const Duration(seconds: 1));
      await reporter.flush();
      expect(harness.transport.sent.map((sent) => sent.error['code']), [
        'LIMITED',
        'LIMITED',
      ]);
      reporter.dispose();
    });
  });

  group('transient failures', () {
    test('5xx and network errors keep the report and back off', () async {
      final harness = ReporterHarness(
        transport: RecordingTransport([
          const IngestTransientFailure('HTTP 503'),
          const IngestTransientFailure('connectionError'),
        ]),
      );
      await harness.start();
      final reporter = harness.reporter;

      reporter.report(code: 'RETRIED', message: 'retried', action: 'a');
      await reporter.flush();
      final firstDelay = harness.timers.scheduledDelays.last;
      expect(firstDelay.inMilliseconds, inInclusiveRange(4000, 6000));

      harness.clock.advance(firstDelay);
      await reporter.flush();
      final secondDelay = harness.timers.scheduledDelays.last;
      expect(secondDelay.inMilliseconds, inInclusiveRange(8000, 12000));

      harness.clock.advance(secondDelay);
      await reporter.flush();

      expect(harness.transport.sent, hasLength(3));
      expect(
        harness.transport.sent.every((sent) => sent.error['code'] == 'RETRIED'),
        isTrue,
      );
      reporter.dispose();
    });

    test('a throwing transport counts as a transient failure', () async {
      final harness = ReporterHarness(transport: _ThrowingOnceTransport());
      await harness.start();

      harness.reporter.report(code: 'X', message: 'm', action: 'a');
      await harness.reporter.flush();
      expect(harness.transport.sent, isEmpty);

      harness.clock.advance(const Duration(minutes: 1));
      await harness.reporter.flush();
      expect(harness.transport.sent, hasLength(1));
      harness.reporter.dispose();
    });
  });
}

class _ThrowingOnceTransport extends RecordingTransport {
  bool _thrown = false;

  @override
  Future<IngestOutcome> send(
    Map<String, Object?> payload, {
    String? bearerToken,
  }) {
    if (!_thrown) {
      _thrown = true;
      throw StateError('socket exploded');
    }
    return super.send(payload, bearerToken: bearerToken);
  }
}
