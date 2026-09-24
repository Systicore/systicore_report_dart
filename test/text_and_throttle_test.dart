import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:systicore_report/src/capture/captured_error.dart';
import 'package:systicore_report/src/support/utf8_truncation.dart';
import 'package:systicore_report/src/throttle/duplicate_filter.dart';
import 'package:systicore_report/src/throttle/rate_limiter.dart';

import 'support/fakes.dart';

CapturedError capturedError(String message, {String action = 'sync'}) =>
    CapturedError(
      capturedAt: DateTime.utc(2026),
      type: 'StateError',
      message: message,
      action: action,
    );

void main() {
  group('DuplicateFilter', () {
    test('suppresses a remembered error within 60 seconds', () {
      final clock = FakeClock();
      final filter = DuplicateFilter(clock: clock.call);

      expect(filter.isDuplicate(capturedError('item 8812 failed')), isFalse);
      filter.remember(capturedError('item 8812 failed'));
      clock.advance(const Duration(seconds: 59));
      expect(filter.isDuplicate(capturedError('item 9913 failed')), isTrue);
      clock.advance(const Duration(seconds: 1));
      expect(filter.isDuplicate(capturedError('item 8812 failed')), isFalse);
    });

    test('checking alone does not record the error', () {
      final filter = DuplicateFilter(clock: FakeClock().call);

      expect(filter.isDuplicate(capturedError('failed')), isFalse);
      expect(filter.isDuplicate(capturedError('failed')), isFalse);
    });

    test('different actions are different errors', () {
      final filter = DuplicateFilter(clock: FakeClock().call)
        ..remember(capturedError('failed', action: 'a'));

      expect(filter.isDuplicate(capturedError('failed', action: 'a')), isTrue);
      expect(filter.isDuplicate(capturedError('failed', action: 'b')), isFalse);
    });
  });

  group('RateLimiter', () {
    test('allows 30 per minute, then recovers as the window slides', () {
      final clock = FakeClock();
      final limiter = RateLimiter(clock: clock.call);

      for (var attempt = 0; attempt < 30; attempt++) {
        expect(limiter.tryAcquire(), isTrue);
        clock.advance(const Duration(seconds: 1));
      }
      expect(limiter.tryAcquire(), isFalse);

      clock.advance(const Duration(seconds: 30));
      expect(limiter.tryAcquire(), isTrue);
    });
  });

  group('truncateUtf8', () {
    test('keeps short text untouched', () {
      expect(truncateUtf8('héllo', 100), 'héllo');
    });

    test('never splits a multi-byte character', () {
      // Byte sizes: a = 1, é = 2, € = 3, 😀 = 4 (a surrogate pair in Dart).
      expect(truncateUtf8('aé€😀', 5), 'aé');
      expect(truncateUtf8('aé€😀', 9), 'aé€');
      expect(truncateUtf8('aé€😀', 10), 'aé€😀');
      expect(
        utf8.encode(truncateUtf8('€' * 100, 50)).length,
        lessThanOrEqualTo(50),
      );
    });

    test('cuts at the byte limit', () {
      expect(truncateUtf8('a' * 50, 10), 'a' * 10);
    });

    test('blank optional text becomes null', () {
      expect(truncateOptionalUtf8('  ', 10), isNull);
      expect(truncateOptionalUtf8(null, 10), isNull);
    });
  });
}
