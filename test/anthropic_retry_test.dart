import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sleep_time/core/anthropic_retry.dart';

void main() {
  group('isRetryableStatus', () {
    test('retries 429, 500, 529', () {
      expect(isRetryableStatus(429), isTrue);
      expect(isRetryableStatus(500), isTrue);
      expect(isRetryableStatus(529), isTrue);
    });

    test('does NOT retry client errors or success', () {
      for (final code in [200, 201, 400, 401, 403, 404, 413, 502, 503]) {
        // Note: 502/503 are not in the spec's retry set (only 429/500/529).
        expect(isRetryableStatus(code), isFalse, reason: 'code $code');
      }
    });
  });

  group('isRetryableTransportError', () {
    test('retries socket / timeout / client exceptions', () {
      expect(
          isRetryableTransportError(const SocketException('down')), isTrue);
      expect(isRetryableTransportError(TimeoutException('slow')), isTrue);
      expect(
          isRetryableTransportError(http.ClientException('reset')), isTrue);
    });

    test('does not retry an arbitrary error', () {
      expect(isRetryableTransportError(StateError('bug')), isFalse);
      expect(isRetryableTransportError(const FormatException('json')), isFalse);
    });
  });

  group('classifyAnthropic', () {
    test('2xx -> ok', () {
      expect(classifyAnthropic(200, null), AnthropicErrorClass.ok);
      expect(classifyAnthropic(299, null), AnthropicErrorClass.ok);
    });

    test('401 / 403 -> auth (never retried)', () {
      expect(classifyAnthropic(401, null), AnthropicErrorClass.auth);
      expect(classifyAnthropic(403, null), AnthropicErrorClass.auth);
    });

    test('400 / 404 -> clientError (surfaced immediately)', () {
      expect(classifyAnthropic(400, null), AnthropicErrorClass.clientError);
      expect(classifyAnthropic(404, null), AnthropicErrorClass.clientError);
    });

    test('429 / 500 / 529 -> retryable', () {
      expect(classifyAnthropic(429, null), AnthropicErrorClass.retryable);
      expect(classifyAnthropic(500, null), AnthropicErrorClass.retryable);
      expect(classifyAnthropic(529, null), AnthropicErrorClass.retryable);
    });

    test('status wins over error when both present', () {
      // A 401 with a socket error still classifies as auth (we know the server
      // answered).
      expect(
        classifyAnthropic(401, const SocketException('x')),
        AnthropicErrorClass.auth,
      );
    });

    test('transport error with no status -> retryable', () {
      expect(
        classifyAnthropic(null, const SocketException('down')),
        AnthropicErrorClass.retryable,
      );
      expect(
        classifyAnthropic(null, TimeoutException('slow')),
        AnthropicErrorClass.retryable,
      );
    });

    test('unknown error with no status -> retryable (degrade to offline)', () {
      expect(
        classifyAnthropic(null, const FormatException('bad json')),
        AnthropicErrorClass.retryable,
      );
    });
  });

  group('backoffDelay', () {
    // Zero-jitter rng so the exponential term is deterministic and testable.
    Random zeroJitter() => _FixedRandom(0.0);

    test('exponential growth without jitter: base * 2^attempt', () {
      const config = BackoffConfig(
        base: Duration(milliseconds: 500),
        maxDelay: Duration(seconds: 8),
      );
      expect(backoffDelay(0, config: config, random: zeroJitter()),
          const Duration(milliseconds: 500)); // 500 * 1
      expect(backoffDelay(1, config: config, random: zeroJitter()),
          const Duration(seconds: 1)); // 500 * 2
      expect(backoffDelay(2, config: config, random: zeroJitter()),
          const Duration(seconds: 2)); // 500 * 4
      expect(backoffDelay(3, config: config, random: zeroJitter()),
          const Duration(seconds: 4)); // 500 * 8
    });

    test('caps the exponential term at maxDelay (before jitter)', () {
      const config = BackoffConfig(
        base: Duration(milliseconds: 500),
        maxDelay: Duration(seconds: 8),
      );
      // attempt 5 => 500 * 32 = 16s, capped to 8s.
      expect(backoffDelay(5, config: config, random: zeroJitter()),
          const Duration(seconds: 8));
    });

    test('jitter stays within [0, base) on top of the exponential term', () {
      const config = BackoffConfig(base: Duration(milliseconds: 500));
      // Max jitter rng (just under 1.0) => exponential + ~base.
      final d = backoffDelay(0, config: config, random: _FixedRandom(0.999));
      // Lower bound is the exponential term (500ms), upper bound < 500+500.
      expect(d.inMicroseconds, greaterThanOrEqualTo(500000));
      expect(d.inMicroseconds, lessThan(1000000));
    });

    test('honors Retry-After verbatim, capped at maxDelay', () {
      const config = BackoffConfig(maxDelay: Duration(seconds: 8));
      expect(
        backoffDelay(0,
            retryAfter: const Duration(seconds: 3), config: config),
        const Duration(seconds: 3),
      );
      // A huge Retry-After is clamped to maxDelay so it can't park the UI.
      expect(
        backoffDelay(0,
            retryAfter: const Duration(seconds: 600), config: config),
        const Duration(seconds: 8),
      );
    });
  });

  group('parseRetryAfter', () {
    test('parses integer seconds (lower- and Title-case headers)', () {
      expect(parseRetryAfter({'retry-after': '5'}), const Duration(seconds: 5));
      expect(parseRetryAfter({'Retry-After': '12'}),
          const Duration(seconds: 12));
    });

    test('returns null for absent / unparseable / negative', () {
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter({}), isNull);
      expect(parseRetryAfter({'retry-after': 'soon'}), isNull);
      expect(parseRetryAfter({'retry-after': '-3'}), isNull);
    });
  });
}

/// Deterministic Random whose nextDouble() always returns a fixed value, so the
/// jitter term in backoffDelay is reproducible in tests.
class _FixedRandom implements Random {
  _FixedRandom(this._value);
  final double _value;
  @override
  double nextDouble() => _value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}
