import 'dart:async';
import 'dart:io';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test.dart' show message, payload;

ChatMessage sequenced(int sequence, {String sender = 'me', String? key}) =>
    ChatMessage.fromJson({
      ...message('message_$sender$sequence', sender: sender, key: key).toJson(),
      'messageSeq': sequence,
    });

ChatRoom sequenceRoom({ChatMessage? last, int delivered = 0, int seen = 0}) =>
    ChatRoom.fromJson({
      ...payload(last: last),
      'receiptProtocol': 'sequence',
      'contentPts': 1,
      'peerDeliveredSeq': delivered,
      'peerSeenSeq': seen,
    });

List<Map<String, Object?>> queries(DebugInspector inspector) =>
    (inspector.snapshot()['events'] as List)
        .cast<Map<String, Object?>>()
        .where(
          (e) =>
              (e['name'] as String).startsWith('query.') && e['phase'] == 'end',
        )
        .toList();

int queryCount(DebugInspector inspector, String operation) =>
    queries(inspector).where((e) => e['name'] == 'query.$operation').length;

void main() {
  late DebugInspector inspector;
  late AppDatabase db;

  setUp(() async {
    inspector = DebugInspector();
    db = AppDatabase(NativeDatabase.memory(), inspector);
    await db.initializeSession('me');
    inspector.setEnabled(true);
  });

  tearDown(() async {
    await db.close();
    inspector.dispose();
  });

  test(
    'a 30-message page shares context reads and merges coverage once',
    () async {
      await db.upsertRoom(sequenceRoom());
      final fresh = List.generate(30, (i) => sequenced(30 - i));
      inspector.clear();
      await db.reconcileLatest(
        'room',
        fresh,
        1,
        0,
        0,
        coverage: {
          'fromSeq': 1,
          'throughSeq': 30,
          'headSeq': 30,
          'contentPts': 1,
          'msgPts': 1,
        },
      );
      final total = queries(inspector).length;
      final selects = queryCount(inspector, 'select');
      final updates = queryCount(inspector, 'update');
      expect(total, lessThanOrEqualTo(11));
      expect(selects, lessThanOrEqualTo(6));
      expect(updates, lessThanOrEqualTo(4));
      expect(queryCount(inspector, 'insert'), 1);
      expect(await db.receiptTarget('room'), 30);
      expect(await db.receiptTarget('room', seen: true), 30);
      expect(await db.messageCount('room'), 30);
      expect((await db.room('room'))!.messagesSyncedPts, 1);
      expect((await db.metadata())!.localPts, 0);
      // Printed only as bounded aggregate evidence; never include message rows.
      // ignore: avoid_print
      print(
        '30-message reconcile: $total SQL, $selects SELECT, $updates UPDATE',
      );
    },
  );

  test(
    'identical acknowledgements and covered ranges perform no writes',
    () async {
      final original = sequenced(1);
      final room = sequenceRoom(last: original, delivered: 1, seen: 1);
      await db.upsertRoom(room);
      await db.upsertMessage(original);
      inspector.clear();
      await db.upsertMessage(original);
      await db.upsertRoom(room);
      await db.recordMessageCoverage('room', {'fromSeq': 1, 'throughSeq': 1});
      expect(
        queries(inspector).every((e) => e['name'] == 'query.select'),
        true,
      );
      expect((await db.message(original.id))!.isSeen, true);
      expect((await db.message(original.id))!.seenAt, isNull);
    },
  );

  test('hydrated message and duplicate acknowledgement each read one joined context', () async {
    final first = sequenced(1);
    final room = sequenceRoom(last: first).toJson();
    inspector.clear();
    await db.applyRoomPayload(room, myUserId: 'me');
    expect(queryCount(inspector, 'select'), 1);
    expect((await db.message(first.id))!.isSeen, false);
    inspector.clear();
    await db.applyRoomPayload(room, myUserId: 'me');
    expect(queryCount(inspector, 'select'), 1);
    expect(queries(inspector), hasLength(1));
  });

  test(
    'own cursor confirmations persist without rereading unchanged tasks',
    () async {
      await db.upsertRoom(sequenceRoom());
      await db.queueReceipt('room', seenThroughSeq: 4);
      final next = {
        ...sequenceRoom(last: sequenced(1)).toJson(),
        'roomPts': 2,
        'ownDeliveredSeq': 4,
        'ownSeenSeq': 4,
      };
      inspector.clear();
      await db.applyRoomPayload(next, myUserId: 'me');
      expect(queryCount(inspector, 'select'), 1);
      inspector.clear();
      await db.applyRoomPayload(next, myUserId: 'me');
      expect(queries(inspector), hasLength(1));
      await db.customStatement(
        "DELETE FROM local_rooms WHERE room_id = 'room'",
      );
      expect(await db.pendingReceiptTargets(), isEmpty);
      // Rehydrate acknowledged state, then admit a covered target. It must not
      // become a pending retry after its room summary is pruned again.
      await db.upsertRoom(ChatRoom.fromJson(next));
      await db.queueReceipt('room', seenThroughSeq: 3);
      await db.customStatement(
        "DELETE FROM local_rooms WHERE room_id = 'room'",
      );
      expect(await db.pendingReceiptTargets(), isEmpty);
    },
  );

  test(
    'transaction-local proof cannot survive a rolled-back acknowledgement',
    () async {
      await db.upsertRoom(sequenceRoom());
      await db.queueReceipt('room', seenThroughSeq: 2);
      final incoming = {
        ...sequenceRoom(last: sequenced(1, sender: 'peer')).toJson(),
        'roomPts': 2,
        'ownDeliveredSeq': 2,
        'ownSeenSeq': 2,
      };
      await expectLater(
        db.transaction(() async {
          await db.applyRoomPayload(incoming, myUserId: 'me');
          await db.setCursor(2, 'epoch');
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(await db.message('message_peer1'), isNull);
      expect((await db.roomRow('room'))!.ownSeenSeq, 0);
      expect((await db.pendingReceiptTargets()).single.seenThroughSeq, 2);
      expect((await db.metadata())!.localPts, 0);
      await db.transaction(() async {
        await db.applyRoomPayload(incoming, myUserId: 'me');
        await db.setCursor(2, 'epoch');
      });
      expect(await db.message('message_peer1'), isNotNull);
      expect(await db.pendingReceiptTargets(), isEmpty);
      expect((await db.metadata())!.localPts, 2);
    },
  );

  test(
    'outbound snapshot combines FIFO head and counts in one indexed read',
    () async {
      await db.upsertMessage(
        message('first', status: 'queued').copyWith(
          enqueueOrder: 1,
          outboxPaused: true,
          nextAttemptAt: DateTime.utc(2099),
        ),
      );
      await db.upsertMessage(
        message('second', status: 'queued').copyWith(enqueueOrder: 2),
      );
      await db.upsertMessage(message('failed', status: 'failed'));
      await db.upsertMessage(
        message('other-account', status: 'queued', sender: 'peer'),
      );
      inspector.clear();
      inspector.setSqliteDetailsEnabled(true);
      final snapshot = await db.outboundSnapshot('me');
      expect(queryCount(inspector, 'select'), 1);
      expect(snapshot.head!.id, 'first');
      expect(snapshot.head!.outboxPaused, true);
      expect(snapshot.queued, 2);
      expect(snapshot.failed, 1);
      expect(snapshot.paused, 1);
      final captured = queries(inspector).single;
      final sql =
          ((captured['data'] as Map)['sqlite'] as Map)['statement'] as String;
      // Bind placeholders only for explaining the captured prepared statement.
      final plan = await db
          .customSelect("EXPLAIN QUERY PLAN ${sql.replaceAll('?', "'me'")}")
          .get();
      final details = plan.map((r) => r.read<String>('detail')).join('\n');
      expect(details, contains('USING INDEX local_messages_outbox'));
      expect(details, isNot(contains('SCAN local_messages')));
      final empty = await db.outboundSnapshot('absent');
      expect(empty.head, isNull);
      expect((empty.queued, empty.failed, empty.paused), (0, 0, 0));
    },
  );

  test('remapping a real room or the same draft performs no SQL', () async {
    inspector.clear();
    await db.remapDraft('room', 'room');
    await db.remapDraft('room', 'another-room');
    await db.remapDraft('draft_peer', 'draft_peer');
    expect(queries(inspector), isEmpty);
  });

  test(
    'batch sender keys stay independent and coverage never bridges a gap',
    () async {
      await db.upsertRoom(sequenceRoom());
      await db.upsertMessages([
        sequenced(1, key: 'shared'),
        sequenced(3, sender: 'peer', key: 'shared'),
      ]);
      expect(await db.messageCount('room'), 2);
      expect(await db.receiptTarget('room'), 1);
      await db.upsertMessages([sequenced(2, sender: 'peer')]);
      expect(await db.receiptTarget('room'), 3);
      expect((await db.metadata())!.localPts, 0);
    },
  );

  test(
    'room watcher reads pending previews in one query and reacts to status',
    () async {
      final server = message('server');
      final pending = message('pending', seconds: 1, status: 'queued');
      await db.upsertRoom(ChatRoom.fromJson(payload(last: server)));
      await db.upsertMessage(pending);
      inspector.clear();
      final emissions = <List<ChatRoom>>[];
      final first = Completer<void>();
      final second = Completer<void>();
      final sub = db.watchRooms(userId: 'me').listen((rooms) {
        emissions.add(rooms);
        if (!first.isCompleted) first.complete();
        if (rooms.single.lastMessage!.id == server.id && !second.isCompleted) {
          second.complete();
        }
      });
      await first.future;
      expect(emissions.single.single.lastMessage!.id, pending.id);
      expect(queryCount(inspector, 'select'), 1);
      await db.setMessageStatus(pending.id, 'sent');
      await second.future;
      expect(emissions.last.single.lastMessage!.id, server.id);
      expect(queryCount(inspector, 'select'), 2);
      await sub.cancel();
    },
  );

  test(
    'pending previews use the outbox index instead of scanning sent history',
    () async {
      await db.upsertRoom(sequenceRoom());
      await db.upsertMessages(List.generate(1000, (i) => sequenced(i + 1)));
      await db.upsertMessage(message('pending', status: 'queued', seconds: 1));
      inspector.clear();
      inspector.setSqliteDetailsEnabled(true);
      final rooms = await db.watchRooms(userId: 'me').first;
      expect(rooms.single.lastMessage!.id, 'pending');
      final captured = queries(inspector).single;
      final sql =
          ((captured['data'] as Map)['sqlite'] as Map)['statement'] as String;
      final plan = await db
          .customSelect("EXPLAIN QUERY PLAN ${sql.replaceAll('?', "'me'")}")
          .get();
      final details = plan.map((r) => r.read<String>('detail')).join('\n');
      expect(details, contains('USING INDEX local_messages_outbox'));
      expect(details, isNot(contains('SCAN local_messages')));
      expect(details, isNot(contains('CORRELATED SCALAR SUBQUERY')));
    },
  );

  test(
    'receipt query filters confirmed tasks but retains pruned-room retry',
    () async {
      await db.upsertRoom(sequenceRoom());
      await db.queueReceipt('room', deliveredThroughSeq: 5);
      await db.confirmReceipt('room', deliveredThroughSeq: 5);
      await db.queueReceipt('pruned', seenThroughSeq: 7);
      inspector.clear();
      final pending = await db.pendingReceiptTargets();
      expect(queryCount(inspector, 'select'), 1);
      expect(pending.single.roomId, 'pruned');
      expect(pending.single.seenThroughSeq, 7);
      inspector.clear();
      await db.queueReceipt('room', deliveredThroughSeq: 5);
      await db.confirmReceipt('room', deliveredThroughSeq: 5);
      expect(
        queries(inspector).every((e) => e['name'] == 'query.select'),
        true,
      );
    },
  );

  test(
    'batched inbox deletion does not reinsert its hidden last message',
    () async {
      final hidden = message('hidden');
      await db.applyRoomPayload(payload(last: hidden), myUserId: 'me');
      await db.applyRoomPayload(
        payload(
          pts: 2,
          last: hidden,
          updated: hidden,
          event: 'message_deleted_me',
        ),
        myUserId: 'me',
      );
      expect(await db.message(hidden.id), isNull);
    },
  );

  test(
    'batched durable coverage and pending receipt survive database reopening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'chat-query-recovery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/chat.sqlite');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      await db.initializeSession('me');
      await db.upsertRoom(sequenceRoom());
      await db.upsertMessages([sequenced(1), sequenced(3, sender: 'peer')]);
      await db.queueReceipt('room', deliveredThroughSeq: 1);
      await db.setCursor(9, 'epoch');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      await db.initializeSession('me');
      expect(await db.messageCount('room'), 2);
      expect(await db.receiptTarget('room'), 1);
      expect((await db.pendingReceiptTargets()).single.deliveredThroughSeq, 1);
      expect((await db.metadata())!.localPts, 9);
      await db.upsertMessages([sequenced(2, sender: 'peer')]);
      expect(await db.receiptTarget('room'), 3);
    },
  );
}
