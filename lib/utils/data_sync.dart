import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/webdav_backups.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

class DataSync with ChangeNotifier {
  DataSync._() : _uploadOverride = null, _downloadOverride = null {
    if (isEnabled) {
      downloadData();
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  @visibleForTesting
  DataSync.withTransfers({
    required Future<Res<bool>> Function() upload,
    required Future<Res<bool>> Function() download,
  }) : _uploadOverride = upload,
       _downloadOverride = download;

  final Future<Res<bool>> Function()? _uploadOverride;
  final Future<Res<bool>> Function()? _downloadOverride;

  void onDataChanged({bool requireAutoSync = true}) {
    // Restoring a backup also emits local change notifications.
    if (!isDownloading && (!requireAutoSync || isEnabled)) {
      unawaited(uploadData());
    }
  }

  bool _handleWindowClose() {
    if (_hasUploadToFinish) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    while (_hasUploadToFinish) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  Completer<Res<bool>>? _pendingUpload;
  Completer<Res<bool>>? _pendingDownload;
  bool get _hasUploadToFinish => _isUploading || _pendingUpload != null;

  String? _lastError;

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
  }

  List<String>? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return [];
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    return List.from(config);
  }

  Future<Res<bool>> uploadData() {
    final request = _pendingUpload ??= Completer<Res<bool>>();
    _startNextTransfer();
    return request.future;
  }

  Future<Res<bool>> downloadData() {
    final request = _pendingDownload ??= Completer<Res<bool>>();
    _startNextTransfer();
    return request.future;
  }

  void _startNextTransfer() {
    if (_isUploading || _isDownloading) return;
    // Publish outstanding local changes before checking for another backup.
    final upload = _pendingUpload != null;
    final request = _pendingUpload ?? _pendingDownload;
    if (request == null) {
      notifyListeners();
      return;
    }
    if (upload) {
      _pendingUpload = null;
    } else {
      _pendingDownload = null;
    }
    _isUploading = upload;
    _isDownloading = !upload;
    _lastError = null;
    notifyListeners();
    unawaited(_finishTransfer(request, upload: upload));
  }

  Future<void> _finishTransfer(
    Completer<Res<bool>> request, {
    required bool upload,
  }) async {
    Res<bool> result;
    try {
      final transfer = upload
          ? _uploadOverride ?? _uploadData
          : _downloadOverride ?? _downloadData;
      result = await transfer();
    } catch (error, stack) {
      Log.error(upload ? 'Upload Data' : 'Data Sync', error, stack);
      result = Res.error(error.toString());
    }
    _lastError = result.errorMessage;
    request.complete(result);
    _isUploading = false;
    _isDownloading = false;
    _startNextTransfer();
  }

  Future<Res<bool>> _uploadData() async {
    var config = _validateConfig();
    if (config == null) {
      return const Res.error('Invalid WebDAV configuration');
    }
    if (config.isEmpty) {
      return const Res(true);
    }
    String url = config[0];
    String user = config[1];
    String pass = config[2];

    var client = newClient(
      url,
      user: user,
      password: pass,
      adapter: RHttpAdapter(),
    );

    File? data;
    try {
      final backups = WebDavBackups(client);
      final existing = await backups.list();
      final backup = WebDavBackups.next(
        existing,
        localVersion: appdata.dataVersion,
        day: DateTime.now().millisecondsSinceEpoch ~/ 86400000,
      );
      await appdata.saveData(false);
      data = await exportAppData(
        sync: appdata.settings['disableSyncFields'].toString().isNotEmpty,
        dataVersion: backup.version,
      );
      await backups.publish(backup, await data.readAsBytes(), existing);
      appdata.settings['dataVersion'] = backup.version;
      await appdata.saveData(false);
      Log.info("Upload Data", "Data uploaded successfully");
      return const Res(true);
    } finally {
      await data?.deleteIgnoreError();
    }
  }

  Future<Res<bool>> _downloadData() async {
    var config = _validateConfig();
    if (config == null) {
      return const Res.error('Invalid WebDAV configuration');
    }
    if (config.isEmpty) {
      return const Res(true);
    }
    String url = config[0];
    String user = config[1];
    String pass = config[2];

    var client = newClient(
      url,
      user: user,
      password: pass,
      adapter: RHttpAdapter(),
    );

    Directory? staging;
    try {
      final backup = (await WebDavBackups(client).list()).firstOrNull;
      if (backup == null) {
        throw 'No data file found';
      }
      if (backup.version <= appdata.dataVersion) {
        Log.info("Data Sync", 'No new data to download');
        return const Res(true);
      }
      Log.info("Data Sync", "Downloading data from WebDAV server");
      staging = await Directory(App.cachePath).createTemp('venera-sync-');
      final localFile = staging.joinFile('data.venera');
      await client.read2File(backup.name, localFile.path);
      await importAppData(localFile, true);
      Log.info("Data Sync", "Data downloaded successfully");
      return const Res(true);
    } finally {
      await staging?.deleteIgnoreError(recursive: true);
    }
  }
}
