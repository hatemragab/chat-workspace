import 'dart:async';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sequence_receipts_test.dart' show sequenced;
import 'sync_test.dart' show FakeApi, message, payload;

class _RoomReadDatabase extends AppDatabase {
  _RoomReadDatabase() : super(NativeDatabase.memory());
  final roomReads = <String, int>{};

  @override
  Future<LocalRoomRow?> roomRow(String id) {
    roomReads.update(id, (value) => value + 1, ifAbsent: () => 1);
    return super.roomRow(id);
  }
}

Map<String, dynamic> _room(String id, int pts, int sequence) => {
  ...payload(
    room: id,
    pts: pts,
    last: ChatMessage.fromJson({
      ...message('$id-$sequence', room: id, sender: 'peer').toJson(),
      'messageSeq': sequence,
    }),
  ),
  'receiptProtocol': 'sequence',
  'contentPts': pts,
};

void main() {
  for (final roomCount in [1, 2]) {
    test(
      '20 contiguous publications read final state once for each of $roomCount rooms',
      () async {
        final db = _RoomReadDatabase();
        await db.initializeSession('me');
        await db.setCursor(1, 'epoch');
        for (var index = 0; index < roomCount; index++) {
          await db.applyRoomPayload(_room('room-$index', 1, 1), myUserId: 'me');
          await db.markMessagesSynced('room-$index', 1);
        }
        final sync = InboxSyncService(
          database: db,
          api: FakeApi()
            ..handler = (_, _) async => throw StateError('Unexpected recovery'),
          userId: 'me',
          isCurrentSession: () => true,
        )..openRoomId = roomCount == 1 ? 'room-0' : null;
        final events = <InboxRoomEvent>[];
        final subscription = sync.roomEventsStream.listen(events.add);
        final release = Completer<void>();
        final blocked = sync.queue.enqueue(() => release.future);
        db.roomReads.clear();
        final pending = [
          for (var index = 0; index < 20; index++)
            sync.receivePublication({
              'epoch': 'epoch',
              'pts': index + 2,
              'room': _room(
                'room-${index % roomCount}',
                index + 2,
                index ~/ roomCount + 2,
              ),
            }),
        ];
        release.complete();
        try {
          await blocked;
          await Future.wait(pending);
          await Future<void>.delayed(Duration.zero);
          expect(events, hasLength(20));
          expect(db.roomReads, {
            for (var index = 0; index < roomCount; index++) 'room-$index': 1,
          });
          expect(
            events.where((event) => event.runRoomFollowUp),
            hasLength(roomCount),
          );
          for (var index = 0; index < roomCount; index++) {
            final sameRoom = events
                .where((event) => event.payload['roomId'] == 'room-$index')
                .toList();
            final finalState = sameRoom.last.roomState!;
            expect(
              sameRoom
                  .take(sameRoom.length - 1)
                  .every((event) => !event.runRoomFollowUp),
              true,
            );
            expect(
              sameRoom.every((event) => identical(event.roomState, finalState)),
              true,
            );
            expect(finalState.receivedThroughSeq, 20 ~/ roomCount + 1);
            expect(db.receiptTargetFromRoom(finalState), 20 ~/ roomCount + 1);
            expect(sameRoom.last.acknowledge, true);
            expect(sameRoom.last.hasIncoming, true);
            if (roomCount == 1) {
              expect(finalState.messagesSyncedPts, finalState.msgPts);
              expect(
                sameRoom.every((event) => !event.needsMessageRecovery),
                true,
              );
            }
          }
          expect((await db.metadata())!.localPts, 21);
          expect(sync.publicationBatches, 1);
        } finally {
          await subscription.cancel();
          await sync.dispose();
          await db.close();
        }
      },
    );
  }

  test('a trailing own echo and compact unread retain earlier incoming follow-up and each mutation', () async {
    final db = _RoomReadDatabase();
    await db.initializeSession('me');
    await db.setCursor(1, 'epoch');
    await db.applyRoomPayload(_room('room', 1, 1), myUserId: 'me');
    await db.markMessagesSynced('room', 1);
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    )..openRoomId = 'room';
    final events = <InboxRoomEvent>[];
    final subscription = sync.roomEventsStream.listen(events.add);
    final release = Completer<void>();
    final blocked = sync.queue.enqueue(() => release.future);
    final pending = [
      sync.receivePublication({
        'epoch': 'epoch',
        'pts': 2,
        'room': _room('room', 2, 2),
      }),
      sync.receivePublication({
        'epoch': 'epoch',
        'pts': 3,
        'room': {
          ..._room('room', 3, 3),
          'lastMessage': sequenced('own', 3).toJson(),
        },
      }),
      sync.receivePublication({
        'epoch': 'epoch',
        'pts': 4,
        'unread': {
          'roomId': 'room',
          'eventType': 'room_unread_cleared',
          'unreadCount': 0,
          'ownDeliveredSeq': 1,
          'ownSeenSeq': 1,
        },
      }),
    ];
    release.complete();
    try {
      await blocked;
      await Future.wait(pending);
      await Future<void>.delayed(Duration.zero);
      expect(events.map((event) => event.payload['eventType']), [
        'message_new',
        'message_new',
        'room_unread_cleared',
      ]);
      expect(events.map((event) => event.runRoomFollowUp), [
        false,
        false,
        true,
      ]);
      expect(events.last.acknowledge, true);
      expect(events.last.hasIncoming, true);
      expect(events.last.roomState!.ownSeenSeq, 1);
      expect(events.last.roomState!.receivedThroughSeq, 3);
      expect(events.last.needsMessageRecovery, false);
    } finally {
      await subscription.cancel();
      await sync.dispose();
      await db.close();
    }
  });
}
