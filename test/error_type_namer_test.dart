import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/capture/error_type_namer.dart';

import 'support/reporter_harness.dart';

/// Stands in for the `Type` of a class that dart2js minified.
class _MinifiedType implements Type {
  @override
  String toString() => 'minified:Ab';
}

class _MinifiedError extends Error {
  @override
  Type get runtimeType => _MinifiedType();
}

void main() {
  group('ErrorTypeNamer', () {
    test('names the class in a build with readable class names', () {
      expect(ErrorTypeNamer().nameOf(StateError('x')), 'StateError');
    });

    test('leaves the type out where class names were renamed', () {
      final namer = ErrorTypeNamer(runtimeNamesAreReadable: false);

      expect(namer.nameOf(StateError('x')), isNull);
    });

    test('leaves a minified name out', () {
      expect(ErrorTypeNamer().nameOf(_MinifiedError()), isNull);
    });
  });

  test('a renamed build reports without type, grouped by code and message',
      () async {
    final harness = ReporterHarness(
      errorTypeNamer: ErrorTypeNamer(runtimeNamesAreReadable: false),
    );
    await harness.start();

    harness.reporter.captureException(
      StateError('vault locked'),
      null,
      code: 'VAULT_LOCKED',
      action: 'VaultSync',
    );
    await harness.reporter.flush();

    final error = harness.transport.sent.single.error;
    expect(error.containsKey('type'), isFalse);
    expect(error['code'], 'VAULT_LOCKED');
    expect(error['message'], 'Bad state: vault locked');
  });
}
