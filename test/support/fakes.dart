import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:systicore_report/testing.dart';

/// Controllable time source.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 9, 24, 10);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
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

/// A Pixel 9 that counts how often the reporter asked for it.
class CountingDeviceContextLoader extends FixedDeviceContextLoader {
  CountingDeviceContextLoader()
      : super(
          brand: 'Google',
          model: 'Pixel 9',
          osVersion: 'Android 16',
          apiLevel: 36,
          appVersion: '1.4.2+17',
        );

  int loads = 0;

  @override
  Future<DeviceContext> load({required String installId}) {
    loads++;
    return super.load(installId: installId);
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
