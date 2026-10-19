import 'dart:async';
import 'dart:convert';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_test.dart' show FakeApi, instant, message, payload;

Map<String, dynamic> session(String id) => {
  'user': {'id': id, 'username': id, 'displayName': id},
  'accessToken': id,
  'centrifugoToken': id,
};

Future<void> waitForController(bool Function() predicate) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError('Expected controller state did not settle');
}

Map<String, dynamic> delta(int pts, List<Map<String, dynamic>> rooms) => {
  'requiresFullSync': false,
  'pts': pts,
  'epoch': 'epoch',
  'rooms': rooms,
};

class PausedDraftDatabase extends AppDatabase {
  PausedDraftDatabase() : super(NativeDatabase.memory());
  final paused = Completer<void>(), resume = Completer<void>();
  bool pauseOnce = true;
  @override
  Future<void> remapDraft(String draftId, String realId) async {
    if (pauseOnce) {
      pauseOnce = false;
      paused.complete();
      await resume.future;
    }
    await super.remapDraft(draftId, realId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('sender-scoped UUIDs coexist and stale acknowledgement cannot consume a peer row', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    );
    try {
      await db.upsertMessage(message('mine', key: 'same-key'));
      await db.upsertMessage(message('peer', sender: 'peer', key: 'same-key'));
      expect((await db.allMessages('room')).length, 2);
      await db.upsertRoom(ChatRoom.fromJson(payload(pts: 10)));
      final foreignAck = message(
        'foreign-ack',
        sender: 'another',
        key: 'same-key',
      );
      await sync.reconcileMutation({
        'room': payload(pts: 9),
        'message': foreignAck.toJson(),
      });
      expect(await db.message('foreign-ack'), isNull);
      expect((await db.message('mine'))!.senderId, 'me');
      expect((await db.message('peer'))!.senderId, 'peer');
    } finally {
      await sync.dispose();
      await db.close();
    }
  });

