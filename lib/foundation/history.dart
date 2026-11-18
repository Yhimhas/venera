import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:ffi' as ffi;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel(
      {required HistoryMixin model,
      required this.ep,
      required this.page,
      this.group,
      Set<String>? readChapters,
      DateTime? time})
      : type = model.historyType,
        title = model.title,
        subtitle = model.subTitle ?? '',
        cover = model.cover,
        id = model.id,
        readEpisode = readChapters ?? <String>{},
        time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
      : type = HistoryType(map["type"]),
        time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
        title = map["title"],
        subtitle = map["subtitle"],
        cover = map["cover"],
        ep = map["ep"],
        page = map["page"],
        id = map["id"],
        readEpisode = Set<String>.from(
            (map["readEpisode"] as List<dynamic>?)?.toSet() ??
                const <String>{}),
        maxPage = map["max_page"];

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
      : type = HistoryType(row["type"]),
        time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
        title = row["title"],
        subtitle = row["subtitle"],
        cover = row["cover"],
        ep = row["ep"],
        page = row["page"],
        id = row["id"],
        readEpisode = Set<String>.from((row["readEpisode"] as String)
            .split(',')
            .where((element) => element != "")),
        maxPage = row["max_page"],
        group = row["chapter_group"];

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String get description {
    var res = "";
    if (group != null){
      res += "${"Group @group".tlParams({
        "group": group!,
      })} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({
        "ep": ep,
      });
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({
        "page": page,
      });
    }
    return res;
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  int get length => _db.select("select count(*) from history;").first[0] as int;

  Set<ComicID>? _cachedHistoryKeys;
  final _recentHistories = <ComicID, History>{};

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    _db = sqlite3.open("${App.dataPath}/history.db");
    try {
      _initHistoryTable();
      ImageFavoriteManager().init();
    } catch (_) {
      _db.dispose();
      rethrow;
    }
    isInitialized = true;
    notifyListeners();
  }

  static const _historyTableDefinition = '''
    (
      id text,
      title text,
      subtitle text,
      cover text,
      time int,
      type int,
      ep int,
      page int,
      readEpisode text,
      max_page int,
      chapter_group int,
      primary key (id, type)
    )
  ''';

  static const _historyColumns =
      'id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page';

  void _initHistoryTable() {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('CREATE TABLE IF NOT EXISTS history $_historyTableDefinition');
      final columns = _db.select('PRAGMA table_info(history)');
      final primaryKey = {
        for (final column in columns)
          if ((column['pk'] as int) > 0) column['name'],
      };
      final hasChapterGroup = columns.any((c) => c['name'] == 'chapter_group');
      if (primaryKey.length != 2 || !primaryKey.containsAll({'id', 'type'})) {
        // Older versions used id alone, which could overwrite another source.
        _db.execute('CREATE TABLE history_upgrade $_historyTableDefinition');
        _db.execute('''
          INSERT INTO history_upgrade ($_historyColumns, chapter_group)
          SELECT $_historyColumns, ${hasChapterGroup ? 'chapter_group' : 'NULL'}
          FROM history
        ''');
        _db.execute('DROP TABLE history');
        _db.execute('ALTER TABLE history_upgrade RENAME TO history');
      } else if (!hasChapterGroup) {
        _db.execute('ALTER TABLE history ADD COLUMN chapter_group INT');
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static const _insertHistorySql = '''
    INSERT OR REPLACE INTO history ($_historyColumns, chapter_group)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ''';

  static Future<void> _addHistoryAsync(int dbAddr, History newItem) {
    return Isolate.run(() {
      final db = sqlite3.fromPointer(ffi.Pointer.fromAddress(dbAddr));
      _writeHistory(db, newItem);
    });
  }

  bool _haveAsyncTask = false;

  /// Create a isolate to add history to prevent blocking the UI thread.
  Future<void> addHistoryAsync(History newItem) async {
    while (_haveAsyncTask) {
      await Future.delayed(Duration(milliseconds: 20));
    }

    _haveAsyncTask = true;
    try {
      await _addHistoryAsync(_db.handle.address, newItem);
      _rememberHistory(newItem);
    } finally {
      _haveAsyncTask = false;
    }
  }

  /// Add or update the reading progress for this comic.
  void addHistory(History newItem) {
    _writeHistory(_db, newItem);
    _rememberHistory(newItem);
  }

  static void _writeHistory(Database db, History newItem) {
    db.execute(_insertHistorySql, [
      newItem.id,
      newItem.title,
      newItem.subtitle,
      newItem.cover,
      newItem.time.millisecondsSinceEpoch,
      newItem.type.value,
      newItem.ep,
      newItem.page,
      newItem.readEpisode.join(','),
      newItem.maxPage,
      newItem.group,
    ]);
  }

  void _rememberHistory(History item) {
    final key = ComicID(item.type, item.id);
    _cachedHistoryKeys?.add(key);
    _recentHistories.remove(key);
    _recentHistories[key] = item;
    if (_recentHistories.length > 10) {
      _recentHistories.remove(_recentHistories.keys.first);
    }
    notifyListeners();
  }

  void clearHistory() {
    _db.execute("delete from history;");
    _updateCache();
    notifyListeners();
  }

void clearUnfavoritedHistory() {
  _db.execute('BEGIN TRANSACTION;');
  try {
    final idAndTypes = _db.select("""
      select id, type from history;
    """);
    for (var element in idAndTypes) {
      final id = element["id"] as String;
      final type = ComicType(element["type"] as int);
      if (!LocalFavoritesManager().isExist(id, type)) {
        _db.execute("""
          delete from history
          where id == ? and type == ?;
        """, [id, type.value]);
      }
    }
    _db.execute('COMMIT;');
  } catch (e) {
    _db.execute('ROLLBACK;');
    rethrow;
  }
  _updateCache();
  notifyListeners();
}

  void remove(String id, ComicType type) async {
    _db.execute("""
      delete from history
      where id == ? and type == ?;
    """, [id, type.value]);
    _updateCache();
    notifyListeners();
  }

  void _updateCache() {
    final keys = {
      for (final row in _db.select('SELECT id, type FROM history'))
        ComicID(ComicType(row['type'] as int), row['id'] as String),
    };
    _cachedHistoryKeys = keys;
    _recentHistories.removeWhere((key, _) => !keys.contains(key));
  }

  History? find(String id, ComicType type) {
    if (_cachedHistoryKeys == null) {
      _updateCache();
    }
    final key = ComicID(type, id);
    if (!_cachedHistoryKeys!.contains(key)) {
      return null;
    }
    final recent = _recentHistories[key];
    if (recent != null) return recent;

    final rows = _db.select(
      'SELECT * FROM history WHERE id = ? AND type = ?',
      [id, type.value],
    );
    return rows.isEmpty ? null : History.fromRow(rows.first);
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }

  void close() {
    if (!isInitialized) return;
    isInitialized = false;
    _cachedHistoryKeys = null;
    _recentHistories.clear();
    _db.dispose();
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute("""
          delete from history
          where id == ? and type == ?;
        """, [history.id, history.type.value]);
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    _updateCache();
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(History history) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return await _refreshSingleHistory(history);
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<bool> _refreshSingleHistory(History history) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return false;
    }

    int retries = 3;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(history.id);
        if (res.error) {
          await Future.delayed(const Duration(seconds: 2));
          retries--;
          if (retries == 0) {
            return false;
          }
          continue;
        }

        var comicDetails = res.data;
        // Update history info while keeping reading progress
        var updatedHistory = History.fromMap({
          'type': history.type.value,
          'time': history.time.millisecondsSinceEpoch,
          'title': comicDetails.title,
          'subtitle': comicDetails.subTitle ?? '',
          'cover': comicDetails.cover,
          'ep': history.ep,
          'page': history.page,
          'id': history.id,
          'readEpisode': history.readEpisode.toList(),
          'max_page': history.maxPage,
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return true;
      } catch (e, s) {
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        await Future.delayed(const Duration(seconds: 2));
        retries--;
        if (retries == 0) {
          return false;
        }
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  Stream<RefreshProgress> refreshAllHistoriesStream() {
    var controller = StreamController<RefreshProgress>();
    _refreshAllHistoriesBase(controller);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
  ) async {
    var histories = getAll();
    int total = histories.length;
    int current = 0;
    int success = 0;
    int failed = 0;
    int skipped = 0;

    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var historiesToRefresh = <History>[];
    for (var history in histories) {
      if (history.sourceKey == 'local') {
        skipped++;
        current++;
        controller.add(RefreshProgress(total, current, success, failed, skipped));
        continue;
      }
      historiesToRefresh.add(history);
    }

    total = historiesToRefresh.length;
    current = 0;
    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var channel = Channel<History>(10);

    () async {
      var c = 0;
      for (var history in historiesToRefresh) {
        await channel.push(history);
        c++;
        if (c % 5 == 0) {
          var delay = c % 100 + 1;
          if (delay > 10) {
            delay = 10;
          }
          await Future.delayed(Duration(seconds: delay));
        }
      }
      channel.close();
    }();

    var updateFutures = <Future>[];
    for (var i = 0; i < 5; i++) {
      var f = () async {
        while (true) {
          var history = await channel.pop();
          if (history == null) {
            break;
          }
          var result = await _refreshSingleHistory(history);
          current++;
          if (result) {
            success++;
          } else {
            failed++;
          }
          controller.add(
            RefreshProgress(total, current, success, failed, skipped),
          );
        }
      }();
      updateFutures.add(f);
    }

    await Future.wait(updateFutures);

    notifyListeners();
    controller.close();
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped,
  );
}
