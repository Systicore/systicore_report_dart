import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/config/reporter_config.dart';
import 'package:systicore_report/src/context/platform_name.dart';

ReporterConfig config({
  bool enabled = true,
  String baseUrl = 'https://reports.example.test',
  String ingestKey = 'pk_test_key',
  int maxQueue = ReporterConfig.defaultMaxQueue,
}) {
  return ReporterConfig(
    enabled: enabled,
    baseUrl: baseUrl,
    ingestKey: ingestKey,
    source: 'example_mobile',
    environment: 'production',
    maxQueue: maxQueue,
  );
}

void main() {
  group('ReporterConfig', () {
    test('is active only with the switch, a URL and a key', () {
      expect(config().isActive, isTrue);
      expect(config(enabled: false).isActive, isFalse);
      expect(config(baseUrl: ' ').isActive, isFalse);
      expect(config(ingestKey: '').isActive, isFalse);
    });

    test('baseUri drops trailing slashes and rejects non-URLs', () {
      expect(
        config(baseUrl: 'https://reports.systicore.hu//').baseUri.toString(),
        'https://reports.systicore.hu',
      );
      expect(config(baseUrl: 'reports.systicore.hu').baseUri, isNull);
    });

    test('maxQueue is clamped', () {
      expect(config(maxQueue: 0).effectiveMaxQueue, 1);
      expect(config(maxQueue: 10000).effectiveMaxQueue, 500);
      expect(config().effectiveMaxQueue, 50);
    });

    test('fromDartDefines is disabled when no defines are passed', () {
      final fromDefines =
          ReporterConfig.fromDartDefines(source: 'example_mobile');

      expect(fromDefines.isActive, isFalse);
      expect(fromDefines.environment, 'development');
      expect(fromDefines.release.commit, isNull);
      expect(fromDefines.maxQueue, 50);
    });
  });

  group('platformNameOf', () {
    test('maps every target platform to the contract names', () {
      final expected = {
        TargetPlatform.android: 'android',
        TargetPlatform.iOS: 'ios',
        TargetPlatform.macOS: 'macos',
        TargetPlatform.windows: 'windows',
        TargetPlatform.linux: 'linux',
        TargetPlatform.fuchsia: null,
      };
      expected.forEach((targetPlatform, name) {
        expect(
          platformNameOf(isWeb: false, targetPlatform: targetPlatform),
          name,
        );
      });
      expect(
        platformNameOf(isWeb: true, targetPlatform: TargetPlatform.android),
        'web',
      );
    });
  });
}