  test(
    'direct lookup paused in remap cannot continue into a switched account',
    () async {
      final db = PausedDraftDatabase();
      final api = FakeApi();
      api.authHandler = (body) async =>
          session(body['debugUserNumber'] == 1 ? 'me' : 'other');
      api.handler = (path, _) async {
        if (path.startsWith('/rooms/direct-peer/')) {
          return api.dio.options.headers['Authorization'] == 'Bearer me'
              ? {'room': payload(room: 'private-first-account')}
              : {'room': null};
        }
        return delta(0, []);
      };
      final seenCredentials = <Object?>[];
      api.otherPostHandler = (path, _) async {
        if (path.endsWith('/seen')) {
          seenCredentials.add(api.dio.options.headers['Authorization']);
        }
        return {'ok': true};
      };
      api.postHandler = (_, _) async => throw const ChatApiException('offline');
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        final opening = controller.openDirect(
          const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
        );
        await db.paused.future;
        final generation = controller.sessionGenerationId;
        final switching = controller.debugLogin(2);
        await Future<void>.delayed(Duration.zero);
        expect(controller.sessionGenerationId, greaterThan(generation));
        db.resume.complete();
        await Future.wait([opening, switching]);
        await controller.openDirect(
          const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
        );
        await controller.sendText('second account draft');
        expect(controller.currentUser!.id, 'other');
        expect(controller.selectedRoom, isNull);
        expect(controller.draftPeer!.id, 'peer');
        expect(await db.room('private-first-account'), isNull);
        expect(await db.allMessages('private-first-account'), isEmpty);
        expect((await db.allMessages('draft_peer')).single.senderId, 'other');
        expect(seenCredentials, isEmpty);
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test(
    'older direct lookup response cannot replace a newer conversation',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      final pending = Completer<Map<String, dynamic>>();
      api.handler = (path, _) async => path.endsWith('/peer-a')
          ? pending.future
          : path.startsWith('/rooms/direct-peer/')
          ? {'room': null}
          : delta(0, []);
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        final old = controller.openDirect(
          const UserProfile(id: 'peer-a', username: 'a', displayName: 'A'),
        );
        await Future<void>.delayed(Duration.zero);
        await controller.openDirect(
          const UserProfile(id: 'peer-b', username: 'b', displayName: 'B'),
        );
        pending.complete({'room': payload(room: 'a-room')});
        await old;
        expect(controller.draftPeer!.id, 'peer-b');
        expect(controller.selectedRoom, isNull);
        expect(await db.room('a-room'), isNull);
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test('coalesced seen then preference recovers all 60 ticks and unchanged reopen stays HTTP-free', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    var pts = 1;
    ChatMessage outgoing(int i) => message('m$i', seconds: i);
    api.handler = (path, query) async {
      if (path == '/rooms/delta') {
        return delta(
          pts,
          query?['sincePts'] == pts
              ? []
              : [
                  payload(
                    pts: pts,
                    msgPts: pts == 1 ? 1 : 2,
                    event: pts == 1 ? 'message_new' : 'room_preferences',
                    last: outgoing(59),
                  ),
                ],
        );
      }
      if (path.endsWith('/messages')) {
        return {
          'messages': List.generate(30, (i) => outgoing(59 - i).toJson()),
          'hasMore': true,
          'receipts': {
            'deliveredThrough': pts > 1
                ? outgoing(59).createdAt.toIso8601String()
                : null,
            'seenThrough': pts > 1
                ? outgoing(59).createdAt.toIso8601String()
                : null,
            'hasGaps': false,
          },
        };
      }
      throw StateError(path);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      await controller.openRoom((await db.room('room'))!);
      await controller.syncNow();
      await db.transaction(() async {
        for (var i = 0; i < 30; i++) {
          await db.upsertMessage(outgoing(i));
        }
        await db.upsertMessage(message('incoming', sender: 'peer'));
        await db.upsertMessage(message('pending', status: 'sending'));
        await db.upsertMessage(message('failed', status: 'failed'));
      });
      pts = 3;
      await controller.syncNow();
      for (var i = 0; i < 60; i++) {
        expect(
          (await db.message('m$i'))!.isSeen,
          true,
          reason: 'old outgoing $i',
        );
      }
      expect((await db.message('incoming'))!.seenAt, isNull);
      expect((await db.message('pending'))!.seenAt, isNull);
      expect((await db.message('failed'))!.seenAt, isNull);
      expect((await db.room('room'))!.messagesSyncedPts, 2);
      final calls = api.messageRequests;
      await controller.closeRoom();
      await controller.openRoom((await db.room('room'))!);
      expect(api.messageRequests, calls);
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  for (final gap in [false, true]) {
    test(
      '${gap ? 'gapped summary' : 'legacy response'} resets uncertifiable old ticks while retaining retry rows',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        try {
          await db.initializeSession('me');
          await db.upsertRoom(ChatRoom.fromJson(payload(pts: 3, msgPts: 2)));
          await db.upsertMessage(message('old'));
          await db.upsertMessage(message('overlap', seconds: 1));
          await db.upsertMessage(message('pending', status: 'sending'));
          await db.upsertMessage(message('failed', status: 'failed'));
          final kept = await db.reconcileLatest(
            'room',
            [message('overlap', seconds: 1)],
            2,
            0,
            1,
            myUserId: 'me',
            requireReceiptSummary: true,
            receipts: gap
                ? ReceiptWatermarks(seenThrough: instant, hasGaps: true)
                : null,
          );
          expect(kept, false);
          expect(await db.message('old'), isNull);
          expect((await db.message('overlap'))!.seenAt, isNull);
          expect((await db.message('pending'))!.status, 'sending');
          expect((await db.message('failed'))!.status, 'failed');
        } finally {
          await db.close();
        }
      },
    );
  }

  test('live receipt boundaries affect confirmed outgoing rows without acknowledging local failed or pending sends', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    );
    try {
      await db.setCursor(1, 'epoch');
      await db.upsertMessage(message('confirmed'));
      await db.upsertMessage(message('pending', status: 'sending'));
      await db.upsertMessage(message('failed', status: 'failed'));
      await db.upsertMessage(message('peer', sender: 'peer'));
      await db.upsertMessage(message('future-confirmed', seconds: 500));
      for (final event in ['room_delivered', 'room_peer_seen']) {
        final pts = event == 'room_delivered' ? 2 : 3;
        await sync.receivePublication({
          'pts': pts,
          'epoch': 'epoch',
          'room': payload(pts: pts, event: event),
        });
        expect((await db.message('confirmed'))!.isDelivered, true);
        expect(
          (await db.message('confirmed'))!.isSeen,
          event == 'room_peer_seen',
        );
        for (final id in ['pending', 'failed', 'peer', 'future-confirmed']) {
          expect((await db.message(id))!.deliveredAt, isNull, reason: id);
          expect((await db.message(id))!.seenAt, isNull, reason: id);
        }
        expect((await db.message('pending'))!.status, 'sending');
        expect((await db.message('failed'))!.status, 'failed');
      }
      expect((await db.metadata())!.localPts, 3);
    } finally {
      await sync.dispose();
      await db.close();
    }
  });

  test('hidden target quote updates sanitize SQLite and a historical slice without inserting the target', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db.initializeSession('me');
      final target = ChatMessage.fromJson({
        ...message('hidden').toJson(),
        'type': 'image',
        'imageUrl': '/public/uploads/private.png',
      });
      final reply = message(
        'visible-reply',
        reply: ReplySnapshot.fromMessage(target),
      );
      await db.upsertMessage(reply);
      final sanitized = ReplySnapshot(
        messageId: 'hidden',
        senderId: 'peer',
        senderName: 'Peer',
        type: 'image',
        text: '🚫 This message was deleted',
        isDeleted: true,
      );
      final update = {
        ...payload(pts: 2, history: 2, event: 'message_deleted_all'),
        'quoteUpdate': sanitized.toJson(),
      };
      await db.transaction(() => db.applyRoomPayload(update, myUserId: 'me'));
      expect(await db.message('hidden'), isNull);
      expect((await db.message('visible-reply'))!.replyTo!.isDeleted, true);
      expect((await db.message('visible-reply'))!.replyTo!.imageUrl, isNull);
      final historical = reconcileJumpSlice([reply], update);
      expect(historical.single.replyTo!.isDeleted, true);
      expect(historical.single.replyTo!.imageUrl, isNull);
      expect(historical.every((message) => message.id != 'hidden'), true);
      final edited = {
        ...payload(pts: 3, history: 3, event: 'message_edited'),
        'quoteUpdate': {
          ...sanitized.toJson(),
          'text': 'edited quote',
          'isDeleted': false,
        },
      };
      await db.applyRoomPayload(edited, myUserId: 'me');
      expect(
        (await db.message('visible-reply'))!.replyTo!.text,
        'edited quote',
      );
      expect(await db.message('hidden'), isNull);
    } finally {
      await db.close();
    }
  });

