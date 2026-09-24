import 'dart:async';

import '../support/clock.dart';
import '../support/reporter_log.dart';
import '../transport/ingest_outcome.dart';
import '../transport/ingest_transport.dart';
import 'circuit_breaker.dart';
import 'exponential_backoff.dart';
import 'persistent_report_queue.dart';
import 'queued_report.dart';

/// Resolves the Bearer token to send with a queued report, or null.
typedef BearerTokenLookup = Future<String?> Function(QueuedReport report);

/// Delivers the queue one report at a time, oldest first.
///
/// A 202 moves on to the next report; a permanent rejection drops the report
/// (and a 401/403 also opens the [CircuitBreaker]); a 429 pauses for its
/// Retry-After; a transient failure pauses with exponential backoff. While
/// paused, a timer wakes the dispatcher up; new reports only wait in the
/// queue. When a run ends, the removals the queue has not written yet are
/// written.
class ReportDispatcher {
  ReportDispatcher({
    required PersistentReportQueue queue,
    required IngestTransport transport,
    required BearerTokenLookup bearerTokenFor,
    required Clock clock,
    TimerFactory createTimer = createSystemTimer,
    CircuitBreaker? circuitBreaker,
    ExponentialBackoff? backoff,
    this.maxReportAge = const Duration(hours: 72),
  })  : _queue = queue,
        _transport = transport,
        _bearerTokenFor = bearerTokenFor,
        _clock = clock,
        _createTimer = createTimer,
        _circuitBreaker = circuitBreaker ?? CircuitBreaker(clock: clock),
        _backoff = backoff ?? ExponentialBackoff();

  /// Reports older than this are stale for triage and are dropped unsent.
  final Duration maxReportAge;

  static const Duration _tokenLookupTimeout = Duration(seconds: 5);

  final PersistentReportQueue _queue;
  final IngestTransport _transport;
  final BearerTokenLookup _bearerTokenFor;
  final Clock _clock;
  final TimerFactory _createTimer;
  final CircuitBreaker _circuitBreaker;
  final ExponentialBackoff _backoff;

  DateTime? _pausedUntil;
  Timer? _wakeUpTimer;
  bool _isDraining = false;
  bool _rerunRequested = false;
  Completer<void>? _drainCompleted;
  bool _disposed = false;

  /// Sends everything that may be sent now. Concurrent calls share one run.
  Future<void> drain() async {
    if (_disposed) return;
    if (_isDraining) {
      _rerunRequested = true;
      await _drainCompleted?.future;
      return;
    }
    _isDraining = true;
    final completed = _drainCompleted = Completer<void>();
    try {
      do {
        _rerunRequested = false;
        await _deliverPending();
      } while (_rerunRequested && !_disposed);
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Report delivery stopped unexpectedly',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isDraining = false;
      unawaited(_queue.persistPending());
      completed.complete();
    }
  }

  void dispose() {
    _disposed = true;
    _wakeUpTimer?.cancel();
    _wakeUpTimer = null;
    _transport.close();
  }

  Future<void> _deliverPending() async {
    while (!_disposed) {
      _dropStaleReports();
      final next = _queue.first;
      if (next == null) return;
      final resumeAt = _resumeAt();
      if (resumeAt != null) {
        _scheduleWakeUp(resumeAt);
        return;
      }
      final outcome = await _send(next);
      _apply(outcome, next);
    }
  }

  DateTime? _resumeAt() {
    final now = _clock();
    DateTime? resumeAt;
    final pausedUntil = _pausedUntil;
    if (pausedUntil != null && now.isBefore(pausedUntil)) {
      resumeAt = pausedUntil;
    }
    final circuitClosesAt = _circuitBreaker.closesAt;
    if (circuitClosesAt != null &&
        (resumeAt == null || circuitClosesAt.isAfter(resumeAt))) {
      resumeAt = circuitClosesAt;
    }
    return resumeAt;
  }

  Future<IngestOutcome> _send(QueuedReport report) async {
    final bearerToken = await _lookUpBearerToken(report);
    try {
      return await _transport.send(report.payload, bearerToken: bearerToken);
    } catch (error) {
      return IngestTransientFailure(error.runtimeType.toString());
    }
  }

  Future<String?> _lookUpBearerToken(QueuedReport report) async {
    try {
      return await _bearerTokenFor(report)
          .timeout(_tokenLookupTimeout, onTimeout: () => null);
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Access token lookup failed; sending without it',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  void _apply(IngestOutcome outcome, QueuedReport report) {
    switch (outcome) {
      case IngestAccepted():
        _queue.remove(report.id);
        _backoff.reset();
      case IngestRejected(:final statusCode, :final isKeyProblem):
        _queue.remove(report.id);
        _backoff.reset();
        if (isKeyProblem) _circuitBreaker.trip();
        ReporterLog.debug('Report rejected with HTTP $statusCode, dropped');
      case IngestRateLimited(:final retryAfter):
        _pausedUntil = _clock().add(retryAfter);
      case IngestTransientFailure(:final reason):
        final delay = _backoff.nextDelay();
        _pausedUntil = _clock().add(delay);
        ReporterLog.debug('Report delivery failed ($reason), retry in $delay');
    }
  }

  void _dropStaleReports() {
    final oldestAllowed = _clock().subtract(maxReportAge);
    _queue.removeWhere((report) => report.createdAt.isBefore(oldestAllowed));
  }

  void _scheduleWakeUp(DateTime resumeAt) {
    _wakeUpTimer?.cancel();
    final delay = resumeAt.difference(_clock());
    _wakeUpTimer = _createTimer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(drain()),
    );
  }
}
