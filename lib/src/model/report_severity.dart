/// Severity of a report. Only `error` and `critical` groups in production
/// open a GitHub issue; `warning` stays in the admin UI.
enum ReportSeverity {
  warning,
  error,
  critical;

  /// Value sent in `error.severity`.
  String get wireName => name;
}
