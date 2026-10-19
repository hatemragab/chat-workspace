import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test.dart' show message;

String legacyCacheSql(int version) {
  assert(version == 1 || version == 2);
  return '''
        CREATE TABLE sync_metadata (
          id INTEGER NOT NULL DEFAULT 1 PRIMARY KEY,
          user_id TEXT NOT NULL, local_pts INTEGER NOT NULL DEFAULT 0,
          local_epoch TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE local_rooms (
          room_id TEXT NOT NULL PRIMARY KEY, room_type TEXT NOT NULL,
          peer_user_id TEXT, display_title TEXT NOT NULL, display_avatar_url TEXT,
          pin_at INTEGER, is_muted INTEGER NOT NULL DEFAULT 0,
          unread_count INTEGER NOT NULL DEFAULT 0, cleared_at INTEGER,
          deleted_at INTEGER, sort_timestamp INTEGER NOT NULL,
          room_pts INTEGER NOT NULL, msg_pts INTEGER NOT NULL,
          last_history_edit_pts INTEGER NOT NULL DEFAULT 0,
          messages_synced_pts INTEGER NOT NULL DEFAULT 0, last_message_json TEXT
        );
        CREATE TABLE local_messages (
          id TEXT NOT NULL PRIMARY KEY, idempotency_key TEXT NOT NULL ${version == 1 ? 'UNIQUE' : ''},
          room_id TEXT NOT NULL, peer_user_id TEXT, sender_id TEXT NOT NULL,
          sender_name TEXT NOT NULL, sender_avatar_url TEXT, type TEXT NOT NULL,
          text TEXT NOT NULL, image_url TEXT, reply_to_json TEXT,
          status TEXT NOT NULL, is_edited INTEGER NOT NULL DEFAULT 0,
          is_deleted_for_all INTEGER NOT NULL DEFAULT 0, delivered_at INTEGER,
          seen_at INTEGER, created_at INTEGER NOT NULL
          ${version == 2 ? ', UNIQUE(sender_id, idempotency_key)' : ''}
        );
        CREATE INDEX local_messages_room_created
          ON local_messages (room_id, created_at, id);
        INSERT INTO sync_metadata VALUES (1, 'me', 17, 'existing-epoch');
        INSERT INTO local_rooms
          (room_id, room_type, display_title, sort_timestamp, room_pts, msg_pts,
           messages_synced_pts)
          VALUES ('room', 'direct', 'Existing', 1000, 17, 15, 15);
        INSERT INTO local_messages
          (id, idempotency_key, room_id, sender_id, sender_name, type, text,
           status, delivered_at, seen_at, created_at)
          VALUES ('sent', 'shared-key', 'room', 'me', 'Me', 'text', 'retained',
                  'sent', 2000, 3000, 1000),
                 ('pending', 'pending-key', 'draft_peer', 'me', 'Me', 'text',
                  'pending text', 'sending', NULL, NULL, 4000),
                 ('failed', 'failed-key', 'draft_peer', 'me', 'Me', 'text',
                  'failed text', 'failed', NULL, NULL, 5000);
        PRAGMA user_version = $version;
      ''';
}

void main() {
  for (final version in [1, 2]) {
    test(
      'v$version migration invalidates only message certification and preserves sender-scoped rows',
      () async {
        final executor = NativeDatabase.memory(
          setup: (raw) {
            raw.execute(legacyCacheSql(version));
          },
        );
        final db = AppDatabase(executor);
        try {
          final metadata = (await db.metadata())!;
          expect(metadata.localPts, 17);
          expect(metadata.localEpoch, 'existing-epoch');
          expect((await db.room('room'))!.messagesSyncedPts, 0);
          expect((await db.room('room'))!.msgPts, 15);
          expect((await db.room('room'))!.roomPts, 17);
          expect((await db.allMessages('room')).length, 1);
          expect((await db.allMessages('draft_peer')).length, 2);
          expect((await db.message('sent'))!.text, 'retained');
          expect(
            (await db.message('sent'))!.seenAt!.millisecondsSinceEpoch,
            3000,
          );
          expect((await db.message('pending'))!.status, 'sending');
          expect((await db.message('failed'))!.status, 'failed');
          expect((await db.message('pending'))!.roomId, 'draft_peer');
          expect(
            (await db.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version'),
            6,
          );
          final indexes = await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type = 'index'",
              )
              .get();
          expect(
            indexes.map((r) => r.read<String>('name')),
            contains('local_messages_room_created'),
          );

          // The accepted backend scope must also be accepted by the migrated DB.
          await db.upsertMessage(
            message('peer-copy', sender: 'peer', key: 'shared-key'),
          );
          expect((await db.message('sent'))!.senderId, 'me');
          expect((await db.message('peer-copy'))!.senderId, 'peer');
          await db.upsertMessage(message('acknowledged', key: 'pending-key'));
          expect(await db.message('pending'), isNull);
          expect((await db.message('acknowledged'))!.status, 'sent');
          expect(
            (await db.messageByIdempotencyKey('me', 'shared-key'))!.id,
            'sent',
          );
          expect(
            (await db.messageByIdempotencyKey('peer', 'shared-key'))!.id,
            'peer-copy',
          );
        } finally {
          await db.close();
        }
      },
    );
  }
}
