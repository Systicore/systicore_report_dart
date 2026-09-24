import '../capture/captured_error.dart';
import '../support/clock.dart';

/// Suppresses repeats of the same error inside a short window, so a
/// failing build method or a retry loop does not flood the queue.
///
/// The key approximates the server-side fingerprint: type/code, the message
/// with digit runs collapsed, the action and the first stack frame.
///
/// Checking and recording are separate steps: an error only counts as seen
/// once it was actually taken, so a repeat of one that was dropped (for
/// example by the rate limit) is not mistaken for a duplicate.
class DuplicateFilter {
  DuplicateFilter({
    required Clock clock,
    this.window = const Duration(seconds: 60),
  }) : _clock = clock;

  final Clock _clock;
  final Duration window;
  final Map<String, DateTime> _lastSeenByKey = {};

  static final RegExp _digitRun = RegExp(r'\d+');
  static const int _maxMessageLengthInKey = 300;

  /// True when an equivalent error was [remember]ed within [window]. Does
  /// not record anything.
  bool isDuplicate(CapturedError captured) {
    final now = _clock();
    _forgetExpired(now);
    final lastSeen = _lastSeenByKey[keyOf(captured)];
    return lastSeen != null && now.difference(lastSeen) < window;
  }

  /// Records [captured] as let through now, so its repeats within [window]
  /// are duplicates.
  void remember(CapturedError captured) {
    _lastSeenByKey[keyOf(captured)] = _clock();
  }

  static String keyOf(CapturedError captured) {
    final message = (captured.message ?? '').replaceAll(_digitRun, '#');
    final shortMessage = message.length > _maxMessageLengthInKey
        ? message.substring(0, _maxMessageLengthInKey)
        : message;
    return [
      captured.type ?? '',
      captured.code ?? '',
      shortMessage,
      captured.action ?? '',
      _firstFrameOf(captured.trace),
    ].join('|');
  }

  static String _firstFrameOf(String? trace) {
    if (trace == null) return '';
    for (final line in trace.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }

  void _forgetExpired(DateTime now) {
    _lastSeenByKey.removeWhere(
      (_, lastSeen) => now.difference(lastSeen) >= window,
    );
  }
}
