import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/proxy.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';
import 'retry.dart';

export 'package:dio/dio.dart';

class MyLogInterceptor implements Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.error("Network",
        "${err.requestOptions.method} ${err.requestOptions.path}\n$err\n${err.response?.data.toString()}");
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
              message: "Invalid Status Code: $statusCode. "
                  "${_getStatusCodeInfo(statusCode)}");
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
            message: "Receive Timeout: "
                "This indicates that the server is too busy to respond");
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
              message: "Connection terminated during handshake: "
                  "This may be caused by the firewall blocking the connection "
                  "or your requests are too frequent.");
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
              message: "Connection reset by peer: "
                  "The error is unrelated to app, please check your network.");
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    var headers = response.headers.map.map((key, value) => MapEntry(
        key.toLowerCase(), value.length == 1 ? value.first : value.toString()));
    headers.remove("cookie");
    String content;
    if (response.data is List<int>) {
      try {
        content = utf8.decode(response.data, allowMalformed: false);
      } catch (e) {
        content = "<Bytes>\nlength:${response.data.length}";
      }
    } else {
      content = response.data.toString();
    }
    Log.addLog(
        (response.statusCode != null && response.statusCode! < 400)
            ? LogLevel.info
            : LogLevel.error,
        "Network",
        "Response ${response.realUri.toString()} ${response.statusCode}\n"
            "headers:\n$headers\n$content");
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    const String headerMask = "********";
    const String dataMask = "****** DATA_PROTECTED ******";
    Log.info(
        "Network",
        "${options.method} ${options.uri}\n"
            "headers:\n${
              options.extra.containsKey("maskHeadersInLog")
                ? options.headers.map((key, value) =>
                  MapEntry(
                    key,
                    options.extra["maskHeadersInLog"].contains(key)
                      ? headerMask
                      : value
                  ))
                : options.headers
            }\n"
            "data:\n${
              options.extra["maskDataInLog"] == true
                ? dataMask
                : options.data
            }"
    );
    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    httpClientAdapter = RHttpAdapter();
    if (App.isInitialized) {
      interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
      interceptors.add(RetryInterceptor(this));
    }
  }

  /// Locks for requests marked with the `prevent-parallel` header.
  ///
  /// Two requests for the same url must not run at the same time; before, this
  /// was implemented by polling the state map every 20ms, which both wasted
  /// timers and released the lock of another request when the failing request
  /// did not own it.
  static final Map<String, Completer<void>> _locks = {};

  static Future<void> _acquire(String key) async {
    while (true) {
      var holder = _locks[key];
      if (holder == null) {
        break;
      }
      await holder.future;
    }
    _locks[key] = Completer<void>();
  }

  static void _release(String key) {
    _locks.remove(key)?.complete();
  }

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    var serial = options?.headers?['prevent-parallel'] == 'true';
    if (serial) {
      await _acquire(path);
      options!.headers!.remove('prevent-parallel');
    }
    try {
      return await super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } finally {
      if (serial) {
        _release(path);
      }
    }
  }
}

class RHttpAdapter implements HttpClientAdapter {
  /// `rhttp.Rhttp.request(settings: ...)` builds a brand new native client for
  /// every request, and a native client owns the connection pool and the TLS
  /// session cache. Doing that per request means a full TCP + TLS handshake for
  /// every single request, which is very expensive on filtered networks where
  /// handshakes are also the first thing to be reset.
  ///
  /// So one client is kept here and shared by every request; it is rebuilt only
  /// when a setting which affects it changes.
  static rhttp.RhttpClient? _client;

  static String? _clientKey;

  static Future<rhttp.RhttpClient>? _pendingClient;

  Future<rhttp.ClientSettings> get settings async {
    return _buildSettings(await getProxy());
  }

