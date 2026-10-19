import 'dart:typed_data';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'schema_migration_test.dart' show legacyCacheSql;

ChatMessage outgoing(
  String key, {
  String sender = 'me',
  String room = 'draft_peer',
  String status = 'queued',
  int timestamp = 1000,
  Uint8List? bytes,
}) => ChatMessage(
  id: 'temp_$sender$key',
  idempotencyKey: key,
  roomId: room,
  peerUserId: 'peer',
  senderId: sender,
  senderName: sender,
  type: bytes == null ? 'text' : 'image',
  text: key,
  status: status,
  createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
  uploadBytes: bytes,
  uploadFilename: bytes == null ? null : 'pending.png',
);

const peer = UserProfile(id: 'peer', username: 'peer', displayName: 'Peer');

String outboxLegacySql(int version) {
  final statements = [legacyCacheSql(version == 1 ? 1 : 2)];
  if (version >= 4) {
    statements.add('''
      ALTER TABLE sync_metadata ADD COLUMN room_page_cursor_json TEXT;
      ALTER TABLE sync_metadata ADD COLUMN room_page_epoch TEXT;
      ALTER TABLE sync_metadata ADD COLUMN room_page_known INTEGER NOT NULL DEFAULT 0;
      UPDATE sync_metadata SET room_page_cursor_json='{"beforeRoomId":"saved"}',
        room_page_epoch='existing-epoch', room_page_known=1;
      ALTER TABLE local_messages ADD COLUMN reply_target_id TEXT;
      ALTER TABLE local_messages ADD COLUMN upload_bytes BLOB;
      ALTER TABLE local_messages ADD COLUMN upload_filename TEXT;
      CREATE INDEX local_messages_reply_target ON local_messages(room_id,reply_target_id);
      UPDATE local_messages SET upload_bytes=X'010203',
        upload_filename='pending.png' WHERE id='pending';
    ''');
  }
  if (version >= 5) {
    statements.add('''
      ALTER TABLE local_messages ADD COLUMN message_seq INTEGER;
      ALTER TABLE local_messages ADD COLUMN delivered_by_cursor INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE local_messages ADD COLUMN seen_by_cursor INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE local_rooms ADD COLUMN content_pts INTEGER;
      ALTER TABLE local_rooms ADD COLUMN receipt_protocol TEXT NOT NULL DEFAULT 'legacy';
      ALTER TABLE local_rooms ADD COLUMN peer_delivered_seq INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE local_rooms ADD COLUMN peer_seen_seq INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE local_rooms ADD COLUMN own_delivered_seq INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE local_rooms ADD COLUMN own_seen_seq INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE local_rooms ADD COLUMN received_through_seq INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE local_rooms ADD COLUMN verified_head_seq INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE local_rooms ADD COLUMN received_ranges_json TEXT NOT NULL DEFAULT '[]';
      CREATE TABLE receipt_tasks (
        room_id TEXT NOT NULL PRIMARY KEY,
        receipt_protocol TEXT NOT NULL DEFAULT 'legacy',
        delivered_target_seq INTEGER NOT NULL DEFAULT 0,
        seen_target_seq INTEGER NOT NULL DEFAULT 0,
        delivered_confirmed_seq INTEGER NOT NULL DEFAULT 0,
        seen_confirmed_seq INTEGER NOT NULL DEFAULT 0,
        delivered_target_timestamp INTEGER, seen_target_timestamp INTEGER,
        delivered_confirmed_timestamp INTEGER, seen_confirmed_timestamp INTEGER
      );
      INSERT INTO receipt_tasks(room_id, delivered_target_seq) VALUES('room', 7);
      UPDATE local_messages SET message_seq=4, delivered_by_cursor=1 WHERE id='sent';
    ''');
  }
  statements.add('PRAGMA user_version=$version;');
  return statements.join('\n');
}

