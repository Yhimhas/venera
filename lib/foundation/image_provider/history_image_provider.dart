import 'dart:async' show Future;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  HistoryImageProvider(this.history)
    : key = jsonEncode([
        'history',
        history.type.value,
        history.id,
        history.cover,
      ]);

  final History history;
  @override
  final String key;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
      url = await HistoryManager().refreshHistoryCover(history, () async {
        final comicSource =
            history.type.comicSource ?? (throw 'Comic source not found.');
        final comic = await comicSource.loadComicInfo!(history.id);
        checkStop();
        return comic.data.cover;
      });
    }
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }
}
