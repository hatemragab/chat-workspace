import 'dart:convert';
import 'dart:io';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'schema_migration_test.dart' show legacyCacheSql;
import 'sync_test.dart' show FakeApi, instant, message, testServerHealth;

final _staleQuote = ReplySnapshot.fromJson({
  'messageId': 'hidden-original',
  'senderId': 'peer',
  'senderName': 'Peer',
  'type': 'text',
  'text': 'Obsolete private preview',
  'imageUrl': null,
  'isDeleted': false,
});

AppDatabase _legacyDatabase(int version, {bool staleQuote = false}) =>
    AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute(legacyCacheSql(version));
          raw.execute(
            "UPDATE local_messages SET delivered_at = NULL, seen_at = NULL WHERE id = 'sent'",
          );
          // Retained history overlaps the oldest row of the next latest page.
          raw.execute(
            '''INSERT INTO local_messages
              (id, idempotency_key, room_id, sender_id, sender_name, type,
               text, status, created_at)
              VALUES ('tail30', 'tail30', 'room', 'me', 'Me', 'text',
                      'tail30', 'sent', ?)''',
            [instant.add(const Duration(seconds: 30)).millisecondsSinceEpoch],
          );
          if (staleQuote) {
            raw.execute('UPDATE local_rooms SET last_history_edit_pts = 12');
            raw.execute(
              "UPDATE local_messages SET reply_to_json = ? WHERE id = 'sent'",
              [jsonEncode(_staleQuote.toJson())],
            );
          }
        },
      ),
    );

FakeApi _unchangedInboxApi(
  Map<String, dynamic> Function(Map<String, dynamic>?) latest,
) => FakeApi()
  ..handler = (path, query) async {
    if (path == '/rooms/delta') {
      expect(query?['sincePts'], 17);
      expect(query?['epoch'], 'existing-epoch');
      return {
        'requiresFullSync': false,
        'pts': 17,
        'epoch': 'existing-epoch',
        'rooms': [],
      };
    }
    if (path == '/rooms/room/messages') return latest(query);
    if (path == '/presence/status') return {'statuses': <String, bool>{}};
    throw StateError('Unexpected GET $path');
  };

