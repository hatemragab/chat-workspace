import 'dart:io';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'schema_migration_test.dart' show legacyCacheSql;
import 'sync_test.dart' show FakeApi, instant, message, payload;

ChatMessage sequenced(
  String id,
  int seq, {
  String sender = 'me',
  String status = 'sent',
}) => ChatMessage.fromJson({
  ...message(id, sender: sender, status: status).toJson(),
  'messageSeq': seq,
});
Map<String, dynamic> sequenceRoom({
  int pts = 1,
  int contentPts = 1,
  ChatMessage? last,
  int delivered = 0,
  int seen = 0,
}) => {
  ...payload(pts: pts, last: last),
  'contentPts': contentPts,
  'receiptProtocol': 'sequence',
  'peerDeliveredSeq': delivered,
  'peerSeenSeq': seen,
};
Map<String, dynamic> receipt(
  int pts, {
  int delivered = 0,
  int seen = 0,
  int contentPts = 1,
}) => {
  'pts': pts,
  'epoch': 'epoch',
  'receipt': {
    'roomId': 'room',
    'eventType': seen > 0 ? 'room_peer_seen' : 'room_delivered',
    'peerDeliveredSeq': delivered,
    'peerSeenSeq': seen,
    'contentPts': contentPts,
  },
};

void main() {
  test('older page head is metadata only while live contiguous coverage advances a verified latest head', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.upsertRoom(ChatRoom.fromJson(sequenceRoom()));
    await db.recordMessageCoverage('room', {
      'fromSeq': 10,
      'throughSeq': 20,
      'headSeq': 100,
    });
    expect(await db.receiptTarget('room', seen: true), isNull);
    await db.recordMessageCoverage('room', {
      'fromSeq': 71,
      'throughSeq': 100,
      'headSeq': 100,
    }, verifyHead: true);
    expect(await db.receiptTarget('room', seen: true), 100);
    expect(await db.receiptTarget('room'), isNull);
    await db.upsertMessage(sequenced('live101', 101, sender: 'peer'));
    expect(await db.receiptTarget('room', seen: true), 101);
    expect(await db.receiptTarget('room'), isNull);
    await db.close();
  });

  test(
    'historical message edits retain previously confirmed receipt status',
    () {
      final original = sequenced('target', 1).copyWith(seenByCursor: true);
      final updated = {
        ...original.toJson(),
        'text': 'edited',
        'isEdited': true,
        'seenByCursor': false,
      };
      final slice = reconcileJumpSlice(
        [original],
        {'updatedMessage': updated, 'eventType': 'message_edited'},
        myUserId: 'me',
      );
      expect(slice.single.text, 'edited');
      expect(slice.single.isSeen, true);
      expect(slice.single.seenAt, isNull);
    },
  );

  test('latest snapshot history revision invalidates older retained rows before certifying its newer msgPts', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.upsertRoom(ChatRoom.fromJson(sequenceRoom()));
    await db.upsertMessage(message('old'));
    final overlapping = message('overlap', seconds: 1);
    await db.upsertMessage(overlapping);
    await db.markMessagesSynced('room', 1);
    final retained = await db.reconcileLatest(
      'room',
      [overlapping],
      1,
      0,
      1,
      coverage: {
        'roomPts': 3,
        'msgPts': 3,
        'contentPts': 3,
        'lastHistoryEditPts': 3,
        'fromSeq': 1,
        'throughSeq': 0,
        'headSeq': 0,
      },
    );
    expect(retained, false);
    expect(await db.message('old'), isNull);
    expect((await db.room('room'))!.messagesSyncedPts, 3);
    await db.close();
  });

  test(
    'compact batch failure rolls back receipts and cursor together',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.initializeSession('me');
      await db.setCursor(1, 'epoch');
      await db.applyRoomPayload(
        sequenceRoom(last: sequenced('own', 1)),
        myUserId: 'me',
      );
      final sync = InboxSyncService(
        database: db,
        api: FakeApi(),
        userId: 'me',
        isCurrentSession: () => true,
      );
      final bad = receipt(3, seen: 1);
      (bad['receipt'] as Map<String, dynamic>)['eventType'] = 'unknown';
      await expectLater(
        Future.wait([
          sync.receivePublication(receipt(2, delivered: 1)),
          sync.receivePublication(bad),
        ]),
        throwsFormatException,
      );
      expect((await db.metadata())!.localPts, 1);
      expect((await db.message('own'))!.isDelivered, false);
      await sync.receivePublication(receipt(2, seen: 1));
      expect((await db.metadata())!.localPts, 2);
      expect((await db.message('own'))!.isSeen, true);
      await sync.dispose();
      await db.close();
    },
  );

  test(
    'sequence acknowledgement requires observed server capability',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.initializeSession('me');
      await db.upsertRoom(
        ChatRoom.fromJson({...sequenceRoom(), 'receiptProtocol': 'legacy'}),
      );
      await db.upsertMessage(sequenced('one', 1));
      expect(await db.receiptTarget('room'), isNull);
      await db.upsertRoom(ChatRoom.fromJson(sequenceRoom(pts: 2)));
      expect(await db.receiptTarget('room'), 1);
      await db.close();
    },
  );

  test('v4 migration preserves exact rows, retry bytes, cursors and verified baselines without renumbering legacy messages', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute(legacyCacheSql(2));
          raw.execute(
            "ALTER TABLE sync_metadata ADD COLUMN room_page_cursor_json TEXT",
          );
          raw.execute(
            "ALTER TABLE sync_metadata ADD COLUMN room_page_epoch TEXT",
          );
          raw.execute(
            "ALTER TABLE sync_metadata ADD COLUMN room_page_known INTEGER NOT NULL DEFAULT 0",
          );
          raw.execute(
            "ALTER TABLE local_messages ADD COLUMN reply_target_id TEXT",
          );
          raw.execute(
            "ALTER TABLE local_messages ADD COLUMN upload_bytes BLOB",
          );
          raw.execute(
            "ALTER TABLE local_messages ADD COLUMN upload_filename TEXT",
          );
          raw.execute(
            "UPDATE local_messages SET upload_bytes=X'010203', upload_filename='pending.png' WHERE id='pending'",
          );
          raw.execute(
            "CREATE INDEX local_messages_reply_target ON local_messages(room_id,reply_target_id)",
          );
          raw.execute('PRAGMA user_version=4');
        },
      ),
    );
    expect((await db.metadata())!.localPts, 17);
    expect((await db.room('room'))!.messagesSyncedPts, 15);
    expect((await db.room('room'))!.receiptProtocol, 'legacy');
    expect((await db.message('sent'))!.messageSeq, isNull);
    expect((await db.message('sent'))!.seenAt!.millisecondsSinceEpoch, 3000);
    expect((await db.message('pending'))!.uploadBytes, [1, 2, 3]);
    expect((await db.message('pending'))!.status, 'sending');
    expect(await db.pendingReceiptTargets(), isEmpty);
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      6,
    );
    await db.close();
  });

  test('compact receipts atomically update sent outgoing, preview and baseline without invented dates', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.setCursor(1, 'epoch');
    await db.applyRoomPayload(
      sequenceRoom(last: sequenced('own', 1)),
      myUserId: 'me',
    );
    await db.markMessagesSynced('room', 1);
    await db.upsertMessage(sequenced('incoming', 2, sender: 'peer'));
    await db.upsertMessage(sequenced('future', 3));
    await db.upsertMessage(sequenced('pending', 1, status: 'sending'));
    await db.upsertMessage(sequenced('failed', 1, status: 'failed'));
    await db.upsertMessage(message('legacy'));
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    );
    await sync.receivePublication(receipt(2, delivered: 2, seen: 1));
    expect((await db.metadata())!.localPts, 2);
    expect((await db.room('room'))!.messagesSyncedPts, 2);
    expect((await db.room('room'))!.displayTitle, 'room');
    expect((await db.room('room'))!.lastMessage!.isSeen, true);
    expect((await db.message('own'))!.isSeen, true);
    expect((await db.message('own'))!.seenAt, isNull);
    for (final id in ['incoming', 'future', 'pending', 'failed', 'legacy']) {
      expect((await db.message(id))!.isSeen, false, reason: id);
      expect((await db.message(id))!.isDelivered, false, reason: id);
    }
    await db.upsertMessage(sequenced('late-page', 2));
    expect((await db.message('late-page'))!.isDelivered, true);
    expect((await db.message('late-page'))!.isSeen, false);
    expect((await db.message('late-page'))!.deliveredAt, isNull);
    await sync.dispose();
    await db.close();
  });

  test('coalesced full snapshots apply persistent cursors and preserve exact legacy dates', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.upsertRoom(ChatRoom.fromJson(sequenceRoom()));
    final exact = message('legacy')
        .copyWith(deliveredAt: instant, seenAt: instant);
    await db.upsertMessage(exact);
    await db.upsertMessage(sequenced('old-seq', 2));
    await db.applyRoomPayload(
      {
        ...sequenceRoom(pts: 9, delivered: 8, seen: 6),
        'eventType': 'room_preferences',
      },
      myUserId: 'me',
      markOpenSynced: false,
    );
    expect((await db.message('old-seq'))!.isSeen, true);
    await db.upsertMessage(sequenced('loaded-later', 5));
    expect((await db.message('loaded-later'))!.isSeen, true);
    expect((await db.message('legacy'))!.seenAt, instant);
    await db.close();
  });

  test('delivery coverage merges verified ranges without skipping a gap; seen uses verified snapshot head', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.upsertRoom(ChatRoom.fromJson(sequenceRoom()));
    await db.recordMessageCoverage('room', {
      'fromSeq': 3,
      'throughSeq': 5,
      'headSeq': 5,
    }, verifyHead: true);
    expect(await db.receiptTarget('room'), isNull);
    expect(await db.receiptTarget('room', seen: true), 5);
    await db.upsertMessage(sequenced('one', 1));
    expect(await db.receiptTarget('room'), 1);
    await db.upsertMessage(sequenced('two', 2, sender: 'peer'));
    expect(await db.receiptTarget('room'), 5);
    await db.close();
  });

  test('pending sequence and legacy receipts survive restart and summary pruning; old confirmation keeps newer work', () async {
    final dir = await Directory.systemTemp.createTemp('chat-receipts-');
    final file = File('${dir.path}/test.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    try {
      await db.initializeSession('me');
      await db.upsertRoom(ChatRoom.fromJson(sequenceRoom()));
      await db.queueReceipt(
        'room',
        deliveredThroughSeq: 3,
        deliveredThroughTimestamp: instant,
      );
      await db.queueReceipt(
        'room',
        seenThroughSeq: 5,
        seenThroughTimestamp: instant.add(const Duration(seconds: 1)),
      );
      await db.confirmReceipt(
        'room',
        deliveredThroughSeq: 3,
        deliveredThroughTimestamp: instant,
      );
      await db.replaceFullInbox([]);
      expect(await db.room('room'), isNull);
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      var pending = (await db.pendingReceiptTargets()).single;
      expect(pending.deliveredThroughSeq, 5);
      expect(pending.seenThroughSeq, 5);
      expect(
        pending.seenThroughTimestamp,
        instant.add(const Duration(seconds: 1)),
      );
      await db.confirmReceipt(
        'room',
        seenThroughSeq: 5,
        seenThroughTimestamp: pending.seenThroughTimestamp,
      );
      expect(await db.pendingReceiptTargets(), isEmpty);
      await db.initializeSession('other');
      expect(await db.pendingReceiptTargets(), isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('unknown compact room recovers through authoritative delta before cursor acceptance', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.setCursor(1, 'epoch');
    final api = FakeApi()
      ..handler = (_, _) async => {
        'pts': 2,
        'epoch': 'epoch',
        'requiresFullSync': false,
        'rooms': [sequenceRoom(pts: 2, last: sequenced('own', 1), seen: 1)],
      };
    final sync = InboxSyncService(
      database: db,
      api: api,
      userId: 'me',
      isCurrentSession: () => true,
    );
    await sync.receivePublication(receipt(2, seen: 1));
    expect(sync.deltaRequests, 1);
    expect((await db.metadata())!.localPts, 2);
    expect((await db.message('own'))!.isSeen, true);
    await sync.dispose();
    await db.close();
  });

  test('legacy cutoff does not promote sequenced same-time messages and jump flags preserve exact dates', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.upsertMessage(message('legacy'));
    await db.upsertMessage(sequenced('new', 1));
    final event = {...sequenceRoom(), 'eventType': 'room_peer_seen'};
    await db.applyRoomPayload(event, myUserId: 'me');
    expect((await db.message('legacy'))!.isSeen, true);
    expect((await db.message('legacy'))!.seenAt, isNull);
    expect((await db.message('new'))!.isSeen, false);
    final untouchedJump = reconcileJumpSlice(
      [sequenced('new', 1)],
      event,
      myUserId: 'me',
    );
    expect(untouchedJump.single.isSeen, false);
    final jump = reconcileJumpSlice(
      [sequenced('jump', 1)],
      {'roomId': 'room', 'eventType': 'room_peer_seen', 'peerSeenSeq': 1},
      myUserId: 'me',
    );
    expect(jump.single.isSeen, true);
    expect(jump.single.seenAt, isNull);
    await db.close();
  });

  test(
    'a content revision mismatch cannot certify a stale message baseline',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.initializeSession('me');
      await db.upsertRoom(ChatRoom.fromJson(sequenceRoom()));
      await db.markMessagesSynced('room', 1);
      await db.applyReceiptPayload({
        'roomId': 'room',
        'eventType': 'room_delivered',
        'peerDeliveredSeq': 2,
        'peerSeenSeq': 0,
        'contentPts': 2,
      }, pts: 3);
      expect((await db.room('room'))!.messagesSyncedPts, 1);
      expect((await db.room('room'))!.msgPts, 3);
      await db.close();
    },
  );
}
