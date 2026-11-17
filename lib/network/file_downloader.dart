import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';

class FileDownloader {
  final String url;
  final String savePath;
  final int maxConcurrent;
  final String? sourceKey;

  FileDownloader(
    this.url,
    this.savePath, {
    this.maxConcurrent = 4,
    this.sourceKey,
  }) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent');
    }
  }

  late final _dio = Dio(BaseOptions(extra: {proxySourceKey: sourceKey}))
    ..httpClientAdapter = RHttpAdapter();
  final _cancelToken = CancelToken();
  Future<void>? _run;
  bool _stopped = false;
  RandomAccessFile? _file;
  Completer<void>? _writing;
  late List<_DownloadBlock> _blocks;
  late int _fileSize;
  int _currentBytes = 0;
  int _lastBytes = 0;

  File get _checkpoint => File('$savePath.download');

  Future<void> _writeStatus() async {
    final temporary = File('${_checkpoint.path}.tmp');
    await temporary.writeAsString(_blocks.join('\n'), flush: true);
    await temporary.rename(_checkpoint.path);
  }

  Future<List<_DownloadBlock>?> _readStatus() async {
    if (!await _checkpoint.exists()) return null;
    final lines = await _checkpoint.readAsLines();
    final blocks = <_DownloadBlock>[];
    var nextStart = 0;
    for (final line in lines) {
      final fields = line.split('-');
      if (fields.length != 3) return null;
      final start = int.tryParse(fields[0]);
      final end = int.tryParse(fields[1]);
      final downloaded = int.tryParse(fields[2]);
      if (start != nextStart ||
          end == null ||
          end <= nextStart ||
          end > _fileSize ||
          downloaded == null ||
          downloaded < 0 ||
          downloaded > end - nextStart) {
        return null;
      }
      blocks.add(_DownloadBlock(nextStart, end, downloaded));
      nextStart = end;
    }
    return nextStart == _fileSize ? blocks : null;
  }

  Future<void> _prepareDownload() async {
    final response = await _dio.head<void>(
      url,
      options: Options(headers: {HttpHeaders.acceptEncodingHeader: 'identity'}),
      cancelToken: _cancelToken,
    );
    if (_stopped) return;
    final size = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    if (size == null || size <= 0) {
      throw const FormatException('Archive has no valid Content-Length');
    }
    _fileSize = size;
    final file = File(savePath);
    final restored = await file.exists() && await file.length() == size
        ? await _readStatus()
        : null;
    if (_stopped) return;
    if (restored != null) {
      _blocks = restored;
      _currentBytes = restored.fold(
        0,
        (total, block) => total + block.downloadedBytes,
      );
      _file = await file.open(mode: FileMode.append);
      return;
    }

    const mib = 1024 * 1024;
    final chunkSize = switch (size) {
      > 1024 * mib => 64 * mib,
      > 512 * mib => 32 * mib,
      _ => 16 * mib,
    };
    _blocks = [
      for (var start = 0; start < size; start += chunkSize)
        _DownloadBlock(start, min(start + chunkSize, size), 0),
    ];
    await file.parent.create(recursive: true);
    // Clear any stale progress before resetting the staging file.
    await _writeStatus();
    _file = await file.open(mode: FileMode.write);
    await _file!.truncate(size);
  }

  Stream<DownloadingStatus> start() {
    if (_run != null) {
      throw StateError('This archive download has already started');
    }
    final progress = StreamController<DownloadingStatus>(onCancel: stop);
    _run = _download(progress);
    return progress.stream;
  }

  Future<void> stop() async {
    _stopped = true;
    _cancelToken.cancel();
    await _run;
  }

  Future<void> _download(StreamController<DownloadingStatus> progress) async {
    Timer? timer;
    try {
      try {
        if (_stopped) return;
        await _prepareDownload();
        if (_stopped) return;
        if (_currentBytes < _fileSize) {
          _lastBytes = _currentBytes;
          progress.add(DownloadingStatus(_currentBytes, _fileSize, 0));
          timer = Timer.periodic(const Duration(seconds: 1), (_) {
            progress.add(
              DownloadingStatus(
                _currentBytes,
                _fileSize,
                _currentBytes - _lastBytes,
              ),
            );
            _lastBytes = _currentBytes;
          });
          await _downloadBlocks();
        }
      } finally {
        timer?.cancel();
        await _file?.close();
        _file = null;
      }

      if (_stopped) return;
      if (_currentBytes != _fileSize) {
        throw FormatException(
          'Expected $_fileSize archive bytes, downloaded $_currentBytes',
        );
      }
      await _checkpoint.delete();
      progress.add(DownloadingStatus(_currentBytes, _fileSize, 0, true));
    } catch (error, stack) {
      if (!_stopped) progress.addError(error, stack);
    } finally {
      unawaited(progress.close());
    }
  }

  Future<void> _downloadBlocks() async {
    final pending = _blocks.where((block) => block.remaining > 0).iterator;
    Future<void> worker() async {
      try {
        while (!_cancelToken.isCancelled && pending.moveNext()) {
          await _fetchBlock(pending.current);
        }
      } catch (error) {
        if (_cancelToken.isCancelled) return;
        _cancelToken.cancel();
        rethrow;
      }
    }

    // Wait for all writers before closing the file, including after an error.
    await Future.wait([
      for (var i = 0; i < min(maxConcurrent, _blocks.length); i++) worker(),
    ]);
  }

  Future<void> _fetchBlock(_DownloadBlock block) async {
    final start = block.start + block.downloadedBytes;
    final end = block.end - 1;
    final expected = block.remaining;
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          HttpHeaders.rangeHeader: 'bytes=$start-$end',
          HttpHeaders.acceptEncodingHeader: 'identity',
        },
      ),
      cancelToken: _cancelToken,
    );
    final range = _rangePattern.firstMatch(
      response.headers.value(HttpHeaders.contentRangeHeader)?.trim() ?? '',
    );
    final validRange =
        response.statusCode == HttpStatus.partialContent &&
        range != null &&
        int.tryParse(range[1]!) == start &&
        int.tryParse(range[2]!) == end &&
        int.tryParse(range[3]!) == _fileSize;
    final wholeFile =
        response.statusCode == HttpStatus.ok &&
        start == 0 &&
        expected == _fileSize;
    if (!validRange && !wholeFile) {
      throw FormatException('Server did not return archive bytes $start-$end');
    }

    final buffer = <int>[];
    var received = 0;
    await for (final data in response.data!.stream) {
      if (_cancelToken.isCancelled) return;
      received += data.length;
      if (received > expected) {
        throw FormatException(
          'Archive range $start-$end exceeded $expected bytes',
        );
      }
      buffer.addAll(data);
      if (buffer.length >= 16 * 1024) {
        await _writeChunk(block, buffer);
        buffer.clear();
      }
    }
    if (_cancelToken.isCancelled) return;
    if (buffer.isNotEmpty) await _writeChunk(block, buffer);
    if (received != expected) {
      throw FormatException(
        'Archive range $start-$end returned $received of $expected bytes',
      );
    }
  }

  static final _rangePattern = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  );

  Future<void> _writeChunk(_DownloadBlock block, List<int> data) async {
    while (_writing != null) {
      await _writing!.future;
    }
    if (_cancelToken.isCancelled) return;
    final lock = _writing = Completer<void>();
    try {
      final file = _file!;
      await file.setPosition(block.start + block.downloadedBytes);
      await file.writeFrom(data);
      block.downloadedBytes += data.length;
      _currentBytes += data.length;
      await _writeStatus();
    } finally {
      _writing = null;
      lock.complete();
    }
  }
}

class DownloadingStatus {
  /// The current downloaded bytes
  final int downloadedBytes;

  /// The total bytes of the file
  final int totalBytes;

  /// Whether the download is finished
  final bool isFinished;

  /// The download speed in bytes per second
  final int bytesPerSecond;

  const DownloadingStatus(
    this.downloadedBytes,
    this.totalBytes,
    this.bytesPerSecond, [
    this.isFinished = false,
  ]);

  @override
  String toString() {
    return "Downloaded: $downloadedBytes/$totalBytes ${isFinished ? "Finished" : ""}";
  }
}

class _DownloadBlock {
  final int start;
  final int end;
  int downloadedBytes;

  _DownloadBlock(this.start, this.end, this.downloadedBytes);

  int get remaining => end - start - downloadedBytes;

  @override
  String toString() => '$start-$end-$downloadedBytes';
}
