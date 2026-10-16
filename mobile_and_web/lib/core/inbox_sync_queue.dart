import 'dart:async';

/// The only execution lane permitted to change the account inbox cursor.
/// Invalidating a session discards waiting jobs; callers still fence responses
/// after awaits, so work started under another account cannot write into Drift.
class InboxSyncQueue {
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  int get generation => _generation;
  Future<T?> enqueue<T>(Future<T> Function() work) {
    final generation = _generation;
    final result = _tail.then<T?>((_) {
      if (generation != _generation) return null;
      return work();
    });
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> get idle => _tail;
  Future<void> clear() async {
    _generation++;
    await _tail;
  }
}
