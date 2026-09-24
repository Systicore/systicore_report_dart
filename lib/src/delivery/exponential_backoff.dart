import 'dart:math';

/// Delay before the next attempt after consecutive transient failures:
/// [initial] doubled per failure up to [maximum], with ±20 % jitter so a
/// fleet of devices coming back online does not retry in lockstep.
class ExponentialBackoff {
  ExponentialBackoff({
    this.initial = const Duration(seconds: 5),
    this.maximum = const Duration(minutes: 5),
    Random? random,
  }) : _random = random ?? Random();

  final Duration initial;
  final Duration maximum;
  final Random _random;
  int _consecutiveFailures = 0;

  static const double _jitterRatio = 0.2;

  Duration nextDelay() {
    final exponent = min(_consecutiveFailures, 20);
    _consecutiveFailures++;
    final uncapped = initial.inMilliseconds * pow(2, exponent);
    final capped = min(uncapped, maximum.inMilliseconds).toDouble();
    final jitter = capped * _jitterRatio * (_random.nextDouble() * 2 - 1);
    return Duration(milliseconds: (capped + jitter).round());
  }

  void reset() => _consecutiveFailures = 0;
}
