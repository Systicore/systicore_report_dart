import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/transport/dio_ingest_transport.dart';
import 'package:systicore_report/src/transport/ingest_outcome.dart';

import 'support/fakes.dart';

void main() {
  late FakeHttpAdapter server;
  late DioIngestTransport transport;

  setUp(() {
    server = FakeHttpAdapter(const FakeHttpAnswer.status(202));
    transport = DioIngestTransport(
      baseUri: Uri.parse('https://reports.example.test/base'),
      ingestKey: 'scpk_test_key',
      dio: Dio()..httpClientAdapter = server,
    );
  });

  test('posts JSON with the key header and without a Bearer by default',
      () async {
    final outcome = await transport.send({
      'error': {'code': 'X'},
    });

    expect(outcome, isA<IngestAccepted>());
    final request = server.requests.single;
    expect(
      request.options.uri.toString(),
      'https://reports.example.test/base/api/v1/ingest',
    );
    expect(request.options.headers['X-Systicore-Key'], 'scpk_test_key');
    expect(request.options.headers.containsKey('Authorization'), isFalse);
    expect(request.json, {
      'error': {'code': 'X'},
    });
  });

  test('429 is read together with its Retry-After header', () async {
    server.answerNext(
      const FakeHttpAnswer.status(
        429,
        headers: {
          'retry-after': ['120'],
        },
        body: '{"status":"rate_limited"}',
      ),
    );

    final outcome = await transport.send(const {});

    expect(
      (outcome as IngestRateLimited).retryAfter,
      const Duration(seconds: 120),
    );
  });

  test('401 is a key problem, 503 and network errors are transient', () async {
    server
      ..answerNext(const FakeHttpAnswer.status(401))
      ..answerNext(const FakeHttpAnswer.status(503))
      ..answerNext(
        const FakeHttpAnswer.failure(DioExceptionType.connectionError),
      );

    final unauthorized = await transport.send(const {});
    final unavailable = await transport.send(const {});
    final offline = await transport.send(const {});

    expect((unauthorized as IngestRejected).isKeyProblem, isTrue);
    expect(unavailable, isA<IngestTransientFailure>());
    expect(offline, isA<IngestTransientFailure>());
  });
}
