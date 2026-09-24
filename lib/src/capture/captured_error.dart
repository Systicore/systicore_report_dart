import 'package:flutter/foundation.dart';

import '../model/breadcrumb.dart';
import '../model/report_severity.dart';
import '../model/report_user.dart';

/// Everything known about one error at the moment it was captured, before
/// it is combined with the release/device envelope into a payload.
@immutable
class CapturedError {
  const CapturedError({
    required this.capturedAt,
    this.type,
    this.code,
    this.message,
    this.trace,
    this.action,
    this.severity = ReportSeverity.error,
    this.tags = const {},
    this.user,
    this.breadcrumbs = const [],
    this.route,
    this.requestId,
  });

  final DateTime capturedAt;

  /// Exception class name, e.g. `StateError`.
  final String? type;

  /// Stable application code, e.g. `VAULT_SYNC_FAILED`.
  final String? code;
  final String? message;
  final String? trace;

  /// Route template, screen or operation; never a raw URL with ids.
  final String? action;
  final ReportSeverity severity;
  final Map<String, String> tags;
  final ReportUser? user;
  final List<Breadcrumb> breadcrumbs;
  final String? route;
  final String? requestId;

  /// The backend rejects a report that has none of type, code and message.
  bool get hasIdentity =>
      _isPresent(type) || _isPresent(code) || _isPresent(message);

  static bool _isPresent(String? value) =>
      value != null && value.trim().isNotEmpty;
}
