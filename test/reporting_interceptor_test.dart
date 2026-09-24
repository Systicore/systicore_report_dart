import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/dio/request_path_template.dart';
import 'package:systicore_report/systicore_report.dart';

import 'support/fakes.dart';
import 'support/reporter_harness.dart';

void main() {
  group('ReportingInterceptor', () {
    late ReporterHarness harness;
    late FakeHttpAdapter appBackend;
    late Dio appDio;

    setUp(() async {
      harness = ReporterHarness();
      await harness.start();
      appBackend = FakeHttpAdapter();
      appDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = appBackend
        ..interceptors.add(ReportingInterceptor(reporter: harness.reporter));
    });

    tearDown(() => harness.reporter.dispose());

    Future<DioException> failingGet(String path) async {
      try {
        await appDio.get<String>(path);
      } on DioException catch (exception) {
        return exception;
      }
      fail('expected $path to fail');
    }

    List<Map<String, Object?>> sentErrors() => [
          for (final sent in harness.transport.sent) sent.error,
        ];

    test('reports a 5xx with a templated action and passes it on', () async {
      appBackend.answerNext(
        const FakeHttpAnswer.status(
          503,
          headers: {
            'x-request-id': ['req-123'],
          },
        ),
      );

      final exception = await failingGet('/api/vault/8812?include=items');
      await harness.reporter.flush();

      expect(exception.type, DioExceptionType.badResponse);
      expect(exception.response?.statusCode, 503);
      final sent = harness.transport.sent.single;
      expect(sent.error['code'], 'HTTP_503');
      expect(sent.error['action'], 'GET /api/vault/:id');
      expect(sent.error['message'], 'HTTP 503 on GET /api/vault/:id');
      expect(sent.error['severity'], 'error');
      final context = sent.payload['context']! as Map<String, Object?>;
      expect(context['requestId'], 'req-123');
      expect(context['tags'], {
        'http.method': 'GET',
        'http.host': 'api.example.test',
        'http.status': '503',
      });
    });

    test('does not report 4xx answers', () async {
      appBackend.answerNext(const FakeHttpAnswer.status(404));
      appBackend.answerNext(const FakeHttpAnswer.status(401));

      await failingGet('/api/missing');
      await failingGet('/api/secret');
      await harness.reporter.flush();

      expect(harness.transport.sent, isEmpty);
    });

    test('reports connection errors and timeouts as warnings', () async {
      appBackend.answerNext(
        const FakeHttpAnswer.failure(DioExceptionType.connectionError),
      );
      appBackend.answerNext(
        const FakeHttpAnswer.failure(DioExceptionType.receiveTimeout),
      );

      final connectionFailure = await failingGet('/api/sync');
      final timeout = await failingGet('/api/items/12');
      await harness.reporter.flush();

      expect(connectionFailure.type, DioExceptionType.connectionError);
      expect(timeout.type, DioExceptionType.receiveTimeout);
      expect(sentErrors().map((error) => error['code']), [
        'HTTP_CONNECTION_ERROR',
        'HTTP_TIMEOUT',
      ]);
      expect(
        sentErrors().map((error) => error['severity']),
        ['warning', 'warning'],
      );
      expect(
        sentErrors().last['message'],
        'Timeout (receiveTimeout) on GET /api/items/:id',
      );
    });

    test('ignores cancelled requests and bad certificates', () async {
      appBackend
          .answerNext(const FakeHttpAnswer.failure(DioExceptionType.cancel));
      appBackend.answerNext(
        const FakeHttpAnswer.failure(DioExceptionType.badCertificate),
      );

      await failingGet('/api/cancelled');
      await failingGet('/api/pinned');
      await harness.reporter.flush();

      expect(harness.transport.sent, isEmpty);
    });

    test('ignores requests to the reports backend itself', () async {
      appBackend.answerNext(const FakeHttpAnswer.status(500));

      await failingGet('$testBaseUrl/api/v1/ingest');
      await harness.reporter.flush();

      expect(harness.transport.sent, isEmpty);
    });

    test('reports 5xx delivered as a response when validateStatus allows it',
        () async {
      appBackend.answerNext(const FakeHttpAnswer.status(500));

      final response = await appDio.get<String>(
        '/api/report',
        options: Options(validateStatus: (_) => true),
      );
      await harness.reporter.flush();

      expect(response.statusCode, 500);
      expect(harness.transport.sent.single.error['code'], 'HTTP_500');
    });

    test('successful responses pass through and become breadcrumbs', () async {
      appBackend.answerNext(const FakeHttpAnswer.status(200, body: 'ok'));
      appBackend.answerNext(const FakeHttpAnswer.status(502));

      final response = await appDio.get<String>('/api/users/42/profile');
      await failingGet('/api/sync');
      await harness.reporter.flush();

      expect(response.data, 'ok');
      final context = harness.transport.sent.single.payload['context']!
          as Map<String, Object?>;
      final breadcrumbs = (context['breadcrumbs']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(breadcrumbs.map((breadcrumb) => breadcrumb['message']), [
        'GET /api/users/:id/profile 200',
        'GET /api/sync 502',
      ]);
      expect(
        breadcrumbs.every((breadcrumb) => breadcrumb['category'] == 'http'),
        isTrue,
      );
    });

    test('a disabled reporter leaves requests untouched', () async {
      final disabled = ReporterHarness();
      await disabled.start(testConfig(enabled: false));
      final dio = Dio()
        ..httpClientAdapter = appBackend
        ..interceptors.add(ReportingInterceptor(reporter: disabled.reporter));
      appBackend.answerNext(const FakeHttpAnswer.status(500));

      final response = await dio.get<String>(
        'https://api.example.test/api/x',
        options: Options(validateStatus: (_) => true),
      );

      expect(response.statusCode, 500);
      expect(disabled.transport.sent, isEmpty);
    });
  });

  group('pathTemplateOf', () {
    final cases = {
      'https://api.test/api/vault/8812?x=1': '/api/vault/:id',
      'https://api.test/api/items/3fa85f64-5717-4562-b3fc-2c963f66afa6':
          '/api/items/:id',
      'https://api.test/api/blobs/deadbeef01': '/api/blobs/:id',
      'https://api.test/api/users/jane@example.com/settings':
          '/api/users/:id/settings',
      'https://api.test/api/share/AbC123dEf456GhI789jKl0': '/api/share/:id',
      'https://api.test/api/v1/health': '/api/v1/health',
      'https://api.test/api/feedback': '/api/feedback',
      'https://api.test': '/',
    };

    cases.forEach((url, template) {
      test(url, () => expect(pathTemplateOf(Uri.parse(url)), template));
    });
  });
}
