import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
