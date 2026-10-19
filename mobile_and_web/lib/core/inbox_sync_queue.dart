import 'dart:async';

import 'debug_inspector.dart';

/// The only execution lane permitted to change the account inbox cursor.
/// Invalidating a session discards waiting jobs; callers still fence responses
/// after awaits, so work started under another account cannot write into Drift.
class InboxSyncQueue {
  InboxSyncQueue({this.inspector}) {
    _updateGauges();
  }

  final DebugInspector? inspector;
  Future<void> _tail = Future<void>.value();
  final Set<_QueuedWork> _waiting = {};
  int _running = 0;
  bool _retired = false;
  int _generation = 0;
  int get generation => _generation;
  int get pendingCount => _waiting.length;
  int get runningCount => _running;

  void refreshInspectorGauges() => _updateGauges();

  void _updateGauges() {
    if (_retired) return;
    inspector?.setGauges({
      'queue.pending': pendingCount,
      'queue.running': runningCount,
    });
  }

  Future<T?> enqueue<T>(
    Future<T> Function() work, {
    String operation = 'inbox.work',
  }) {
    if (_retired) return Future<T?>.value();
    final generation = _generation;
    final job = _QueuedWork(generation, inspector?.captureContext(), operation);
    _waiting.add(job);
    _updateGauges();
    inspector?.record(
      'queue',
      'enqueue',
      data: {
        'operation': operation,
        'generation': generation,
        'pending': pendingCount,
      },
      context: job.context,
    );
    final result = _tail.then<T?>((_) async {
      _waiting.remove(job);
      if (generation != _generation) return null;
      _running++;
      _updateGauges();
      Future<T> run() async {
        inspector?.record(
          'queue',
          'start',
          data: {
            'operation': operation,
            'generation': generation,
            'pending': pendingCount,
            'durationMs': job.wait.elapsedMicroseconds / 1000,
          },
          context: job.context,
        );
        try {
          return await work();
        } finally {
          _running--;
          _updateGauges();
          inspector?.record(
            'queue',
            'finish',
            data: {
              'operation': operation,
              'generation': generation,
              'pending': pendingCount,
              'invalidated': generation != _generation,
            },
            context: job.context,
          );
        }
      }

      final debug = inspector;
      return debug == null
          ? run()
          : debug.trace(
              'queue',
              operation,
              run,
              data: {'generation': generation},
              context: job.context,
            );
    });
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> get idle => _tail;

  /// Discard waiting work without waiting for an in-flight HTTP request.
  /// The active operation must still check its session fence after each await.
  void invalidate() {
    _generation++;
    for (final job in _waiting) {
      inspector?.record(
        'queue',
        'cancel',
        data: {'operation': job.operation, 'generation': job.generation},
        context: job.context,
      );
    }
    _waiting.clear();
    _updateGauges();
    inspector?.record('queue', 'invalidate', data: {'generation': _generation});
  }

  Future<void> clear() async {
    invalidate();
    await _tail;
    _updateGauges();
  }

  /// Retired session work must not overwrite a later session's shared gauges.
  void retire() {
    if (_retired) return;
    invalidate();
    inspector?.setGauges({'queue.pending': 0, 'queue.running': 0});
    _retired = true;
  }
}

class _QueuedWork {
  _QueuedWork(this.generation, this.context, this.operation);
  final Stopwatch wait = Stopwatch()..start();
  final int generation;
  final DebugTraceContext? context;
  final String operation;
}
