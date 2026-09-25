import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../transport/ingest_outcome.dart';
import '../transport/ingest_transport.dart';

/// One ingest request a [RecordingIngestTransport] received.
@immutable
class RecordedIngestRequest {
  const RecordedIngestRequest(this.payload, this.bearerToken);

  /// The JSON body exactly as it would go over the wire.
  final Map<String, Object?> payload;

  /// The Bearer token sent with the request; null when none was attached.
  final String? bearerToken;

  /// The body's `error` object.
  Map<String, Object?> get error => payload['error']! as Map<String, Object?>;
}

/// [IngestTransport] that records every request instead of sending it, and
/// answers with the scripted outcomes first, then with [IngestAccepted].
class RecordingIngestTransport implements IngestTransport {
  RecordingIngestTransport([List<IngestOutcome>? scriptedOutcomes])
      : _scriptedOutcomes = [...?scriptedOutcomes];

  final List<IngestOutcome> _scriptedOutcomes;
  final List<RecordedIngestRequest> _sent = [];
  bool _isClosed = false;

  /// The requests received so far, oldest first.
  List<RecordedIngestRequest> get sent => UnmodifiableListView(_sent);

  /// Whether the reporter released the transport (`dispose`).
  bool get isClosed => _isClosed;

  /// Answers a later request with [outcome], after the ones already
  /// scripted.
  void answerNext(IngestOutcome outcome) => _scriptedOutcomes.add(outcome);

  @override
  Future<IngestOutcome> send(
    Map<String, Object?> payload, {
    String? bearerToken,
  }) async {
    // Round-trip through JSON like the real transport, so a test sees
    // exactly what would go over the wire.
    final wireCopy = jsonDecode(jsonEncode(payload)) as Map<String, Object?>;
    _sent.add(RecordedIngestRequest(wireCopy, bearerToken));
    if (_scriptedOutcomes.isEmpty) return const IngestAccepted();
    return _scriptedOutcomes.removeAt(0);
  }

  @override
  void close() => _isClosed = true;
}
