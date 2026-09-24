/// What the reports backend's answer means for the report that was sent.
sealed class IngestOutcome {
  const IngestOutcome();
}

/// 2xx: stored (or deliberately sampled away). The report is done.
final class IngestAccepted extends IngestOutcome {
  const IngestAccepted();
}

/// 400/401/403/413 and other permanent 4xx: retrying cannot help, the
/// report is dropped.
final class IngestRejected extends IngestOutcome {
  const IngestRejected(this.statusCode);

  final int statusCode;

  /// 401/403: the key is unknown, revoked, expired or not allowed here, so
  /// every further report would fail the same way.
  bool get isKeyProblem => statusCode == 401 || statusCode == 403;
}

/// 429: wait [retryAfter] before sending anything again.
final class IngestRateLimited extends IngestOutcome {
  const IngestRateLimited(this.retryAfter);

  final Duration retryAfter;
}

/// 5xx, 408 or a network failure: keep the report and retry with backoff.
final class IngestTransientFailure extends IngestOutcome {
  const IngestTransientFailure(this.reason);

  final String reason;
}
