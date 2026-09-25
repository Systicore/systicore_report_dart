import 'package:flutter/foundation.dart';

import '../config/reporter_config.dart';
import '../model/device_context.dart';

/// The per-process part of every report: release, environment, platform,
/// device and the issuer of the app's user ids. Resolved once during
/// `init`.
@immutable
class ReportEnvelope {
  const ReportEnvelope({
    required this.release,
    required this.environment,
    required this.platform,
    required this.device,
    this.userIssuer,
  });

  /// Fills a missing release version from the installed package version.
  factory ReportEnvelope.resolve({
    required ReporterConfig config,
    required DeviceContext device,
    required String? platform,
  }) {
    final configuredVersion = config.release.version?.trim() ?? '';
    final userIssuer = config.userIssuer?.trim() ?? '';
    return ReportEnvelope(
      release: ReleaseInfo(
        version: configuredVersion.isNotEmpty
            ? configuredVersion
            : (device.appVersion.isEmpty ? null : device.appVersion),
        commit: config.release.commit,
        buildTime: config.release.buildTime,
      ),
      environment: config.environment,
      platform: platform,
      device: device,
      userIssuer: userIssuer.isEmpty ? null : userIssuer,
    );
  }

  final ReleaseInfo release;
  final String environment;

  /// `android`, `ios`, `web`, `windows`, `macos`, `linux`, or null when
  /// the platform has no contract name.
  final String? platform;
  final DeviceContext device;

  /// Issuer for a report's user id that came without one.
  final String? userIssuer;
}
