import 'dart:async';

import 'package:flutter/foundation.dart';

import '../support/reporter_log.dart';

/// Reports a framework error; returns whether the reporter took it over.
typedef FlutterErrorCapture = bool Function(FlutterErrorDetails details);

/// Reports an uncaught error; returns whether the reporter took it over.
typedef UncaughtErrorCapture = bool Function(
  Object error,
  StackTrace stackTrace,
);

/// Hooks the reporter into Flutter's two global error callbacks without
/// taking them away from the app: whatever handler was installed before
/// keeps running after the report is captured.
class UncaughtErrorHandlers {
  UncaughtErrorHandlers({
    required FlutterErrorCapture captureFlutterError,
    required UncaughtErrorCapture captureUncaughtError,
    PlatformDispatcher? platformDispatcher,
  })  : _captureFlutterError = captureFlutterError,
        _captureUncaughtError = captureUncaughtError,
        _platformDispatcher = platformDispatcher ?? PlatformDispatcher.instance;

  final FlutterErrorCapture _captureFlutterError;
  final UncaughtErrorCapture _captureUncaughtError;
  final PlatformDispatcher _platformDispatcher;

  void install() {
    _chainFlutterErrorHandler();
    _chainPlatformErrorHandler();
  }

  // Errors inside the framework (build, layout, paint, gestures). The
  // previous handler — FlutterError.presentError by default — still prints
  // the error in debug builds.
  void _chainFlutterErrorHandler() {
    final previousHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _captureFlutterError(details);
      previousHandler?.call(details);
    };
  }

  // Uncaught asynchronous errors of the root zone. Returning true tells the
  // engine the error was handled, so it is only returned once the reporter
  // (or the previous handler) actually took the error over; otherwise the
  // engine's default handling stays in place.
  void _chainPlatformErrorHandler() {
    final previousHandler = _platformDispatcher.onError;
    _platformDispatcher.onError = (Object error, StackTrace stackTrace) {
      final reported = _captureUncaughtError(error, stackTrace);
      final handledByPrevious =
          previousHandler?.call(error, stackTrace) ?? false;
      if (reported && !handledByPrevious) {
        ReporterLog.surfaceHandledError('Uncaught error', error, stackTrace);
      }
      return reported || handledByPrevious;
    };
  }
}

/// Runs [appMain] in a zone whose uncaught errors are reported.
///
/// Call `WidgetsFlutterBinding.ensureInitialized()` inside [appMain], in the
/// same zone as `runApp`. An error the reporter does not take over (for
/// example while reporting is disabled) is passed on to the surrounding
/// zone instead of being swallowed. The returned future completes when
/// [appMain] has returned or thrown. [zoneSpecification] and [zoneValues]
/// configure the zone as in `runZonedGuarded`.
Future<void> runInGuardedZone(
  FutureOr<void> Function() appMain, {
  required UncaughtErrorCapture captureUncaughtError,
  ZoneSpecification? zoneSpecification,
  Map<Object?, Object?>? zoneValues,
}) {
  final outerZone = Zone.current;
  final finished = Completer<void>();
  unawaited(
    runZonedGuarded<Future<void>>(
      () async {
        try {
          await appMain();
        } finally {
          if (!finished.isCompleted) finished.complete();
        }
      },
      (Object error, StackTrace stackTrace) {
        if (captureUncaughtError(error, stackTrace)) {
          ReporterLog.surfaceHandledError(
            'Uncaught zone error',
            error,
            stackTrace,
          );
          return;
        }
        outerZone.handleUncaughtError(error, stackTrace);
      },
      zoneSpecification: zoneSpecification,
      zoneValues: zoneValues,
    ),
  );
  return finished.future;
}
