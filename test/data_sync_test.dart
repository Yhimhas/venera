import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  setUp(() {
    final previousConfig = appdata.settings['webdav'];
    final previousAutoSync = appdata.implicitData['webdavAutoSync'];
    addTearDown(() {
      appdata.settings['webdav'] = previousConfig;
      appdata.implicitData['webdavAutoSync'] = previousAutoSync;
    });
    appdata.settings['webdav'] = ['https://example.invalid/dav', '', ''];
    appdata.implicitData['webdavAutoSync'] = true;
  });

  test('saving settings with auto sync off only writes locally', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-sync-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    App.dataPath = directory.path;
    final previousSync = DataSync.instance;
    addTearDown(() => DataSync.instance = previousSync);
    final transfers = <String>[];
    final sync = DataSync.withTransfers(
      upload: () async {
        transfers.add('upload');
        return const Res(true);
      },
      download: () async {
        transfers.add('download');
        return const Res(true);
      },
    );
    DataSync.instance = sync;
    appdata.implicitData['webdavAutoSync'] = false;

    await appdata.saveData();

    expect(await File('${directory.path}/appdata.json').exists(), isTrue);
    expect(transfers, isEmpty);
    await sync.uploadData();
    await sync.downloadData();
    expect(transfers, ['upload', 'download']);

    appdata.implicitData['webdavAutoSync'] = true;
    await appdata.saveData();
    expect(transfers, ['upload', 'download', 'upload']);
  });

  test('disabling auto sync skips uploads still in the queue', () async {
    final uploaded = Completer<Res<bool>>();
    var uploads = 0;
    final sync = DataSync.withTransfers(
      upload: () {
        uploads++;
        return uploaded.future;
      },
      download: () async => const Res(true),
    );

    final active = sync.uploadData();
    sync.onDataChanged();
    appdata.implicitData['webdavAutoSync'] = false;
    uploaded.complete(const Res(true));
    await active;

    expect(uploads, 1);
    expect(sync.isUploading, isFalse);
  });

  test('automatic downloads respect the switch after waiting', () async {
    final uploaded = Completer<Res<bool>>();
    var downloads = 0;
    final sync = DataSync.withTransfers(
      upload: () => uploaded.future,
      download: () async {
        downloads++;
        return const Res(true);
      },
    );

    appdata.implicitData['webdavAutoSync'] = false;
    sync.downloadAutomatically();
    expect(downloads, 0);
    expect(sync.isConfigured, isTrue);

    appdata.implicitData['webdavAutoSync'] = true;
    final upload = sync.uploadData();
    sync.downloadAutomatically();
    appdata.implicitData['webdavAutoSync'] = false;
    uploaded.complete(const Res(true));
    await upload;

    expect(downloads, 0);
    expect(sync.isDownloading, isFalse);
  });

  test('a queued manual download survives disabling auto sync', () async {
    final uploaded = Completer<Res<bool>>();
    var downloads = 0;
    final sync = DataSync.withTransfers(
      upload: () => uploaded.future,
      download: () async {
        downloads++;
        return const Res(true);
      },
    );

    final upload = sync.uploadData();
    sync.downloadAutomatically();
    final manualDownload = sync.downloadData();
    appdata.implicitData['webdavAutoSync'] = false;
    uploaded.complete(const Res(true));
    await upload;

    expect((await manualDownload).data, isTrue);
    expect(downloads, 1);
  });

  test('publishes later changes before a waiting download', () async {
    final firstUpload = Completer<Res<bool>>();
    final nextUpload = Completer<Res<bool>>();
    final transfers = <String>[];
    var revision = 1;
    final sync = DataSync.withTransfers(
      upload: () {
        transfers.add('upload $revision');
        return revision == 1 ? firstUpload.future : nextUpload.future;
      },
      download: () async {
        transfers.add('download');
        return const Res(true);
      },
    );
    var wentIdleBeforeNextUpload = false;
    sync.addListener(() {
      if (revision > 1 && transfers.length == 1 && !sync.isUploading) {
        wentIdleBeforeNextUpload = true;
      }
    });

    final first = sync.uploadData();
    final download = sync.downloadData();
    revision = 2;
    sync.onDataChanged();
    final second = sync.uploadData();
    revision = 3;
    final third = sync.uploadData();
    expect(transfers, ['upload 1']);

    firstUpload.complete(const Res(true));
    expect((await first).success, isTrue);
    expect(transfers, ['upload 1', 'upload 3']);
    expect(wentIdleBeforeNextUpload, isFalse);

    nextUpload.complete(const Res.error('Upload rejected'));
    expect((await second).errorMessage, 'Upload rejected');
    expect((await third).errorMessage, 'Upload rejected');
    expect((await download).success, isTrue);
    expect(transfers, ['upload 1', 'upload 3', 'download']);
  });

  test(
    'manual upload waits for the current download and returns its result',
    () async {
      final downloaded = Completer<Res<bool>>();
      final uploaded = Completer<Res<bool>>();
      var uploads = 0;
      final sync = DataSync.withTransfers(
        upload: () {
          uploads++;
          return uploaded.future;
        },
        download: () => downloaded.future,
      );

      final download = sync.downloadData();
      final upload = sync.uploadData();
      expect(uploads, 0);

      downloaded.complete(const Res(true));
      await download;
      expect(uploads, 1);

      uploaded.completeError(StateError('Upload rejected'));
      expect((await upload).errorMessage, contains('Upload rejected'));
      expect(sync.lastError, contains('Upload rejected'));
      expect(sync.isUploading, isFalse);
    },
  );

  test('restore notifications do not queue an automatic upload', () async {
    final downloaded = Completer<Res<bool>>();
    var uploads = 0;
    final sync = DataSync.withTransfers(
      upload: () async {
        uploads++;
        return const Res(true);
      },
      download: () => downloaded.future,
    );

    final download = sync.downloadData();
    sync.onDataChanged();
    downloaded.complete(const Res(true));
    await download;

    expect(uploads, 0);
    expect(sync.isUploading, isFalse);
  });
}
