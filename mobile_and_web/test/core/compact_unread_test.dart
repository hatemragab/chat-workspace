import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sequence_receipts_test.dart' show sequenced;
import 'sync_test.dart' show FakeApi, instant, message, payload;

Map<String, dynamic> unreadRoom({
  int pts = 10,
  int msgPts = 7,
  int unread = 4,
  int ownDelivered = 1,
  int ownSeen = 1,
}) => {
  ...payload(pts: pts, msgPts: msgPts, history: 2, last: sequenced('own', 4)),
  'contentPts': 7,
  'unreadCount': unread,
  'receiptProtocol': 'sequence',
  'peerDeliveredSeq': 3,
  'peerSeenSeq': 2,
  'ownDeliveredSeq': ownDelivered,
  'ownSeenSeq': ownSeen,
};
Map<String, dynamic> unreadEvent({
  int pts = 11,
  int unread = 2,
  int delivered = 5,
  int seen = 3,
  String epoch = 'epoch',
}) => {
  'epoch': epoch,
  'pts': pts,
  'unread': {
    'eventType': 'room_unread_cleared',
    'roomId': 'room',
    'unreadCount': unread,
    'ownDeliveredSeq': delivered,
    'ownSeenSeq': seen,
  },
};
Map<String, dynamic> unreadPatch(Map<String, dynamic> event) =>
    jsonMap(event['unread']);

Future<AppDatabase> preparedDatabase({int baseline = 7}) async {
  final db = AppDatabase(NativeDatabase.memory());
  await db.initializeSession('me');
  await db.setCursor(10, 'epoch');
  await db.applyRoomPayload(unreadRoom(), myUserId: 'me');
  await db.markMessagesSynced('room', baseline);
  return db;
}