void main() {
  for (final version in [1, 2, 3, 4, 5]) {
    test(
      'v$version upgrade retains rows and cursors with recoverable outbox',
      () async {
        final db = AppDatabase(
          NativeDatabase.memory(
            setup: (raw) => raw.execute(outboxLegacySql(version)),
          ),
        );
        addTearDown(db.close);
        final metadata = (await db.metadata())!;
        expect(metadata.localPts, 17);
        expect(metadata.localEpoch, 'existing-epoch');
        expect(metadata.lastOutboundOrder, 1);
        expect(
          (await db.room('room'))!.messagesSyncedPts,
          version < 3 ? 0 : 15,
        );
        final sent = (await db.message('sent'))!;
        expect(sent.text, 'retained');
        expect(sent.deliveredAt!.millisecondsSinceEpoch, 2000);
        expect(sent.seenAt!.millisecondsSinceEpoch, 3000);
        expect(sent.enqueueOrder, isNull);
        expect((await db.message('failed'))!.status, 'failed');
        expect((await db.message('failed'))!.enqueueOrder, isNull);
        if (version >= 4) {
          expect(metadata.roomPageCursorJson, '{"beforeRoomId":"saved"}');
          expect(metadata.roomPageKnown, isTrue);
          expect((await db.message('pending'))!.uploadBytes, [1, 2, 3]);
          expect((await db.message('pending'))!.uploadFilename, 'pending.png');
        }
        if (version == 5) {
          expect(sent.messageSeq, 4);
          expect(sent.deliveredByCursor, isTrue);
          expect(
            (await db.select(db.receiptTasks).get()).single.deliveredTargetSeq,
            7,
          );
        }
        await db.initializeSession('me');
        final interrupted = (await db.nextOutboundMessage('me'))!;
        expect(interrupted.id, 'pending');
        expect(interrupted.status, 'queued');
        expect(interrupted.outcomeUnknown, isTrue);
        expect((await db.message('failed'))!.status, 'failed');
        expect((await db.metadata())!.localPts, 17);
        expect((await db.room('draft_peer'))!.lastMessage!.id, 'failed');
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          6,
        );
      },
    );
  }

  test('FIFO uses durable allocation rather than timestamps and survives a drained queue', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.initializeSession('me');
    await db.enqueueOutboundMessage(
      outgoing('first', timestamp: 3000),
      peer: peer,
    );
    await db.enqueueOutboundMessage(
      outgoing('second', timestamp: 1000),
      peer: peer,
    );
    expect((await db.nextOutboundMessage('me'))!.idempotencyKey, 'first');
    expect((await db.messageByIdempotencyKey('me', 'second'))!.enqueueOrder, 2);
    await db.updateOutboundState('me', 'first', status: 'failed');
    expect((await db.nextOutboundMessage('me'))!.idempotencyKey, 'second');
    await db.upsertMessage(
      ChatMessage.fromJson({
        ...outgoing('second').toJson(),
        'id': 'server-second',
        'roomId': 'real-room',
        'status': 'sent',
      }),
    );
    await db.initializeSession('me');
    await db.setCursor(20, 'epoch');
    await db.saveRoomPage('epoch', {'beforeRoomId': 'saved'});
    await db.enqueueOutboundMessage(
      outgoing('third', timestamp: 0),
      peer: peer,
    );
    expect((await db.nextOutboundMessage('me'))!.enqueueOrder, 3);
    expect((await db.metadata())!.localPts, 20);
    expect((await db.metadata())!.lastOutboundOrder, 3);
  });

  test(
    'enqueue and draft are atomic and duplicate enqueue cannot mutate payload',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.initializeSession('me');
      await expectLater(
        db.transaction(() async {
          await db.enqueueOutboundMessage(outgoing('rolled-back'), peer: peer);
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(await db.messageByIdempotencyKey('me', 'rolled-back'), isNull);
      expect(await db.room('draft_peer'), isNull);
      expect((await db.metadata())!.lastOutboundOrder, 0);
      await db.enqueueOutboundMessage(outgoing('kept'), peer: peer);
      await db.enqueueOutboundMessage(
        outgoing('kept', timestamp: 5000),
        peer: peer,
      );
      expect(
        (await db.messageByIdempotencyKey(
          'me',
          'kept',
        ))!.createdAt.millisecondsSinceEpoch,
        1000,
      );
      expect((await db.metadata())!.lastOutboundOrder, 1);
      await expectLater(
        db.enqueueOutboundMessage(outgoing('wrong', sender: 'other')),
        throwsStateError,
      );
      expect(await db.messageByIdempotencyKey('other', 'wrong'), isNull);
    },
  );

  test('paused and delayed head remains first and scoped state updates preserve metadata', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.initializeSession('me');
    await db.enqueueOutboundMessage(outgoing('shared'), peer: peer);
    await db.enqueueOutboundMessage(outgoing('newer'), peer: peer);
    await db.upsertMessage(outgoing('shared', sender: 'other'));
    final retryAt = DateTime.utc(2026, 10, 19);
    await db.updateOutboundState(
      'me',
      'shared',
      status: 'queued',
      retryCount: 2,
      nextAttemptAt: retryAt,
      errorCode: 'unavailable',
      errorMessage: 'Server temporarily unavailable.',
      outcomeUnknown: true,
      paused: true,
    );
    await db.updateOutboundState('me', 'shared', retryCount: 3);
    final head = (await db.nextOutboundMessage('me'))!;
    expect(head.idempotencyKey, 'shared');
    expect(head.outboxPaused, isTrue);
    expect(head.nextAttemptAt, retryAt);
    expect(head.lastErrorCode, 'unavailable');
    expect(head.retryCount, 3);
    expect(
      (await db.messageByIdempotencyKey('other', 'shared'))!.retryCount,
      0,
    );
    await db.retryOutboundMessage('me', 'shared');
    final retried = (await db.nextOutboundMessage('me'))!;
    expect(retried.enqueueOrder, head.enqueueOrder);
    expect(retried.outcomeUnknown, isTrue);
    expect(retried.retryCount, 0);
    expect(retried.nextAttemptAt, isNull);
    expect(retried.lastErrorCode, isNull);
    expect(retried.lastErrorText, isNull);
    expect(retried.outboxPaused, isFalse);
  });

  test('ack clears outbox atomically and all stale local writes cannot downgrade it', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.initializeSession('me');
    final pending = outgoing('ack', bytes: Uint8List.fromList([1, 2, 3]));
    await db.enqueueOutboundMessage(pending, peer: peer);
    await db.enqueueOutboundMessage(outgoing('later'), peer: peer);
    await db.updateOutboundState(
      'me',
      'ack',
      status: 'sending',
      retryCount: 2,
      nextAttemptAt: DateTime.utc(2026, 10, 19),
      errorCode: 'unavailable',
      errorMessage: 'Try later.',
      outcomeUnknown: true,
      paused: true,
    );
    final ack = ChatMessage.fromJson({
      ...pending.toJson(),
      'id': 'server-ack',
      'roomId': 'real-room',
      'status': 'sent',
    });
    await db.upsertMessage(ack);
    await db.updateOutboundState(
      'me',
      'ack',
      status: 'failed',
      retryCount: 10,
      paused: true,
    );
    await db.upsertMessage(pending.copyWith(status: 'failed'));
    await db.retryOutboundMessage('me', 'ack');
    await db.enqueueOutboundMessage(pending, peer: peer);
    expect(await db.message(pending.id), isNull);
    final stored = (await db.messageByIdempotencyKey('me', 'ack'))!;
    expect(stored.id, 'server-ack');
    expect(stored.status, 'sent');
    expect(stored.enqueueOrder, isNull);
    expect(stored.retryCount, 0);
    expect(stored.nextAttemptAt, isNull);
    expect(stored.lastErrorCode, isNull);
    expect(stored.lastErrorText, isNull);
    expect(stored.outcomeUnknown, isFalse);
    expect(stored.outboxPaused, isFalse);
    expect(stored.uploadBytes, isNull);
    expect(await db.room('draft_peer'), isNull);
    expect((await db.nextOutboundMessage('me'))!.roomId, 'real-room');
    expect((await db.metadata())!.localPts, 0);
  });

  test('queued drafts and image bytes survive full inbox/history replacement and recovery', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.initializeSession('me');
    await db.enqueueOutboundMessage(
      outgoing('image', bytes: Uint8List.fromList([3, 2, 1])),
      peer: peer,
    );
    await db.replaceFullInbox([]);
    expect((await db.room('draft_peer'))!.lastMessage!.status, 'queued');
    expect((await db.watchRooms().first).single.lastMessage!.status, 'queued');
    await db.reconcileLatest('draft_peer', [], 0, 0, 0);
    await db.updateOutboundState('me', 'image', status: 'sending');
    await db.initializeSession('me');
    final restored = (await db.nextOutboundMessage('me'))!;
    expect(restored.status, 'queued');
    expect(restored.uploadBytes, [3, 2, 1]);
    expect(restored.outcomeUnknown, isTrue);
    await db.checkUploadQuota(1);
    await db.initializeSession('other');
    expect(await db.nextOutboundMessage('me'), isNull);
    expect((await db.metadata())!.lastOutboundOrder, 0);
  });

  test('model copy keeps metadata unless clearing it explicitly', () {
    final message = outgoing('copy').copyWith(
      enqueueOrder: 4,
      retryCount: 3,
      nextAttemptAt: DateTime.utc(2026),
      lastErrorCode: 'temporary',
      lastErrorText: 'Try later.',
      outcomeUnknown: true,
      outboxPaused: true,
    );
    final copied = ChatMessage.fromJson(
      message.copyWith(imageUrl: '/image').toJson(),
    );
    expect(copied.enqueueOrder, 4);
    expect(copied.lastErrorText, 'Try later.');
    expect(copied.outcomeUnknown, isTrue);
    final cleared = copied.copyWith(clearOutbox: true);
    expect(cleared.enqueueOrder, isNull);
    expect(cleared.retryCount, 0);
    expect(cleared.nextAttemptAt, isNull);
    expect(cleared.lastErrorText, isNull);
    expect(cleared.outboxPaused, isFalse);
    expect(cleared.outcomeUnknown, isFalse);
  });

  test('queued images count toward upload quota and diagnostics remain sender scoped', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.initializeSession('me');
    for (var index = 0; index < 20; index++) {
      await db.enqueueOutboundMessage(
        outgoing('image-$index', bytes: Uint8List.fromList([1])),
      );
    }
    await db.updateOutboundState('me', 'image-0', paused: true);
    await db.updateOutboundState('me', 'image-1', status: 'failed');
    await db.upsertMessage(
      outgoing('foreign', sender: 'other', status: 'failed'),
    );
    await expectLater(db.checkUploadQuota(1), throwsStateError);
    expect(await db.outboundCounts('me'), (queued: 19, failed: 1, paused: 1));
    expect(await db.outboundCounts('other'), (queued: 0, failed: 1, paused: 0));
    expect(await db.outboundCounts('absent'), (
      queued: 0,
      failed: 0,
      paused: 0,
    ));
  });
}
