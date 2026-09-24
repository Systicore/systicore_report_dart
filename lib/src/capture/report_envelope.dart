import 'package:flutter/foundation.dart';

import '../config/reporter_config.dart';
import '../model/device_context.dart';

/// The per-process part of every report: release, environment, platform
/// and device. Resolved once during `init`.
@immutable
class ReportEnvelope {
  const ReportEnvelope({
    required this.release,
    required this.environment,
    required this.platform,
    required this.device,
  });

  /// Fills a missing release version from the installed package version.
  factory ReportEnvelope.resolve({
    required ReporterConfig config,
    required DeviceContext device,
    required String? platform,
  }) {
    final configuredVersion = config.release.version?.trim() ?? '';
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
    );
  }

  final ReleaseInfo release;
  final String environment;

  /// `android`, `ios`, `web`, `windows`, `macos`, `linux`, or null when
  /// the platform has no contract name.
  final String? platform;
  final DeviceContext device;
}
