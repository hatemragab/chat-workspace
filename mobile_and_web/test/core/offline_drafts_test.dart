import 'dart:io';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test.dart' show instant, message, payload;

const _peer = UserProfile(
  id: 'peer',
  username: 'peer_name',
  displayName: 'Cached Peer',
  avatarUrl: '/public/uploads/cached-peer.png',
);

Future<void> _savePending(AppDatabase db, ChatMessage pending) =>
    db.transaction(() async {
      await db.upsertMessage(pending);
      await db.upsertDraftRoom(_peer, pending);
    });

void main() {
  test('an actual pending draft send creates a local inbox entry with peer metadata', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.initializeSession('me');
      expect(await db.watchRooms().first, isEmpty);
      // Confirmed messages cannot create a local-only draft summary.
      await db.upsertDraftRoom(_peer, message('confirmed', room: 'draft_peer'));
      expect(await db.watchRooms().first, isEmpty);

      final pending = message('pending', room: 'draft_peer', status: 'sending');
      await _savePending(db, pending);
      final draft = (await db.watchRooms().first).single;
      expect(draft.roomId, 'draft_peer');
      expect(draft.peerUserId, _peer.id);
      expect(draft.displayTitle, _peer.displayName);
      expect(draft.displayAvatarUrl, _peer.avatarUrl);
      expect(draft.lastMessage!.id, pending.id);
      expect(draft.lastMessage!.status, 'sending');
      expect(draft.sortTimestamp, pending.createdAt);
      expect([draft.roomPts, draft.msgPts, draft.messagesSyncedPts], [0, 0, 0]);

      await db.setMessageStatus(pending.id, 'failed');
      expect(
        (await db.watchRooms().first).single.lastMessage!.status,
        'failed',
      );
      expect((await db.metadata())!.localPts, 0);
      expect((await db.metadata())!.localEpoch, '');
    } finally {
      await db.close();
    }
  });

  test('pending draft sends sort by their latest local message without moving backwards', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.initializeSession('me');
      await db.upsertRoom(ChatRoom.fromJson(payload(room: 'real-room')));
      await _savePending(
        db,
        message('latest', room: 'draft_peer', status: 'sending', seconds: 1),
      );
      await _savePending(
        db,
        message('older', room: 'draft_peer', status: 'failed', seconds: -1),
      );
      final rooms = await db.watchRooms().first;
      expect(rooms.map((room) => room.roomId), ['draft_peer', 'real-room']);
      expect(rooms.first.lastMessage!.id, 'latest');
      expect(
        rooms.first.sortTimestamp,
        instant.add(const Duration(seconds: 1)),
      );
    } finally {
      await db.close();
    }
  });

  test('full inbox replacement retains only drafts with pending sends and still removes stale real rooms', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.initializeSession('me');
      await db.setCursor(17, 'existing-epoch');
      await db.upsertRoom(ChatRoom.fromJson(payload(room: 'stale-real')));
      await db.upsertMessage(message('old-history', room: 'stale-real'));
      await db.upsertRoom(ChatRoom.fromJson(payload(room: 'draft_empty')));
      await _savePending(
        db,
        message('pending', room: 'draft_peer', status: 'failed'),
      );

      await db.transaction(() => db.replaceFullInbox([payload(room: 'fresh')]));
      expect((await db.watchRooms().first).map((room) => room.roomId).toSet(), {
        'fresh',
        'draft_peer',
      });
      expect(await db.room('stale-real'), isNull);
      expect(await db.message('old-history'), isNotNull);
      expect(await db.room('draft_empty'), isNull);
      expect((await db.message('pending'))!.status, 'failed');
      expect((await db.room('draft_peer'))!.displayTitle, _peer.displayName);
      expect((await db.metadata())!.localPts, 17);
      expect((await db.metadata())!.localEpoch, 'existing-epoch');

      await db.removeMessage('pending');
      await db.transaction(() => db.replaceFullInbox([payload(room: 'fresh')]));
      expect(await db.room('draft_peer'), isNull);
    } finally {
      await db.close();
    }
  });

  test('draft acknowledgement remaps all pending rows and removes its summary atomically', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.initializeSession('me');
      await _savePending(
        db,
        message(
          'first',
          room: 'draft_peer',
          status: 'sending',
          key: 'first-key',
        ),
      );
      await _savePending(
        db,
        message('second', room: 'draft_peer', status: 'failed', seconds: 1),
      );

      await expectLater(
        db.transaction(() async {
          await db.remapDraft('draft_peer', 'real-room');
          throw StateError('Roll back this acknowledgement');
        }),
        throwsStateError,
      );
      expect(await db.room('draft_peer'), isNotNull);
      expect((await db.allMessages('draft_peer')).length, 2);
      expect(await db.allMessages('real-room'), isEmpty);

      await db.transaction(() async {
        await db.remapDraft('draft_peer', 'real-room');
        await db.upsertRoom(ChatRoom.fromJson(payload(room: 'real-room')));
        await db.upsertMessage(
          message('ack', room: 'real-room', key: 'first-key'),
        );
      });
      expect(await db.room('draft_peer'), isNull);
      expect(await db.allMessages('draft_peer'), isEmpty);
      expect(await db.message('first'), isNull);
      expect((await db.message('ack'))!.roomId, 'real-room');
      expect((await db.message('second'))!.roomId, 'real-room');
      expect((await db.message('second'))!.status, 'failed');
      expect((await db.watchRooms().first).single.roomId, 'real-room');

      await db.upsertMessage(
        message(
          'peer-copy',
          room: 'real-room',
          sender: 'peer',
          key: 'first-key',
        ),
      );
      expect((await db.message('ack'))!.senderId, 'me');
      expect((await db.message('peer-copy'))!.senderId, 'peer');

      await db.remapDraft('real-room', 'real-room');
      expect(await db.room('real-room'), isNotNull);
    } finally {
      await db.close();
    }
  });

  for (final status in ['queued', 'sending', 'failed']) {
    test(
      'a socket acknowledgement of a $status draft repairs the conversation without a REST response',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        try {
          await db.initializeSession('me');
          await _savePending(
            db,
            message(
              'temporary',
              room: 'draft_peer',
              status: status,
              key: 'shared-key',
            ),
          );
          await _savePending(
            db,
            message(
              'other-pending',
              room: 'draft_peer',
              status: 'failed',
              seconds: 1,
            ),
          );
          // Another sender's identical UUID must not acknowledge this draft.
          await db.upsertMessage(
            message(
              'peer-ack',
              room: 'other-room',
              sender: 'peer',
              key: 'shared-key',
            ),
          );
          expect((await db.message('temporary'))!.roomId, 'draft_peer');
          expect(await db.room('draft_peer'), isNotNull);

          final acknowledged = message(
            'server-ack',
            room: 'real-room',
            key: 'shared-key',
          );
          await db.transaction(
            () => db.applyRoomPayload(
              payload(room: 'real-room', pts: 2, last: acknowledged),
              myUserId: 'me',
            ),
          );
          // A lost HTTP response can subsequently mark its old temporary ID
          // failed. The confirmed server message and remap must remain intact.
          await db.setMessageStatus('temporary', 'failed');
          expect(await db.message('temporary'), isNull);
          expect(await db.room('draft_peer'), isNull);
          expect(await db.allMessages('draft_peer'), isEmpty);
          expect((await db.message('server-ack'))!.status, 'sent');
          expect((await db.message('other-pending'))!.roomId, 'real-room');
          expect((await db.message('other-pending'))!.status, 'failed');
          expect((await db.message('peer-ack'))!.roomId, 'other-room');
          expect(
            (await db.messageByIdempotencyKey('me', 'shared-key'))!.id,
            'server-ack',
          );
          expect(
            (await db.messageByIdempotencyKey('peer', 'shared-key'))!.id,
            'peer-ack',
          );
          expect((await db.watchRooms().first).single.roomId, 'real-room');
        } finally {
          await db.close();
        }
      },
    );
  }

  test('standalone acknowledgement rolls back remapping if the confirmed insert fails', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.initializeSession('me');
      await _savePending(
        db,
        message(
          'temporary',
          room: 'draft_peer',
          status: 'sending',
          key: 'shared-key',
        ),
      );
      await _savePending(
        db,
        message(
          'other-pending',
          room: 'draft_peer',
          status: 'failed',
          seconds: 1,
        ),
      );
      await db.customStatement('''
        CREATE TEMP TRIGGER reject_test_ack BEFORE INSERT ON local_messages
        WHEN NEW.id = 'server-ack'
        BEGIN SELECT RAISE(ABORT, 'Synthetic acknowledgement insert failure'); END
      ''');

      await expectLater(
        db.upsertMessage(
          message('server-ack', room: 'real-room', key: 'shared-key'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(await db.message('server-ack'), isNull);
      expect(await db.room('draft_peer'), isNotNull);
      expect((await db.message('temporary'))!.roomId, 'draft_peer');
      expect((await db.message('temporary'))!.status, 'sending');
      expect((await db.message('other-pending'))!.roomId, 'draft_peer');
      expect(await db.allMessages('real-room'), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('startup backfills historical orphan drafts without losing retry keys or account isolation', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.initializeSession('me');
      await db.setCursor(17, 'existing-epoch');
      await db.upsertMessage(
        message(
          'older',
          room: 'draft_peer',
          status: 'failed',
          key: 'older-key',
        ),
      );
      await db.upsertMessage(
        message('newer', room: 'draft_peer', status: 'sending', seconds: 1),
      );
      expect(await db.watchRooms().first, isEmpty);

      await db.initializeSession('me');
      final draft = (await db.watchRooms().first).single;
      expect(draft.roomId, 'draft_peer');
      expect(draft.peerUserId, 'peer');
      expect(draft.displayTitle, 'peer');
      expect(draft.lastMessage!.id, 'newer');
      expect(draft.lastMessage!.status, 'queued');
      expect(draft.lastMessage!.outcomeUnknown, isTrue);
      expect((await db.message('older'))!.idempotencyKey, 'older-key');
      expect((await db.metadata())!.localPts, 17);
      await db.initializeSession('me');
      expect((await db.watchRooms().first).length, 1);

      await db.initializeSession('other');
      expect(await db.watchRooms().first, isEmpty);
      expect(await db.allMessages('draft_peer'), isEmpty);
      expect((await db.metadata())!.userId, 'other');
    } finally {
      await db.close();
    }
  });

  test('pending draft metadata and messages survive a database reopen while offline', () async {
    final directory = await Directory.systemTemp.createTemp(
      'chat-offline-draft-',
    );
    final file = File('${directory.path}/cache.sqlite');
    final db = AppDatabase(NativeDatabase(file));
    try {
      await db.initializeSession('me');
      await _savePending(
        db,
        message('pending', room: 'draft_peer', status: 'sending'),
      );
    } finally {
      await db.close();
    }
    final reopened = AppDatabase(NativeDatabase(file));
    try {
      await reopened.initializeSession('me');
      final draft = (await reopened.watchRooms().first).single;
      expect(draft.displayTitle, _peer.displayName);
      expect(draft.displayAvatarUrl, _peer.avatarUrl);
      expect(draft.lastMessage!.id, 'pending');
      expect(draft.lastMessage!.status, 'queued');
      expect(draft.lastMessage!.outcomeUnknown, isTrue);
      expect(draft.sortTimestamp, instant);
      expect((await reopened.allMessages(draft.roomId)).single.id, 'pending');
    } finally {
      await reopened.close();
      await directory.delete(recursive: true);
    }
  });
}
