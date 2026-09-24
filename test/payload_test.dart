import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/context/platform_name.dart';
import 'package:systicore_report/src/support/uuid.dart';
import 'package:systicore_report/src/systicore_reporter.dart';
import 'package:systicore_report/src/transport/dio_ingest_transport.dart';
import 'package:systicore_report/systicore_report.dart';

import 'support/fakes.dart';
import 'support/reporter_harness.dart';

void main() {
  group('wire format of POST /api/v1/ingest', () {
    late FakeHttpAdapter adapter;
    late SysticoreReporter reporter;
    String? signedInUserId;

    setUp(() {
      adapter = FakeHttpAdapter(const FakeHttpAnswer.status(202));
      signedInUserId = '42';
      reporter = SysticoreReporter.withDependencies(
        ReporterDependencies(
          storage: CountingStorage(),
          deviceContextLoader: FixedDeviceContextLoader(),
          transportFactory: (baseUri, ingestKey) => DioIngestTransport(
            baseUri: baseUri,
            ingestKey: ingestKey,
            dio: Dio()..httpClientAdapter = adapter,
          ),
        ),
      );
    });

    tearDown(() => reporter.dispose());

    Future<void> startReporter() => reporter.init(
          testConfig(
            baseUrl: '$testBaseUrl/',
            release: const ReleaseInfo(
              commit: 'abc1234',
              buildTime: '2026-09-24T10:00:00Z',
            ),
            accessTokenProvider: () async => 'access-token-1',
            userIdProvider: () => signedInUserId,
          ),
        );

    test('captureException sends the contract body and headers', () async {
      await startReporter();
      reporter
        ..setRoute('/vault/:id')
        ..addBreadcrumb('opened vault', category: BreadcrumbCategory.nav);

      reporter.captureException(
        StateError('Vault sync failed for item 8812'),
        StackTrace.current,
        action: 'VaultSync',
        tags: {'feature': 'vault'},
      );
      await reporter.flush();

      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.options.method, 'POST');
      expect(
        request.options.uri.toString(),
        'https://reports.example.test/api/v1/ingest',
      );
      expect(request.options.headers['X-Systicore-Key'], testIngestKey);
      expect(request.options.headers['Authorization'], 'Bearer access-token-1');
      expect(request.options.contentType, startsWith('application/json'));

      final body = request.json;
      expect(body.keys.toSet(), {
        'error',
        'release',
        'environment',
        'platform',
        'device',
        'user',
        'context',
      });

      final error = body['error']! as Map<String, Object?>;
      expect(error.keys.toSet(),
          {'type', 'message', 'trace', 'action', 'severity'});
      expect(error['type'], 'StateError');
      expect(error['message'], 'Bad state: Vault sync failed for item 8812');
      expect(error['trace'], contains('payload_test.dart'));
      expect(error['action'], 'VaultSync');
      expect(error['severity'], 'error');

      expect(body['release'], {
        'version': '1.4.2+17',
        'commit': 'abc1234',
        'buildTime': '2026-09-24T10:00:00Z',
      });
      expect(body['environment'], 'production');
      expect(body['platform'], currentPlatformName());

      final device = body['device']! as Map<String, Object?>;
      expect(device.keys.toSet(), {
        'brand',
        'model',
        'osVersion',
        'apiLevel',
        'appVersion',
        'installId',
      });
      expect(device['appVersion'], '1.4.2+17');
      expect(device['apiLevel'], 36);
      expect(isUuidV4(device['installId']! as String), isTrue);

      expect(body['user'], {'id': '42'});

      final context = body['context']! as Map<String, Object?>;
      expect(context.keys.toSet(), {'route', 'tags', 'breadcrumbs'});
      expect(context['route'], '/vault/:id');
      expect(context['tags'], {'feature': 'vault'});
      final breadcrumbs = context['breadcrumbs']! as List<Object?>;
      final breadcrumb = breadcrumbs.single! as Map<String, Object?>;
      expect(breadcrumb.keys.toSet(), {'ts', 'category', 'message'});
      expect(breadcrumb['category'], 'nav');
      expect(breadcrumb['message'], 'opened vault');
      expect(
        DateTime.parse(breadcrumb['ts']! as String).isUtc,
        isTrue,
      );
    });

    test('report() keeps the ErrorReporter call shape', () async {
      await startReporter();

      reporter.report(
        code: 'VAULT_SYNC_FAILED',
        message: 'getVault returned 503',
        trace: 'trace text',
        action: 'GET /api/vault/:id',
      );
      await reporter.flush();

      final error =
          adapter.requests.single.json['error']! as Map<String, Object?>;
      expect(error, {
        'code': 'VAULT_SYNC_FAILED',
        'message': 'getVault returned 503',
        'trace': 'trace text',
        'action': 'GET /api/vault/:id',
        'severity': 'error',
      });
    });

    test('an explicit release version wins over the package version', () async {
      await reporter.init(
        testConfig(release: const ReleaseInfo(version: '2.0.0+99')),
      );

      reporter.report(code: 'X', message: 'm', action: 'a');
      await reporter.flush();

      final release =
          adapter.requests.single.json['release']! as Map<String, Object?>;
      expect(release, {'version': '2.0.0+99'});
    });

    test('message and trace are cut to the byte caps on character boundaries',
        () async {
      await startReporter();

      reporter.report(
        code: 'LONG',
        message: 'é' * 10000,
        trace: 'x' * 40000,
        action: 'a' * 500,
      );
      await reporter.flush();

      final error =
          adapter.requests.single.json['error']! as Map<String, Object?>;
      final message = error['message']! as String;
      expect(utf8.encode(message).length, lessThanOrEqualTo(8 * 1024));
      expect(message, 'é' * 4096);
      expect((error['trace']! as String).length, 16 * 1024);
      expect((error['action']! as String).length, 200);
    });

    test('no Bearer token once another user is signed in', () async {
      await startReporter();
      reporter.report(code: 'X', message: 'captured for 42', action: 'a');
      signedInUserId = '77';

      await reporter.flush();

      final request = adapter.requests.single;
      expect(request.options.headers.containsKey('Authorization'), isFalse);
      expect(request.json['user'], {'id': '42'});
    });

    test('no user and no Bearer token while signed out', () async {
      signedInUserId = null;
      await startReporter();

      reporter.report(code: 'X', message: 'anonymous', action: 'a');
      await reporter.flush();

      final request = adapter.requests.single;
      expect(request.options.headers.containsKey('Authorization'), isFalse);
      expect(request.json.containsKey('user'), isFalse);
    });

    test('setUser overrides the provider and carries the issuer', () async {
      await startReporter();
      reporter.setUser('7', issuer: 'https://auth.systicore.hu');

      reporter.report(code: 'X', message: 'm', action: 'a');
      await reporter.flush();

      expect(adapter.requests.single.json['user'], {
        'id': '7',
        'issuer': 'https://auth.systicore.hu',
      });
    });
  });
}
