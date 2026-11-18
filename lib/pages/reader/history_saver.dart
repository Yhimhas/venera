import 'dart:async';

import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';

class ReaderHistorySaver {
  ReaderHistorySaver(this._write);

  final Future<void> Function(History) _write;
  Timer? _timer;
  History? _pending;
  Future<bool> _saving = Future.value(true);
  bool _closed = false;

  void schedule(History history) {
    if (_closed) return;
    _pending = history;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), _flush);
  }

  Future<void> close(void Function() onSaved) async {
    if (_closed) return;
    _closed = true;
    if (await _flush()) onSaved();
  }

  Future<bool> _flush() {
    _timer?.cancel();
    _timer = null;
    final history = _pending;
    _pending = null;
    if (history != null) {
      final next = _save(history);
      _saving = _saving.then((_) => next);
    }
    return _saving;
  }

  Future<bool> _save(History history) async {
    try {
      await _write(history);
      return true;
    } catch (error, stack) {
      Log.error('History', 'Failed to save reading progress: $error', stack);
      return false;
    }
  }
}
