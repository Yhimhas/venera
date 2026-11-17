import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/proxy.dart';

void main() {
  final sources = ProxyRuleScope.source.settingsKey;
  final domains = ProxyRuleScope.domain.settingsKey;

  setUp(() {
    appdata.settings['proxy'] = 'global-proxy:3128';
    appdata.settings[sources] = {};
    appdata.settings[domains] = {};
    NetworkCacheManager().clear();
    resetProxyCache();
  });

  test('old settings still use the global proxy', () async {
    appdata.settings[sources] = null;
    appdata.settings[domains] = null;
    final url = Uri.parse('https://cdn.example.org/');
    expect(
      await getProxy(uri: url, sourceKey: 'source'),
      'http://global-proxy:3128',
    );
    appdata.settings['proxy'] = 'direct';
    expect(await getProxy(uri: url), isNull);
  });

  test(
    'source wins, then the most specific domain, then the global proxy',
    () async {
      appdata.settings[sources] = jsonDecode(
        '{"first":"direct","second":"socks5://source-proxy:1080"}',
      );
      appdata.settings[domains] = {
        'example.org': 'http://parent-proxy:3128',
        'cdn.example.org': 'https://cdn-proxy:443',
      };
      final url = Uri.parse('https://IMG.CDN.Example.org./page');
      expect(
        await Future.wait([
          getProxy(uri: url, sourceKey: 'first'),
          getProxy(uri: url, sourceKey: 'second'),
          getProxy(uri: url),
          getProxy(uri: Uri.parse('https://api.example.org/')),
          getProxy(uri: Uri.parse('https://notexample.org/')),
        ]),
        [
          null,
          'socks5://source-proxy:1080',
          'https://cdn-proxy:443',
          'http://parent-proxy:3128',
          'http://global-proxy:3128',
        ],
      );
      expect(normalizeProxyDomain(' CDN.Example.org. '), 'cdn.example.org');
      expect(normalizeProxyDomain('https://cdn.example.org'), isNull);
      expect(normalizeProxyDomain('cdn.example.org:443'), isNull);
    },
  );

  test(
    'cached responses are separated by source and effective proxy',
    () async {
      appdata.settings[sources] = {
        'first': 'direct',
        'second': 'http://source-proxy:3128',
      };
      final dio = Dio(BaseOptions(responseType: ResponseType.plain))
        ..httpClientAdapter = _EchoRouteAdapter()
        ..interceptors.add(NetworkCacheManager());
      addTearDown(dio.close);

      Future<String?> fetch(String sourceKey) async {
        return (await dio.get<String>(
          'https://example.org/image',
          options: Options(extra: {proxySourceKey: sourceKey}),
        )).data;
      }

      expect(await fetch('first'), 'direct');
      expect(await fetch('second'), 'http://source-proxy:3128');
      appdata.settings[sources] = {'first': 'http://new-proxy:3128'};
      expect(await fetch('first'), 'http://new-proxy:3128');
      expect(await fetch('second'), 'http://global-proxy:3128');
    },
  );
}

class _EchoRouteAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      options.extra[resolvedProxyKey] as String? ?? 'direct',
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}
