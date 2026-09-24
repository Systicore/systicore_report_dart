import 'dart:collection';

import '../support/clock.dart';

/// Sliding-window limit on captured reports. The backend limits per key
/// and IP anyway; this keeps one misbehaving device from burning the
/// component's shared quota and the user's data plan.
class RateLimiter {
  RateLimiter({
    required Clock clock,
    this.limit = 30,
    this.window = const Duration(minutes: 1),
  }) : _clock = clock;

  final Clock _clock;
  final int limit;
  final Duration window;
  final Queue<DateTime> _acceptedAt = Queue<DateTime>();

  /// Records a report and returns true while under [limit] per [window].
  bool tryAcquire() {
    final now = _clock();
    while (
        _acceptedAt.isNotEmpty && now.difference(_acceptedAt.first) >= window) {
      _acceptedAt.removeFirst();
    }
    if (_acceptedAt.length >= limit) return false;
    _acceptedAt.addLast(now);
    return true;
  }
}
