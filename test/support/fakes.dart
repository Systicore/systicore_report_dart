import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:systicore_report/src/context/device_context_loader.dart';
import 'package:systicore_report/src/model/device_context.dart';
import 'package:systicore_report/src/storage/memory_reporter_storage.dart';
import 'package:systicore_report/src/transport/ingest_outcome.dart';
import 'package:systicore_report/src/transport/ingest_transport.dart';

/// Controllable time source.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 9, 24, 10);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
}

/// One request a [RecordingTransport] received.
class SentReport {
  SentReport(this.payload, this.bearerToken);

  final Map<String, Object?> payload;
  final String? bearerToken;

  Map<String, Object?> get error => payload['error']! as Map<String, Object?>;
}

/// Records payloads and answers with scripted outcomes (then 202).
class RecordingTransport implements IngestTransport {
  RecordingTransport([List<IngestOutcome>? scriptedOutcomes])
      : _scriptedOutcomes = [...?scriptedOutcomes];

  final List<IngestOutcome> _scriptedOutcomes;
  final List<SentReport> sent = [];
  bool closed = false;

  void answerNext(IngestOutcome outcome) => _scriptedOutcomes.add(outcome);

  @override
  Future<IngestOutcome> send(
    Map<String, Object?> payload, {
    String? bearerToken,
  }) async {
    // Round-trip through JSON like the real transport, so tests see exactly
    // what would go over the wire.
    final wireCopy = jsonDecode(jsonEncode(payload)) as Map<String, Object?>;
    sent.add(SentReport(wireCopy, bearerToken));
    if (_scriptedOutcomes.isEmpty) return const IngestAccepted();
    return _scriptedOutcomes.removeAt(0);
  }

  @override
  void close() => closed = true;
}

/// Storage that counts accesses, to prove the disabled mode touches nothing.
class CountingStorage extends MemoryReporterStorage {
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) {
    reads++;
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    writes++;
    return super.write(key, value);
  }
}

class FixedDeviceContextLoader implements DeviceContextLoader {
  int loads = 0;

  @override
  Future<DeviceContext> load({required String installId}) async {
    loads++;
    return DeviceContext(
      brand: 'Google',
      model: 'Pixel 9',
      osVersion: 'Android 16',
      apiLevel: 36,
      appVersion: '1.4.2+17',
      installId: installId,
    );
  }
}

/// Timer factory that never fires on its own; tests advance the clock and
/// call `flush()` instead.
class ManualTimers {
  final List<Duration> scheduledDelays = [];

  Timer call(Duration delay, void Function() callback) {
    scheduledDelays.add(delay);
    return _InertTimer();
  }
}

class _InertTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// A scripted answer of [FakeHttpAdapter].
class FakeHttpAnswer {
  const FakeHttpAnswer.status(
    this.statusCode, {
    this.headers = const {},
    this.body = '',
  })  : failure = null,
        thrownError = null;

  const FakeHttpAnswer.failure(DioExceptionType this.failure)
      : statusCode = 0,
        headers = const {},
        body = '',
        thrownError = null;

  /// The adapter throws [thrownError] itself, as dart:io does, and dio
  /// wraps it the way it wraps a real adapter's exception.
  const FakeHttpAnswer.thrown(Object this.thrownError)
      : statusCode = 0,
        headers = const {},
        body = '',
        failure = null;

  final int statusCode;
  final Map<String, List<String>> headers;
  final String body;
  final DioExceptionType? failure;
  final Object? thrownError;
}

/// Request as seen by [FakeHttpAdapter].
class RecordedRequest {
  RecordedRequest(this.options, this.body);

  final RequestOptions options;
  final String body;

  Map<String, Object?> get json => jsonDecode(body) as Map<String, Object?>;
}

/// In-memory Dio adapter: no sockets, scripted answers.
class FakeHttpAdapter implements HttpClientAdapter {
  FakeHttpAdapter([this.defaultAnswer = const FakeHttpAnswer.status(200)]);

  FakeHttpAnswer defaultAnswer;
  final List<FakeHttpAnswer> _scriptedAnswers = [];
  final List<RecordedRequest> requests = [];

  void answerNext(FakeHttpAnswer answer) => _scriptedAnswers.add(answer);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bodyBytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bodyBytes.addAll(chunk);
      }
    }
    requests.add(RecordedRequest(options, utf8.decode(bodyBytes)));
    final answer =
        _scriptedAnswers.isEmpty ? defaultAnswer : _scriptedAnswers.removeAt(0);
    final failure = answer.failure;
    if (failure != null) {
      throw DioException(requestOptions: options, type: failure);
    }
    final thrownError = answer.thrownError;
    if (thrownError != null) throw thrownError;
    return ResponseBody.fromString(
      answer.body,
      answer.statusCode,
      headers: answer.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
