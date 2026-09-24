import 'dart:async';

/// Current time source; injected so throttling, backoff and the circuit
/// breaker can be tested without waiting.
typedef Clock = DateTime Function();

/// Creates the one-shot timer that wakes the dispatcher up after a pause.
typedef TimerFactory = Timer Function(Duration delay, void Function() callback);

DateTime systemClock() => DateTime.now();

Timer createSystemTimer(Duration delay, void Function() callback) =>
    Timer(delay, callback);