  static rhttp.ClientSettings _buildSettings(String? proxy) {
    return rhttp.ClientSettings(
      proxySettings: proxy == null
          ? const rhttp.ProxySettings.noProxy()
          : rhttp.ProxySettings.proxy(proxy),
      redirectSettings: const rhttp.RedirectSettings.limited(5),
      timeoutSettings: const rhttp.TimeoutSettings(
        connectTimeout: Duration(seconds: 15),
        keepAliveTimeout: Duration(seconds: 60),
        keepAlivePing: Duration(seconds: 30),
      ),
      throwOnStatusCode: false,
      dnsSettings: rhttp.DnsSettings.static(overrides: _getOverrides()),
      tlsSettings: rhttp.TlsSettings(
        sni: appdata.settings['sni'] != false,
        verifyCertificates: appdata.settings['ignoreBadCertificate'] != true,
      ),
    );
  }

  /// Everything in [ClientSettings] which cannot change the meaning of an
  /// already established connection is left out, so editing e.g. the timeout
  /// does not throw the connection pool away.
  static String _clientKeyOf(String? proxy) {
    return [
      proxy ?? '',
      appdata.settings['sni'] != false,
      appdata.settings['ignoreBadCertificate'] != true,
      _getOverrides().entries
          .map((e) => "${e.key}=${e.value.join(',')}")
          .join(';'),
    ].join('|');
  }

  static Future<rhttp.RhttpClient> _getClient() async {
    var proxy = await getProxy();
    var key = _clientKeyOf(proxy);
    var client = _client;
    if (client != null && key == _clientKey) {
      return client;
    }
    // Another request may be creating a client for the same settings.
    var pending = _pendingClient;
    if (pending != null) {
      var created = await pending;
      if (key == _clientKey) {
        return created;
      }
    }
    var future = rhttp.RhttpClient.create(settings: _buildSettings(proxy));
    _pendingClient = future;
    try {
      var created = await future;
      var old = _client;
      _client = created;
      _clientKey = key;
      old?.dispose();
      return created;
    } finally {
      if (identical(_pendingClient, future)) {
        _pendingClient = null;
      }
    }
  }

  static Map<String, List<String>> _getOverrides() {
    if (!appdata.settings['enableDnsOverrides'] == true) {
      return {};
    }
    var config = appdata.settings["dnsOverrides"];
    var result = <String, List<String>>{};
    if (config is Map) {
      for (var entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key] = [entry.value];
        }
      }
    }
    return result;
  }

  @override
  void close({bool force = false}) {
    // The client is shared by all the adapters in the app, so it must not be
    // disposed together with a single (short lived) dio instance.
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = "venera/v${App.version}";
    }

    var res = await (await _getClient()).request(
      method: rhttp.HttpMethod(options.method),
      url: options.uri.toString(),
      expectBody: rhttp.HttpExpectBody.stream,
      body: requestStream == null ? null : rhttp.HttpBody.stream(requestStream),
      headers: rhttp.HttpHeaders.rawMap(
        Map.fromEntries(
          options.headers.entries.map(
            (e) => MapEntry(e.key, e.value.toString().trim()),
          ),
        ),
      ),
    );
    if (res is! rhttp.HttpStreamResponse) {
      throw Exception("Invalid response type: ${res.runtimeType}");
    }
    var headers = <String, List<String>>{};
    for (var entry in res.headers) {
      var key = entry.$1.toLowerCase();
      headers[key] ??= [];
      headers[key]!.add(entry.$2);
    }
    return ResponseBody(
      res.body,
      res.statusCode,
      statusMessage: _getStatusMessage(res.statusCode),
      isRedirect: false,
      headers: headers,
    );
  }

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => "OK",
      201 => "Created",
      202 => "Accepted",
      204 => "No Content",
      206 => "Partial Content",
      301 => "Moved Permanently",
      302 => "Found",
      400 => "Invalid Status Code 400: The Request is invalid.",
      401 => "Invalid Status Code 401: The Request is unauthorized.",
      403 =>
        "Invalid Status Code 403: No permission to access the resource. Check your account or network.",
      404 => "Invalid Status Code 404: Not found.",
      429 =>
        "Invalid Status Code 429: Too many requests. Please try again later.",
      _ => "Invalid Status Code $statusCode",
    };
  }
}
