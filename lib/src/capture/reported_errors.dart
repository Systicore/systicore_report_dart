import '../support/clock.dart';

/// Remembers the error objects reported within the last [window], so an
/// error that is rethrown, or escapes to a global handler after it was
/// reported, is not reported a second time under another code.
///
/// Errors are compared by identity and held in an [Expando], so a
/// remembered error is not kept alive. The window matters for errors that
/// are the same object every time, such as a `const` exception: once it
/// has passed, such an error is reported again like any repeated error.
///
/// An [Expando] cannot be attached to strings, numbers, booleans or
/// records; such errors are never remembered.
class ReportedErrors {
  ReportedErrors({
    required Clock clock,
    this.window = const Duration(seconds: 60),
  }) : _clock = clock;

  final Clock _clock;
  final Duration window;
  final Expando<DateTime> _reportedAt =
      Expando<DateTime>('systicore_report.reported');

  void remember(Object error) {
    if (!_canBeRemembered(error)) return;
    _reportedAt[error] = _clock();
  }

  bool contains(Object error) {
    if (!_canBeRemembered(error)) return false;
    final reportedAt = _reportedAt[error];
    return reportedAt != null && _clock().difference(reportedAt) < window;
  }

  static bool _canBeRemembered(Object error) =>
      error is! String && error is! num && error is! bool && error is! Record;
}
