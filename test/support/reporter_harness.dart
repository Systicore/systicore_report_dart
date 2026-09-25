import 'package:systicore_report/src/capture/error_type_namer.dart';
import 'package:systicore_report/systicore_report.dart';
import 'package:systicore_report/testing.dart';

import 'fakes.dart';

const String testBaseUrl = 'https://reports.example.test';
const String testKeyRandomPart = '0123456789abcdefghijklmnopqrstuv';
const String testIngestKey = 'scpk_test_$testKeyRandomPart';
const String testSecretIngestKey = 'scsk_test_$testKeyRandomPart';

ReporterConfig testConfig({
  bool enabled = true,
  String baseUrl = testBaseUrl,
  String ingestKey = testIngestKey,
  ReleaseInfo release = const ReleaseInfo(commit: 'abc1234'),
  AccessTokenProvider? accessTokenProvider,
  UserIdProvider? userIdProvider,
  String? userIssuer,
  int maxQueue = ReporterConfig.defaultMaxQueue,
}) {
  return ReporterConfig(
    enabled: enabled,
    baseUrl: baseUrl,
    ingestKey: ingestKey,
    source: 'example_mobile',
    environment: 'production',
    release: release,
    accessTokenProvider: accessTokenProvider,
    userIdProvider: userIdProvider,
    userIssuer: userIssuer,
    maxQueue: maxQueue,
  );
}

/// A reporter wired to fakes, plus handles on those fakes.
class ReporterHarness {
  ReporterHarness({
    ReporterStorage? storage,
    RecordingIngestTransport? transport,
    FakeClock? clock,
    ErrorTypeNamer? errorTypeNamer,
  })  : storage = storage ?? CountingStorage(),
        transport = transport ?? RecordingIngestTransport(),
        clock = clock ?? FakeClock() {
    reporter = SysticoreReporter.withDependencies(
      ReporterDependencies(
        storage: this.storage,
        transportFactory: (baseUri, ingestKey) {
          transportCreations++;
          return this.transport;
        },
        deviceContextLoader: deviceContextLoader,
        clock: this.clock.call,
        createTimer: timers.call,
        errorTypeNamer: errorTypeNamer,
      ),
    );
  }

  final ReporterStorage storage;
  final RecordingIngestTransport transport;
  final FakeClock clock;
  final ManualTimers timers = ManualTimers();
  final CountingDeviceContextLoader deviceContextLoader =
      CountingDeviceContextLoader();
  late final SysticoreReporter reporter;
  int transportCreations = 0;

  Future<void> start([ReporterConfig? config]) async {
    await reporter.init(config ?? testConfig());
    await reporter.flush();
  }
}
