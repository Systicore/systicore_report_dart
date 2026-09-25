import 'dart:async';

import 'package:flutter/foundation.dart';

import 'capture/captured_error.dart';
import 'capture/error_type_namer.dart';
import 'capture/payload_builder.dart';
import 'capture/report_envelope.dart';
import 'capture/reported_errors.dart';
import 'config/reporter_config.dart';
import 'context/device_context_loader.dart';
import 'context/install_id_repository.dart';
import 'context/platform_name.dart';
import 'delivery/persistent_report_queue.dart';
import 'delivery/queued_report.dart';
import 'delivery/report_dispatcher.dart';
import 'flutter/uncaught_error_handlers.dart';
import 'model/breadcrumb.dart';
import 'model/report_severity.dart';
import 'model/report_user.dart';
import 'storage/platform_storage.dart';
import 'storage/reporter_storage.dart';
import 'support/clock.dart';
import 'support/reporter_log.dart';
import 'support/uuid.dart';
import 'throttle/duplicate_filter.dart';
import 'throttle/rate_limiter.dart';
import 'transport/dio_ingest_transport.dart';
import 'transport/ingest_transport.dart';

/// Creates the transport for a configured reporter.
typedef IngestTransportFactory = IngestTransport Function(
  Uri baseUri,
  String ingestKey,
);

/// Replaceable collaborators of [SysticoreReporter]; a null field means the
/// production default. Exported for tests by
/// `package:systicore_report/testing.dart`.
@immutable
class ReporterDependencies {
  const ReporterDependencies({
    this.storage,
    this.transportFactory,
    this.deviceContextLoader,
    this.clock,
    this.createTimer,
    this.platformDispatcher,
    this.errorTypeNamer,
  });

  /// Holds the queue and the install id; default: a file in the app's
  /// support directory (localStorage on the web).
  final ReporterStorage? storage;

  /// Creates the transport once `init` knows the URL and key; default:
  /// Dio posting to `/api/v1/ingest`.
  final IngestTransportFactory? transportFactory;

  /// Describes the device; default: device_info_plus and
  /// package_info_plus.
  final DeviceContextLoader? deviceContextLoader;

  /// Time source for throttling, backoff and breadcrumbs.
  final Clock? clock;

  /// Timers that wake the delivery up after backoff or `Retry-After`.
  final TimerFactory? createTimer;

  /// Receives the uncaught-error handler that
  /// [SysticoreReporter.installHandlers] chains in.
  final PlatformDispatcher? platformDispatcher;

  /// Names error classes for `error.type`.
  final ErrorTypeNamer? errorTypeNamer;
}

enum _Phase { awaitingInit, initialising, active, disabled }

/// Sends errors of a Flutter app to the Systicore reports backend.
///
/// Use the shared [instance] (or create one and keep it). Everything is
/// fire-and-forget: no method throws into the app, none blocks on the
/// network, and with reporting disabled every call is a no-op.
///
/// Errors captured before [init] are buffered and sent once [init] has
/// resolved the release and device information.
class SysticoreReporter {
  SysticoreReporter() : this.withDependencies(const ReporterDependencies());

  /// A reporter on replaced collaborators, for tests; see
  /// `package:systicore_report/testing.dart`.
  @visibleForTesting
  SysticoreReporter.withDependencies(ReporterDependencies dependencies)
      : _dependencies = dependencies,
        _clock = dependencies.clock ?? systemClock,
        _duplicateFilter =
            DuplicateFilter(clock: dependencies.clock ?? systemClock),
        _rateLimiter = RateLimiter(clock: dependencies.clock ?? systemClock),
        _reportedErrors =
            ReportedErrors(clock: dependencies.clock ?? systemClock),
        _errorTypeNamer = dependencies.errorTypeNamer ?? ErrorTypeNamer();

  /// The app-wide reporter.
  static final SysticoreReporter instance = SysticoreReporter();

