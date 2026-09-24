import 'dart:convert';

import 'package:dio/dio.dart';

import 'ingest_outcome.dart';
import 'ingest_response_classifier.dart';
import 'ingest_transport.dart';

/// [IngestTransport] on a private Dio instance.
///
/// It must not share the app's Dio: the app's interceptors would attach
/// cookies or tokens meant for the app's own API, retry on 401, and — with
/// a reporting interceptor installed — report the reporter's own failures.
class DioIngestTransport implements IngestTransport {
  DioIngestTransport({
    required Uri baseUri,
    required String ingestKey,
    Dio? dio,
  })  : _ingestKey = ingestKey,
        _dio = dio ?? Dio(_defaultOptions()) {
    _dio.options.baseUrl = baseUri.toString();
  }

  static const String ingestPath = '/api/v1/ingest';
  static const String keyHeader = 'X-Systicore-Key';
  static const Duration _timeout = Duration(seconds: 10);

  final String _ingestKey;
  final Dio _dio;

  static BaseOptions _defaultOptions() => BaseOptions(
        connectTimeout: _timeout,
        receiveTimeout: _timeout,
        responseType: ResponseType.plain,
      );

  @override
  Future<IngestOutcome> send(
    Map<String, Object?> payload, {
    String? bearerToken,
  }) async {
    try {
      final response = await _dio.post<String>(
        ingestPath,
        data: jsonEncode(payload),
        options: Options(
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
          headers: {
            keyHeader: _ingestKey,
            if (bearerToken != null && bearerToken.isNotEmpty)
              'Authorization': 'Bearer $bearerToken',
          },
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      return IngestResponseClassifier.classify(
        response.statusCode ?? 0,
        retryAfterHeader: response.headers.value('retry-after'),
      );
    } on DioException catch (exception) {
      return IngestTransientFailure(exception.type.name);
    } catch (error) {
      return IngestTransientFailure(error.runtimeType.toString());
    }
  }

  @override
  void close() => _dio.close(force: true);
}
