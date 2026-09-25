import 'package:dio/dio.dart';

import '../model/report_severity.dart';
import 'network_failure_cause.dart';

/// The HTTP failures worth a report: the server broke (5xx) or the request
/// never completed. 4xx answers are the app's normal business and are not
/// reported.
enum HttpFailureKind {
  serverError,
  timeout,
  connectionError;

  /// Offline users and flaky networks are common and not a bug, so they
  /// stay warnings (visible in the admin UI, never a GitHub issue).
  ReportSeverity get severity =>
      this == serverError ? ReportSeverity.error : ReportSeverity.warning;

  String codeFor(int? statusCode) {
    switch (this) {
      case HttpFailureKind.serverError:
        return 'HTTP_${statusCode ?? 500}';
      case HttpFailureKind.timeout:
        return 'HTTP_TIMEOUT';
      case HttpFailureKind.connectionError:
        return 'HTTP_CONNECTION_ERROR';
    }
  }

  String describe(String action, {int? statusCode, String? detail}) {
    switch (this) {
      case HttpFailureKind.serverError:
        return 'HTTP ${statusCode ?? 500} on $action';
      case HttpFailureKind.timeout:
        return 'Timeout${detail == null ? '' : ' ($detail)'} on $action';
      case HttpFailureKind.connectionError:
        return 'Connection error on $action';
    }
  }

  static const Set<DioExceptionType> _timeoutTypes = {
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  };

  /// Null for failures that are not reported: 4xx, cancellations, bad
  /// certificates and unknown errors other than network failures. Written
  /// with ifs rather than an exhaustive switch so a new DioExceptionType in
  /// a later dio 5.x release cannot break compilation.
  static HttpFailureKind? of(DioException exception) {
    final type = exception.type;
    if (type == DioExceptionType.badResponse) {
      return fromStatusCode(exception.response?.statusCode);
    }
    if (_timeoutTypes.contains(type)) return HttpFailureKind.timeout;
    if (type == DioExceptionType.connectionError) {
      return HttpFailureKind.connectionError;
    }
    // A connection that broke after it was opened.
    if (type == DioExceptionType.unknown &&
        isNetworkFailureCause(exception.error)) {
      return HttpFailureKind.connectionError;
    }
    return null;
  }

  static HttpFailureKind? fromStatusCode(int? statusCode) =>
      statusCode != null && statusCode >= 500 ? serverError : null;
}