  static const int _maxCapturedBeforeInit = ReporterConfig.defaultMaxQueue;
  static const String _flutterErrorCode = 'FLUTTER_ERROR';
  static const String _uncaughtErrorCode = 'UNHANDLED';

  final ReporterDependencies _dependencies;
  final Clock _clock;
  final DuplicateFilter _duplicateFilter;
  final RateLimiter _rateLimiter;
  final ReportedErrors _reportedErrors;
  final ErrorTypeNamer _errorTypeNamer;
  final BreadcrumbTrail _breadcrumbs = BreadcrumbTrail();
  final List<CapturedError> _capturedBeforeInit = [];

  _Phase _phase = _Phase.awaitingInit;
  Future<void>? _initialisation;
  ReporterConfig? _config;
  Uri? _baseUri;
  PayloadBuilder? _payloadBuilder;
  PersistentReportQueue? _queue;
  ReportDispatcher? _dispatcher;
  ReportUser? _explicitUser;
  String? _route;
  bool _handlersInstalled = false;

  /// True once [init] has completed with an active configuration.
  bool get isActive => _phase == _Phase.active;

  /// Configures the reporter, restores reports a previous run could not
  /// deliver and starts sending. Only the first call has an effect.
  Future<void> init(ReporterConfig config) {
    final running = _initialisation;
    if (running != null) {
      ReporterLog.debug('init() called again; the first configuration stays');
      return running;
    }
    return _initialisation = _initialise(config);
  }

  /// Reports an error under a stable application [code].
  ///
  /// Same call shape as the apps' former `ErrorReporter.report`. Keep
  /// [message] free of response bodies and personal data, and [action] a
  /// route template or operation name, never a URL with ids.
  void report({
    required String code,
    required String message,
    String? trace,
    required String action,
    ReportSeverity severity = ReportSeverity.error,
    Map<String, String>? tags,
    String? requestId,
  }) {
    _captureError(
      code: code,
      message: message,
      trace: trace,
      action: action,
      severity: severity,
      tags: tags,
      requestId: requestId,
    );
  }

  /// Reports a caught exception. Returns true when the reporter took it
  /// over (queued, or a duplicate of one queued within the last minute).
  ///
  /// Once taken, [error] counts as reported: when the app rethrows it or
  /// lets it escape, the global handlers ([installHandlers], [runGuarded])
  /// do not report it again. An explicit call is always judged on its own,
  /// also for an error reported before (e.g. by `ReportingInterceptor`),
  /// so a report under another [code] or [action] is sent.
  ///
  /// The class name is sent as `type`, except in minified (web release) and
  /// obfuscated builds, whose class names change with every build. There,
  /// pass a stable [code] so the backend keeps grouping the error.
  bool captureException(
    Object error,
    StackTrace? stackTrace, {
    String? action,
    ReportSeverity severity = ReportSeverity.error,
    Map<String, String>? tags,
    String? code,
  }) {
    return _captureError(
      thrown: error,
      type: _errorTypeNamer.nameOf(error),
      code: code,
      message: _describe(error),
      trace: stackTrace?.toString(),
      action: action,
      severity: severity,
      tags: tags,
    );
  }

  /// Marks [error] as reported, so for the next minute the global handlers
  /// ([installHandlers], [runGuarded]) do not report it again when the app
  /// rethrows it or lets it escape uncaught. An explicit [captureException]
  /// of it is still sent.
  ///
  /// `ReportingInterceptor` marks the `DioException`s it reports. Call this
  /// after reporting an error some other way, for example with [report].
  /// Strings, numbers, booleans and records cannot be marked.
  void markReported(Object error) {
    try {
      _reportedErrors.remember(error);
    } catch (internalError, stackTrace) {
      _logInternalFailure(internalError, stackTrace);
    }
  }

  /// Whether [error] was reported, or marked with [markReported], within
  /// the last minute.
  bool isReported(Object error) {
    try {
      return _reportedErrors.contains(error);
    } catch (internalError, stackTrace) {
      _logInternalFailure(internalError, stackTrace);
      return false;
    }
  }

