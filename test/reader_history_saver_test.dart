import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/reader/history_saver.dart';

void main() {
  History progress(int page) => History.fromMap({
    'id': 'comic',
    'type': 0,
    'title': 'Comic',
    'subtitle': '',
    'cover': '',
    'time': 1,
    'ep': 2,
    'page': page,
  });

  testWidgets('closing before the timer saves the latest page before syncing', (
    tester,
  ) async {
    final savedPages = <int>[];
    final written = Completer<void>();
    final saver = ReaderHistorySaver((history) {
      savedPages.add(history.page);
      return written.future;
    });
    var syncCount = 0;
    saver.schedule(progress(8));
    saver.schedule(progress(9));
    final closing = saver.close(() => syncCount++);
    await tester.pump();
    final pagesAtClose = savedPages.toList();
    final syncsBeforeWrite = syncCount;
    written.complete();
    await tester.pump(const Duration(seconds: 1));
    await closing;

    expect(pagesAtClose, [9]);
    expect(syncsBeforeWrite, 0);
    expect(syncCount, 1);
    expect(savedPages, [9]);
  });

  testWidgets('closing waits for a write already started by the timer', (
    tester,
  ) async {
    final written = Completer<void>();
    var writeCount = 0;
    final saver = ReaderHistorySaver((history) {
      writeCount++;
      return written.future;
    });
    saver.schedule(progress(9));
    await tester.pump(const Duration(seconds: 1));
    expect(writeCount, 1);

    var synced = false;
    final closing = saver.close(() => synced = true);
    await tester.pump();
    final syncedBeforeWrite = synced;
    written.complete();
    await closing;
    expect(syncedBeforeWrite, isFalse);
    expect(synced, isTrue);
    expect(writeCount, 1);
  });

  testWidgets('a failed save does not start sync when the reader closes', (
    tester,
  ) async {
    final saver = ReaderHistorySaver(
      (_) async => throw StateError('Disk unavailable'),
    );
    saver.schedule(progress(9));
    var synced = false;
    final closing = saver.close(() => synced = true);
    await tester.pump(const Duration(seconds: 1));
    await closing;
    expect(synced, isFalse);
  });

  testWidgets('keeps debouncing page changes while the reader is open', (
    tester,
  ) async {
    final savedPages = <int>[];
    final saver = ReaderHistorySaver(
      (history) async => savedPages.add(history.page),
    );
    saver.schedule(progress(8));
    await tester.pump(const Duration(milliseconds: 500));
    saver.schedule(progress(9));
    await tester.pump(const Duration(milliseconds: 500));
    expect(savedPages, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(savedPages, [9]);
    await saver.close(() {});
  });
}
