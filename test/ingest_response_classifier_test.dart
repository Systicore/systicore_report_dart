import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/transport/ingest_outcome.dart';
import 'package:systicore_report/src/transport/ingest_response_classifier.dart';

void main() {
  IngestOutcome classify(int statusCode) =>
      IngestResponseClassifier.classify(statusCode);

  group('status classification', () {
    test('2xx is accepted', () {
      expect(classify(202), isA<IngestAccepted>());
      expect(classify(201), isA<IngestAccepted>());
    });

    test('permanent 4xx are rejected; only 401/403 are key problems', () {
      for (final statusCode in [400, 401, 403, 404, 413, 422]) {
        final outcome = classify(statusCode);
        expect(outcome, isA<IngestRejected>());
        expect(
          (outcome as IngestRejected).isKeyProblem,
          statusCode == 401 || statusCode == 403,
        );
      }
    });

    test('5xx and 408 are transient', () {
      for (final statusCode in [408, 500, 502, 503, 504]) {
        expect(classify(statusCode), isA<IngestTransientFailure>());
      }
    });

    test('429 carries the Retry-After delay', () {
      final outcome = IngestResponseClassifier.classify(
        429,
        retryAfterHeader: '30',
      );
      expect(
        (outcome as IngestRateLimited).retryAfter,
        const Duration(seconds: 30),
      );
    });
  });

  group('Retry-After parsing', () {
    test('delta-seconds, clamped to [1 s, 1 h]', () {
      expect(
        IngestResponseClassifier.parseRetryAfter('120'),
        const Duration(seconds: 120),
      );
      expect(
        IngestResponseClassifier.parseRetryAfter(' 5 '),
        const Duration(seconds: 5),
      );
      expect(
        IngestResponseClassifier.parseRetryAfter('0'),
        const Duration(seconds: 1),
      );
      expect(
        IngestResponseClassifier.parseRetryAfter('999999'),
        const Duration(hours: 1),
      );
    });

    test('dates, garbage and a missing header fall back to 60 s', () {
      for (final header in ['Wed, 21 Oct 2026 07:28:00 GMT', 'soon', null]) {
        expect(
          IngestResponseClassifier.parseRetryAfter(header),
          IngestResponseClassifier.defaultRetryAfter,
        );
      }
    });
  });
}
