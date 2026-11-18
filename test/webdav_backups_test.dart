import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/webdav_backups.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

void main() {
  final bytes = Uint8List.fromList([1, 2, 3]);

  test(
    'a failed PUT preserves existing backups and removes its partial upload',
    () async {
      final client = _Client(['20000-7.venera', '19999-6.venera'])
        ..failPut = true;
      final backups = WebDavBackups(client);
      final existing = await backups.list();
      final next = WebDavBackups.next(existing, localVersion: 7, day: 20000);

      await expectLater(
        backups.publish(next, bytes, existing),
        throwsStateError,
      );
      expect(
        client.files.keys,
        unorderedEquals(['20000-7.venera', '19999-6.venera']),
      );
      expect(
        client.operations.where((event) => event.startsWith('DELETE ')).single,
        matches(r'^DELETE venera-upload-.*\.part$'),
      );
    },
  );

  test(
    'a MOVE conflict preserves both the previous and competing backup',
    () async {
      final client = _Client(['20000-7.venera']);
      final backups = WebDavBackups(client);
      final existing = await backups.list();
      final next = WebDavBackups.next(existing, localVersion: 7, day: 20000);
      client.files[next.name] = Uint8List.fromList([9]);

      await expectLater(
        backups.publish(next, bytes, existing),
        throwsStateError,
      );
      expect(client.files.keys, unorderedEquals(['20000-7.venera', next.name]));
      expect(client.files[next.name], [9]);
    },
  );

  test('a successful upload prunes only superseded managed backups', () async {
    final client = _Client([
      '20000-9.venera',
      '20000-10.venera',
      for (var index = 1; index <= 10; index++)
        '${20000 - index}-${10 - index}.venera',
      'manual.venera',
    ]);
    final backups = WebDavBackups(client);
    final existing = await backups.list();
    final next = WebDavBackups.next(existing, localVersion: 3, day: 20000);

    await backups.publish(next, bytes, existing);

    expect(next.version, 11);
    expect(
      client.operations.indexWhere((event) => event.startsWith('MOVE ')),
      lessThan(
        client.operations.indexWhere((event) => event.startsWith('DELETE ')),
      ),
    );
    expect(
      client.files.keys,
      unorderedEquals([
        next.name,
        for (var index = 1; index <= 9; index++)
          '${20000 - index}-${10 - index}.venera',
        'manual.venera',
      ]),
    );
    expect(client.files[next.name], bytes);
  });

  test(
    'orders backup versions numerically and skips unrelated entries',
    () async {
      final client = _Client([
        '20000-9.venera',
        '20000-10.venera',
        '19999-11.venera',
        'manual.venera',
      ]);
      client.otherEntries.add(dav.File(name: '20001-90.venera', isDir: true));
      client.otherEntries.add(dav.File());
      final existing = await WebDavBackups(client).list();
      expect(existing.map((backup) => backup.version), [11, 10, 9]);
      expect(
        WebDavBackups.next(existing, localVersion: 3, day: 20001).version,
        12,
      );
    },
  );

  test(
    'a cleanup permission failure does not fail a published upload',
    () async {
      const previous = '20000-7.venera';
      final client = _Client([previous])..failDelete.add(previous);
      final backups = WebDavBackups(client);
      final existing = await backups.list();
      final next = WebDavBackups.next(existing, localVersion: 7, day: 20000);

      await backups.publish(next, bytes, existing);
      expect(client.files.keys, unorderedEquals([previous, next.name]));
      expect(client.files[next.name], bytes);
      expect(
        client.operations.where((operation) => operation.startsWith('DELETE')),
        ['DELETE $previous'],
      );
    },
  );
}

class _Client implements dav.Client {
  _Client(Iterable<String> paths)
    : files = {
        for (final path in paths) path: Uint8List.fromList([0]),
      };

  final Map<String, Uint8List> files;
  final otherEntries = <dav.File>[];
  final operations = <String>[];
  final failDelete = <String>{};
  bool failPut = false;

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async => [
    for (final name in files.keys) dav.File(name: name, isDir: false),
    ...otherEntries,
  ];

  @override
  Future<void> write(
    String path,
    Uint8List data, {
    void Function(int, int)? onProgress,
    CancelToken? cancelToken,
  }) async {
    operations.add('PUT $path');
    if (failPut) {
      files[path] = Uint8List.fromList([data.first]);
      throw StateError('PUT failed');
    }
    files[path] = data;
  }

  @override
  Future<void> rename(
    String oldPath,
    String newPath,
    bool overwrite, [
    CancelToken? cancelToken,
  ]) async {
    operations.add('MOVE $oldPath $newPath');
    if (!overwrite && files.containsKey(newPath)) {
      throw StateError('MOVE conflict');
    }
    files[newPath] = files.remove(oldPath)!;
  }

  @override
  Future<void> remove(String path, [CancelToken? cancelToken]) async {
    operations.add('DELETE $path');
    if (failDelete.contains(path)) throw StateError('DELETE forbidden');
    files.remove(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
