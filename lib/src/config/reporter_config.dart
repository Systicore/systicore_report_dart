import 'package:flutter/foundation.dart';

/// Returns the current Systicore access token, or null when signed out.
/// Called right before a report is sent, never at capture time. Return the
/// token already held in memory: triggering a refresh from here would put
/// the app's network stack on the reporting path.
typedef AccessTokenProvider = Future<String?> Function();

/// Returns the signed-in user's id, or null when signed out. Called
/// synchronously when an error is captured, so it must be cheap.
typedef UserIdProvider = String? Function();

/// Build identity of the running app, sent as the report's `release`.
@immutable
class ReleaseInfo {
  const ReleaseInfo({this.version, this.commit, this.buildTime});

  /// Release version such as `1.4.2+17`. When empty, the reporter uses the
  /// installed package's `version+buildNumber` from PackageInfo.
  final String? version;

  /// Commit SHA the build was made from (the `GIT_SHA` dart-define).
  final String? commit;

  /// RFC 3339 build timestamp.
  final String? buildTime;
}

/// Configuration passed to `SysticoreReporter.init`.
///
/// Reporting is a no-op unless [enabled] is true, [baseUrl] is non-empty and
/// [ingestKey] is a public `scpk_` key. A secret `scsk_` key is refused: it
/// belongs to a backend and must never ship inside an app.
@immutable
class ReporterConfig {
  const ReporterConfig({
    required this.enabled,
    required this.baseUrl,
    required this.ingestKey,
    required this.source,
    required this.environment,
    this.release = const ReleaseInfo(),
    this.accessTokenProvider,
    this.userIdProvider,
    this.maxQueue = defaultMaxQueue,
  });

  /// Reads the standard dart-defines: `REPORTS_ENABLED`, `REPORTS_URL`,
  /// `REPORTS_KEY`, `GIT_SHA`, `APP_VERSION` and `ENV`.
  ///
  /// The defines are compile-time constants of the whole program, so they
  /// reach this package exactly as passed to `flutter build`/`flutter run`.
  factory ReporterConfig.fromDartDefines({
    required String source,
    String? environment,
    String? buildTime,
    AccessTokenProvider? accessTokenProvider,
    UserIdProvider? userIdProvider,
    int maxQueue = defaultMaxQueue,
  }) {
    return ReporterConfig(
      enabled: _enabledDefine,
      baseUrl: _urlDefine,
      ingestKey: _keyDefine,
      source: source,
      environment: environment ?? _environmentDefine,
      release: ReleaseInfo(
        version: _appVersionDefine.isEmpty ? null : _appVersionDefine,
        commit: _commitDefine.isEmpty ? null : _commitDefine,
        buildTime: buildTime,
      ),
      accessTokenProvider: accessTokenProvider,
      userIdProvider: userIdProvider,
      maxQueue: maxQueue,
    );
  }

  static const int defaultMaxQueue = 50;

  /// Prefix of the public ingest keys an app may carry (contract v1.1).
  static const String publicKeyPrefix = 'scpk_';

  /// Prefix of the secret ingest keys reserved for backends (contract v1.1).
  static const String secretKeyPrefix = 'scsk_';

  static const bool _enabledDefine = bool.fromEnvironment('REPORTS_ENABLED');
  static const String _urlDefine = String.fromEnvironment('REPORTS_URL');
  static const String _keyDefine = String.fromEnvironment('REPORTS_KEY');
  static const String _commitDefine = String.fromEnvironment('GIT_SHA');
  static const String _appVersionDefine = String.fromEnvironment('APP_VERSION');
  static const String _environmentDefine =
      String.fromEnvironment('ENV', defaultValue: 'development');

  /// Master switch (`REPORTS_ENABLED`); dev and local builds keep it false.
  final bool enabled;

  /// Reports backend base URL (`REPORTS_URL`), e.g.
  /// `https://reports.systicore.hu`.
  final String baseUrl;

  /// Public `scpk_` ingest key of this component (`REPORTS_KEY`).
  final String ingestKey;

  /// Component name such as `passguard_mobile`. The backend derives the
  /// component from the key; this value only labels local diagnostics.
  final String source;

  /// `production`, `development`, `staging`… Informational: the key's own
  /// environment is authoritative on the server.
  final String environment;

  final ReleaseInfo release;

  /// Supplies the Systicore Bearer token so the backend can verify the user.
  final AccessTokenProvider? accessTokenProvider;

  /// Supplies the user id attached to captured errors.
  final UserIdProvider? userIdProvider;

  /// Maximum number of reports waiting for delivery; the oldest is dropped
  /// when a new one would exceed it.
  final int maxQueue;

  /// Whether [ingestKey] is a public `scpk_` key.
  bool get hasPublicKey => ingestKey.trim().startsWith(publicKeyPrefix);

  /// Whether [ingestKey] is a secret `scsk_` key, which an app must never
  /// carry: anyone can extract it from the build.
  bool get hasSecretKey => ingestKey.trim().startsWith(secretKeyPrefix);

  /// Whether this configuration actually sends anything. Only a public
  /// `scpk_` key is accepted; any other key, a secret `scsk_` key above all,
  /// turns reporting off.
  bool get isActive => enabled && baseUrl.trim().isNotEmpty && hasPublicKey;

  /// [maxQueue] clamped to a sane range.
  int get effectiveMaxQueue => maxQueue.clamp(1, 500);

  /// Parsed [baseUrl] without a trailing slash, or null when unusable.
  Uri? get baseUri {
    final trimmed = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return null;
    }
    return parsed;
  }
}
