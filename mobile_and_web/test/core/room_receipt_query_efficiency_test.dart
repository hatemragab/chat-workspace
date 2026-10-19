import 'dart:async';
import 'dart:typed_data';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'database_query_efficiency_test.dart'
    show queries, queryCount, sequenced, sequenceRoom;
import 'sync_test.dart' show instant, message, payload;

String statement(Map<String, Object?> event) =>
    ((event['data'] as Map)['sqlite'] as Map)['statement'] as String;

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

  for (final explicitUser in [true, false]) {
    test(
      '${explicitUser ? 'session-bound' : 'compatibility'} room watch ignores cursor-only writes and still reacts to pending status',
      () async {
        final pending = message('pending', status: 'queued');
        await db.upsertRoom(sequenceRoom());
        await db.upsertMessage(pending);
        final emissions = <List<ChatRoom>>[];
        final initial = Completer<void>();
        final failed = Completer<void>();
        final subscription = db
            .watchRooms(userId: explicitUser ? 'me' : null)
            .listen((rooms) {
              emissions.add(rooms);
              if (!initial.isCompleted) initial.complete();
              if (rooms.single.lastMessage!.status == 'failed' &&
                  !failed.isCompleted) {
                failed.complete();
              }
            });
        addTearDown(subscription.cancel);
        await initial.future;
        inspector.clear();
        await db.setCursor(17, 'epoch');
        await db.saveRoomPage('epoch', {'sortTimestamp': 1, 'roomId': 'room'});
        await db.queueReceipt('room', deliveredThroughSeq: 1);
        await pumpEventQueue();
        expect(emissions, hasLength(1));
        expect(
          queries(inspector).where(
            (event) =>
                event['name'] == 'query.select' &&
                statement(event).startsWith('WITH pending_messages'),
          ),
          isEmpty,
        );
        expect((await db.metadata())!.localPts, 17);
        await db.setMessageStatus('pending', 'failed');
        await failed.future;
        expect(emissions.last.single.lastMessage!.status, 'failed');
        expect(
          (await db.pendingReceiptTargets()).single.deliveredThroughSeq,
          1,
        );
      },
    );
  }

  test('identical room watches share the same parameterized query', () async {
    await db.upsertRoom(sequenceRoom());
    inspector.clear();
    final first = Completer<void>();
    final second = Completer<void>();
    final subscriptions = [
      db.watchRooms(userId: 'me').listen((_) {
        if (!first.isCompleted) first.complete();
      }),
      db.watchRooms(userId: 'me').listen((_) {
        if (!second.isCompleted) second.complete();
      }),
    ];
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });
    await Future.wait([first.future, second.future]);
    expect(queryCount(inspector, 'select'), 1);
    final event = queries(inspector).single;
    expect(statement(event), isNot(contains('sync_metadata')));
    expect((event['data'] as Map)['argumentCount'], 1);
  });

  test('narrow pending previews retain text, photos and draft ordering while full reads keep upload and retry state', () async {
    await db.upsertRoom(ChatRoom.fromJson(payload(last: message('server'))));
    await db.upsertMessage(
      message('failed-text', status: 'failed', seconds: 2),
    );
    await db.upsertMessage(
      message('other-account', sender: 'other', status: 'queued', seconds: 9),
    );
    final image = ChatMessage(
      id: 'pending-photo',
      idempotencyKey: 'pending-photo',
      roomId: 'draft_peer',
      senderId: 'me',
      senderName: 'Me',
      type: 'image',
      text: 'Photo caption',
      createdAt: instant.add(const Duration(seconds: 4)),
      status: 'queued',
      uploadBytes: Uint8List.fromList([0, 1, 255]),
      uploadFilename: 'photo.png',
      enqueueOrder: 1,
      retryCount: 2,
      outboxPaused: true,
      lastErrorCode: 'temporary',
    );
    await db.upsertMessage(image);
    await db.upsertDraftRoom(
      const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      image,
    );
    inspector.clear();
    final rooms = await db.watchRooms(userId: 'me').first;
    expect(rooms.map((room) => room.roomId), ['draft_peer', 'room']);
    final preview = rooms.first.lastMessage!;
    expect(preview.id, image.id);
    expect(preview.type, 'image');
    expect(preview.text, image.text);
    expect(preview.status, 'queued');
    expect(preview.outboxPaused, true);
    expect(preview.uploadBytes, isNull);
    expect(rooms.first.sortTimestamp, image.createdAt);
    expect(rooms.last.lastMessage!.id, 'failed-text');
    expect(rooms.last.lastMessage!.status, 'failed');
    final sql = statement(queries(inspector).single);
    for (final excluded in [
      'upload_bytes',
      'upload_filename',
      'reply_to_json',
      'enqueue_order',
      'retry_count',
      'last_error_code',
    ]) {
      expect(sql, isNot(contains(excluded)));
    }
    final full = (await db.message(image.id))!;
    final conversation =
        (await db.watchMessages('draft_peer', 30).first).single;
    final outbound = (await db.outboundSnapshot('me')).head!;
    for (final stored in [full, conversation, outbound]) {
      expect(stored.uploadBytes, [0, 1, 255]);
      expect(stored.uploadFilename, 'photo.png');
      expect(stored.retryCount, 2);
      expect(stored.outboxPaused, true);
      expect(stored.lastErrorCode, 'temporary');
    }
  });

  for (final protocol in ['sequence', 'legacy']) {
    test(
      '$protocol no-op receipt does not reread messages; committed receipt refreshes ticks and rollback preserves state',
      () async {
        final outgoing = protocol == 'sequence'
            ? sequenced(2)
            : message('outgoing');
        await db.upsertRoom(
          protocol == 'sequence'
              ? sequenceRoom()
              : ChatRoom.fromJson(payload()),
        );
        await db.upsertMessages([
          outgoing,
          message('incoming', sender: 'peer'),
        ]);
        final emissions = <List<ChatMessage>>[];
        final initial = Completer<void>();
        final seen = Completer<void>();
        final subscription = db.watchMessages('room', 30).listen((messages) {
          emissions.add(messages);
          if (!initial.isCompleted) initial.complete();
          if (messages.any(
                (message) => message.id == outgoing.id && message.isSeen,
              ) &&
              !seen.isCompleted) {
            seen.complete();
          }
        });
        addTearDown(subscription.cancel);
        await initial.future;

        Future<void> receipt({required bool matches}) async {
          if (protocol == 'sequence') {
            await db.applyReceiptPayload(
              {
                'roomId': 'room',
                'eventType': 'room_peer_seen',
                'peerDeliveredSeq': matches ? 2 : 1,
                'peerSeenSeq': matches ? 2 : 1,
                'contentPts': 1,
              },
              pts: matches ? 3 : 2,
              myUserId: 'me',
            );
          } else {
            await db.applyRoomPayload({
              ...payload(pts: matches ? 3 : 2, event: 'room_peer_seen'),
              'actionTimestamp':
                  (matches
                          ? instant
                          : instant.subtract(const Duration(seconds: 1)))
                      .toIso8601String(),
            }, myUserId: 'me');
          }
        }

        inspector.clear();
        await receipt(matches: false);
        await pumpEventQueue();
        expect(emissions, hasLength(1));
        expect(
          queries(inspector).where(
            (event) =>
                event['name'] == 'query.select' &&
                statement(event).contains('FROM "local_messages"'),
          ),
          isEmpty,
        );
        await expectLater(
          db.transaction(() async {
            await receipt(matches: true);
            throw StateError('rollback receipt');
          }),
          throwsStateError,
        );
        await pumpEventQueue();
        expect(
          emissions.last
              .firstWhere((message) => message.id == outgoing.id)
              .isSeen,
          false,
        );
        expect((await db.message(outgoing.id))!.isSeen, false);
        final beforeCommit = emissions.length;
        await receipt(matches: true);
        await seen.future;
        expect(emissions, hasLength(beforeCommit + 1));
        final committed = emissions.last.firstWhere(
          (message) => message.id == outgoing.id,
        );
        expect(committed.isDelivered, true);
        expect(committed.isSeen, true);
        expect(committed.seenAt, isNull);
        expect(
          emissions.last
              .firstWhere((message) => message.id == 'incoming')
              .isSeen,
          false,
        );
        expect((await db.metadata())!.localPts, 0);
      },
    );
  }
}