  for (final fullReset in [false, true]) {
    test(
      '${fullReset ? 'full reset' : 'coalesced delta'} refreshes a historical deletion without updatedMessage; new tail alone leaves it in place',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = FakeApi();
        var pts = 1, aroundCalls = 0;
        ChatMessage tail() => message('tail-$pts', seconds: 600 + pts);
        Map<String, dynamic> room() =>
            payload(pts: pts, history: pts >= 3 ? 2 : 0, last: tail());
        api.handler = (path, query) async {
          if (path == '/rooms/delta') {
            if (fullReset && pts == 3 && query?['sincePts'] != pts) {
              return {'requiresFullSync': true};
            }
            return delta(pts, query?['sincePts'] == pts ? [] : [room()]);
          }
          if (path == '/rooms') {
            return {
              'rooms': [room()],
              'pts': pts,
              'epoch': 'epoch',
              'nextCursor': null,
            };
          }
          if (path.contains('/around/')) {
            aroundCalls++;
            return {
              'messages': [
                ChatMessage.fromJson({
                  ...message('ancient', seconds: -600).toJson(),
                  if (pts >= 3) ...{
                    'isDeletedForAll': true,
                    'text': '🚫 This message was deleted',
                    'imageUrl': null,
                  },
                }).toJson(),
              ],
            };
          }
          if (path.endsWith('/messages')) {
            return {
              'messages': [tail().toJson()],
              'hasMore': true,
              'receipts': {
                'deliveredThrough': null,
                'seenThrough': null,
                'hasGaps': false,
              },
            };
          }
          throw StateError(path);
        };
        final controller = ChatController(
          database: db,
          api: api,
          enableRealtime: false,
        );
        try {
          await controller.debugLogin(1);
          await controller.openRoom((await db.room('room'))!);
          await controller.jumpToMessage('ancient');
          expect(controller.isJumpMode, true);
          expect(controller.messages.single.isDeletedForAll, false);
          expect(aroundCalls, 1);
          pts = 2; // Only a new tail message: do not move or refetch history.
          await controller.syncNow();
          expect(controller.isJumpMode, true);
          expect(controller.messages.single.id, 'ancient');
          expect(aroundCalls, 1);
          pts = 3; // Delete followed by another tail: only history revision remains.
          await controller.syncNow();
          expect(controller.isJumpMode, true);
          expect(controller.messages.single.id, 'ancient');
          expect(controller.messages.single.isDeletedForAll, true);
          expect(
            controller.messages.single.text,
            '🚫 This message was deleted',
          );
          expect(aroundCalls, 2);
          expect((await db.metadata())!.localPts, 3);
          expect(
            await db.message('ancient'),
            isNull,
          ); // Remote context stays in memory.
        } finally {
          await controller.logout();
          await db.close();
        }
      },
    );
  }

  test('historical target hidden during disconnect returns to latest instead of retaining its old body', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    var pts = 1;
    api.handler = (path, query) async {
      if (path == '/rooms/delta') {
        return delta(
          pts,
          query?['sincePts'] == pts
              ? []
              : [
                  payload(
                    pts: pts,
                    history: pts > 1 ? 2 : 0,
                    last: message('latest', seconds: 600),
                  ),
                ],
        );
      }
      if (path.contains('/around/')) {
        if (pts > 1) {
          throw const ChatApiException('not visible', statusCode: 404);
        }
        return {
          'messages': [message('ancient', seconds: -600).toJson()],
        };
      }
      return {
        'messages': [message('latest', seconds: 600).toJson()],
        'hasMore': false,
        'receipts': {
          'deliveredThrough': null,
          'seenThrough': null,
          'hasGaps': false,
        },
      };
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      await controller.openRoom((await db.room('room'))!);
      await controller.jumpToMessage('ancient');
      pts = 3;
      await controller.syncNow();
      await Future<void>.delayed(Duration.zero);
      expect(controller.isJumpMode, false);
      expect(controller.messages.any((m) => m.id == 'ancient'), false);
      expect(controller.error, isNull);
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test(
    'a delayed historical response cannot replace a newer jump selection',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      final pending = Completer<Map<String, dynamic>>(),
          started = Completer<void>();
      api.handler = (path, query) async {
        if (path == '/rooms/delta') {
          return delta(
            1,
            query?['sincePts'] == 1 ? [] : [payload(last: message('latest'))],
          );
        }
        if (path.endsWith('/around/first')) {
          started.complete();
          return pending.future;
        }
        if (path.endsWith('/around/second')) {
          return {
            'messages': [message('second', seconds: -500).toJson()],
          };
        }
        return {
          'messages': [message('latest').toJson()],
          'hasMore': false,
          'receipts': {
            'deliveredThrough': null,
            'seenThrough': null,
            'hasGaps': false,
          },
        };
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        await controller.openRoom((await db.room('room'))!);
        final first = controller.jumpToMessage('first');
        await started.future;
        final second = controller.jumpToMessage('second');
        pending.complete({
          'messages': [message('first', seconds: -600).toJson()],
        });
        await Future.wait([first, second]);
        expect(controller.isJumpMode, true);
        expect(controller.messages.single.id, 'second');
        expect(controller.highlightMessageId, 'second');
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test('optional debug discovery outage cannot block saved session, sending sweep or startup sync and can retry', () async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.upsertMessage(message('interrupted', status: 'sending'));
    final api = FakeApi();
    var unavailable = true, deltas = 0, directories = 0;
    api.usersHandler = (path) async {
      if (path == '/auth/debug-users') {
        directories++;
        if (unavailable) {
          throw const ChatApiException('unavailable', statusCode: 503);
        }
        return [
          const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
        ];
      }
      return [];
    };
    api.handler = (_, _) async {
      deltas++;
      return delta(1, []);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.initialize();
      expect(controller.initialized, true);
      expect(controller.currentUser!.id, 'me');
      expect((await db.message('interrupted'))!.status, 'queued');
      expect((await db.message('interrupted'))!.outcomeUnknown, isTrue);
      await waitForController(
        () => controller.diagnostics['remoteStartupComplete'] == true,
      );
      expect(deltas, 1);
      final generation = controller.sessionGenerationId;
      unavailable = false;
      await controller.initialize();
      expect(controller.debugUsers.single.id, 'peer');
      expect(directories, 2);
      expect(deltas, 1);
      expect(controller.sessionGenerationId, generation);
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test('mandatory startup outage retries same saved session without duplicating it or clearing credentials', () async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    var unavailable = true, deltas = 0;
    api.handler = (_, _) async {
      deltas++;
      if (unavailable) {
        throw const ChatApiException('unavailable', statusCode: 503);
      }
      return delta(1, []);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.initialize();
      await waitForController(() => controller.connectionStatus == 'Offline');
      expect(controller.initialized, true);
      expect(controller.diagnostics['remoteStartupComplete'], false);
      expect(controller.currentUser!.id, 'me');
      expect(
        (await SharedPreferences.getInstance()).getString('chat_session'),
        isNotNull,
      );
      final generation = controller.sessionGenerationId;
      unavailable = false;
      await Future.wait([controller.syncNow(), controller.syncNow()]);
      expect(controller.initialized, true);
      expect(controller.error, isNull);
      expect(controller.sessionGenerationId, generation);
      expect(
        deltas,
        3,
      ); // one failed startup, one retry, one explicit inbox refresh
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test('visible Sync now completes failed cold-start setup without relogin or duplicate session startup', () async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    var unavailable = true, userRequests = 0, heartbeats = 0;
    api.usersHandler = (path) async {
      if (path == '/users') {
        userRequests++;
        return [
          const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
        ];
      }
      return [];
    };
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        return {
          'statuses': {'peer': true},
        };
      }
      if (unavailable) {
        throw const ChatApiException('unavailable', statusCode: 503);
      }
      return delta(1, [payload()]);
    };
    api.otherPostHandler = (path, _) async {
      if (path == '/presence/heartbeat') heartbeats++;
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.initialize();
      await waitForController(() => controller.connectionStatus == 'Offline');
      expect(controller.initialized, true);
      expect(controller.diagnostics['remoteStartupComplete'], false);
      expect(controller.currentUser!.id, 'me');
      expect(controller.users, isEmpty);
      expect(heartbeats, 0);
      final generation = controller.sessionGenerationId;
      unavailable = false;
      await controller.syncNow();
      expect(controller.initialized, true);
      expect(controller.error, isNull);
      expect(controller.sessionGenerationId, generation);
      expect(controller.users.single.id, 'peer');
      expect(controller.onlineUserIds, {'peer'});
      expect((await db.metadata())!.localPts, 1);
      expect(userRequests, 1);
      expect(heartbeats, 0);
      final startupEvents = (controller.diagnostics['recentEvents'] as List)
          .where((event) => event['event'] == 'session_started')
          .length;
      await controller.syncNow();
      expect(userRequests, 1);
      expect(heartbeats, 0);
      expect(
        (controller.diagnostics['recentEvents'] as List)
            .where((event) => event['event'] == 'session_started')
            .length,
        startupEvents,
      );
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test(
    'pending optional directory request cannot delay saved-session recovery',
    () async {
      SharedPreferences.setMockInitialValues({
        'chat_session': jsonEncode(session('me')),
      });
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      final directoryStarted = Completer<void>();
      final directory = Completer<List<UserProfile>>();
      api.usersHandler = (path) async {
        if (path == '/auth/debug-users') {
          directoryStarted.complete();
          return directory.future;
        }
        return [];
      };
      api.handler = (_, _) async => delta(1, []);
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        final initializing = controller.initialize();
        await directoryStarted.future;
        await initializing.timeout(const Duration(seconds: 2));
        expect(controller.currentUser!.id, 'me');
        await controller.syncNow();
        expect((await db.metadata())!.localPts, 1);
        expect(controller.initialized, true);
        directory.completeError(
          const ChatApiException('unavailable', statusCode: 503),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.currentUser!.id, 'me');
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test('Sync now retries mandatory startup while optional debug discovery remains pending and later notifies its users', () async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    final directory = Completer<List<UserProfile>>();
    var unavailable = true,
        directoryRequests = 0,
        usersRequests = 0,
        heartbeats = 0;
    api.usersHandler = (path) async {
      if (path == '/auth/debug-users') {
        directoryRequests++;
        return directory.future;
      }
      usersRequests++;
      return [
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      ];
    };
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        return {
          'statuses': {'peer': true},
        };
      }
      if (unavailable) {
        throw const ChatApiException('unavailable', statusCode: 503);
      }
      return delta(1, [payload()]);
    };
    api.otherPostHandler = (path, _) async {
      if (path == '/presence/heartbeat') heartbeats++;
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    final directoryNotified = Completer<void>();
    void observeDirectory() {
      if (controller.debugUsers.isNotEmpty && !directoryNotified.isCompleted) {
        directoryNotified.complete();
      }
    }

    controller.addListener(observeDirectory);
    try {
      await controller.initialize().timeout(const Duration(seconds: 2));
      await waitForController(() => controller.connectionStatus == 'Offline');
      expect(controller.initialized, true);
      expect(controller.diagnostics['remoteStartupComplete'], false);
      expect(controller.currentUser!.id, 'me');
      expect(directory.isCompleted, false);
      expect(directoryRequests, 1);
      expect(heartbeats, 0);
      final generation = controller.sessionGenerationId;
      unavailable = false;
      await controller.syncNow().timeout(const Duration(seconds: 2));
      expect(controller.initialized, true);
      expect(controller.error, isNull);
      expect(controller.sessionGenerationId, generation);
      expect(controller.users.single.id, 'peer');
      expect(controller.onlineUserIds, {'peer'});
      expect(heartbeats, 0);
      expect(usersRequests, 1);
      expect(directoryRequests, 1);
      expect(directory.isCompleted, false);
      await controller.initialize();
      expect(directoryRequests, 1);
      directory.complete([
        const UserProfile(
          id: 'debug-peer',
          username: 'debug',
          displayName: 'Debug peer',
        ),
      ]);
      await directoryNotified.future.timeout(const Duration(seconds: 2));
      expect(controller.debugUsers.single.id, 'debug-peer');
      expect(directoryRequests, 1);
    } finally {
      controller.removeListener(observeDirectory);
      await controller.logout();
      await db.close();
    }
  });
}
