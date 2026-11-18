import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart' show CancelToken;
import 'package:venera/network/images.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  @override
  void cancel() async {
    if (_discarded) return;
    _discarded = true;
    _isRunning = false;
    stopRecorder();
    _cancelWorkers();
    try {
      await _waitForWorkers();
      final downloadPath = path;
      if (downloadPath == null) return;
      final local = LocalManager().find(id, comicType);
      if (local == null) {
        await Directory(downloadPath).deleteIfExists(recursive: true);
      } else {
        final downloadedFolders = local.downloadedChapters
            .map(LocalManager.getChapterDirectoryName)
            .map((name) => name.toLowerCase())
            .toSet();
        for (final chapter in chapters ?? const <String>[]) {
          final folder = LocalManager.getChapterDirectoryName(chapter);
          if (folder.isEmpty ||
              folder == '.' ||
              folder == '..' ||
              downloadedFolders.contains(folder.toLowerCase())) {
            continue;
          }
          final directory = Directory(FilePath.join(downloadPath, folder));
          await directory.deleteIfExists(recursive: true);
        }
      }
    } on FileSystemException catch (error, stack) {
      Log.error('Download', 'Failed to delete download files: $error', stack);
    } finally {
      LocalManager().removeTask(this);
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _message = "Paused";
    _cancelWorkers();
    stopRecorder();
    notifyListeners();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  bool _isRunning = false;

  bool _isError = false;

  bool _discarded = false;

  int _runId = 0;

  bool _isCurrent(int runId) => _isRunning && _runId == runId;

  String _message = "Fetching comic info...";

  String? _cover;

  /// Complete image lists, keyed by chapter ID (empty for chapterless comics).
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  final tasks = <int, _ImageDownloadWrapper>{};
  final _activeWorkers = <_ImageDownloadWrapper>{};

  void _cancelWorkers() {
    for (final worker in _activeWorkers) {
      worker.cancel();
    }
  }

  Future<void> _waitForWorkers() async {
    await Future.wait(_activeWorkers.map((worker) => worker.wait()));
  }

  int get _maxConcurrentTasks =>
      (appdata.settings["downloadThreads"] as num).toInt();

  void _scheduleTasks(int runId) {
    if (!_isCurrent(runId)) return;
    var images = _images![_images!.keys.elementAt(_chapter)]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      final existing = tasks[i];
      if (existing != null) {
        if (!existing.isComplete && existing.error == null) {
          downloading++;
        }
        continue;
      }
      Directory saveTo;
      if (comic!.chapters != null) {
        saveTo = Directory(FilePath.join(
          path!,
          LocalManager.getChapterDirectoryName(
            _images!.keys.elementAt(_chapter),
          ),
        ));
        if (!saveTo.existsSync()) {
          saveTo.createSync(recursive: true);
        }
      } else {
        saveTo = Directory(path!);
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
      );
      tasks[i] = task;
      _activeWorkers.add(task);
      task.wait().then((completedTask) {
        _activeWorkers.remove(completedTask);
        if (completedTask.isComplete && identical(tasks[i], completedTask)) {
          _scheduleTasks(runId);
        }
      });
      downloading++;
    }
  }

  @override
  void resume() async {
    if (_isRunning || _discarded) return;
    final runId = ++_runId;
    _isError = false;
    _message = "Resuming...";
    _isRunning = true;
    notifyListeners();
    if (_activeWorkers.isNotEmpty) await _waitForWorkers();
    if (!_isCurrent(runId)) return;
    runRecorder();

    if (comic == null) {
      _message = "Fetching comic info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isCurrent(runId)) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        if (!_isCurrent(runId)) return;
        path = dir.path;
      } catch (e, s) {
        if (!_isCurrent(runId)) return;
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();
    if (!_isCurrent(runId)) return;

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress
            in ImageDownloader.loadThumbnail(comic!.cover, source.key)) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (!_isCurrent(runId)) return null;
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (!_isCurrent(runId)) return;
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
      if (!_isCurrent(runId)) return;
    }

    if (_images == null) {
      final chapterIds = _selectedChapterIds.toList();
      final images = <String, List<String>>{};
      var totalCount = 0;
      for (final chapterId in chapterIds) {
        _message = chapterId == null
            ? "Fetching image list..."
            : "Fetching image list (${images.length}/${chapterIds.length})...";
        notifyListeners();
        if (!_isCurrent(runId)) return;
        final res = await _runWithRetry(() async {
          final result = await source.loadComicPages!(comicId, chapterId);
          if (result.error) throw result.errorMessage!;
          return result.data;
        });
        if (!_isCurrent(runId)) return;
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        }
        final pages = res.data;
        images[chapterId ?? ''] = pages;
        totalCount += pages.length;
      }
      _images = images;
      _totalCount = totalCount;
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
      if (!_isCurrent(runId)) return;
    }

    while (_chapter < _images!.length) {
      var images = _images![_images!.keys.elementAt(_chapter)]!;
      tasks.clear();
      while (_index < images.length) {
        _scheduleTasks(runId);
        var task = tasks[_index]!;
        await task.wait();
        if (!_isCurrent(runId)) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          _setError("Error: ${task.error}");
          return;
        }
        _index++;
        _downloadedCount++;
        _message = "$_downloadedCount/$_totalCount";
        await LocalManager().saveCurrentDownloadingTasks();
        if (!_isCurrent(runId)) return;
      }
      _index = 0;
      _chapter++;
    }

    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    _cancelWorkers();
    stopRecorder();
    notifyListeners();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  Iterable<String?> get _selectedChapterIds {
    final comicChapters = comic?.chapters;
    if (comicChapters == null) return const [null];
    final ids = comicChapters.allChapters.keys;
    final selected = chapters;
    return selected == null ? ids : ids.where(selected.contains);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    final source = ComicSource.find(json["source"]);
    if (source == null) return null;
    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    final task = ImagesDownloadTask(
      source: source,
      comicId: json["comicId"],
      comic:
          json["comic"] == null ? null : ComicDetails.fromJson(json["comic"]),
      chapters: ListOrNull.from(json["chapters"]),
    )
      ..path = json["path"]
      .._cover = json["cover"];
    final savedImages = images;
    // Older builds could save a partial list before fetching every chapter.
    if (savedImages != null &&
        task._selectedChapterIds.every(
          (id) => savedImages.containsKey(id ?? ''),
        )) {
      task
        .._images = savedImages
        .._downloadedCount = json["downloadedCount"]
        .._totalCount = json["totalCount"]
        .._index = json["index"]
        .._chapter = json["chapter"];
    }
    return task;
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: chapters ?? comic?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(Future<T> Function() task,
    {int retry = 3}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;
  final String chapter;
  final int index;
  final String image;
  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  );

  bool isComplete = false;
  String? error;
  final _cancelToken = CancelToken();
  late final Future<_ImageDownloadWrapper> _result = _download();

  void cancel() => _cancelToken.cancel();

  Future<_ImageDownloadWrapper> wait() => _result;

  Future<_ImageDownloadWrapper> _download() async {
    const attempts = 3;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (_cancelToken.isCancelled) break;
      var lastBytes = 0;
      var written = false;
      try {
        await for (final progress in ImageDownloader.loadComicImageUnwrapped(
          image,
          task.source.key,
          task.comicId,
          chapter,
          cancelToken: _cancelToken,
        )) {
          if (_cancelToken.isCancelled) return this;
          task.onData(progress.currentBytes - lastBytes);
          lastBytes = progress.currentBytes;
          final bytes = progress.imageBytes;
          if (bytes == null) continue;

          final fileType = detectFileType(bytes);
          final file = saveTo.joinFile('$index${fileType.ext}');
          await file.writeAsBytes(bytes);
          written = true;
          break;
        }
        if (_cancelToken.isCancelled) break;
        if (written) {
          isComplete = true;
          return this;
        }
        throw const FormatException('Image download ended without data');
      } catch (e, stack) {
        if (_cancelToken.isCancelled) break;
        Log.error('Download', e.toString(), stack);
        if (attempt == attempts) error = e.toString();
      }
    }
    return this;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;
  Future<void>? _run;
  int _runId = 0;
  bool _discarded = false;
  bool _archiveReady = false;
  late final _archiveFile = File(
    FilePath.join(
      App.dataPath,
      'archive-downloads',
      '${sha256.convert(utf8.encode(jsonEncode([source.key, comic.id, archiveUrl])))}.zip',
    ),
  );

  bool _isCurrent(int runId) => _isRunning && _runId == runId;

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _speed = 0;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    if (_discarded) return;
    _discarded = true;
    ++_runId;
    _isRunning = false;
    await _downloader?.stop();
    await _run;
    await _deleteStagingFiles();
    if (path != null) {
      await Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    ++_runId;
    _isRunning = false;
    _message = "Paused";
    _speed = 0;
    _downloader?.stop();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() {
    if (_isRunning || _discarded) {
      return;
    }
    final runId = ++_runId;
    _isError = false;
    _isRunning = true;
    _message = "Downloading...";
    final previous = _run;
    _run = _runArchive(runId, previous);
    notifyListeners();
  }

  Future<void> _runArchive(int runId, Future<void>? previous) async {
    try {
      await previous;
      if (!_isCurrent(runId)) return;

      if (path == null) {
        final dir = await LocalManager().findValidDirectory(
          comic.id,
          comicType,
          comic.title,
        );
        path = dir.path;
        if (!(await dir.exists())) {
          await dir.create();
        }
        await LocalManager().saveCurrentDownloadingTasks();
      }
      if (!_isCurrent(runId)) return;

      if (!_archiveReady || !await _archiveFile.exists()) {
        if (!_isCurrent(runId)) return;
        _archiveReady = false;
        Log.info("Download", "Downloading $archiveUrl");
        final downloader = _downloader = FileDownloader(
          archiveUrl,
          _archiveFile.path,
          sourceKey: source.key,
          retainCheckpoint: true,
        );
        await for (final status in downloader.start()) {
          if (status.isFinished) _archiveReady = true;
          if (!_isCurrent(runId)) return;
          _currentBytes = status.downloadedBytes;
          _expectedBytes = status.totalBytes;
          _message =
              "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
          _speed = status.bytesPerSecond;
          notifyListeners();
        }
      }
      if (!_isCurrent(runId)) return;
      if (!_archiveReady) {
        _setError("Error: Download failed");
        return;
      }

      try {
        await _extractArchive(_archiveFile.path, path!);
      } catch (e) {
        if (_isCurrent(runId)) _setError("Failed to extract archive: $e");
        return;
      }
      if (!_isCurrent(runId)) return;
      final saved = await LocalManager().completeTask(this);
      _isRunning = false;
      if (saved) await _deleteStagingFiles();
    } catch (e) {
      if (_isCurrent(runId)) _setError("Error: $e");
    } finally {
      _downloader = null;
    }
  }

  Future<void> _deleteStagingFiles() async {
    await _archiveFile.deleteIgnoreError();
    await File('${_archiveFile.path}.download').deleteIgnoreError();
    await File('${_archiveFile.path}.download.tmp').deleteIgnoreError();
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      final temporary = await Directory(App.cachePath).createTemp('archive-');
      final cacheDir = temporary.path;
      try {
        await Isolate.run(() {
          ZipFile.openAndExtract(archive, cacheDir);
        });
        await copyDirectoryIsolate(temporary, out);
      } finally {
        await temporary.deleteIgnoreError(recursive: true);
      }
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    final comic = ComicDetails.fromJson(json["comic"]);
    if (ComicSource.find(comic.sourceKey) == null) return null;
    return ArchiveDownloadTask(json["archiveUrl"], comic)..path = json["path"];
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
