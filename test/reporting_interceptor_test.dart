import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/dio/request_path_template.dart';
import 'package:systicore_report/systicore_report.dart';

import 'support/fakes.dart';
import 'support/reporter_harness.dart';

/// An app's token refresh: on a 401 it retries the request once on the
/// same Dio and passes the retry's outcome on through the outer chain.
class _RetryOnUnauthorized extends Interceptor {
  _RetryOnUnauthorized(this.dio, {this.copyRetryFailure = false});

  final Dio dio;

  /// Passes on a copy of the retry's DioException instead of the original.
  final bool copyRetryFailure;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.response?.statusCode != 401) return handler.next(err);
    try {
      final response = await dio.fetch<dynamic>(err.requestOptions);
      handler.resolve(response);
    } on DioException catch (retryFailure) {
      handler.next(
        copyRetryFailure
            ? retryFailure.copyWith(message: 'retry failed')
            : retryFailure,
      );
    }
  }
}

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

    test('reports network failures that dio wraps as unknown', () async {
      final networkFailures = <String, Object>{
        '/api/reset': const SocketException('Connection reset by peer'),
        '/api/headers': const HttpException(
          'Connection closed before full header was received',
        ),
        '/api/tls': const HandshakeException('Handshake error in client'),
      };
      final exceptions = <DioException>[];
      for (final entry in networkFailures.entries) {
        appBackend.answerNext(FakeHttpAnswer.thrown(entry.value));
        exceptions.add(await failingGet(entry.key));
      }
      await harness.reporter.flush();

      for (final exception in exceptions) {
        expect(exception.type, DioExceptionType.unknown);
        expect(harness.reporter.isReported(exception), isTrue);
      }
      expect(
        exceptions.map((exception) => exception.error),
        networkFailures.values,
      );
      // The same code and message as a connectionError of the endpoint.
      expect(sentErrors().map((error) => error['message']), [
        'Connection error on GET /api/reset',
        'Connection error on GET /api/headers',
        'Connection error on GET /api/tls',
      ]);
      for (final error in sentErrors()) {
        expect(error['code'], 'HTTP_CONNECTION_ERROR');
        expect(error['severity'], 'warning');
      }
    });

    test('ignores unknown failures without a network cause', () async {
      appBackend
        ..answerNext(
          const FakeHttpAnswer.thrown(FormatException('Unexpected character')),
        )
        ..answerNext(
          const FakeHttpAnswer.thrown(FileSystemException('Disk full')),
        );

      final decodingFailure = await failingGet('/api/decode');
      final fileFailure = await failingGet('/api/download');
      await harness.reporter.flush();

      expect(decodingFailure.type, DioExceptionType.unknown);
      expect(fileFailure.type, DioExceptionType.unknown);
      expect(harness.transport.sent, isEmpty);
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

  group('ReportingInterceptor with a retry on the same Dio', () {
    late ReporterHarness harness;
    late FakeHttpAdapter appBackend;

    setUp(() async {
      harness = ReporterHarness();
      await harness.start();
      appBackend = FakeHttpAdapter();
    });

    tearDown(() => harness.reporter.dispose());

    Dio retryingDio({bool copyRetryFailure = false}) {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = appBackend;
      dio.interceptors
        ..add(_RetryOnUnauthorized(dio, copyRetryFailure: copyRetryFailure))
        ..add(ReportingInterceptor(reporter: harness.reporter));
      return dio;
    }

    Future<DioException> failingGetOn(Dio dio, String path) async {
      try {
        await dio.get<String>(path);
      } on DioException catch (exception) {
        return exception;
      }
      fail('expected $path to fail');
    }

    // A later report carries every breadcrumb recorded so far.
    Future<List<Object?>> breadcrumbMessages() async {
      harness.reporter.report(code: 'PROBE', message: 'probe', action: 'test');
      await harness.reporter.flush();
      final context = harness.transport.sent.last.payload['context']!
          as Map<String, Object?>;
      return [
        for (final breadcrumb in context['breadcrumbs']! as List<Object?>)
          (breadcrumb! as Map<String, Object?>)['message'],
      ];
    }

    for (final copyRetryFailure in [false, true]) {
      final passedOn = copyRetryFailure ? 'a copy of it' : 'it';
      test('a failed retry is reported once when the app passes on $passedOn',
          () async {
        final dio = retryingDio(copyRetryFailure: copyRetryFailure);
        appBackend
          ..answerNext(const FakeHttpAnswer.status(401))
          ..answerNext(const FakeHttpAnswer.status(503));

        final exception = await failingGetOn(dio, '/api/sync');
        await harness.reporter.flush();

        expect(appBackend.requests, hasLength(2));
        if (copyRetryFailure) expect(exception.message, 'retry failed');
        // What escapes to the app is marked, so the global handlers skip it.
        expect(harness.reporter.isReported(exception), isTrue);
        expect(harness.transport.sent.single.error['code'], 'HTTP_503');
        expect(await breadcrumbMessages(), ['GET /api/sync 503']);
      });
    }

    test('a successful retry is recorded once', () async {
      final dio = retryingDio();
      appBackend
        ..answerNext(const FakeHttpAnswer.status(401))
        ..answerNext(const FakeHttpAnswer.status(200, body: 'ok'));

      final response = await dio.get<String>('/api/sync');

      expect(response.data, 'ok');
      expect(await breadcrumbMessages(), ['GET /api/sync 200']);
      expect(harness.transport.sent.single.error['code'], 'PROBE');
    });

    test('a retry through a second Dio is reported once', () async {
      final retryDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = appBackend
        ..interceptors.add(ReportingInterceptor(reporter: harness.reporter));
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = appBackend;
      dio.interceptors
        ..add(_RetryOnUnauthorized(retryDio))
        ..add(ReportingInterceptor(reporter: harness.reporter));
      appBackend
        ..answerNext(const FakeHttpAnswer.status(401))
        ..answerNext(const FakeHttpAnswer.status(502));

      await expectLater(
        dio.get<String>('/api/sync'),
        throwsA(isA<DioException>()),
      );
      await harness.reporter.flush();

      expect(harness.transport.sent.single.error['code'], 'HTTP_502');
      expect(await breadcrumbMessages(), ['GET /api/sync 502']);
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