void main() {
  test('group unread patches preserve message revisions with zero direct receipt checkpoints', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.applyRoomPayload({
      ...unreadRoom(),
      'roomType': 'group',
      'peerUserId': null,
      'ownDeliveredSeq': 0,
      'ownSeenSeq': 0,
      'peerDeliveredSeq': 0,
      'peerSeenSeq': 0,
    }, myUserId: 'me');
    await db.markMessagesSynced('room', 7);
    await db.applyUnreadPayload(
      unreadPatch(unreadEvent(unread: 2, delivered: 0, seen: 0)),
      pts: 11,
    );
    final room = (await db.room('room'))!;
    expect(room.unreadCount, 2);
    expect(room.roomType, 'group');
    expect(room.msgPts, 7);
    expect(room.messagesSyncedPts, 7);
    expect(room.ownSeenSeq, 0);
    await db.close();
  });

  for (final count in [0, 2]) {
    test(
      'compact unread applies exact count$count and own progress without changing preview, message ticks or baseline',
      () async {
        final db = await preparedDatabase();
        await db.upsertMessage(sequenced('incoming', 5, sender: 'peer'));
        await db.upsertMessage(message('pending', status: 'sending'));
        await db.upsertMessage(message('failed', status: 'failed'));
        final beforeRoom = (await db.roomRow('room'))!;
        final beforeMessages = (await db.allMessages('room'))
            .map((m) => m.toJson())
            .toList();
        final api = FakeApi()
          ..handler = (_, _) async =>
              throw StateError('Unexpected REST request');
        final sync = InboxSyncService(
          database: db,
          api: api,
          userId: 'me',
          isCurrentSession: () => true,
        );
        final events = <Map<String, dynamic>>[];
        final subscription = sync.roomEventsStream.listen(
          (event) => events.add(event.payload),
        );
        await sync.receivePublication(unreadEvent(unread: count));
        final after = (await db.roomRow('room'))!;
        expect(after.unreadCount, count);
        expect(after.roomPts, 11);
        expect(after.ownDeliveredSeq, 5);
        expect(after.ownSeenSeq, 3);
        expect(after.receivedThroughSeq, 5);
        expect((await db.metadata())!.localPts, 11);
        final beforeJson = beforeRoom.toJson();
        final afterJson = after.toJson();
        for (final key in [
          'unreadCount',
          'roomPts',
          'ownDeliveredSeq',
          'ownSeenSeq',
          'receivedThroughSeq',
        ]) {
          beforeJson.remove(key);
          afterJson.remove(key);
        }
        expect(afterJson, beforeJson);
        expect(
          (await db.allMessages('room')).map((m) => m.toJson()).toList(),
          beforeMessages,
        );
        expect((await db.message('own'))!.isSeen, false);
        expect((await db.message('own'))!.isDelivered, false);
        await Future<void>.delayed(Duration.zero);
        expect(events.single['compactUnread'], true);
        expect(events.single['needsMessageRecovery'], false);
        expect(sync.deltaRequests, 0);
        await subscription.cancel();
        await sync.dispose();
        await db.close();
      },
    );
  }

  test('stale unread snapshot keeps a newer badge and room revision while merging monotonic own progress', () async {
    final db = await preparedDatabase();
    await db.applyUnreadPayload(
      unreadPatch(unreadEvent(unread: 0, delivered: 2, seen: 6)),
      pts: 9,
    );
    final room = (await db.room('room'))!;
    expect(room.unreadCount, 4);
    expect(room.roomPts, 10);
    expect(room.ownDeliveredSeq, 6);
    expect(room.ownSeenSeq, 6);
    await db.applyUnreadPayload(
      unreadPatch(unreadEvent(unread: 3, delivered: 1, seen: 1)),
      pts: 11,
    );
    final fresh = (await db.room('room'))!;
    expect(fresh.unreadCount, 3);
    expect(fresh.ownDeliveredSeq, 6);
    expect(fresh.ownSeenSeq, 6);
    expect(fresh.msgPts, 7);
    expect(fresh.messagesSyncedPts, 7);
    await db.close();
  });

  test('own progress confirms only covered sequence work and never timestamp targets', () async {
    final db = await preparedDatabase();
    await db.queueReceipt(
      'room',
      deliveredThroughSeq: 5,
      seenThroughSeq: 4,
      seenThroughTimestamp: instant,
    );
    await db.applyUnreadPayload(
      unreadPatch(unreadEvent(delivered: 3, seen: 3)),
      pts: 11,
    );
    var pending = (await db.pendingReceiptTargets()).single;
    expect(pending.deliveredThroughSeq, 5);
    expect(pending.seenThroughSeq, 4);
    await db.applyUnreadPayload(
      unreadPatch(unreadEvent(delivered: 5, seen: 4)),
      pts: 12,
    );
    pending = (await db.pendingReceiptTargets()).single;
    expect(pending.deliveredThroughSeq, isNull);
    expect(pending.seenThroughSeq, isNull);
    expect(pending.seenThroughTimestamp, instant);
    expect(pending.deliveredThroughTimestamp, instant);
    await db.close();
  });

  test(
    'an unread event preserves a prior uncertified message baseline',
    () async {
      final db = await preparedDatabase(baseline: 1);
      final sync = InboxSyncService(
        database: db,
        api: FakeApi(),
        userId: 'me',
        isCurrentSession: () => true,
      );
      final events = <Map<String, dynamic>>[];
      final subscription = sync.roomEventsStream.listen(
        (event) => events.add(event.payload),
      );
      await sync.receivePublication(unreadEvent());
      expect((await db.room('room'))!.messagesSyncedPts, 1);
      expect((await db.room('room'))!.msgPts, 7);
      await Future<void>.delayed(Duration.zero);
      expect(events.single['needsMessageRecovery'], true);
      await subscription.cancel();
      await sync.dispose();
      await db.close();
    },
  );

  test('compact unread shares an atomic batch with peer receipts without advancing msgPts again', () async {
    final db = await preparedDatabase();
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    );
    await Future.wait([
      sync.receivePublication({
        'epoch': 'epoch',
        'pts': 11,
        'receipt': {
          'roomId': 'room',
          'eventType': 'room_delivered',
          'peerDeliveredSeq': 4,
          'peerSeenSeq': 2,
          'contentPts': 7,
        },
      }),
      sync.receivePublication(unreadEvent(pts: 12, unread: 2)),
    ]);
    final room = (await db.room('room'))!;
    expect(room.roomPts, 12);
    expect(room.msgPts, 11);
    expect(room.messagesSyncedPts, 11);
    expect(room.unreadCount, 2);
    expect((await db.message('own'))!.isDelivered, true);
    expect((await db.message('own'))!.isSeen, false);
    expect((await db.metadata())!.localPts, 12);
    await sync.dispose();
    await db.close();
  });

  test('invalid unread in a batch rolls back prior badge, own checkpoints, task confirmations and inbox cursor', () async {
    final db = await preparedDatabase();
    await db.queueReceipt('room', seenThroughSeq: 3);
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    );
    final invalid = unreadEvent(pts: 12);
    (invalid['unread'] as Map<String, dynamic>)['unreadCount'] = -1;
    await expectLater(
      Future.wait([
        sync.receivePublication(unreadEvent(unread: 0)),
        sync.receivePublication(invalid),
      ]),
      throwsFormatException,
    );
    expect((await db.metadata())!.localPts, 10);
    expect((await db.room('room'))!.unreadCount, 4);
    expect((await db.room('room'))!.ownSeenSeq, 1);
    expect((await db.pendingReceiptTargets()).single.seenThroughSeq, 3);
    await sync.dispose();
    await db.close();
  });

  test('an absent compact unread room recovers authoritative full state before advancing inbox', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.setCursor(10, 'epoch');
    final api = FakeApi()
      ..handler = (_, _) async => {
        'requiresFullSync': false,
        'epoch': 'epoch',
        'pts': 11,
        'rooms': [unreadRoom(pts: 11, unread: 2, ownDelivered: 5, ownSeen: 3)],
      };
    final sync = InboxSyncService(
      database: db,
      api: api,
      userId: 'me',
      isCurrentSession: () => true,
    );
    await sync.receivePublication(unreadEvent());
    expect(sync.deltaRequests, 1);
    expect((await db.metadata())!.localPts, 11);
    expect((await db.room('room'))!.unreadCount, 2);
    expect((await db.room('room'))!.displayTitle, 'room');
    await sync.dispose();
    await db.close();
  });

  for (final newEpoch in [false, true]) {
    test(
      '${newEpoch ? 'epoch change' : 'gap'} recovers coalesced unread and own checkpoints from full room state',
      () async {
        final db = await preparedDatabase();
        final epoch = newEpoch ? 'new-epoch' : 'epoch';
        final api = FakeApi()
          ..handler = (_, _) async => {
            'requiresFullSync': false,
            'epoch': epoch,
            'pts': 15,
            'rooms': [
              {
                ...unreadRoom(
                  pts: 15,
                  msgPts: 13,
                  unread: 3,
                  ownDelivered: 8,
                  ownSeen: 7,
                ),
                'eventType': 'room_preferences',
              },
            ],
          };
        final sync = InboxSyncService(
          database: db,
          api: api,
          userId: 'me',
          isCurrentSession: () => true,
        );
        await sync.receivePublication(
          unreadEvent(pts: 15, epoch: epoch, unread: 0),
        );
        final room = (await db.room('room'))!;
        expect(sync.deltaRequests, 1);
        expect((await db.metadata())!.localEpoch, epoch);
        expect((await db.metadata())!.localPts, 15);
        expect(room.unreadCount, 3);
        expect(room.ownSeenSeq, 7);
        expect(room.ownDeliveredSeq, 8);
        expect(room.msgPts, 13);
        expect(room.messagesSyncedPts, 7);
        await sync.dispose();
        await db.close();
      },
    );
  }
}
