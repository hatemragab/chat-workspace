import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'database_query_efficiency_test.dart'
    show queries, queryCount, sequenced, sequenceRoom;
import 'sync_test.dart' show instant, message;

String _statement(Map<String, Object?> query) =>
    ((query['data'] as Map)['sqlite'] as Map)['statement'] as String;

void _expectOneContextRead(DebugInspector inspector) {
  final reads = queries(inspector)
      .where((event) => event['name'] == 'query.select')
      .map(_statement)
      .toList();
  expect(
    reads.where((sql) => sql.contains('FROM "sync_metadata"')),
    hasLength(1),
  );
  expect(
    reads.where((sql) => sql.contains('FROM "local_rooms"')),
    hasLength(1),
  );
}

void main() {
  late DebugInspector inspector;
  late AppDatabase db;

  setUp(() async {
    inspector = DebugInspector();
    db = AppDatabase(NativeDatabase.memory(), inspector);
    await db.initializeSession('me');
    inspector.setEnabled(true);
    inspector.setSqliteDetailsEnabled(true);
  });

  tearDown(() async {
    await db.close();
    inspector.dispose();
  });

  test('captured user avoids metadata reads and determines outgoing receipt direction', () async {
    await db.upsertRoom(sequenceRoom());
    inspector.clear();
    await db.storeOlderMessagePage(
      'room',
      [sequenced(1, sender: 'captured'), sequenced(2, sender: 'peer')],
      coverage: {'fromSeq': 1, 'throughSeq': 2},
      receiptState: {'peerDeliveredSeq': 2, 'peerSeenSeq': 2},
      userId: 'captured',
    );
    final reads = queries(inspector)
        .where((event) => event['name'] == 'query.select')
        .map(_statement)
        .toList();
    expect(reads, hasLength(2));
    expect(reads.where((sql) => sql.contains('sync_metadata')), isEmpty);
    expect(
      reads.where((sql) => sql.contains('FROM "local_rooms"')),
      hasLength(1),
    );
    expect((await db.message('message_captured1'))!.isSeen, true);
    expect((await db.message('message_peer2'))!.isDelivered, false);
    expect((await db.metadata())!.userId, 'me');
  });

  test(
    'a whole older page shares context and retains receipt gaps and the outbox',
    () async {
      await db.upsertRoom(
        sequenceRoom(last: sequenced(100), delivered: 5, seen: 3),
      );
      await db.upsertMessage(sequenced(2));
      await db.recordMessageCoverage('room', {
        'fromSeq': 91,
        'throughSeq': 100,
        'headSeq': 100,
      }, verifyHead: true);
      await db.markMessagesSynced('room', 1);
      await db.queueReceipt('room', seenThroughSeq: 12);
      await db.setCursor(23, 'epoch');
      final pending = ChatMessage(
        id: 'pending-image',
        idempotencyKey: 'pending-image-key',
        roomId: 'room',
        senderId: 'me',
        senderName: 'Me',
        type: 'image',
        text: 'Pending caption',
        createdAt: instant,
        status: 'queued',
        uploadBytes: Uint8List.fromList([1, 2, 255]),
        uploadFilename: 'pending.png',
        enqueueOrder: 17,
        retryCount: 2,
        nextAttemptAt: DateTime.utc(2099),
        lastErrorCode: 'network',
        lastErrorText: 'Retry later',
        outcomeUnknown: true,
        outboxPaused: true,
      );
      await db.upsertMessage(pending);
      final pendingBefore = await db.message(pending.id);
      final metadataBefore = await db.metadata();
      final page = List.generate(
        30,
        (index) => sequenced(60 - index, sender: index == 27 ? 'peer' : 'me'),
      );
      inspector.clear();
      await db.storeOlderMessagePage(
        'room',
        page,
        coverage: {'fromSeq': 31, 'throughSeq': 60, 'headSeq': 100},
        receiptState: {
          'peerDeliveredSeq': 60,
          'peerSeenSeq': 50,
          'ownDeliveredSeq': 10,
          'ownSeenSeq': 9,
        },
      );
      _expectOneContextRead(inspector);
      expect(queryCount(inspector, 'select'), 3);
      final inserts = queries(inspector)
          .where((event) => event['name'] == 'query.insert')
          .toList();
      expect(inserts, hasLength(1));
      expect((inserts.single['data'] as Map)['argumentCount'], 900);
      expect(
        RegExp(r'\), \(').allMatches(_statement(inserts.single)),
        hasLength(29),
      );

      expect((await db.message('message_me2'))!.isSeen, true);
      expect((await db.message('message_me50'))!.isSeen, true);
      expect((await db.message('message_me51'))!.isDelivered, true);
      expect((await db.message('message_me51'))!.isSeen, false);
      expect((await db.message('message_peer33'))!.isDelivered, false);
      final room = (await db.roomRow('room'))!;
      expect((room.peerDeliveredSeq, room.peerSeenSeq), (60, 50));
      expect((room.ownDeliveredSeq, room.ownSeenSeq), (10, 9));
      expect(room.receivedThroughSeq, 10);
      expect(jsonDecode(room.receivedRangesJson), [
        [31, 60],
        [91, 100],
      ]);
      expect(room.verifiedHeadSeq, 100);
      expect(room.messagesSyncedPts, 1);
      expect(await db.receiptTarget('room'), 10);
      expect(await db.receiptTarget('room', seen: true), 100);
      final task = (await db.pendingReceiptTargets()).single;
      expect(task.seenThroughSeq, 12);
      expect(await db.metadata(), metadataBefore);
      final pendingAfter = (await db.message(pending.id))!;
      expect(pendingAfter.toJson(), pendingBefore!.toJson());
      expect(pendingAfter.uploadBytes, orderedEquals([1, 2, 255]));
      expect(pendingAfter.uploadFilename, 'pending.png');
      expect((await db.outboundSnapshot('me')).head!.id, pending.id);
    },
  );

  test(
    'older snapshot never regresses retained ticks or certifies its head',
    () async {
      await db.upsertRoom(sequenceRoom(delivered: 90, seen: 80));
      await db.confirmReceipt(
        'room',
        deliveredThroughSeq: 10,
        seenThroughSeq: 8,
      );
      await db.upsertMessage(sequenced(35).copyWith(seenByCursor: true));
      inspector.clear();
      await db.storeOlderMessagePage(
        'room',
        [sequenced(35)],
        coverage: {'fromSeq': 31, 'throughSeq': 40, 'headSeq': 100},
        receiptState: {
          'peerDeliveredSeq': 20,
          'peerSeenSeq': 10,
          'ownDeliveredSeq': 4,
          'ownSeenSeq': 3,
        },
      );
      _expectOneContextRead(inspector);
      expect((await db.message('message_me35'))!.isSeen, true);
      final room = (await db.roomRow('room'))!;
      expect((room.peerDeliveredSeq, room.peerSeenSeq), (90, 80));
      expect((room.ownDeliveredSeq, room.ownSeenSeq), (10, 8));
      expect(room.receivedThroughSeq, 10);
      expect(room.verifiedHeadSeq, 0);
      expect(jsonDecode(room.receivedRangesJson), [
        [31, 40],
      ]);
    },
  );

  test('page coverage fills only a contiguous proven gap and confirms durable tasks', () async {
    await db.upsertRoom(sequenceRoom());
    await db.recordMessageCoverage('room', {'fromSeq': 1, 'throughSeq': 5});
    await db.recordMessageCoverage('room', {'fromSeq': 10, 'throughSeq': 12});
    await db.queueReceipt('room', seenThroughSeq: 12);
    inspector.clear();
    await db.storeOlderMessagePage(
      'room',
      [],
      coverage: {'fromSeq': 6, 'throughSeq': 9, 'headSeq': 100},
      receiptState: {'ownDeliveredSeq': 12, 'ownSeenSeq': 12},
    );
    _expectOneContextRead(inspector);
    expect(queryCount(inspector, 'select'), 2);
    expect(queryCount(inspector, 'insert'), 0);
    expect(await db.pendingReceiptTargets(), isEmpty);
    expect(await db.receiptTarget('room'), 12);
    expect(await db.receiptTarget('room', seen: true), 12);
    expect((await db.roomRow('room'))!.verifiedHeadSeq, 12);
    expect((await db.metadata())!.localPts, 0);
  });

  test('a legacy page without coverage still persists one batch and exact receipts', () async {
    await db.upsertRoom(sequenceRoom());
    final exactSeen = instant.add(const Duration(minutes: 2));
    final legacy = message('legacy')
        .copyWith(deliveredAt: exactSeen, seenAt: exactSeen);
    inspector.clear();
    await db.storeOlderMessagePage(
      'room',
      [legacy, sequenced(3)],
      // Legacy responses without coverage did not apply snapshot cursors.
      receiptState: {'peerSeenSeq': 100, 'ownSeenSeq': 100},
    );
    _expectOneContextRead(inspector);
    expect(queryCount(inspector, 'select'), 3);
    expect(queryCount(inspector, 'insert'), 1);
    final stored = (await db.message('legacy'))!;
    expect(stored.seenAt, exactSeen);
    expect(stored.deliveredAt, exactSeen);
    expect(await db.receiptTarget('room'), isNull);
    final room = (await db.roomRow('room'))!;
    expect(
      (room.peerSeenSeq, room.ownSeenSeq, room.verifiedHeadSeq),
      (0, 0, 0),
    );
  });

  test('missing room or session context is resolved once without inventing receipts', () async {
    await db.clearAllTables();
    inspector.clear();
    await db.storeOlderMessagePage(
      'room',
      [sequenced(1)],
      coverage: {'fromSeq': 1, 'throughSeq': 1, 'headSeq': 100},
      receiptState: {'peerSeenSeq': 1, 'ownSeenSeq': 1},
    );
    _expectOneContextRead(inspector);
    expect(queryCount(inspector, 'select'), 3);
    expect((await db.message('message_me1'))!.isSeen, false);
    expect(await db.roomRow('room'), isNull);
    expect(await db.metadata(), isNull);
  });

  test('coverage failure rolls back the whole page, receipts and task confirmation', () async {
    await db.upsertRoom(sequenceRoom());
    await db.upsertMessage(sequenced(1));
    await db.queueReceipt('room', seenThroughSeq: 8);
    await db.setCursor(23, 'epoch');
    final roomBefore = await db.roomRow('room');
    final tasksBefore = await db.select(db.receiptTasks).get();
    await db.customStatement('''
CREATE TRIGGER reject_history_coverage BEFORE UPDATE ON local_rooms
WHEN NEW.received_through_seq > 8 AND NEW.peer_seen_seq = 60
BEGIN SELECT RAISE(ABORT, 'history coverage rejected'); END
''');
    await expectLater(
      db.storeOlderMessagePage(
        'room',
        List.generate(30, (index) => sequenced(index + 31)),
        coverage: {'fromSeq': 1, 'throughSeq': 60},
        receiptState: {'peerSeenSeq': 60, 'ownSeenSeq': 8},
      ),
      throwsA(
        predicate(
          (error) => error.toString().contains('history coverage rejected'),
        ),
      ),
    );
    expect(await db.messageCount('room'), 1);
    expect((await db.message('message_me1'))!.isSeen, false);
    expect(await db.roomRow('room'), roomBefore);
    expect(await db.select(db.receiptTasks).get(), tasksBefore);
    expect((await db.metadata())!.localPts, 23);
    await db.customStatement('DROP TRIGGER reject_history_coverage');
    await db.storeOlderMessagePage(
      'room',
      [sequenced(2)],
      coverage: {'fromSeq': 2, 'throughSeq': 2},
      receiptState: {'peerSeenSeq': 2, 'ownSeenSeq': 8},
    );
    expect(await db.messageCount('room'), 2);
    expect(await db.pendingReceiptTargets(), isEmpty);
  });

  test('page identity adoption preserves later pending draft upload and sender keys', () async {
    await db.upsertRoom(sequenceRoom());
    final first = message(
      'pending-first',
      room: 'draft_peer',
      status: 'queued',
      key: 'same-key',
    );
    final photo = ChatMessage(
      id: 'pending-photo',
      idempotencyKey: 'pending-photo-key',
      roomId: 'draft_peer',
      senderId: 'me',
      senderName: 'Me',
      type: 'image',
      text: '',
      createdAt: instant,
      status: 'failed',
      uploadBytes: Uint8List.fromList([2, 3, 255]),
      uploadFilename: 'pending.png',
      enqueueOrder: 17,
      retryCount: 2,
      outcomeUnknown: true,
    );
    await db.upsertMessages([first, photo]);
    final before = (await db.message(photo.id))!;
    await db.storeOlderMessagePage(
      'room',
      [
        sequenced(1, key: 'same-key'),
        sequenced(2, sender: 'peer', key: 'same-key'),
      ],
      coverage: {'fromSeq': 1, 'throughSeq': 2},
    );
    expect(await db.message(first.id), isNull);
    expect(
      (await db.messageByIdempotencyKey('me', 'same-key'))!.id,
      'message_me1',
    );
    expect(
      (await db.messageByIdempotencyKey('peer', 'same-key'))!.id,
      'message_peer2',
    );
    final after = (await db.message(photo.id))!;
    expect(after.roomId, 'room');
    expect(after.toJson(), before.copyWith(roomId: 'room').toJson());
    expect(after.uploadBytes, orderedEquals([2, 3, 255]));
    expect(after.uploadFilename, 'pending.png');
  });

  test(
    'a page from another room cannot alter the requested room or messages',
    () async {
      inspector.clear();
      await expectLater(
        db.storeOlderMessagePage('room', [message('other', room: 'another')]),
        throwsArgumentError,
      );
      expect(queries(inspector), isEmpty);
      expect(await db.messageCount('another'), 0);
    },
  );
}
