import 'dart:async';

import 'package:dio/dio.dart';

/// Retries idempotent (GET) requests which failed because of a connection
/// level error.
///
/// Chinese networks frequently reset TLS handshakes (or drop connections) for
/// a while, and a single retry with a short backoff usually succeeds. Only GET
/// requests are retried so that no side effect is executed twice.
class RetryInterceptor extends Interceptor {
  RetryInterceptor(
    this.dio, {
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 400),
  });

  final Dio dio;
  final int maxAttempts;
  final Duration baseDelay;

  static const String _attemptKey = "retryAttempt";

  bool _shouldRetry(DioException err) {
    if (err.requestOptions.method.toUpperCase() != "GET") {
      return false;
    }
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      default:
        final text = "${err.error}";
        return text.contains("Connection reset by peer") ||
            text.contains("Connection terminated during handshake") ||
            text.contains("Connection error") ||
            text.contains("Handshake") ||
            text.contains("timed out");
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final attempt = (err.requestOptions.extra[_attemptKey] as int?) ?? 0;
    if (attempt + 1 >= maxAttempts || !_shouldRetry(err)) {
      handler.next(err);
      return;
    }
    await Future.delayed(baseDelay * (1 << attempt));
    final options = err.requestOptions;
    options.extra[_attemptKey] = attempt + 1;
    try {
      handler.resolve(await dio.fetch(options));
    } catch (_) {
      handler.next(err);
    }
  }
}