  /// Sets the user attached to later reports; null clears it. An explicit
  /// user wins over [ReporterConfig.userIdProvider]. Without an [issuer],
  /// [ReporterConfig.userIssuer] is sent.
  void setUser(String? id, {String? issuer}) {
    final trimmed = id?.trim() ?? '';
    _explicitUser =
        trimmed.isEmpty ? null : ReportUser(id: trimmed, issuer: issuer);
  }

  /// Sets the current route template (e.g. `/vault/:id`), sent as
  /// `context.route`.
  void setRoute(String? route) {
    final trimmed = route?.trim() ?? '';
    _route = trimmed.isEmpty ? null : trimmed;
  }

  /// Records a step that is attached to the next reports (last 20 kept).
  void addBreadcrumb(
    String message, {
    BreadcrumbCategory category = BreadcrumbCategory.log,
  }) {
    if (_phase == _Phase.disabled) return;
    try {
      _breadcrumbs.add(
        Breadcrumb(timestamp: _clock(), category: category, message: message),
      );
    } catch (error, stackTrace) {
      _logInternalFailure(error, stackTrace);
    }
  }

  /// Reports framework errors (`FlutterError.onError`) and uncaught
  /// asynchronous errors (`PlatformDispatcher.instance.onError`), keeping
  /// the handlers installed before. Does nothing when reporting is disabled.
  void installHandlers() {
    if (_phase == _Phase.disabled || _handlersInstalled) return;
    try {
      UncaughtErrorHandlers(
        captureFlutterError: _captureFlutterError,
        captureUncaughtError: _captureUncaughtError,
        platformDispatcher: _dependencies.platformDispatcher,
      ).install();
      _handlersInstalled = true;
    } catch (error, stackTrace) {
      _logInternalFailure(error, stackTrace);
    }
  }

  /// Runs [appMain] inside `runZonedGuarded` and reports what escapes it.
  /// Put `WidgetsFlutterBinding.ensureInitialized()`, [init] and `runApp`
  /// inside [appMain] so they share the zone.
  ///
  /// [zoneSpecification] and [zoneValues] are passed on to
  /// `runZonedGuarded`, for example a `print` handler that mirrors log lines
  /// into the app's own log viewer. As with `runZonedGuarded` itself, the
  /// specification's `handleUncaughtError` is replaced by the reporter's.
  Future<void> runGuarded(
    FutureOr<void> Function() appMain, {
    ZoneSpecification? zoneSpecification,
    Map<Object?, Object?>? zoneValues,
  }) {
    return runInGuardedZone(
      appMain,
      captureUncaughtError: _captureUncaughtError,
      zoneSpecification: zoneSpecification,
      zoneValues: zoneValues,
    );
  }

  /// Whether [uri] points at the reports backend, whose own failures must
  /// never be reported.
  bool isReportsEndpoint(Uri uri) {
    final baseUri = _baseUri ?? _config?.baseUri;
    if (baseUri == null || uri.host.isEmpty) return false;
    return uri.host.toLowerCase() == baseUri.host.toLowerCase();
  }

  /// Tries to deliver everything queued now (respecting backoff, Retry-After
  /// and the circuit breaker) and waits for the queue to be written.
  Future<void> flush() async {
    try {
      await _initialisation;
      await _dispatcher?.drain();
      await _queue?.persistPending();
    } catch (error, stackTrace) {
      _logInternalFailure(error, stackTrace);
    }
  }

  /// Stops delivery and releases the HTTP client. Queued reports stay
  /// persisted for the next start.
  void dispose() {
    _phase = _Phase.disabled;
    _dispatcher?.dispose();
    _dispatcher = null;
    unawaited(_queue?.persistPending());
  }

