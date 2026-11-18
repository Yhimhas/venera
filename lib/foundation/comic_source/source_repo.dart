import 'dart:async';
import 'dart:convert';

import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';

/// A loaded comic source repository index.
class SourceRepoIndex {
  /// The url which actually returned the index.
  final String url;

  /// The decoded index.json content.
  final List<dynamic> data;

  /// Whether [url] differs from the configured url because the configured one
  /// failed. A mirror can also win the race while the configured url still
  /// works (it is just slower), and then the configured url must be kept.
  final bool switched;

  const SourceRepoIndex(this.url, this.data, {this.switched = false});
}

/// Helper for loading the comic source repository (index.json and source
/// scripts) with automatic mirror fallback.
///
/// The default repository url points to jsdelivr, whose `cdn.jsdelivr.net`
/// host is blocked by SNI based filtering in some networks while the other
/// jsdelivr mirrors (which resolve to the same IPs) still work. So when the
/// configured url fails, we retry on the other mirrors instead of failing.
class SourceRepo {
  /// Default repository url, using a mirror which is reachable from mainland
  /// China (`cdn.jsdelivr.net` is SNI filtered there).
  static const String defaultUrl =
      "https://fastly.jsdelivr.net/gh/venera-app/venera-configs@main/index.json";

  /// jsdelivr mirrors, in preferred order.
  static const List<String> _jsdelivrHosts = [
    'fastly.jsdelivr.net',
    'gcore.jsdelivr.net',
    'testingcf.jsdelivr.net',
    'quantil.jsdelivr.net',
    'cdn.jsdelivr.net',
  ];

  /// Whether [url] looks like the default venera-configs repository.
  static bool isDefaultRepo(String url) {
    return url.contains('venera-app/venera-configs');
  }

  /// Build candidate urls for [url], most preferred first.
  ///
  /// Mirrors share the path of the original url, so a user configured
  /// repository keeps working when its host is filtered.
  static List<String> candidates(String url) {
    final result = <String>[];
    void add(String u) {
      u = u.trim();
      if (u.isNotEmpty && !result.contains(u)) {
        result.add(u);
      }
    }

    final trimmed = url.trim();
    add(trimmed);

    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) {
      final host = uri.host;
      if (host.endsWith('jsdelivr.net')) {
        for (final mirror in _jsdelivrHosts) {
          add(uri.replace(host: mirror).toString());
        }
        // /gh/{user}/{repo}@{ref}/{path} -> raw.githubusercontent.com
        final segments = uri.pathSegments;
        if (segments.length >= 4 && segments[0] == 'gh') {
          final repoRef = segments[2];
          final split = repoRef.indexOf('@');
          if (split > 0) {
            final repo = repoRef.substring(0, split);
            final ref = repoRef.substring(split + 1);
            final path = segments.sublist(3).join('/');
            add('https://raw.githubusercontent.com/'
                '${segments[1]}/$repo/$ref/$path');
          }
        }
      }
    }

    return result;
  }

  /// Load and decode the repository index.
  ///
  /// All candidates are requested concurrently and the first successful one
  /// wins, so a filtered host only costs the time of a failed handshake.
  static Future<SourceRepoIndex> load(String url) async {
    final urls = candidates(url);
    if (urls.isEmpty) {
      throw Exception("Invalid repository url");
    }
    final completer = Completer<SourceRepoIndex>();
    final configuredDone = Completer<void>();
    var pending = urls.length;
    var configuredFailed = false;
    Object? lastError;

    void onError(String candidate, Object error) {
      if (candidate == urls.first) {
        configuredFailed = true;
        if (!configuredDone.isCompleted) {
          configuredDone.complete();
        }
      }
      lastError = error;
      pending--;
      if (pending == 0 && !completer.isCompleted) {
        completer.completeError(lastError!);
      }
    }

    for (final u in urls) {
      () async {
        try {
          final data = await _fetchIndexExact(u);
          if (u == urls.first && !configuredDone.isCompleted) {
            configuredDone.complete();
          }
          if (!completer.isCompleted) {
            completer.complete(
              SourceRepoIndex(u, data, switched: configuredFailed),
            );
          }
        } catch (e) {
          onError(u, e);
        }
      }();
    }

    // Give the configured url a moment to report its own failure, so a mirror
    // which merely answered faster does not get persisted as the repository.
    var result = await completer.future;
    if (result.url != urls.first && !configuredDone.isCompleted) {
      await Future.any([
        Future.delayed(const Duration(seconds: 2)),
        configuredDone.future,
      ]);
    }
    if (result.url != urls.first) {
      result = SourceRepoIndex(
        result.url,
        result.data,
        switched: configuredFailed,
      );
    }
    return result;
  }

  static Future<List<dynamic>> _fetchIndexExact(String url) async {
    final data = await _getTextExact(url);
    final decoded = jsonDecode(data);
    if (decoded is! List) {
      throw Exception("Invalid index.json");
    }
    return decoded;
  }

  /// Fetch a text resource, falling back to mirrors one by one.
  ///
  /// Used for source scripts: they are big enough that racing every mirror
  /// would waste traffic, and the first candidate is usually the cached one.
  static Future<String> fetchText(
    String url, {
    String? sourceKey,
    CancelToken? cancelToken,
  }) async {
    final urls = candidates(url);
    Object? lastError;
    for (final u in urls) {
      try {
        return await _getTextExact(
          u,
          sourceKey: sourceKey,
          cancelToken: cancelToken,
        );
      } catch (e) {
        if (cancelToken?.cancelError case final error?) throw error;
        lastError = e;
      }
    }
    throw lastError ?? Exception("Network error");
  }

  static Future<String> _getTextExact(
    String url, {
    String? sourceKey,
    CancelToken? cancelToken,
  }) async {
    final res = await AppDio().get<String>(
      url,
      cancelToken: cancelToken,
      options: Options(
        extra: sourceKey == null ? null : {proxySourceKey: sourceKey},
        responseType: ResponseType.plain,
        headers: {"cache-time": "no"},
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final data = res.data;
    if (res.statusCode != 200 || data == null || data.isEmpty) {
      throw Exception("HTTP ${res.statusCode}");
    }
    return data;
  }
}
