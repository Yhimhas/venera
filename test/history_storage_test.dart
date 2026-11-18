import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

void main() {
  if (Platform.isLinux) {
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
      addTearDown(() {
        if (manager.isInitialized) manager.close();
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

      manager.close();
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
      manager.close();

      final imported = sqlite3.open(dbPath);
      try {
        imported.execute('UPDATE history SET page = 9');
      } finally {
        imported.dispose();
      }
      await manager.init();
      expect(manager.find(id, firstType)?.page, 9);
    });
  });
}
