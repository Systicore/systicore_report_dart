import 'package:flutter/foundation.dart';

/// The installation that produced a report (`device` in the ingest body).
@immutable
class DeviceContext {
  const DeviceContext({
    required this.brand,
    required this.model,
    required this.osVersion,
    required this.apiLevel,
    required this.appVersion,
    required this.installId,
  });

  final String brand;
  final String model;
  final String osVersion;
  final int apiLevel;

  /// `version+buildNumber` of the installed package.
  final String appVersion;

  /// Random per-install id; lets the backend count affected devices.
  final String installId;

  Map<String, Object?> toJson() => {
        'brand': brand,
        'model': model,
        'osVersion': osVersion,
        'apiLevel': apiLevel,
        'appVersion': appVersion,
        'installId': installId,
      };
}
