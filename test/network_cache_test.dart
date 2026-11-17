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

  test('HEAD checks reuse valid data and fall through on failure', () async {
    const validHeadUrl = '$url?head=allowed';
    expect((await dio.get<String>(url)).data, 'response 1');
    expect((await dio.get<String>(validHeadUrl)).data, 'response 2');
    await Future<void>.delayed(const Duration(milliseconds: 5100));
    final fresh = await dio
        .get<String>(url)
        .timeout(const Duration(seconds: 2));
    expect(fresh.data, 'response 3');
    final cached = await dio.get<String>(validHeadUrl);
    expect(cached.data, 'response 2');
    expect(cached.headers.value('venera-cache'), 'true');
    expect(adapter.methods, ['GET', 'GET', 'HEAD', 'GET', 'HEAD']);
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
    if (options.method == 'HEAD') {
      final status = options.uri.queryParameters['head'] == 'allowed'
          ? 200
          : 405;
      return ResponseBody.fromString('', status);
    }
    return ResponseBody.fromString('response ${++_gets}', 200);
  }

  @override
  void close({bool force = false}) {}
}
