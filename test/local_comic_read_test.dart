import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  final comic = LocalComic(
    id: 'local-grouped-comic',
    title: 'Grouped comic',
    subtitle: '',
    tags: [],
    directory: 'grouped',
    chapters: const ComicChapters.grouped({
      'Volume 1': {'a': 'Chapter A', 'b': 'Chapter B'},
      'Volume 2': {'c': 'Chapter C', 'd': 'Chapter D'},
    }),
    cover: '',
    comicType: ComicType.local,
    downloadedChapters: ['d', 'b'],
    createdAt: DateTime(2026),
  );

  Future<Reader> openComic(WidgetTester tester, {History? history}) async {
    final previousManager = HistoryManager.cache;
    HistoryManager.cache = _TestHistoryManager(history);
    addTearDown(() => HistoryManager.cache = previousManager);
    final observer = _ReaderRouteObserver();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      navigatorObservers: [observer],
      home: const SizedBox(),
    ));
    comic.read();
    final route = observer.readerRoute;
    final reader = route.builder(App.rootContext) as Reader;
    App.rootNavigatorKey.currentState!.removeRoute(route);
    return reader;
  }

  testWidgets('opens the earliest downloaded chapter in reading order', (
    tester,
  ) async {
    final reader = await openComic(tester);
    expect(reader.initialChapter, 2);
    expect(reader.initialChapterGroup, isNull);
  });

  testWidgets('resumes legacy history with its absolute chapter number', (
    tester,
  ) async {
    final reader = await openComic(
      tester,
      history: History.fromModel(model: comic, ep: 4, page: 3),
    );
    expect(reader.initialChapter, 4);
    expect(reader.initialChapterGroup, isNull);
    expect(reader.initialPage, 3);
  });

  testWidgets('keeps the stored group and its relative chapter number', (
    tester,
  ) async {
    final reader = await openComic(
      tester,
      history: History.fromModel(model: comic, group: 2, ep: 1, page: 2),
    );
    expect(reader.initialChapter, 1);
    expect(reader.initialChapterGroup, 2);
    expect(reader.initialPage, 2);
  });
}

class _ReaderRouteObserver extends NavigatorObserver {
  late AppPageRoute<dynamic> readerRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is AppPageRoute<dynamic>) readerRoute = route;
  }
}

class _TestHistoryManager extends HistoryManager {
  _TestHistoryManager(this.history) : super.create();

  final History? history;

  @override
  History? find(String id, ComicType type) => history;
}
