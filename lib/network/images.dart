import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/utils/image.dart';

import 'app_dio.dart';
import 'proxy.dart';

abstract class ImageDownloader {
  static Stream<ImageDownloadProgress> loadThumbnail(
      String url, String? sourceKey,
      [String? cid]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if(comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    var dio = AppDio(BaseOptions(
      headers: Map<String, dynamic>.from(configs['headers']),
      method: configs['method'] ?? 'GET',
      responseType: ResponseType.stream,
      extra: {proxySourceKey: sourceKey},
    ));

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(requestUrl,
        data: configs['data']);
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      final uint8List = Uint8List.fromList(buffer);
      buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
      (configs['onResponse'] as JSInvokable).free();
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages = <String, _ImageLoad>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    final downloads = _loadingImages.values.toList();
    _loadingImages.clear();
    for (final download in downloads) {
      download.cancel();
    }
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
      String imageKey, String? sourceKey, String cid, String eid) {
    return _startComicImage(imageKey, sourceKey, cid, eid).stream;
  }

  static void preloadComicImage(
      String imageKey, String? sourceKey, String cid, String eid) {
    _startComicImage(imageKey, sourceKey, cid, eid);
  }

  static _ImageLoad _startComicImage(
      String imageKey, String? sourceKey, String cid, String eid) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    return _loadingImages.putIfAbsent(cacheKey, () {
      final token = CancelToken();
      return _ImageLoad(
        _loadComicImage(imageKey, sourceKey, cid, eid, cancelToken: token),
        token,
        (download) {
          if (identical(_loadingImages[cacheKey], download)) {
            _loadingImages.remove(cacheKey);
          }
        },
      );
    });
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
  }) {
    return _loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      cancelToken: cancelToken,
    );
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
  }) async* {
    if (cancelToken?.isCancelled == true) return;
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = await CacheManager().findCache(cacheKey);
    if (cancelToken?.isCancelled == true) return;

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = (await comicSource!.getImageLoadingConfig
              ?.call(imageKey, cid, eid)) ??
          {};
    }
    if (cancelToken?.isCancelled == true) return;
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {
          'user-agent': webUA,
        };

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(BaseOptions(
          headers: configs['headers'],
          method: configs['method'] ?? 'GET',
          responseType: ResponseType.stream,
          extra: {proxySourceKey: sourceKey},
        ));

        var req = await dio.request<ResponseBody>(
          configs['url'] ?? imageKey,
          data: configs['data'],
          cancelToken: cancelToken,
        );
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        await for (var data in stream) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([Uint8List.fromList(buffer)]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            buffer = result;
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        if (cancelToken?.isCancelled == true) return;
        await CacheManager().writeCache(cacheKey, data);
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        if (cancelToken?.isCancelled == true ||
            retryLimit < 0 ||
            onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

/// Shares one eager image download with reader and prefetch callers.
class _ImageLoad {
  _ImageLoad(Stream<ImageDownloadProgress> source, this._token, this._onClosed) {
    _subscription = source.listen(
      (progress) {
        if (progress.imageBytes != null) {
          _availableImage = progress;
        }
        for (final listener in _listeners) {
          listener.add(progress);
        }
      },
      onError: _fail,
      onDone: _close,
      cancelOnError: true,
    );
  }

  final CancelToken _token;
  final void Function(_ImageLoad) _onClosed;
  final _listeners = <StreamController<ImageDownloadProgress>>{};
  late final StreamSubscription<ImageDownloadProgress> _subscription;
  ImageDownloadProgress? _availableImage;
  bool _closed = false;

  Stream<ImageDownloadProgress> get stream {
    final listener = StreamController<ImageDownloadProgress>();
    listener.onCancel = () => _listeners.remove(listener);
    _listeners.add(listener);
    final image = _availableImage;
    if (image != null) listener.add(image);
    return listener.stream;
  }

  void _fail(Object error, StackTrace stackTrace) {
    for (final listener in _listeners) {
      listener.addError(error, stackTrace);
    }
    _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _onClosed(this);
    _availableImage = null;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      unawaited(listener.close());
    }
  }

  void cancel() {
    if (_closed) return;
    _token.cancel('Comic image load cancelled');
    _fail(_token.cancelError!, StackTrace.current);
    _subscription.cancel().ignore();
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
