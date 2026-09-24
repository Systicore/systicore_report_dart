import 'package:flutter_test/flutter_test.dart';

import 'support/reporter_harness.dart';

void main() {
  group('client-side throttling', () {
    test('a repeated error is sent once and still counts as taken over',
        () async {
      final harness = ReporterHarness();
      await harness.start();

      final first = harness.reporter.captureException(StateError('loop'), null);
      final second =
          harness.reporter.captureException(StateError('loop'), null);
      await harness.reporter.flush();

      expect(first, isTrue);
      expect(second, isTrue);
      expect(harness.transport.sent, hasLength(1));
    });

    test('more than 30 distinct errors a minute are dropped', () async {
      final harness = ReporterHarness();
      await harness.start();

      final results = [
        for (var index = 0; index < 35; index++)
          harness.reporter.captureException(
            StateError('error $index'),
            null,
            action: 'action $index',
          ),
      ];
      await harness.reporter.flush();

      expect(results.where((taken) => taken), hasLength(30));
      expect(harness.transport.sent, hasLength(30));
    });

    test('an error dropped by the rate limit is sent once the window frees up',
        () async {
      final harness = ReporterHarness();
      await harness.start();
      for (var index = 0; index < 30; index++) {
        harness.reporter.captureException(
          StateError('error $index'),
          null,
          action: 'action $index',
        );
      }
      harness.clock.advance(const Duration(seconds: 30));

      final whileLimited =
          harness.reporter.captureException(StateError('late'), null);
      harness.clock.advance(const Duration(seconds: 30));
      final afterWindow =
          harness.reporter.captureException(StateError('late'), null);
      await harness.reporter.flush();

      expect(whileLimited, isFalse);
      expect(afterWindow, isTrue);
      expect(harness.transport.sent, hasLength(31));
      expect(harness.transport.sent.last.error['message'], 'Bad state: late');
    });

    test('a report without type, code or message is not sent', () async {
      final harness = ReporterHarness();
      await harness.start();

      harness.reporter.report(code: ' ', message: '', action: 'a');
      await harness.reporter.flush();

      expect(harness.transport.sent, isEmpty);
    });
  });
}
