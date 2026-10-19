import 'dart:async';
import 'dart:convert';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, Object?>> events(DebugInspector inspector) =>
    (inspector.snapshot()['events'] as List).cast<Map<String, Object?>>();

Map<String, int> gauges(DebugInspector inspector) =>
    (inspector.snapshot()['gauges'] as Map).cast<String, int>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DebugInspector inspector;
  late AppDatabase db;

  setUp(() {
    inspector = DebugInspector();
    inspector.updateContext(userId: 'me', sessionGeneration: 1);
    db = AppDatabase(NativeDatabase.memory(), inspector);
  });

  tearDown(() async {
    await db.close();
    inspector.dispose();
  });

  test(
    'executor remains usable when disabled and observes a runtime enable',
    () async {
      await db.initializeSession('me');
      expect(events(inspector), isEmpty);
      inspector.setEnabled(true);
      final rows = await db
          .customSelect(
            'SELECT ? AS value',
            variables: [Variable<String>('private-sql-argument')],
          )
          .get();
      expect(rows.single.read<String>('value'), 'private-sql-argument');
      final query = events(inspector).lastWhere(
        (event) => event['name'] == 'query.select' && event['phase'] == 'end',
      );
      expect((query['data'] as Map)['argumentCount'], 1);
      expect((query['data'] as Map)['rowCount'], 1);
      expect(query['durationMicros'], isA<int>());
      final encoded = jsonEncode(inspector.snapshot());
      expect(encoded, isNot(contains('private-sql-argument')));
      expect(encoded, isNot(contains('SELECT ?')));
    },
  );

  test(
    'transaction results, rollback and query failures are preserved',
    () async {
      inspector.setEnabled(true);
      await db.initializeSession('me');
      await db.transaction(() => db.setCursor(3, 'epoch'));
      await expectLater(
        db.transaction(() async {
          await db.setCursor(7, 'epoch');
          throw StateError('private-failure-message');
        }),
        throwsStateError,
      );
      expect((await db.metadata())!.localPts, 3);
      final transactions = events(inspector).where(
        (event) => event['name'] == 'transaction' && event['phase'] == 'end',
      );
      expect(
        transactions.map((event) => (event['data'] as Map)['outcome']),
        containsAll(['commit', 'rollback']),
      );
      await expectLater(
        db.customSelect('SELECT * FROM private_missing_table').get(),
        throwsA(isA<Object>()),
      );
      final failed = events(inspector).lastWhere(
        (event) => event['name'] == 'query.select' && event['phase'] == 'end',
      );
      expect((failed['data'] as Map)['errorType'], isA<String>());
      final encoded = jsonEncode(inspector.snapshot());
      expect(encoded, isNot(contains('private-failure-message')));
      expect(encoded, isNot(contains('private_missing_table')));
    },
  );

  test(
    'watched rows retain pause, resume and cancellation semantics',
    () async {
      inspector.setEnabled(true);
      await db.initializeSession('me');
      final initialRooms = Completer<void>();
      final initialMessages = Completer<void>();
      final changedMessages = Completer<void>();
      var messageEmissions = 0;
      final rooms = db.watchRooms().listen((_) {
        if (!initialRooms.isCompleted) initialRooms.complete();
      });
      final messages = db.watchMessages('room', 30).listen((rows) {
        messageEmissions++;
        if (!initialMessages.isCompleted) initialMessages.complete();
        if (rows.isNotEmpty && !changedMessages.isCompleted) {
          changedMessages.complete();
        }
      });
      await Future.wait([initialRooms.future, initialMessages.future]);
      expect(gauges(inspector)['drift.subscriptions'], 2);
      messages.pause();
      await db.upsertMessage(
        ChatMessage(
          id: 'message',
          idempotencyKey: 'key',
          roomId: 'room',
          senderId: 'me',
          senderName: 'private-sender-name',
          type: 'text',
          text: 'private-message-content',
          status: 'sent',
          createdAt: DateTime.utc(2026, 10, 16),
        ),
      );
      expect(messageEmissions, 1);
      messages.resume();
      await changedMessages.future;
      expect(
        events(inspector).where((event) => event['name'] == 'watch.emit'),
        isNotEmpty,
      );
      await rooms.cancel();
      await messages.cancel();
      await messages.cancel();
      expect(gauges(inspector)['drift.subscriptions'], 0);
      expect(
        events(inspector).where((event) => event['name'] == 'watch.cancel'),
        hasLength(2),
      );
      final encoded = jsonEncode(inspector.snapshot());
      expect(encoded, isNot(contains('private-message-content')));
      expect(encoded, isNot(contains('private-sender-name')));
    },
  );

  test(
    'manual sampling finds a watch that started while capture was disabled',
    () async {
      await db.initializeSession('me');
      final first = Completer<void>();
      final subscription = db.watchMessages('room', 30).listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      expect(events(inspector), isEmpty);
      inspector.setEnabled(true);
      db.refreshInspectorGauges();
      expect(gauges(inspector)['drift.messageSubscriptions'], 1);
      expect(gauges(inspector)['drift.subscriptions'], 1);
      inspector.setPaused(true);
      await subscription.cancel();
      inspector.setPaused(false);
      db.refreshInspectorGauges();
      expect(gauges(inspector)['drift.messageSubscriptions'], 0);
      expect(gauges(inspector)['drift.subscriptions'], 0);
    },
  );

  test(
    'an active watch survives timeline clear with its initiating identity',
    () async {
      inspector.setEnabled(true);
      await db.initializeSession('me');
      final first = Completer<void>();
      final next = Completer<void>();
      late StreamSubscription<List<ChatMessage>> subscription;
      await inspector.trace('test', 'subscribe', () async {
        subscription = db.watchMessages('room', 30).listen((rows) {
          if (!first.isCompleted) first.complete();
          if (rows.isNotEmpty && !next.isCompleted) next.complete();
        });
        await first.future;
      });
      inspector.clear();
      inspector.updateContext(userId: 'another', sessionGeneration: 2);
      await db.upsertMessage(
        ChatMessage(
          id: 'message',
          idempotencyKey: 'key',
          roomId: 'room',
          senderId: 'me',
          senderName: 'Me',
          type: 'text',
          text: '',
          status: 'sent',
          createdAt: DateTime.utc(2026, 10, 16),
        ),
      );
      await next.future;
      final emission = events(inspector)
          .lastWhere((event) => event['name'] == 'watch.emit');
      expect(emission['userId'], 'me');
      expect(emission['sessionGeneration'], 1);
      expect(emission['traceId'], isNull);
      expect(gauges(inspector)['drift.messageSubscriptions'], 1);
      await subscription.cancel();
      expect(events(inspector).last['name'], 'watch.cancel');
      expect(events(inspector).last['userId'], 'me');
    },
  );

  test(
    'an injected database can attach the shared inspector after opening',
    () async {
      db.attachDebugInspector(null);
      await db.initializeSession('me');
      inspector.setEnabled(true);
      db.attachDebugInspector(inspector);
      await db.metadata();
      expect(db.debugInspector, same(inspector));
      expect(
        events(inspector).any((event) => event['name'] == 'query.select'),
        isTrue,
      );
    },
  );
}
