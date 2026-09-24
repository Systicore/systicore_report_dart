import '../support/clock.dart';

/// Stops all sending for [openDuration] after the backend refused the key
/// (401/403): every further request would be refused the same way.
class CircuitBreaker {
  CircuitBreaker({
    required Clock clock,
    this.openDuration = const Duration(minutes: 5),
  }) : _clock = clock;

  final Clock _clock;
  final Duration openDuration;
  DateTime? _closesAt;

  void trip() => _closesAt = _clock().add(openDuration);

  bool get isOpen {
    final closesAt = _closesAt;
    return closesAt != null && _clock().isBefore(closesAt);
  }

  /// When sending may resume; null while closed.
  DateTime? get closesAt => isOpen ? _closesAt : null;
}
