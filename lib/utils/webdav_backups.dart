import 'dart:math' as math;
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:venera/foundation/log.dart';
import 'package:webdav_client/webdav_client.dart';

typedef WebDavBackup = ({String name, int day, int version});

class WebDavBackups {
  const WebDavBackups(this._client);

  final Client _client;
  static final _fileName = RegExp(r'^(\d+)-(\d+)\.venera$');

  Future<List<WebDavBackup>> list() async {
    final entries = await _client.readDir('/');
    final backups = <WebDavBackup>[];
    for (final entry in entries) {
      final name = entry.name;
      if (name == null || entry.isDir == true) continue;
      final match = _fileName.firstMatch(name);
      if (match == null || match[0] != name) continue;
      final day = int.tryParse(match[1]!);
      final version = int.tryParse(match[2]!);
      if (day != null && version != null) {
        backups.add((name: name, day: day, version: version));
      }
    }
    backups.sort((a, b) {
      final version = b.version.compareTo(a.version);
      return version == 0 ? b.day.compareTo(a.day) : version;
    });
    return backups;
  }

  static WebDavBackup next(
    List<WebDavBackup> existing, {
    required int localVersion,
    required int day,
  }) {
    final version =
        math.max(localVersion, existing.firstOrNull?.version ?? 0) + 1;
    return (name: '$day-$version.venera', day: day, version: version);
  }

  Future<void> publish(
    WebDavBackup backup,
    Uint8List bytes,
    List<WebDavBackup> existing,
  ) async {
    final staged = 'venera-upload-${const Uuid().v4()}.part';
    try {
      await _client.write(staged, bytes);
      await _client.rename(staged, backup.name, false);
    } catch (_) {
      await _remove(staged);
      rethrow;
    }

    final keptDays = {backup.day};
    for (final entry in existing) {
      if (entry.version >= backup.version) continue;
      if (keptDays.length < 10 && keptDays.add(entry.day)) continue;
      await _remove(entry.name);
    }
  }

  Future<void> _remove(String name) async {
    try {
      await _client.remove(name);
    } catch (error, stack) {
      Log.error('WebDAV', 'Failed to remove $name: $error', stack);
    }
  }
}
