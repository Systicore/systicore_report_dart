import 'package:dio/dio.dart';

import '../model/breadcrumb.dart';
import '../support/reporter_log.dart';
import '../systicore_reporter.dart';
import 'http_failure.dart';
import 'request_path_template.dart';

/// Dio interceptor that reports server errors (status >= 500) and
/// connection/timeout failures, and records every call as an `http`
/// breadcrumb.
///
/// It only observes: every callback passes the response or error on
/// unchanged, and a failure inside the reporter can never affect the
/// request. Requests to the reports backend itself are ignored. Add it last
/// so it sees the outcome after the app's own retry interceptors.
///
/// A `DioException` it reports is marked with
/// [SysticoreReporter.markReported]: when the app lets it escape uncaught,
/// the global handlers do not report it a second time.
class ReportingInterceptor extends Interceptor {
  ReportingInterceptor({
    SysticoreReporter? reporter,
    this.recordBreadcrumbs = true,
  }) : _reporter = reporter ?? SysticoreReporter.instance;

  final SysticoreReporter _reporter;

  /// Whether each finished request is added as a breadcrumb.
  final bool recordBreadcrumbs;

  static const String _requestIdHeader = 'x-request-id';

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _observeSafely(() => _observeResponse(response));
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _observeSafely(() => _observeFailure(err));
    handler.next(err);
  }

  // A Dio whose validateStatus accepts 5xx delivers them here, not in
  // onError.
  void _observeResponse(Response<dynamic> response) {
    final request = response.requestOptions;
    if (_reporter.isReportsEndpoint(request.uri)) return;
    final statusCode = response.statusCode;
    _recordBreadcrumb(request, '${statusCode ?? '-'}');
    final failure = HttpFailureKind.fromStatusCode(statusCode);
    if (failure == null) return;
    _report(
      request,
      failure,
      statusCode: statusCode,
      requestId: response.headers.value(_requestIdHeader),
    );
  }

  void _observeFailure(DioException exception) {
    final request = exception.requestOptions;
    if (_reporter.isReportsEndpoint(request.uri)) return;
    final statusCode = exception.response?.statusCode;
    _recordBreadcrumb(request, '${statusCode ?? exception.type.name}');
    final failure = HttpFailureKind.of(exception);
    if (failure == null) return;
    _report(
      request,
      failure,
      statusCode: statusCode,
      requestId: exception.response?.headers.value(_requestIdHeader),
      detail: exception.type.name,
      trace: exception.stackTrace.toString(),
    );
    _reporter.markReported(exception);
  }

  void _report(
    RequestOptions request,
    HttpFailureKind failure, {
    int? statusCode,
    String? requestId,
    String? detail,
    String? trace,
  }) {
    final method = request.method.toUpperCase();
    final action = '$method ${pathTemplateOf(request.uri)}';
    _reporter.report(
      code: failure.codeFor(statusCode),
      message: failure.describe(action, statusCode: statusCode, detail: detail),
      trace: trace,
      action: action,
      severity: failure.severity,
      tags: {
        'http.method': method,
        'http.host': request.uri.host,
        if (statusCode != null) 'http.status': '$statusCode',
      },
      requestId: requestId,
    );
  }

  void _recordBreadcrumb(RequestOptions request, String outcome) {
    if (!recordBreadcrumbs) return;
    final method = request.method.toUpperCase();
    _reporter.addBreadcrumb(
      '$method ${pathTemplateOf(request.uri)} $outcome',
      category: BreadcrumbCategory.http,
    );
  }

  static void _observeSafely(void Function() observe) {
    try {
      observe();
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'ReportingInterceptor failed; request unaffected',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
