import 'ingest_outcome.dart';

/// Sends one ingest payload. Implementations never throw: every failure is
/// an [IngestOutcome].
abstract interface class IngestTransport {
  Future<IngestOutcome> send(
    Map<String, Object?> payload, {
    String? bearerToken,
  });

  /// Releases the underlying HTTP client.
  void close();
}
