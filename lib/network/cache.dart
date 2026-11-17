import 'dart:typed_data';

import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';

typedef _CacheKey = (Uri, String?, String?, ResponseType);

class NetworkCache {
  final Map<String, dynamic> requestHeaders;

  final Map<String, List<String>> responseHeaders;

  final Object? data;

  final DateTime time;

  final int size;

  const NetworkCache({
    required this.requestHeaders,
    required this.responseHeaders,
    required this.data,
    required this.time,
    required this.size,
  });
}

class NetworkCacheManager extends Interceptor {
  NetworkCacheManager([this._dio]);

  final Dio? _dio;
  static final _cache = <_CacheKey, NetworkCache>{};
  static int _size = 0;
  static const _cacheDirectiveKey = 'venera.cacheDirective';

  static _CacheKey _key(RequestOptions options) {
    return (
      options.uri,
      options.extra[proxySourceKey] as String?,
      options.extra[resolvedProxyKey] as String?,
      options.responseType,
    );
  }

  static const _maxCacheSize = 10 * 1024 * 1024;

  void _setCache(_CacheKey key, NetworkCache cache) {
    _removeCache(key);
    while (_size + cache.size > _maxCacheSize) {
      _removeCache(_cache.keys.first);
    }
    _cache[key] = cache;
    _size += cache.size;
  }

  void _removeCache(_CacheKey key) {
    _size -= _cache.remove(key)?.size ?? 0;
  }

  void clear() {
    _cache.clear();
    _size = 0;
  }

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    if (options.method != "GET") {
      return handler.next(options);
    }
    // RetryInterceptor can replay these options after the internal header has
    // been removed, so keep the directive for the lifetime of the request.
    final cacheTime = options.extra.putIfAbsent(
      _cacheDirectiveKey,
      () => options.headers.remove('cache-time'),
    );
    if (!options.extra.containsKey(resolvedProxyKey)) {
      options.extra[resolvedProxyKey] = await getProxy(
        uri: options.uri,
        sourceKey: options.extra[proxySourceKey] as String?,
      );
    }
    final key = _key(options);
    if (cacheTime == 'no') {
      _removeCache(key);
      return handler.next(options);
    }
    final cache = _cache[key];
    if (cache == null ||
        !compareHeaders(options.headers, cache.requestHeaders)) {
      return handler.next(options);
    }

    final age = DateTime.now().difference(cache.time);
    var canReuse =
        age < const Duration(seconds: 5) ||
        (cacheTime == 'long' && age < const Duration(hours: 6));
    if (!canReuse && age < const Duration(hours: 2)) {
      final head = options.copyWith(
        method: 'HEAD',
        responseType: ResponseType.plain,
      )..data = null;
      try {
        final response = await (_dio ?? AppDio()).fetch(head);
        canReuse =
            response.statusCode == 200 &&
            compareHeaders(cache.responseHeaders, response.headers.map);
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) {
          return handler.reject(error.copyWith(requestOptions: options));
        }
        // HEAD is optional. Some servers reject it even when GET works.
      }
    }
    if (canReuse && identical(_cache[key], cache)) {
      return handler.resolve(Response(
        requestOptions: options,
        data: cache.data,
        headers: Headers.fromMap(cache.responseHeaders)
          ..set('venera-cache', 'true'),
        statusCode: 200,
      ));
    }
    if (identical(_cache[key], cache)) {
      _removeCache(key);
    }
    handler.next(options);
  }

  static bool compareHeaders(Map<String, dynamic> a, Map<String, dynamic> b) {
    a = Map.from(a);
    b = Map.from(b);
    const shouldIgnore = [
      'cache-time',
      'prevent-parallel',
      'date',
      'x-varnish',
      'cf-ray',
      'connection',
      'vary',
      'content-encoding',
      'report-to',
      'server-timing',
      'token',
      'set-cookie',
      'cf-cache-status',
      'cf-request-id',
      'cf-ray',
      'authorization',
    ];
    for (var key in shouldIgnore) {
      a.remove(key);
      b.remove(key);
    }
    if (a.length != b.length) {
      return false;
    }
    for (var key in a.keys) {
      if (a[key] is List && b[key] is List) {
        if (a[key].length != b[key].length) {
          return false;
        }
        for (var i = 0; i < a[key].length; i++) {
          if (a[key][i] != b[key][i]) {
            return false;
          }
        }
      } else if (a[key] != b[key]) {
        return false;
      }
    }
    return true;
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    if (response.requestOptions.method != "GET" ||
        response.requestOptions.extra[_cacheDirectiveKey] == 'no') {
      return handler.next(response);
    }
    if (response.statusCode != null && response.statusCode! >= 400) {
      return handler.next(response);
    }
    var size = _calculateSize(response.data);
    if (size != null && size < 1024 * 1024 && size > 0) {
      var cache = NetworkCache(
        requestHeaders: response.requestOptions.headers,
        responseHeaders: Map.from(response.headers.map),
        data: response.data,
        time: DateTime.now(),
        size: size,
      );
      _setCache(_key(response.requestOptions), cache);
    }
    handler.next(response);
  }

  static int? _calculateSize(Object? data) {
    if (data == null) {
      return 0;
    }
    if (data is List<int>) {
      return data.length;
    }
    if (data is Uint8List) {
      return data.length;
    }
    if (data is String) {
      if (data.trim().isEmpty) {
        return 0;
      }
      if (data.length < 512 && data.contains("IP address")) {
        return 0;
      }
      return data.length * 4;
    }
    if (data is Map) {
      return data.toString().length * 4;
    }
    return null;
  }
}
