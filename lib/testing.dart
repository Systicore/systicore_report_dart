/// Test seams of `package:systicore_report`, for an app's own tests: a
/// reporter on a recording transport, in-memory storage and a fixed
/// device, without platform plugins or network.
///
/// ```dart
/// import 'package:systicore_report/systicore_report.dart';
/// import 'package:systicore_report/testing.dart';
///
/// final transport = RecordingIngestTransport();
/// final reporter = SysticoreReporter.withDependencies(
///   ReporterDependencies(
///     storage: MemoryReporterStorage(),
///     transportFactory: (baseUri, ingestKey) => transport,
///     deviceContextLoader: const FixedDeviceContextLoader(),
///   ),
/// );
/// await reporter.init(config);
/// reporter.report(code: 'VAULT_SYNC_FAILED', message: 'm', action: 'a');
/// await reporter.flush();
/// expect(transport.sent.single.error['code'], 'VAULT_SYNC_FAILED');
/// ```
///
/// `SysticoreReporter.withDependencies` is meant for test code only.
library;

export 'src/context/device_context_loader.dart' show DeviceContextLoader;
export 'src/model/device_context.dart' show DeviceContext;
export 'src/storage/memory_reporter_storage.dart' show MemoryReporterStorage;
export 'src/storage/reporter_storage.dart' show ReporterStorage;
export 'src/support/clock.dart' show Clock, TimerFactory;
export 'src/systicore_reporter.dart'
    show IngestTransportFactory, ReporterDependencies;
export 'src/testing/fixed_device_context_loader.dart'
    show FixedDeviceContextLoader;
export 'src/testing/recording_ingest_transport.dart'
    show RecordedIngestRequest, RecordingIngestTransport;
export 'src/transport/ingest_outcome.dart'
    show
        IngestAccepted,
        IngestOutcome,
        IngestRateLimited,
        IngestRejected,
        IngestTransientFailure;
export 'src/transport/ingest_transport.dart' show IngestTransport;
