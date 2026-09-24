import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../model/device_context.dart';
import '../support/reporter_log.dart';

/// Describes the running installation for the report's `device` block.
abstract interface class DeviceContextLoader {
  Future<DeviceContext> load({required String installId});
}

/// [DeviceContextLoader] backed by device_info_plus and package_info_plus.
///
/// Uses `defaultTargetPlatform` and `kIsWeb` instead of `dart:io`, so it
/// also runs on the web. It deliberately never reads the Windows computer
/// name, the Linux machine id or any other identifier of a person.
class PluginDeviceContextLoader implements DeviceContextLoader {
  PluginDeviceContextLoader({DeviceInfoPlugin? deviceInfo})
      : _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _deviceInfo;

  @override
  Future<DeviceContext> load({required String installId}) async {
    final appVersion = await _loadAppVersion();
    final hardware = await _loadHardware();
    return DeviceContext(
      brand: hardware.brand,
      model: hardware.model,
      osVersion: hardware.osVersion,
      apiLevel: hardware.apiLevel,
      appVersion: appVersion,
      installId: installId,
    );
  }

  Future<String> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final buildNumber = packageInfo.buildNumber.trim();
      return buildNumber.isEmpty
          ? packageInfo.version
          : '${packageInfo.version}+$buildNumber';
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Package info unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      return '';
    }
  }

  Future<_Hardware> _loadHardware() async {
    try {
      return await _describeHardware();
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Device info unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      return const _Hardware.unknown();
    }
  }

  Future<_Hardware> _describeHardware() async {
    if (kIsWeb) {
      final browser = await _deviceInfo.webBrowserInfo;
      return _Hardware(
        brand: 'Browser',
        model: browser.browserName.name,
        osVersion: browser.platform ?? '',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final android = await _deviceInfo.androidInfo;
        return _Hardware(
          brand: android.brand,
          model: android.model,
          osVersion: 'Android ${android.version.release}',
          apiLevel: android.version.sdkInt,
        );
      case TargetPlatform.iOS:
        final ios = await _deviceInfo.iosInfo;
        return _Hardware(
          brand: 'Apple',
          model: ios.utsname.machine,
          osVersion: 'iOS ${ios.systemVersion}',
        );
      case TargetPlatform.macOS:
        final macos = await _deviceInfo.macOsInfo;
        return _Hardware(
          brand: 'Apple',
          model: macos.model,
          osVersion: 'macOS ${macos.majorVersion}.${macos.minorVersion}'
              '.${macos.patchVersion}',
        );
      case TargetPlatform.windows:
        // productName ("Windows 11 Pro"), never computerName: the host name
        // usually contains the owner's name.
        final windows = await _deviceInfo.windowsInfo;
        return _Hardware(
          brand: 'PC',
          model: windows.productName,
          osVersion: 'Windows ${windows.majorVersion}.${windows.minorVersion}',
          apiLevel: windows.buildNumber,
        );
      case TargetPlatform.linux:
        final linux = await _deviceInfo.linuxInfo;
        return _Hardware(
          brand: 'PC',
          model: linux.prettyName,
          osVersion: 'Linux ${linux.versionId ?? ''}'.trim(),
        );
      case TargetPlatform.fuchsia:
        return const _Hardware.unknown();
    }
  }
}

class _Hardware {
  const _Hardware({
    required this.brand,
    required this.model,
    required this.osVersion,
    this.apiLevel = 0,
  });

  const _Hardware.unknown()
      : brand = '',
        model = '',
        osVersion = '',
        apiLevel = 0;

  final String brand;
  final String model;
  final String osVersion;
  final int apiLevel;
}
