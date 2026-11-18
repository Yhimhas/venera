import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/file_downloader.dart';

void main() {
  final source = _FixtureSource();
  final manager = LocalManager();
  late File queue;

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-queue-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    App.dataPath = directory.path;
    queue = File('${directory.path}/downloading_tasks.json');
    manager.downloadingTasks.clear();
    source.loadComicPages = null;
    source.getImageLoadingConfig = null;
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove(source.key));
  });

  ImagesDownloadTask images(String id) {
    return ImagesDownloadTask(source: source, comicId: id);
  }

  ArchiveDownloadTask archive(String id) {
    final comic = ComicDetails.fromJson({
      'title': id,
      'comicId': id,
      'sourceKey': source.key,
      'cover': '',
      'tags': <String, List<String>>{},
    });
    return ArchiveDownloadTask('https://example.org/$id.zip', comic)
      ..path = '${App.dataPath}/$id';
  }

  Map<String, dynamic> groupedTaskJson() => {
    ...images('grouped').toJson(),
    'comic': {
      'title': 'Grouped comic',
      'comicId': 'grouped',
      'sourceKey': source.key,
      'cover': '',
      'tags': <String, List<String>>{},
      'chapters': {
        'Volume 1': {'a': 'Chapter A'},
        'Volume 2': {'b': 'Chapter B'},
      },
    },
    'path': App.dataPath,
    'cover': 'file://${App.dataPath}/cover.png',
  };

  ImagesDownloadTask pageDownload(
    List<String> pages,
    Future<File?> Function(String) findCache,
  ) {
    final previousCache = CacheManager.instance;
    final previousThreads = appdata.settings['downloadThreads'];
    CacheManager.instance = _FixtureCache(findCache);
    appdata.settings['downloadThreads'] = 1;
    addTearDown(() {
      CacheManager.instance = previousCache;
      appdata.settings['downloadThreads'] = previousThreads;
    });
    final task = ImagesDownloadTask.fromJson({
      ...groupedTaskJson(),
      'chapters': ['a'],
      'images': {'a': pages},
      'totalCount': pages.length,
    })!;
    manager.downloadingTasks.add(task);
    addTearDown(task.pause);
    task.resume();
    return task;
  }

  test('a saved archive is restored paused with its URL and path', () async {
    final original = archive('archive');
    await queue.writeAsString(jsonEncode([original.toJson()]));
    manager.restoreDownloadingTasks();
    final task = manager.downloadingTasks.single as ArchiveDownloadTask;
    expect(task.archiveUrl, original.archiveUrl);
    expect(task.path, original.path);
    expect(task.isPaused, isTrue);
    expect(task.comic.id, original.comic.id);
  });

  test(
    'an invalid entry or missing source leaves later tasks restorable',
    () async {
      final unavailable = images('missing').toJson()
        ..['source'] = 'unavailable';
      final data = jsonEncode([
        images('first').toJson(),
        'invalid record',
        unavailable,
        archive('archive').toJson(),
        images('last').toJson(),
      ]);
      await queue.writeAsString(data);
      manager.restoreDownloadingTasks();
      expect(manager.downloadingTasks.map((task) => task.id), [
        'first',
        'archive',
        'last',
      ]);
      expect(await queue.readAsString(), data);
    },
  );

  test('an unreadable queue is kept on disk', () async {
    const contents = '[{"type":"ImagesDownloadTask"';
    await queue.writeAsString(contents);
    manager.restoreDownloadingTasks();
    expect(manager.downloadingTasks, isEmpty);
    expect(await queue.readAsString(), contents);
  });

  test('resuming during chapter loading collects the full image list', () async {
    final firstRunBlocked = Completer<void>();
    final releaseFirstRun = Completer<Res<List<String>>>();
    final requests = <String?>[];
    source.loadComicPages = (_, chapter) async {
      requests.add(chapter);
      if (requests.length == 2) {
        firstRunBlocked.complete();
        return releaseFirstRun.future;
      }
      return Res(['image-$chapter']);
    };
    final task = ImagesDownloadTask.fromJson(groupedTaskJson())!;
    manager.downloadingTasks.add(task);
    addTearDown(() {
      task.pause();
      if (!releaseFirstRun.isCompleted) {
        releaseFirstRun.complete(const Res(['stale-image']));
      }
    });

    task.resume();
    await firstRunBlocked.future.timeout(const Duration(seconds: 5));
    task.pause();
    expect(task.toJson()['images'], isNull);

    final collected = Completer<void>();
    task.addListener(() {
      if (task.message == '0/2') {
        task.pause();
        collected.complete();
      }
    });
    task.resume();
    releaseFirstRun.complete(const Res(['stale-image']));
    await collected.future.timeout(const Duration(seconds: 5));
    await manager.saveCurrentDownloadingTasks();
    expect(requests, ['a', 'b', 'a', 'b']);
    final saved = (jsonDecode(await queue.readAsString()) as List).single;
    expect(saved['images'], {
      'a': ['image-a'],
      'b': ['image-b'],
    });
  });

  test('old queue entries keep progress only for a complete image list', () {
    final saved = groupedTaskJson()
      ..['images'] = {
        'a': ['image-a'],
      }
      ..['totalCount'] = 1
      ..['downloadedCount'] = 1
      ..['index'] = 1;
    final incomplete = ImagesDownloadTask.fromJson(saved)!.toJson();
    expect(incomplete['images'], isNull);
    expect(incomplete['index'], 0);
    expect(incomplete['downloadedCount'], 0);

    // Only chapter a was requested, so the same list is complete for this task.
    saved['chapters'] = ['a'];
    final complete = ImagesDownloadTask.fromJson(saved)!.toJson();
    expect(complete['images'], saved['images']);
    expect(complete['index'], 1);
    expect(complete['downloadedCount'], 1);
  });

  test('a paused page worker settles when its pending cache check returns', () async {
    final checkingCache = Completer<void>();
    final cachedFile = Completer<File?>();
    var sourceRequests = 0;
    source.getImageLoadingConfig = (_, _, _) async {
      sourceRequests++;
      throw StateError('Paused page reached the source');
    };
    final task = pageDownload(['page'], (_) {
      checkingCache.complete();
      return cachedFile.future;
    });
    await checkingCache.future.timeout(const Duration(seconds: 2));
    final worker = task.tasks.values.single;
    final stopped = worker.wait();

    task.pause();
    cachedFile.complete(null);
    await stopped.timeout(const Duration(seconds: 2));
    expect(worker.isComplete, isFalse);
    expect(sourceRequests, 0);
  });

  test('a worker that already failed also releases later waiters', () async {
    final task = pageDownload(['page'], (_) async {
      throw StateError('Cache read failed');
    });
    final failed = Completer<void>();
    task.addListener(() {
      if (task.isError && !failed.isCompleted) failed.complete();
    });
    await failed.future.timeout(const Duration(seconds: 2));

    final worker = task.tasks.values.single;
    expect(await worker.wait().timeout(const Duration(seconds: 2)), same(worker));
    expect(worker.error, contains('Cache read failed'));
  });

  test('a page saved from cache does not start a second transfer', () async {
    final bytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    final cached = await File('${App.dataPath}/cached.png').writeAsBytes(bytes);
    final nextPage = Completer<void>();
    final pending = Completer<File?>();
    final sourceRequests = <String>[];
    source.getImageLoadingConfig = (image, _, _) async {
      sourceRequests.add(image);
      throw StateError('Unexpected source request');
    };
    final task = pageDownload(['cached', 'pending'], (key) async {
      if (key.startsWith('cached@')) return cached;
      if (!nextPage.isCompleted) nextPage.complete();
      return pending.future;
    });
    addTearDown(() {
      task.pause();
      if (!pending.isCompleted) pending.complete(null);
    });

    await nextPage.future.timeout(const Duration(seconds: 2));
    expect(await File('${App.dataPath}/a/0.png').readAsBytes(), bytes);
    expect(sourceRequests, isEmpty);
  });

  test('overlapping saves keep the latest complete queue', () async {
    final saves = <Future<bool>>[];
    for (var i = 0; i < 12; i++) {
      manager.downloadingTasks = [images('image-$i'), archive('archive-$i')];
      saves.add(manager.saveCurrentDownloadingTasks());
    }
    expect(await Future.wait(saves), everyElement(isTrue));
    final entries = jsonDecode(await queue.readAsString()) as List;
    expect(entries.map((entry) => entry['type']), [
      'ImagesDownloadTask',
      'ArchiveDownloadTask',
    ]);
    expect(entries.first['comicId'], 'image-11');
    expect(entries.last['comic']['comicId'], 'archive-11');
  });

  test(
    'a failed save leaves the previous queue and allows later saves',
    () async {
      manager.downloadingTasks.add(images('old'));
      expect(await manager.saveCurrentDownloadingTasks(), isTrue);
      final previous = await queue.readAsString();
      final blocked = await Directory('${queue.path}.tmp').create();
      manager.downloadingTasks = [images('new')];
      expect(await manager.saveCurrentDownloadingTasks(), isFalse);
      expect(await queue.readAsString(), previous);
      await blocked.delete();
      expect(await manager.saveCurrentDownloadingTasks(), isTrue);
      expect(await queue.readAsString(), contains('"comicId":"new"'));
    },
  );

  test(
    'an already staged archive can resume without a network request',
    () async {
      final file = File('${App.dataPath}/staged.zip');
      await file.writeAsBytes([0, 1, 2, 3]);
      final checkpoint = File('${file.path}.download');
      await checkpoint.writeAsString('0-4-4');
      final result = await FileDownloader(
        'https://example.invalid/archive.zip',
        file.path,
        retainCheckpoint: true,
      ).start().last;
      expect(result.isFinished, isTrue);
      expect(result.downloadedBytes, 4);
      expect(await checkpoint.readAsString(), '0-4-4');
    },
  );
}

class _FixtureSource implements ComicSource {
  @override
  String get key => 'queueFixture';

  @override
  LoadComicPagesFunc? loadComicPages;

  @override
  GetImageLoadingConfigFunc? getImageLoadingConfig;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixtureCache implements CacheManager {
  _FixtureCache(this._find);

  final Future<File?> Function(String) _find;

  @override
  Future<File?> findCache(String key) => _find(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
