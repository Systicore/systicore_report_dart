import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Diagnostics of the reporter itself.
///
/// Only debug builds log: a release build must stay silent about report
/// internals. Nothing logged here may contain the ingest key or a token.
abstract final class ReporterLog {
  static const String _name = 'systicore_report';

  static void debug(String message, {Object? error, StackTrace? stackTrace}) {
    if (!kDebugMode) return;
    developer.log(message, name: _name, error: error, stackTrace: stackTrace);
  }

  /// Makes an error the reporter took over visible on the developer's
  /// console, since handling it suppresses the framework's own printout.
  static void surfaceHandledError(
    String origin,
    Object error,
    StackTrace? stackTrace,
  ) {
    if (!kDebugMode) return;
    debugPrint('[$_name] $origin: $error');
    if (stackTrace != null) debugPrint(stackTrace.toString());
  }
}
