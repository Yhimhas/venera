import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/data.dart';
import 'package:zip_flutter/zip_flutter.dart';

void main() {
  String? skipReason;
  final zipLibrary = switch (Platform.operatingSystem) {
    'linux' => 'libzip_flutter.so',
    'windows' => 'zip_flutter.dll',
    'macos' => 'zip_flutter.framework/zip_flutter',
    _ => null,
  };
  if (zipLibrary == null) {
    skipReason = 'ZIP library is unavailable on this test platform';
  } else {
    try {
      DynamicLibrary.open(zipLibrary);
      sqlite3.openInMemory().dispose();
    } on ArgumentError {
      skipReason =
          'ZIP or SQLite native library is unavailable in this test runner';
    }
  }

  group('app data export', skip: skipReason, () {
    late Directory root;
    late HistoryManager history;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('venera-export-test-');
      addTearDown(() => root.delete(recursive: true));
      App.dataPath = (await Directory('${root.path}/data').create()).path;
      App.cachePath = (await Directory('${root.path}/cache').create()).path;
      final previous = HistoryManager.cache;
      history = HistoryManager.create();
      HistoryManager.cache = history;
      addTearDown(() async {
        await history.close();
        HistoryManager.cache = previous;
      });
      await history.init();
      await Directory('${App.dataPath}/comic_source').create();
      await File(
        '${App.dataPath}/local_favorite.db',
      ).writeAsString('favorites');
      await File('${App.dataPath}/cookie.db').writeAsString('cookies');
      await File(
        '${App.dataPath}/appdata.json',
      ).writeAsString('{"mode":"full"}');
      await File(
        '${App.dataPath}/syncdata.json',
      ).writeAsString('{"mode":"sync"}');
    });

    History progress(int page) => History.fromMap({
      'id': 'comic',
      'type': 0,
      'title': 'Comic',
      'subtitle': '',
      'cover': '',
      'time': 1,
      'ep': 1,
      'page': page,
    });

    Future<Directory> extract(File archive) async {
      final directory = await root.createTemp('extracted-');
      ZipFile.openAndExtract(archive.path, directory.path);
      return directory;
    }

    test('includes queued reading progress stored in SQLite WAL', () async {
      history.addHistory(progress(4));
      final live = sqlite3.open('${App.dataPath}/history.db');
      addTearDown(live.dispose);
      expect(live.select('PRAGMA journal_mode = WAL').single[0], 'wal');
      final write = history.addHistoryAsync(progress(8));
      final archive = await exportAppData(false);
      await write;

      final unpacked = await extract(archive);
      final snapshot = sqlite3.open(
        '${unpacked.path}/history.db',
        mode: OpenMode.readOnly,
      );
      try {
        expect(snapshot.select('PRAGMA quick_check').single[0], 'ok');
        expect(snapshot.select('SELECT page FROM history').single[0], 8);
      } finally {
        snapshot.dispose();
      }
    });

    test('back-to-back exports produce independent archives', () async {
      final archives = await Future.wait([
        exportAppData(false),
        exportAppData(),
      ]);
      expect(archives.first.path, isNot(archives.last.path));
      final full = await extract(archives.first);
      final sync = await extract(archives.last);
      expect(
        await File('${full.path}/appdata.json').readAsString(),
        '{"mode":"full"}',
      );
      expect(
        await File('${sync.path}/appdata.json').readAsString(),
        '{"mode":"sync"}',
      );
      expect(await Directory(App.cachePath).list().length, 2);
    });

    test('a failed archive leaves no export staging files', () async {
      final cookie = File('${App.dataPath}/cookie.db');
      await cookie.rename('${cookie.path}.unavailable');
      final previous = await File(
        '${App.cachePath}/existing.venera',
      ).writeAsString('previous export');

      await expectLater(exportAppData(false), throwsA(isA<ZipException>()));
      final remaining = await Directory(App.cachePath).list().toList();
      expect(remaining.single.path, previous.path);
      expect(await previous.readAsString(), 'previous export');
    });
  });
}