List<ChatMessage> _latestMessages({bool seen = false}) => List.generate(
  30,
  (index) => message('tail${59 - index}', seconds: 59 - index).copyWith(
    deliveredAt: seen ? instant.add(const Duration(minutes: 2)) : null,
    seenAt: seen ? instant.add(const Duration(minutes: 2)) : null,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode({
        'user': {'id': 'me', 'username': 'me', 'displayName': 'Me'},
        'accessToken': 'synthetic-token',
        'centrifugoToken': 'synthetic-realtime-token',
      }),
    });
  });

  for (final version in [1, 2]) {
    test(
      'v$version upgrade repairs older receipts despite an unchanged inbox and then reuses its cache',
      () async {
        final db = _legacyDatabase(version);
        final through = instant.add(const Duration(seconds: 59));
        final api = _unchangedInboxApi(
          (_) => {
            'messages': _latestMessages(seen: true)
                .map((m) => m.toJson())
                .toList(),
            'hasMore': true,
            'receipts': {
              'deliveredThrough': through.toIso8601String(),
              'seenThrough': through.toIso8601String(),
              'hasGaps': false,
            },
          },
        );
        final controller = ChatController(
          database: db,
          api: api,
          enableRealtime: false,
          healthMonitorFactory: testServerHealth,
        );
        try {
          await controller.initialize();
          expect(controller.initialized, true);
          expect(controller.error, isNull);
          expect((await db.room('room'))!.messagesSyncedPts, 0);
          expect((await db.message('sent'))!.seenAt, isNull);
          await controller.openRoom((await db.room('room'))!);
          await controller.syncNow();
          expect(controller.error, isNull);
          expect(api.messageRequests, 1);
          expect((await db.message('sent'))!.isSeen, true);
          expect((await db.message('sent'))!.seenAt, isNull);
          expect((await db.message('sent'))!.text, 'retained');
          expect((await db.allMessages('room')).length, 31);
          expect((await db.message('pending'))!.status, 'queued');
          expect((await db.message('pending'))!.outcomeUnknown, isTrue);
          expect((await db.message('failed'))!.status, 'failed');
          expect((await db.message('pending'))!.roomId, 'draft_peer');
          expect((await db.metadata())!.localPts, 17);
          expect((await db.metadata())!.localEpoch, 'existing-epoch');
          expect((await db.room('room'))!.messagesSyncedPts, 15);

          await controller.closeRoom();
          await controller.openRoom((await db.room('room'))!);
          await controller.syncNow();
          expect(api.messageRequests, 1);
          expect((await db.message('sent'))!.isSeen, true);
          expect((await db.message('sent'))!.seenAt, isNull);
        } finally {
          await controller.logout();
          await db.close();
        }
      },
    );

    test(
      'v$version upgrade invalidates stale older quotes before fetching their current history',
      () async {
        final db = _legacyDatabase(version, staleQuote: true);
        final sanitized = message('sent', seconds: -60).copyWith(
          replyTo: ReplySnapshot.fromJson({
            ..._staleQuote.toJson(),
            'text': '🚫 This message was deleted',
            'isDeleted': true,
          }),
        );
        final api = _unchangedInboxApi(
          (query) => {
            'messages': query?['beforeId'] != null
                ? [sanitized.toJson()]
                : _latestMessages().map((m) => m.toJson()).toList(),
            'hasMore': query?['beforeId'] == null,
            if (query?['beforeId'] == null)
              'receipts': {
                'deliveredThrough': null,
                'seenThrough': null,
                'hasGaps': false,
              },
          },
        );
        final controller = ChatController(
          database: db,
          api: api,
          enableRealtime: false,
          healthMonitorFactory: testServerHealth,
        );
        try {
          await controller.initialize();
          expect((await db.message('sent'))!.replyTo!.isDeleted, false);
          await controller.openRoom((await db.room('room'))!);
          await controller.syncNow();
          expect(controller.error, isNull);
          expect(api.messageRequests, 1);
          expect(await db.message('sent'), isNull);
          expect(await db.message('hidden-original'), isNull);
          expect((await db.message('pending'))!.roomId, 'draft_peer');
          expect((await db.message('failed'))!.text, 'failed text');
          await controller.loadOlderMessages();
          expect(controller.error, isNull);
          expect(api.messageRequests, 2);
          expect((await db.message('sent'))!.replyTo!.isDeleted, true);
          expect(
            (await db.message('sent'))!.replyTo!.text,
            '🚫 This message was deleted',
          );
          expect(await db.message('hidden-original'), isNull);
          await controller.closeRoom();
          await controller.openRoom((await db.room('room'))!);
          await controller.syncNow();
          expect(api.messageRequests, 2);
        } finally {
          await controller.logout();
          await db.close();
        }
      },
    );
  }

  test(
    'a verified v3 baseline survives closing and reopening the database',
    () async {
      final directory = await Directory.systemTemp.createTemp('chat-upgrade-');
      final file = File('${directory.path}/cache.sqlite');
      final db = AppDatabase(
        NativeDatabase(file, setup: (raw) => raw.execute(legacyCacheSql(2))),
      );
      try {
        expect((await db.room('room'))!.messagesSyncedPts, 0);
        await db.markMessagesSynced('room', 15);
      } finally {
        await db.close();
      }
      final reopened = AppDatabase(NativeDatabase(file));
      final api = _unchangedInboxApi(
        (_) => throw StateError('Unexpected refetch'),
      );
      final controller = ChatController(
        database: reopened,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      try {
        await controller.initialize();
        expect((await reopened.room('room'))!.messagesSyncedPts, 15);
        await controller.openRoom((await reopened.room('room'))!);
        await controller.syncNow();
        expect(controller.error, isNull);
        expect(api.messageRequests, 0);
        expect((await reopened.message('sent'))!.text, 'retained');
        expect((await reopened.metadata())!.localPts, 17);
      } finally {
        await controller.logout();
        await reopened.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
