import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'review_regressions_test.dart' show delta;
import 'sync_test.dart' show FakeApi, instant, message, payload;

Future<void> _draft(AppDatabase db, int number) => db.transaction(() async {
  final peerId = 'draft-peer-$number';
  final pending = message(
    'pending-$number',
    room: 'draft_$peerId',
    status: 'failed',
    seconds: -100 - number,
  );
  await db.upsertDraftRoom(
    UserProfile(id: peerId, username: peerId, displayName: peerId),
    pending,
  );
  await db.upsertMessage(pending);
});

void main() {
  test(
    'old pending drafts cannot become a server room pagination cursor',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      final sync = InboxSyncService(
        database: db,
        api: api,
        userId: 'me',
        isCurrentSession: () => true,
      );
      try {
        await db.initializeSession('me');
        await db.setCursor(24, 'epoch');
        for (var i = 0; i < 24; i++) {
          await db.upsertRoom(
            ChatRoom.fromJson({
              ...payload(room: 'real-$i'),
              'sortTimestamp': instant
                  .add(Duration(seconds: i))
                  .toIso8601String(),
            }),
          );
        }
        await _draft(db, 1);
        var pages = 0;
        api.handler = (path, query) async {
          if (path == '/rooms/delta') return delta(24, []);
          expect(path, '/rooms');
          expect(query!['beforeRoomId'], 'real-0');
          expect(query['beforeSortTimestamp'], instant.toIso8601String());
          pages++;
          return {'rooms': <Map<String, dynamic>>[], 'nextCursor': null};
        };
        await sync.syncInboxDelta();
        expect(sync.hasMoreRooms, false);
        expect((await db.watchRooms().first).length, 25);
        await sync.loadMoreRooms();
        expect(pages, 0);
        expect(
          (await db.allMessages('draft_draft-peer-1')).single.status,
          'failed',
        );
      } finally {
        await sync.dispose();
        await db.close();
      }
    },
  );

  test('a draft-only inbox never invents more server pages or sends a draft cursor', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    final sync = InboxSyncService(
      database: db,
      api: api,
      userId: 'me',
      isCurrentSession: () => true,
    );
    try {
      await db.initializeSession('me');
      for (var i = 0; i < 25; i++) {
        await _draft(db, i);
      }
      var requests = 0;
      api.handler = (path, _) async {
        expect(path, '/rooms/delta');
        requests++;
        return delta(0, []);
      };
      await sync.syncInboxDelta();
      expect(sync.hasMoreRooms, false);
      await sync.loadMoreRooms();
      expect(requests, 1);
      expect((await db.watchRooms().first).length, 25);
    } finally {
      await sync.dispose();
      await db.close();
    }
  });
}
