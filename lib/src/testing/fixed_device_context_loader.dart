import '../context/device_context_loader.dart';
import '../model/device_context.dart';

/// [DeviceContextLoader] that describes the same made-up device every time,
/// without the device_info_plus and package_info_plus platform channels,
/// which unit tests do not have.
class FixedDeviceContextLoader implements DeviceContextLoader {
  const FixedDeviceContextLoader({
    this.brand = 'Test',
    this.model = 'Test device',
    this.osVersion = 'Test OS',
    this.apiLevel = 0,
    this.appVersion = '1.0.0+1',
  });

  final String brand;
  final String model;
  final String osVersion;
  final int apiLevel;

  /// `version+buildNumber`; also the release version unless the
  /// configuration names one.
  final String appVersion;

  @override
  Future<DeviceContext> load({required String installId}) async {
    return DeviceContext(
      brand: brand,
      model: model,
      osVersion: osVersion,
      apiLevel: apiLevel,
      appVersion: appVersion,
      installId: installId,
    );
  }
}
