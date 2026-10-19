import 'dart:async';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class PausedWatchReads extends QueryInterceptor {
  bool enabled = false;
  final started = <String, Completer<void>>{
    // The room preview query also reads pending messages. Classify that
    // joined query as the room watch before matching its message subquery.
    'local_rooms': Completer<void>(),
    'local_messages': Completer<void>(),
  };
  final release = Completer<void>();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (enabled) {
      for (final table in started.keys) {
        final first = started[table]!;
        if (!first.isCompleted &&
            RegExp('FROM ["]?$table[" ]').hasMatch(statement)) {
          first.complete();
          await release.future;
          break;
        }
      }
    }
    // Drift's actual executor checks the original cancellation zone here.
    // The probe does not inject an exception or change application behavior.
    return executor.runSelect(statement, args);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('watch invalidation records typed cancellation without query or watch failures', () async {
    final inspector = DebugInspector(enabled: true);
    final gate = PausedWatchReads();
    final isolate = DriftIsolate.inCurrent(() => NativeDatabase.memory());
    final connection = await isolate.connect();
    final db = AppDatabase(connection.executor.interceptWith(gate), inspector);
    await db.initializeSession('synthetic-user');
    inspector.clear();
    gate.enabled = true;
    final roomResult = Completer<List<ChatRoom>>();
    final messageResult = Completer<List<ChatMessage>>();
    final errors = <Object>[];
    final rooms = db.watchRooms().listen((rows) {
      if (rows.isNotEmpty && !roomResult.isCompleted) roomResult.complete(rows);
    }, onError: errors.add);
    final messages = db.watchMessages('synthetic-room', 50).listen((rows) {
      if (rows.isNotEmpty && !messageResult.isCompleted) {
        messageResult.complete(rows);
      }
    }, onError: errors.add);
    try {
      await Future.wait(gate.started.values.map((value) => value.future));
      await db.upsertRoom(
        ChatRoom(
          roomId: 'synthetic-room',
          roomType: 'group',
          displayTitle: 'Synthetic room',
          sortTimestamp: DateTime.utc(2026),
        ),
      );
      await db.upsertMessage(
        ChatMessage(
          id: 'synthetic-message',
          idempotencyKey: 'synthetic-key',
          roomId: 'synthetic-room',
          senderId: 'synthetic-user',
          senderName: 'Synthetic user',
          type: 'text',
          text: '',
          createdAt: DateTime.utc(2026),
        ),
      );
      gate.release.complete();
      await Future.wait([roomResult.future, messageResult.future]);
      await Future<void>.delayed(Duration.zero);
      final events = (inspector.snapshot()['events'] as List).cast<Map>();
      final cancellations = events
          .where(
            (event) =>
                event['name'] == 'query.select' &&
                (event['data'] as Map)['outcome'] == 'cancelled',
          )
          .toList();
      expect(cancellations, hasLength(2));
      expect(
        cancellations.every(
          (event) => !(event['data'] as Map).containsKey('errorType'),
        ),
        true,
      );
      final aggregates = (inspector.snapshot()['aggregates'] as List)
          .cast<Map>();
      expect(
        aggregates.singleWhere(
          (value) =>
              value['category'] == 'drift' && value['name'] == 'query.select',
        )['errorCount'],
        0,
      );
      expect(errors, isEmpty);
      expect(events.where((event) => event['name'] == 'watch.error'), isEmpty);
      expect(
        (await db.allMessages('synthetic-room')).single.id,
        'synthetic-message',
      );
    } finally {
      if (!gate.release.isCompleted) gate.release.complete();
      await rooms.cancel();
      await messages.cancel();
      await db.close();
      await isolate.shutdownAll();
      inspector.dispose();
    }
  });
}
