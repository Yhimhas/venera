import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
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
    sync.onDataChanged(requireAutoSync: false);
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
    sync.onDataChanged(requireAutoSync: false);
    downloaded.complete(const Res(true));
    await download;

    expect(uploads, 0);
    expect(sync.isUploading, isFalse);
  });
}
