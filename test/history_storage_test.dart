import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/history_image_provider.dart';
import 'package:venera/foundation/res.dart';

void main() {
  String? asyncSkipReason;
  if (Platform.isLinux) {
    try {
      DynamicLibrary.open('libsqlite3.so');
    } on ArgumentError {
      asyncSkipReason =
          'SQLite default library is unavailable to worker isolates';
    }
    open.overrideFor(OperatingSystem.linux, () {
      try {
        return DynamicLibrary.open('libsqlite3.so');
      } on ArgumentError {
        return DynamicLibrary.open('libsqlite3.so.0');
      }
    });
  }
  String? skipReason;
  try {
    sqlite3.openInMemory().dispose();
  } on ArgumentError {
    skipReason = 'SQLite native library is unavailable in this test runner';
  }

  group('reading history storage', skip: skipReason, () {
    const id = 'shared-id';
    const firstType = ComicType(1001);
    const secondType = ComicType(1002);
    late String dbPath;
    late HistoryManager manager;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('venera-history-test-');
      addTearDown(() => dir.delete(recursive: true));
      App.dataPath = dir.path;
      dbPath = '${dir.path}/history.db';
      final previousManager = HistoryManager.cache;
      manager = HistoryManager.create();
      HistoryManager.cache = manager;
      addTearDown(() async {
        await manager.close();
        HistoryManager.cache = previousManager;
      });
    });

    History progress(ComicType type, int page) => History.fromMap({
      'id': id,
      'type': type.value,
      'title': 'Example comic',
      'subtitle': '',
      'cover': '',
      'time': 1,
      'ep': 2,
      'page': page,
      'max_page': 20,
    });

    test('identical IDs keep independent progress by source', () async {
      await manager.init();
      manager.addHistory(progress(firstType, 4));
      expect(manager.find(id, secondType), isNull);
      manager.addHistory(progress(secondType, 8));
      expect(manager.find(id, firstType)?.page, 4);
      expect(manager.find(id, secondType)?.page, 8);

      await manager.close();
      await manager.init();
      expect(manager.getAll(), hasLength(2));
      expect(manager.find(id, firstType)?.page, 4);
      manager.batchDeleteHistories([const ComicID(firstType, id)]);
      expect(manager.find(id, firstType), isNull);
      expect(manager.find(id, secondType)?.page, 8);
    });

    for (final hasGroup in [false, true]) {
      test('migrates legacy history with chapter_group=$hasGroup', () async {
        final legacy = sqlite3.open(dbPath);
        try {
          legacy.execute('''
            CREATE TABLE history (
              id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, cover TEXT,
              time INT, type INT, ep INT, page INT, readEpisode TEXT, max_page INT
              ${hasGroup ? ', chapter_group INT' : ''}
            );
            CREATE TABLE image_favorites (id TEXT PRIMARY KEY, marker TEXT);
            INSERT INTO image_favorites VALUES ('example', 'keep');
          ''');
          legacy.execute(
            '''
            INSERT INTO history VALUES (?, 'Legacy', 'subtitle', 'cover', 1234,
              ?, 2, 7, '2-1,2-2', 15 ${hasGroup ? ', 2' : ''});
          ''',
            [id, firstType.value],
          );
        } finally {
          legacy.dispose();
        }

        await manager.init();
        manager.addHistory(progress(secondType, 8));
        final old = manager.getAll().singleWhere(
          (item) => item.type == firstType,
        );
        expect(old.title, 'Legacy');
        expect(old.subtitle, 'subtitle');
        expect(old.cover, 'cover');
        expect(old.time.millisecondsSinceEpoch, 1234);
        expect(old.ep, 2);
        expect(old.page, 7);
        expect(old.readEpisode, {'2-1', '2-2'});
        expect(old.maxPage, 15);
        expect(old.group, hasGroup ? 2 : null);

        final stored = sqlite3.open(dbPath);
        try {
          expect(
            stored
                .select('SELECT marker FROM image_favorites')
                .single['marker'],
            'keep',
          );
        } finally {
          stored.dispose();
        }
      });
    }

    test('reopening a changed database discards old cached progress', () async {
      await manager.init();
      manager.addHistory(progress(firstType, 4));
      expect(manager.find(id, firstType)?.page, 4);
      await manager.close();

      final imported = sqlite3.open(dbPath);
      try {
        imported.execute('UPDATE history SET page = 9');
      } finally {
        imported.dispose();
      }
      await manager.init();
      expect(manager.find(id, firstType)?.page, 9);
    });

    group('async progress', skip: asyncSkipReason, () {
      test(
        'keeps existing metadata when a reader saves an older snapshot',
        () async {
          await manager.init();
          final reader = progress(firstType, 4)..cover = 'old.png';
          manager.addHistory(reader);
          manager.addHistory(
            progress(firstType, 4)
              ..title = 'Refreshed title'
              ..subtitle = 'Refreshed subtitle'
              ..cover = 'new.png',
          );

          await manager.addHistoryAsync(
            reader
              ..page = 9
              ..ep = 3
              ..group = 2
              ..maxPage = 30
              ..readEpisode.add('2-3')
              ..time = DateTime.fromMillisecondsSinceEpoch(2000),
          );

          final saved = manager.find(id, firstType)!;
          expect(saved.title, 'Refreshed title');
          expect(saved.subtitle, 'Refreshed subtitle');
          expect(saved.cover, 'new.png');
          expect(saved.page, 9);
          expect(saved.ep, 3);
          expect(saved.group, 2);
          expect(saved.maxPage, 30);
          expect(saved.readEpisode, {'2-3'});
          expect(saved.time.millisecondsSinceEpoch, 2000);
          expect(manager.getAll().single.cover, 'new.png');
        },
      );

      test('captures queued progress before the reader changes it', () async {
        await manager.init();
        final first = manager.addHistoryAsync(progress(firstType, 4));
        final reader = progress(secondType, 8)..readEpisode.add('2');
        final second = manager.addHistoryAsync(reader);
        reader.page = 12;
        reader.readEpisode.add('3');

        await Future.wait([first, second]);
        final saved = manager.find(id, secondType)!;
        expect(saved.page, 8);
        expect(saved.readEpisode, {'2'});
        expect(manager.getAll(), hasLength(2));
      });

      test(
        'closing finishes accepted writes before reopening the database',
        () async {
          await manager.init();
          final first = manager.addHistoryAsync(progress(firstType, 4));
          final second = manager.addHistoryAsync(progress(secondType, 8));
          final closing = manager.close();
          await manager.addHistoryAsync(progress(firstType, 99));
          await closing;
          await Future.wait([first, second]);
          expect(manager.isInitialized, isFalse);

          await manager.init();
          expect(manager.find(id, firstType)?.page, 4);
          expect(manager.find(id, secondType)?.page, 8);
          await manager.addHistoryAsync(progress(secondType, 12));
          expect(manager.find(id, secondType)?.page, 12);
        },
      );

      test('a failed write does not block queued writes or closing', () async {
        await manager.init();
        final control = sqlite3.open(dbPath);
        try {
          control.execute('''
            CREATE TRIGGER fail_write BEFORE INSERT ON history WHEN NEW.page = 99
            BEGIN SELECT RAISE(ABORT, 'test write failure'); END;
          ''');
        } finally {
          control.dispose();
        }

        final failed = expectLater(
          manager.addHistoryAsync(progress(firstType, 99)),
          throwsA(
            predicate(
              (Object error) => error.toString().contains('test write failure'),
            ),
          ),
        );
        final second = manager.addHistoryAsync(progress(firstType, 8));
        await manager.close().timeout(const Duration(seconds: 5));
        await failed;
        await second;
        await manager.init();
        expect(manager.find(id, firstType)?.page, 8);
      });
    });

    group('metadata refresh', () {
      late _DeferredSource source;
      late ComicType type;

      setUp(() async {
        source = _DeferredSource();
        type = ComicType.fromKey(source.key);
        ComicSourceManager().add(source);
        addTearDown(() => ComicSourceManager().remove(source.key));
        await manager.init();
        manager.addHistory(progress(type, 4));
      });

      void finishRefresh() {
        source.response.complete(
          Res(
            ComicDetails.fromJson({
              'comicId': id,
              'sourceKey': source.key,
              'title': 'Updated title',
              'subtitle': 'Updated subtitle',
              'cover': 'https://example.invalid/updated.png',
              'tags': <String, List<String>>{},
            }),
          ),
        );
      }

      test('keeps newer reading progress when the request finishes', () async {
        final refreshing = manager.refreshHistoryInfo(manager.getAll().single);
        manager.addHistory(
          progress(type, 9)
            ..ep = 3
            ..group = 2
            ..maxPage = 30
            ..readEpisode.add('2-3')
            ..time = DateTime.fromMillisecondsSinceEpoch(2000),
        );
        finishRefresh();

        expect(await refreshing, isTrue);
        final saved = manager.find(id, type)!;
        expect(saved.title, 'Updated title');
        expect(saved.subtitle, 'Updated subtitle');
        expect(saved.cover, endsWith('updated.png'));
        expect(saved.page, 9);
        expect(saved.ep, 3);
        expect(saved.group, 2);
        expect(saved.maxPage, 30);
        expect(saved.readEpisode, {'2-3'});
        expect(saved.time.millisecondsSinceEpoch, 2000);
      });

      test('does not recreate a record removed during the request', () async {
        final refreshing = manager.refreshHistoryInfo(manager.getAll().single);
        manager.batchDeleteHistories([ComicID(type, id)]);
        finishRefresh();

        expect(await refreshing, isFalse);
        expect(manager.getAll(), isEmpty);
        expect(manager.find(id, type), isNull);
      });

      test('does not update records in a reopened database', () async {
        final refreshing = manager.refreshHistoryInfo(manager.getAll().single);
        await manager.close();
        await manager.init();
        manager.addHistory(progress(type, 12)..title = 'Imported title');
        finishRefresh();

        expect(await refreshing, isFalse);
        expect(manager.find(id, type)?.title, 'Imported title');
        expect(manager.find(id, type)?.page, 12);
      });

      test(
        'backfilling a cover keeps progress and changes the image key',
        () async {
          final snapshot = manager.getAll().single;
          final oldImage = HistoryImageProvider(snapshot);
          final oldKey = oldImage.key;
          final pending = Completer<String>();
          final loading = manager.refreshHistoryCover(
            snapshot,
            () => pending.future,
          );
          manager.addHistory(progress(type, 9));
          const cover = 'https://example.invalid/cover.png';
          pending.complete(cover);

          expect(await loading, cover);
          final saved = manager.find(id, type)!;
          expect(saved.page, 9);
          expect(saved.cover, cover);
          expect(oldImage.key, oldKey);
          expect(HistoryImageProvider(saved), isNot(oldImage));
        },
      );

      test(
        'a late fallback cannot replace a newer cover or restore a record',
        () async {
          final pending = Completer<String>();
          final loading = manager.refreshHistoryCover(
            manager.getAll().single,
            () => pending.future,
          );
          const cover = 'https://example.invalid/current.png';
          manager.addHistory(progress(type, 9)..cover = cover);
          pending.complete('https://example.invalid/previous.png');
          await loading;
          expect(manager.find(id, type)?.cover, cover);

          final deletedCover = Completer<String>();
          final afterDeletion = manager.refreshHistoryCover(
            manager.getAll().single,
            () => deletedCover.future,
          );
          manager.batchDeleteHistories([ComicID(type, id)]);
          deletedCover.complete('https://example.invalid/deleted.png');
          await afterDeletion;
          expect(manager.getAll(), isEmpty);
        },
      );
    });
  });
}

class _DeferredSource implements ComicSource {
  final response = Completer<Res<ComicDetails>>();

  @override
  String get key => 'historyRefreshFixture';

  @override
  LoadComicFunc get loadComicInfo =>
      (_) => response.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
