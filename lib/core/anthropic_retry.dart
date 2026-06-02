import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Classification of an Anthropic Messages API outcome into how the caller
/// should react. Kept network-free + pure so the routing logic is unit-testable
/// without ever touching a socket.
enum AnthropicErrorClass {
  /// 2xx — the request succeeded; no error handling needed.
  ok,

  /// 401 / 403 or a missing/blank API key. NOT retryable. The UI should route
  /// the user to the settings / missing-key path, not surface a generic deny.
  auth,

  /// 400 / 404 (and other non-retryable 4xx that are not auth). A client bug —
  /// surface immediately rather than retrying.
  clientError,

  /// 429 / 500 / 529 or a transport failure (SocketException, TimeoutException,
  /// ClientException). Retryable; after retries are exhausted the UI should show
  /// an OFFLINE-style, retryable result rather than a cruel deny.
  retryable,
}

/// Pure status-code retry predicate. Retry on 429 (rate limit), 500 (server
/// error), and 529 (overloaded). Everything else (incl. 400/401/403/404 and any
/// 2xx) is NOT retried at the status level — auth/client errors must surface
/// immediately. Extracted so it is unit-testable with no network.
bool isRetryableStatus(int code) =>
    code == 429 || code == 500 || code == 529;

/// Whether a thrown transport error is the kind we retry: a dropped/refused
/// socket, a timeout, or an http ClientException (connection reset, etc.).
bool isRetryableTransportError(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is http.ClientException;

/// Classify a request outcome from its HTTP [status] (null when the request
/// never completed) and/or the [error] thrown while attempting it. Pure: no
/// network, no clock — deterministic and unit-testable.
///
/// Precedence: an explicit status wins (we know what the server said); only
/// when there is no status do we look at the thrown error.
AnthropicErrorClass classifyAnthropic(int? status, Object? error) {
  if (status != null) {
    if (status >= 200 && status < 300) return AnthropicErrorClass.ok;
    if (status == 401 || status == 403) return AnthropicErrorClass.auth;
    if (isRetryableStatus(status)) return AnthropicErrorClass.retryable;
    // 400 / 404 and any other non-retryable, non-auth status: client error.
    return AnthropicErrorClass.clientError;
  }
  if (error != null && isRetryableTransportError(error)) {
    return AnthropicErrorClass.retryable;
  }
  // Unknown error with no status (e.g. a bad-JSON decode): treat as retryable
  // so we degrade to the offline path rather than a hard client error.
  return AnthropicErrorClass.retryable;
}

/// Backoff configuration for the Anthropic retry loop. Defaults match the
/// hardening spec: base 0.5s, max 8s, at most 3 retries (4 total attempts).
class BackoffConfig {
  const BackoffConfig({
    this.base = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 8),
    this.maxRetries = 3,
  });

  final Duration base;
  final Duration maxDelay;
  final int maxRetries;
}

/// Compute the delay before retry [attempt] (0-indexed: attempt 0 is the wait
/// after the FIRST failure). Exponential with jitter:
///   delay = min(maxDelay, base * 2^attempt) + random(0..base)
///
/// When [retryAfter] is supplied (a 429 `Retry-After` header, in seconds) it is
/// honored verbatim instead of the computed value — but still capped at
/// [BackoffConfig.maxDelay] so a hostile/huge header can't park the UI forever.
///
/// [random] is injectable so tests can pin jitter (or pass a zero-jitter rng to
/// assert the exact exponential bound). Pure: no I/O.
Duration backoffDelay(
  int attempt, {
  Duration? retryAfter,
  BackoffConfig config = const BackoffConfig(),
  Random? random,
}) {
  if (retryAfter != null) {
    return retryAfter > config.maxDelay ? config.maxDelay : retryAfter;
  }
  // base * 2^attempt, computed in microseconds, capped at maxDelay BEFORE jitter
  // so the jitter is always additive on top of a bounded exponential term.
  final exp = config.base.inMicroseconds * (1 << attempt);
  final capped =
      exp > config.maxDelay.inMicroseconds ? config.maxDelay.inMicroseconds : exp;
  final rng = random ?? Random();
  // Jitter in [0, base): full-jitter style spread to avoid thundering herd.
  final jitter = (rng.nextDouble() * config.base.inMicroseconds).round();
  return Duration(microseconds: capped + jitter);
}

/// Parse a `Retry-After` response header value (seconds form only — the API
/// sends integer seconds on 429) into a [Duration]. Returns null when absent or
/// unparseable. Pure: tolerates a missing header map.
Duration? parseRetryAfter(Map<String, String>? headers) {
  if (headers == null) return null;
  final raw = headers['retry-after'] ?? headers['Retry-After'];
  if (raw == null) return null;
  final seconds = int.tryParse(raw.trim());
  if (seconds == null || seconds < 0) return null;
  return Duration(seconds: seconds);
}
