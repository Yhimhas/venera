import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cache.dart';

void main() {
  const url = 'https://example.org/resource';
  late Dio dio;
  late _TestAdapter adapter;

  setUp(() {
    appdata.settings['proxy'] = 'direct';
    NetworkCacheManager().clear();
    adapter = _TestAdapter();
    dio = Dio(BaseOptions(responseType: ResponseType.plain))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(NetworkCacheManager(dio));
    addTearDown(dio.close);
  });

  test('cache-time no bypasses both cache reads and writes', () async {
    expect((await dio.get<String>(url)).data, 'response 1');
    expect((await dio.get<String>(url)).data, 'response 1');
    final refresh = await dio.get<String>(
      url,
      options: Options(headers: {'cache-time': 'no'}),
    );
    expect(refresh.data, 'response 2');
    expect((await dio.get<String>(url)).data, 'response 3');
    expect(adapter.forwardedCacheDirective, isFalse);
  });

  test('plain text and bytes have independent cached responses', () async {
    expect((await dio.get<String>(url)).data, 'response 1');
    final bytes = await dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    expect(utf8.decode(bytes.data!), 'response 2');
    expect((await dio.get<String>(url)).data, 'response 1');
  });

  test('a repeated range request keeps its partial response status', () async {
    final options = Options(headers: {'range': 'bytes=0-9'});
    final first = await dio.get<String>(url, options: options);
    final second = await dio.get<String>(url, options: options);
    expect(first.statusCode, 206);
    expect(second.statusCode, 206);
    expect(second.headers.value('content-range'), 'bytes 0-9/100');
    expect(adapter.methods, ['GET', 'GET']);
  });

  test('HEAD checks reuse valid data and fall through on failure', () async {
    const blockedHeadUrl = '$url?head=blocked&validator=1';
    const validHeadUrl = '$url?head=allowed&validator=1';
    const noValidatorUrl = '$url?head=allowed';
    expect((await dio.get<String>(blockedHeadUrl)).data, 'response 1');
    expect((await dio.get<String>(validHeadUrl)).data, 'response 2');
    expect((await dio.get<String>(noValidatorUrl)).data, 'response 3');
    await Future<void>.delayed(const Duration(milliseconds: 5100));
    final fresh = await dio
        .get<String>(blockedHeadUrl)
        .timeout(const Duration(seconds: 2));
    expect(fresh.data, 'response 4');
    final cached = await dio.get<String>(validHeadUrl);
    expect(cached.data, 'response 2');
    expect(cached.headers.value('venera-cache'), 'true');
    expect((await dio.get<String>(noValidatorUrl)).data, 'response 5');
    expect(adapter.methods, ['GET', 'GET', 'GET', 'HEAD', 'GET', 'HEAD', 'GET']);
  });
}

class _TestAdapter implements HttpClientAdapter {
  int _gets = 0;
  bool forwardedCacheDirective = false;
  final methods = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    methods.add(options.method);
    forwardedCacheDirective |= options.headers.containsKey('cache-time');
    final headers = <String, List<String>>{
      if (options.uri.queryParameters.containsKey('validator'))
        'etag': ['"revision-1"'],
    };
    if (options.method == 'HEAD') {
      final status = options.uri.queryParameters['head'] == 'allowed'
          ? 200
          : 405;
      return ResponseBody.fromString('', status, headers: headers);
    }
    if (options.headers.containsKey('range')) {
      return ResponseBody.fromString('0123456789', 206, headers: {
        'content-range': ['bytes 0-9/100'],
      });
    }
    return ResponseBody.fromString('response ${++_gets}', 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}