  Future<void> _initialise(ReporterConfig config) async {
    _config = config;
    final baseUri = config.baseUri;
    if (!config.isActive || baseUri == null) {
      _logWhyInactive(config, baseUri);
      _disable();
      return;
    }
    _phase = _Phase.initialising;
    try {
      await _start(config, baseUri);
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Reporter start failed; reporting is off',
        error: error,
        stackTrace: stackTrace,
      );
      _disable();
    }
  }

  Future<void> _start(ReporterConfig config, Uri baseUri) async {
    final storage = _dependencies.storage ?? createPlatformStorage();
    final installId = await InstallIdRepository(storage).loadOrCreate();
    final deviceContextLoader =
        _dependencies.deviceContextLoader ?? PluginDeviceContextLoader();
    final device = await deviceContextLoader.load(installId: installId);
    final queue = PersistentReportQueue(
      storage: storage,
      capacity: config.effectiveMaxQueue,
      clock: _clock,
    );
    await queue.load();
    if (_phase == _Phase.disabled) return;

    final createTransport = _dependencies.transportFactory ?? _dioTransport;
    final dispatcher = ReportDispatcher(
      queue: queue,
      transport: createTransport(baseUri, config.ingestKey.trim()),
      bearerTokenFor: _bearerTokenFor,
      clock: _clock,
      createTimer: _dependencies.createTimer ?? createSystemTimer,
    );
    _baseUri = baseUri;
    _payloadBuilder = PayloadBuilder(
      ReportEnvelope.resolve(
        config: config,
        device: device,
        platform: currentPlatformName(),
      ),
    );
    _queue = queue;
    _dispatcher = dispatcher;
    _phase = _Phase.active;
    ReporterLog.debug(
      'Reporting active for ${config.source} (${config.environment}), '
      '${queue.length} report(s) restored',
    );
    _enqueueCapturedBeforeInit();
    unawaited(dispatcher.drain());
  }

  static IngestTransport _dioTransport(Uri baseUri, String ingestKey) =>
      DioIngestTransport(baseUri: baseUri, ingestKey: ingestKey);

  /// Explains a configuration that was switched on but cannot report. Only
  /// the key's kind is named, never the key itself.
  static void _logWhyInactive(ReporterConfig config, Uri? baseUri) {
    if (!config.enabled) return;
    if (config.hasSecretKey) {
      ReporterLog.debug(
        'REPORTS_KEY is a secret scsk_ key, which must never ship in an app; '
        'reporting is off',
      );
    } else if (config.ingestKey.trim().isNotEmpty && !config.hasPublicKey) {
      ReporterLog.debug(
        'REPORTS_KEY is not a public scpk_ key; reporting is off',
      );
    } else if (config.isActive && baseUri == null) {
      ReporterLog.debug('REPORTS_URL is not a valid URL; reporting is off');
    }
  }

  void _disable() {
    _phase = _Phase.disabled;
    _capturedBeforeInit.clear();
    _breadcrumbs.clear();
  }

  bool _captureFlutterError(FlutterErrorDetails details) {
    // Silent errors (e.g. a failed network image) are expected noise.
    if (details.silent) return false;
    if (_isAlreadyReported(details.exception)) return true;
    return _captureError(
      thrown: details.exception,
      type: _errorTypeNamer.nameOf(details.exception),
      code: _flutterErrorCode,
      message: _describeFlutterError(details),
      trace: details.stack?.toString(),
      action: 'flutter/${details.library ?? 'unknown'}',
    );
  }

  bool _captureUncaughtError(Object error, StackTrace stackTrace) {
    if (_isAlreadyReported(error)) return true;
    return _captureError(
      thrown: error,
      type: _errorTypeNamer.nameOf(error),
      code: _uncaughtErrorCode,
      message: _describe(error),
      trace: stackTrace.toString(),
      action: 'uncaught',
    );
  }

  // An error that reaches a global handler after it was reported (rethrown,
  // or escaping uncaught) counts as taken over without a second report.
  // Only the global handlers skip it; explicit calls are judged on their
  // own. With reporting disabled nothing is taken over.
  bool _isAlreadyReported(Object error) =>
      _phase != _Phase.disabled && isReported(error);

  // [thrown] is the error object behind the report, if there is one. Once
  // the report is taken, it is remembered for [_isAlreadyReported].
  bool _captureError({
    Object? thrown,
    String? type,
    String? code,
    String? message,
    String? trace,
    String? action,
    ReportSeverity severity = ReportSeverity.error,
    Map<String, String>? tags,
    String? requestId,
  }) {
    if (_phase == _Phase.disabled) return false;
    try {
      final taken = _accept(
        CapturedError(
          capturedAt: _clock(),
          type: type,
          code: code,
          message: message,
          trace: trace,
          action: action,
          severity: severity,
          tags: tags ?? const {},
          user: _currentUser(),
          breadcrumbs: _breadcrumbs.snapshot(),
          route: _route,
          requestId: requestId,
        ),
      );
      if (taken && thrown != null) _reportedErrors.remember(thrown);
      return taken;
    } catch (error, stackTrace) {
      _logInternalFailure(error, stackTrace);
      return false;
    }
  }

  // A repeat of an error taken within the last minute counts as taken over.
  // The error is only remembered once the rate limit let it through, so a
  // repeat of a dropped error is sent (or dropped) on its own merits.
  bool _accept(CapturedError captured) {
    if (!captured.hasIdentity) return false;
    if (_duplicateFilter.isDuplicate(captured)) return true;
    if (!_rateLimiter.tryAcquire()) {
      ReporterLog.debug('Client-side rate limit reached; report dropped');
      return false;
    }
    _duplicateFilter.remember(captured);
    if (_phase == _Phase.active) {
      _enqueue(captured);
    } else {
      _bufferUntilInit(captured);
    }
    return true;
  }

  void _bufferUntilInit(CapturedError captured) {
    _capturedBeforeInit.add(captured);
    if (_capturedBeforeInit.length > _maxCapturedBeforeInit) {
      _capturedBeforeInit.removeAt(0);
    }
  }

  void _enqueueCapturedBeforeInit() {
    final buffered = List<CapturedError>.of(_capturedBeforeInit);
    _capturedBeforeInit.clear();
    buffered.forEach(_enqueue);
  }

  void _enqueue(CapturedError captured) {
    final payloadBuilder = _payloadBuilder;
    final queue = _queue;
    final dispatcher = _dispatcher;
    if (payloadBuilder == null || queue == null || dispatcher == null) return;
    queue.add(
      QueuedReport(
        id: generateUuidV4(),
        createdAt: captured.capturedAt,
        userId: captured.user?.id,
        payload: payloadBuilder.build(captured),
      ),
    );
    unawaited(dispatcher.drain());
  }

  ReportUser? _currentUser() {
    final explicitUser = _explicitUser;
    if (explicitUser != null) return explicitUser;
    final userIdProvider = _config?.userIdProvider;
    if (userIdProvider == null) return null;
    try {
      final id = userIdProvider()?.trim() ?? '';
      return id.isEmpty ? null : ReportUser(id: id);
    } catch (error, stackTrace) {
      _logInternalFailure(error, stackTrace);
      return null;
    }
  }

  // The token proves who is signed in *now*. It is only attached when that
  // is the user the report was captured for; otherwise a report replayed
  // after an account switch would be attributed to the wrong person.
  Future<String?> _bearerTokenFor(QueuedReport report) async {
    final accessTokenProvider = _config?.accessTokenProvider;
    final reportUserId = report.userId;
    if (accessTokenProvider == null || reportUserId == null) return null;
    if (_currentUser()?.id != reportUserId) return null;
    final token = (await accessTokenProvider())?.trim() ?? '';
    return token.isEmpty ? null : token;
  }

  static String _describe(Object error) {
    try {
      return error.toString();
    } catch (_) {
      return 'Instance of ${error.runtimeType}';
    }
  }

  static String _describeFlutterError(FlutterErrorDetails details) {
    try {
      return details.exceptionAsString();
    } catch (_) {
      return _describe(details.exception);
    }
  }

  static void _logInternalFailure(Object error, StackTrace stackTrace) {
    ReporterLog.debug(
      'Reporter internal failure',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
