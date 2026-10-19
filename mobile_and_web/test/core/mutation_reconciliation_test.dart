import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test.dart' show FakeApi, message, payload;

List<Map<String, Object?>> completedQueries(DebugInspector inspector) =>
    (inspector.snapshot()['events'] as List)
        .cast<Map<String, Object?>>()
        .where(
          (event) =>
              event['category'] == 'drift' &&
              (event['name'] as String).startsWith('query.') &&
              event['phase'] == 'end',
        )
        .toList();

List<Map<String, Object?>> writes(DebugInspector inspector) =>
    completedQueries(inspector)
        .where((event) => event['name'] != 'query.select')
        .toList();

List<String> queryOperations(DebugInspector inspector) =>
    completedQueries(inspector)
        .map((event) => '${event['name']}:${(event['data'] as Map)['table']}')
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DebugInspector inspector;
  late AppDatabase db;
  late InboxSyncService sync;

  setUp(() async {
    inspector = DebugInspector(enabled: true);
    db = AppDatabase(NativeDatabase.memory(), inspector);
    await db.initializeSession('me');
    await db.setCursor(0, 'epoch');
    sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
      restoredHasMoreRooms: false,
    );
  });

  tearDown(() async {
    await sync.dispose();
    await db.close();
    inspector.dispose();
  });

  test(
    'a repeated top-level message adds no SQL to room reconciliation',
    () async {
      final sent = message('server');
      final room = payload(last: sent);
      inspector.clear();
      await sync.reconcileMutation({'room': room});
      final roomOnly = queryOperations(inspector);
      await db.clearAllTables();
      await db.initializeSession('me');
      await db.setCursor(0, 'epoch');
      final encoded = sent.toJson()..remove('id');
      encoded['_id'] = sent.id;
      inspector.clear();
      await sync.reconcileMutation({'room': room, 'message': encoded});
      expect(queryOperations(inspector), roomOnly);
    },
  );

  test(
    'socket first then REST performs no duplicate resource writes',
    () async {
      final sent = message('server', key: 'send-key');
      final room = payload(last: sent);
      await db.upsertMessage(
        message('temporary', key: 'send-key', status: 'queued'),
      );
      await sync.receivePublication({'pts': 1, 'epoch': 'epoch', 'room': room});
      inspector.clear();
      await sync.reconcileMutation({'room': room, 'message': sent.toJson()});
      expect(writes(inspector), isEmpty);
      expect(completedQueries(inspector), hasLength(1));
      expect(await db.message('temporary'), isNull);
      expect((await db.message(sent.id))!.status, 'sent');
      expect((await db.metadata())!.localPts, 1);
    },
  );

  test('REST first still lets the socket advance its inbox cursor', () async {
    final sent = message('server', key: 'send-key');
    final room = payload(last: sent);
    await db.upsertMessage(
      message('temporary', key: 'send-key', status: 'sending'),
    );
    await sync.reconcileMutation({'room': room, 'message': sent.toJson()});
    expect((await db.metadata())!.localPts, 0);
    inspector.clear();
    await sync.receivePublication({'pts': 1, 'epoch': 'epoch', 'room': room});
    expect(completedQueries(inspector), hasLength(3));
    expect(
      writes(inspector)
          .where((event) => (event['data'] as Map)['table'] != 'sync_metadata'),
      isEmpty,
    );
    expect((await db.metadata())!.localPts, 1);
    expect((await db.allMessages('room')).map((item) => item.id), [sent.id]);
  });

  test(
    'a stale acknowledgement still resolves an offline draft send',
    () async {
      await db.upsertMessage(
        message(
          'temporary',
          key: 'send-key',
          room: 'draft_peer',
          status: 'queued',
        ),
      );
      await db.applyRoomPayload(
        payload(pts: 10, last: message('newer')),
        myUserId: 'me',
      );
      final sent = message('server', key: 'send-key');
      await sync.reconcileMutation({
        'room': payload(pts: 9, last: sent),
        'message': sent.toJson(),
      });
      expect(await db.message('temporary'), isNull);
      expect((await db.message(sent.id))!.status, 'sent');
      expect((await db.room('room'))!.lastMessage!.id, 'newer');
      expect((await db.room('room'))!.roomPts, 10);
      expect((await db.metadata())!.localPts, 0);
    },
  );

  test('stale REST preserves a newer message body and receipt state', () async {
    final original = message('server', key: 'send-key');
    final edited = ChatMessage.fromJson({
      ...original.toJson(),
      'text': 'edited after sending',
      'isEdited': true,
      'seenAt': instantForReceipt.toIso8601String(),
    });
    await sync.receivePublication({
      'pts': 1,
      'epoch': 'epoch',
      'room': payload(last: original),
    });
    await sync.receivePublication({
      'pts': 2,
      'epoch': 'epoch',
      'room': payload(
        pts: 2,
        event: 'message_edited',
        last: edited,
        updated: edited,
      ),
    });
    inspector.clear();
    await sync.reconcileMutation({
      'room': payload(last: original),
      'message': original.toJson(),
    });
    expect(writes(inspector), isEmpty);
    expect((await db.message(original.id))!.text, edited.text);
    expect((await db.message(original.id))!.isSeen, isTrue);
    expect((await db.metadata())!.localPts, 2);
  });

  test('stale sender-scoped keys never acknowledge another sender', () async {
    await db.upsertMessage(
      message('temporary', key: 'shared-key', status: 'queued'),
    );
    await db.applyRoomPayload(payload(pts: 10), myUserId: 'me');
    final other = message('other-server', key: 'shared-key', sender: 'peer');
    await sync.reconcileMutation({
      'room': payload(pts: 9, last: other),
      'message': other.toJson(),
    });
    expect((await db.message('temporary'))!.status, 'queued');
    expect(await db.message(other.id), isNull);
  });

  test(
    'a delete-for-me acknowledgement does not reinsert its removed message',
    () async {
      final hidden = message('hidden');
      await db.applyRoomPayload(payload(last: hidden), myUserId: 'me');
      await sync.reconcileMutation({
        'room': payload(
          pts: 2,
          history: 2,
          event: 'message_deleted_me',
          updated: hidden,
        ),
        'message': hidden.toJson(),
      });
      expect(await db.message(hidden.id), isNull);
      expect((await db.metadata())!.localPts, 0);
    },
  );

  test(
    'a distinct top-level resource still acknowledges its pending send',
    () async {
      await db.upsertMessage(
        message('temporary', key: 'send-key', status: 'failed'),
      );
      final sent = message('server', key: 'send-key');
      await sync.reconcileMutation({
        'room': payload(last: message('another')),
        'message': sent.toJson(),
      });
      expect(await db.message('temporary'), isNull);
      expect((await db.message(sent.id))!.status, 'sent');
      expect((await db.room('room'))!.lastMessage!.id, 'another');
    },
  );

  test(
    'an equal room revision still repairs an absent acknowledged message',
    () async {
      final sent = message('server', key: 'send-key');
      final room = payload(last: sent);
      await db.applyRoomPayload(room, myUserId: 'me');
      await db.removeMessage(sent.id);
      inspector.clear();
      await sync.reconcileMutation({'room': room, 'message': sent.toJson()});
      expect((await db.message(sent.id))!.status, 'sent');
      expect((await db.metadata())!.localPts, 0);
    },
  );

  test(
    'equal-revision resource differences still update content and quotes',
    () async {
      final original = message('original');
      await db.applyRoomPayload(payload(last: original), myUserId: 'me');
      await db.upsertMessage(
        message('reply', reply: ReplySnapshot.fromMessage(original)),
      );
      final edited = ChatMessage.fromJson({
        ...original.toJson(),
        'text': 'changed content',
        'isEdited': true,
      });
      await sync.reconcileMutation({
        'room': payload(event: 'message_edited', last: edited, updated: edited),
        'message': edited.toJson(),
      });
      expect((await db.message(original.id))!.text, edited.text);
      expect((await db.message('reply'))!.replyTo!.text, edited.text);
      expect((await db.metadata())!.localPts, 0);
    },
  );

  test(
    'equal-revision REST preserves stronger sequence receipt state',
    () async {
      final sent = ChatMessage.fromJson({
        ...message('server').toJson(),
        'messageSeq': 2,
      });
      final room = {
        ...payload(last: sent),
        'receiptProtocol': 'sequence',
        'peerDeliveredSeq': 3,
        'peerSeenSeq': 3,
      };
      await db.applyRoomPayload(room, myUserId: 'me');
      await sync.reconcileMutation({
        'room': {...room, 'peerDeliveredSeq': 0, 'peerSeenSeq': 0},
        'message': sent.toJson(),
      });
      expect((await db.message(sent.id))!.isSeen, isTrue);
      expect((await db.room('room'))!.peerSeenSeq, 3);
      expect((await db.metadata())!.localPts, 0);
    },
  );

  test(
    'compact peer receipt uses one room read and the captured account',
    () async {
      await db.applyRoomPayload({
        ...payload(
          pts: 0,
          last: ChatMessage.fromJson({
            ...message('server').toJson(),
            'messageSeq': 1,
          }),
        ),
        'receiptProtocol': 'sequence',
        'contentPts': 0,
      }, myUserId: 'me');
      inspector.clear();
      await sync.receivePublication({
        'pts': 1,
        'epoch': 'epoch',
        'receipt': {
          'roomId': 'room',
          'eventType': 'room_peer_seen',
          'peerDeliveredSeq': 1,
          'peerSeenSeq': 1,
          'contentPts': 0,
        },
      });
      final reads = completedQueries(inspector)
          .where((event) => event['name'] == 'query.select');
      expect(
        reads.where(
          (event) => (event['data'] as Map)['table'] == 'local_rooms',
        ),
        hasLength(1),
      );
      expect(
        reads.where(
          (event) => (event['data'] as Map)['table'] == 'sync_metadata',
        ),
        hasLength(1),
      );
      expect((await db.message('server'))!.isSeen, isTrue);
      expect((await db.metadata())!.localPts, 1);
    },
  );

  test(
    'an unchanged delta does not rewrite the persisted inbox cursor',
    () async {
      (sync.api as FakeApi).handler = (_, _) async => {
        'requiresFullSync': false,
        'pts': 0,
        'epoch': 'epoch',
        'rooms': [],
      };
      inspector.clear();
      await sync.syncInboxDelta();
      expect(writes(inspector), isEmpty);
      expect(completedQueries(inspector), hasLength(1));
      expect((await db.metadata())!.localPts, 0);
    },
  );

  test(
    'compact unread reads its room once while applying atomically',
    () async {
      await db.applyRoomPayload({
        ...payload(pts: 0),
        'unreadCount': 3,
        'receiptProtocol': 'sequence',
      }, myUserId: 'me');
      inspector.clear();
      await sync.receivePublication({
        'pts': 1,
        'epoch': 'epoch',
        'unread': {
          'roomId': 'room',
          'eventType': 'room_unread_cleared',
          'unreadCount': 1,
          'ownDeliveredSeq': 2,
          'ownSeenSeq': 1,
        },
      });
      expect(
        completedQueries(inspector).where(
          (event) =>
              event['name'] == 'query.select' &&
              (event['data'] as Map)['table'] == 'local_rooms',
        ),
        hasLength(1),
      );
      final room = (await db.room('room'))!;
      expect(room.unreadCount, 1);
      expect(room.ownDeliveredSeq, 2);
      expect(room.ownSeenSeq, 1);
      expect((await db.metadata())!.localPts, 1);
    },
  );

  test(
    'a missing compact room rolls back its whole batch before delta recovery',
    () async {
      await db.applyRoomPayload({
        ...payload(pts: 0),
        'unreadCount': 3,
        'receiptProtocol': 'sequence',
      }, myUserId: 'me');
      var checkedRollback = false;
      (sync.api as FakeApi).handler = (_, _) async {
        expect((await db.metadata())!.localPts, 0);
        expect((await db.room('room'))!.unreadCount, 3);
        expect((await db.room('room'))!.ownSeenSeq, 0);
        checkedRollback = true;
        return {
          'requiresFullSync': false,
          'pts': 2,
          'epoch': 'epoch',
          'rooms': [
            {
              ...payload(pts: 1),
              'unreadCount': 1,
              'receiptProtocol': 'sequence',
              'ownDeliveredSeq': 2,
              'ownSeenSeq': 1,
            },
            {...payload(room: 'missing', pts: 2), 'unreadCount': 2},
          ],
        };
      };
      await Future.wait([
        sync.receivePublication({
          'pts': 1,
          'epoch': 'epoch',
          'unread': {
            'roomId': 'room',
            'eventType': 'room_unread_cleared',
            'unreadCount': 1,
            'ownDeliveredSeq': 2,
            'ownSeenSeq': 1,
          },
        }),
        sync.receivePublication({
          'pts': 2,
          'epoch': 'epoch',
          'unread': {
            'roomId': 'missing',
            'eventType': 'room_unread_cleared',
            'unreadCount': 2,
            'ownDeliveredSeq': 0,
            'ownSeenSeq': 0,
          },
        }),
      ]);
      expect(checkedRollback, isTrue);
      expect(sync.deltaRequests, 1);
      expect((await db.metadata())!.localPts, 2);
      expect((await db.room('room'))!.unreadCount, 1);
      expect((await db.room('missing'))!.unreadCount, 2);
      expect(
        (inspector.snapshot()['events'] as List).where(
          (event) => (event['data'] as Map).containsKey('errorType'),
        ),
        isEmpty,
      );
    },
  );

  test('a hydrated room followed by compact state in the same batch needs no delta', () async {
    await Future.wait([
      sync.receivePublication({
        'pts': 1,
        'epoch': 'epoch',
        'room': {...payload(), 'unreadCount': 3},
      }),
      sync.receivePublication({
        'pts': 2,
        'epoch': 'epoch',
        'unread': {
          'roomId': 'room',
          'eventType': 'room_unread_cleared',
          'unreadCount': 1,
          'ownDeliveredSeq': 2,
          'ownSeenSeq': 1,
        },
      }),
    ]);
    expect(sync.deltaRequests, 0);
    expect((await db.metadata())!.localPts, 2);
    expect((await db.room('room'))!.unreadCount, 1);
    expect((await db.room('room'))!.ownSeenSeq, 1);
  });
}

final instantForReceipt = DateTime.utc(2026, 10, 16, 12, 1);
