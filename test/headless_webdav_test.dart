import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/headless.dart';
import 'package:venera/utils/data_sync.dart';

Future<({int code, List<Map<String, dynamic>> events})> runCommand(
  String? operation,
) async {
  const prefix = '[CLI PRINT] ';
  final events = <Map<String, dynamic>>[];
  final code = await runZoned(
    () => runWebDavCommand(operation),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (line.startsWith(prefix)) {
          events.add(jsonDecode(line.substring(prefix.length)));
        }
      },
    ),
  );
  return (code: code, events: events);
}

void main() {
  setUp(() {
    final previousSync = DataSync.instance;
    final previousConfig = appdata.settings['webdav'];
    final previousImplicitData = appdata.implicitData;
    final previousHeadless = App.isHeadless;
    App.isHeadless = true;
    appdata.implicitData = {'webdavAutoSync': true};
    DataSync.instance = null;
    addTearDown(() {
      DataSync.instance = previousSync;
      appdata.settings['webdav'] = previousConfig;
      appdata.implicitData = previousImplicitData;
      App.isHeadless = previousHeadless;
    });
  });

  for (final operation in ['up', 'down']) {
    test('webdav $operation reports transfer failure', () async {
      const error = Res<bool>.error('Server rejected the request');
      DataSync.instance = DataSync.withTransfers(
        upload: () async => error,
        download: () async => error,
      );

      final result = await runCommand(operation);

      expect(result.code, 1);
      expect(result.events.map((event) => event['status']), [
        'running',
        'error',
      ]);
      expect(result.events.last['message'], error.errorMessage);
    });

    test('webdav $operation runs the requested transfer', () async {
      final transfers = <String>[];
      DataSync.instance = DataSync.withTransfers(
        upload: () async {
          transfers.add('up');
          return const Res(true);
        },
        download: () async {
          transfers.add('down');
          return const Res(true);
        },
      );

      final result = await runCommand(operation);

      expect(transfers, [operation]);
      expect(result.code, 0);
      expect(result.events.map((event) => event['status']), [
        'running',
        'success',
      ]);
    });
  }

  test('webdav requires an up or down operation', () async {
    final result = await runCommand(null);

    expect(result.code, 1);
    expect(result.events.single['status'], 'error');
  });

  testWidgets(
    'missing WebDAV configuration fails without scheduling desktop UI work',
    (tester) async {
      appdata.settings['webdav'] = <String>[];

      for (final operation in ['up', 'down']) {
        final result = await runCommand(operation);

        expect(result.code, 1);
        expect(result.events.last, {
          'status': 'error',
          'message': 'WebDAV is not configured',
        });
      }

      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  test('headless commands suppress automatic WebDAV transfers', () async {
    appdata.settings['webdav'] = ['https://example.invalid/dav', '', ''];
    final transfers = <String>[];
    final sync = DataSync.withTransfers(
      upload: () async {
        transfers.add('up');
        return const Res(true);
      },
      download: () async {
        transfers.add('down');
        return const Res(true);
      },
    );
    DataSync.instance = sync;
    sync.downloadAutomatically();
    sync.onDataChanged();

    expect((await runCommand('up')).code, 0);
    expect(transfers, ['up']);
  });
}
