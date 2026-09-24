/// Error reporting for Flutter apps into the Systicore reports backend.
///
/// ```dart
/// await SysticoreReporter.instance.init(
///   ReporterConfig.fromDartDefines(source: 'passguard_mobile'),
/// );
/// SysticoreReporter.instance.installHandlers();
/// ```
library;

export 'src/config/reporter_config.dart'
    show AccessTokenProvider, ReleaseInfo, ReporterConfig, UserIdProvider;
export 'src/model/breadcrumb.dart' show BreadcrumbCategory;
export 'src/model/report_severity.dart' show ReportSeverity;
export 'src/systicore_reporter.dart' show SysticoreReporter;
