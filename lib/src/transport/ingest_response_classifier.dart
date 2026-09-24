import 'ingest_outcome.dart';

/// Maps an HTTP answer of `POST /api/v1/ingest` to an [IngestOutcome]
/// following the client rules of contract v1 §3.
abstract final class IngestResponseClassifier {
  static const Duration defaultRetryAfter = Duration(seconds: 60);
  static const Duration _minimumRetryAfter = Duration(seconds: 1);
  static const Duration _maximumRetryAfter = Duration(hours: 1);

  static IngestOutcome classify(int statusCode, {String? retryAfterHeader}) {
    if (statusCode >= 200 && statusCode < 300) return const IngestAccepted();
    if (statusCode == 429) {
      return IngestRateLimited(parseRetryAfter(retryAfterHeader));
    }
    if (statusCode == 408 || statusCode >= 500) {
      return IngestTransientFailure('HTTP $statusCode');
    }
    if (statusCode >= 400) return IngestRejected(statusCode);
    // 1xx/3xx never come from the ingest route itself (a redirect means a
    // proxy or a misconfigured base URL). Keep the reports: the queue is
    // bounded in size and age, and the endpoint may be fixed meanwhile.
    return IngestTransientFailure('HTTP $statusCode');
  }

  /// `Retry-After` in delta-seconds, clamped to [1 s, 1 h]. HTTP-date
  /// values and garbage fall back to [defaultRetryAfter].
  static Duration parseRetryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    if (seconds == null) return defaultRetryAfter;
    final delay = Duration(seconds: seconds);
    if (delay < _minimumRetryAfter) return _minimumRetryAfter;
    if (delay > _maximumRetryAfter) return _maximumRetryAfter;
    return delay;
  }
}
