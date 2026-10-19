import 'dart:async';
import 'dart:typed_data';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final instant = DateTime.utc(2026, 10, 16, 12);
ServerHealthMonitor testServerHealth() => ServerHealthMonitor(
  healthUri: Uri.parse('http://test.invalid/health'),
  probe: () async => true,
);
ChatMessage message(
  String id, {
  String room = 'room',
  String sender = 'me',
  int seconds = 0,
  String status = 'sent',
  String? key,
  ReplySnapshot? reply,
}) => ChatMessage(
  id: id,
  idempotencyKey: key ?? id,
  roomId: room,
  senderId: sender,
  senderName: sender,
  type: 'text',
  text: id,
  status: status,
  createdAt: instant.add(Duration(seconds: seconds)),
  replyTo: reply,
);
Map<String, dynamic> payload({
  String room = 'room',
  int pts = 1,
  int? msgPts,
  int history = 0,
  String event = 'message_new',
  ChatMessage? last,
  ChatMessage? updated,
}) => {
  'roomId': room,
  'roomType': 'direct',
  'peerUserId': 'peer',
  'displayTitle': room,
  'sortTimestamp': instant.toIso8601String(),
  'roomPts': pts,
  'msgPts': msgPts ?? pts,
  'lastHistoryEditPts': history,
  'lastMessage': last?.toJson(),
  'eventType': event,
  'updatedMessage': updated?.toJson(),
  'actionTimestamp': instant.add(const Duration(minutes: 2)).toIso8601String(),
};

class FakeApi extends ChatApi {
  List<UserProfile> userList = [];
  Future<List<UserProfile>> Function(String)? usersHandler;
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>?)?
  otherPostHandler;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? authHandler;
  Future<String> Function(Uint8List, String)? uploadHandler;
  @override
  Future<String> uploadImage(Uint8List bytes, String filename) =>
      uploadHandler != null
      ? uploadHandler!(bytes, filename)
      : super.uploadImage(bytes, filename);
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>?)?
  postHandler;
  @override
  Future<({List<UserProfile> users, String? nextCursor})> directoryPage({
    String? cursor,
  }) async => (users: await getUsers('/users'), nextCursor: null);
  @override
  Future<List<UserProfile>> getUsers(String path) async => usersHandler != null
      ? usersHandler!(path)
      : path == '/users'
      ? userList
      : [];
  @override
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/auth/debug-login' ||
        path == '/auth/login' ||
        path == '/auth/signup') {
      if (authHandler != null) return authHandler!(body!);
      return {
        'user': {'id': 'me', 'username': 'me', 'displayName': 'Me'},
        'accessToken': 'test-token',
        'centrifugoToken': 'test-realtime-token',
      };
    }
    if (path == '/messages' && postHandler != null) {
      return postHandler!(path, body);
    }
    return otherPostHandler != null
        ? otherPostHandler!(path, body)
        : {'ok': true};
  }

  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>?)? handler;
  @override
  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async => handler!(path, query);
}

class PausableMessageDatabase extends AppDatabase {
  PausableMessageDatabase() : super(NativeDatabase.memory());

  bool pauseInsert = false;
  bool pauseStatus = false;
  final writePaused = Completer<void>();
  final resumeWrite = Completer<void>();

  @override
  Future<void> upsertMessage(ChatMessage message) async {
    await super.upsertMessage(message);
    if (pauseInsert && message.status == 'queued') {
      pauseInsert = false;
      writePaused.complete();
      await resumeWrite.future;
    }
  }

  @override
  Future<void> setMessageStatus(String id, String status) async {
    await super.setMessageStatus(id, status);
    if (pauseStatus && status == 'sending') {
      pauseStatus = false;
      writePaused.complete();
      await resumeWrite.future;
    }
  }

  @override
  Future<void> updateOutboundState(
    String senderId,
    String key, {
    String? status,
    int? retryCount,
    DateTime? nextAttemptAt,
    String? errorCode,
    String? errorMessage,
    bool? outcomeUnknown,
    bool? paused,
    bool clearError = false,
    bool clearRetryAt = false,
  }) async {
    await super.updateOutboundState(
      senderId,
      key,
      status: status,
      retryCount: retryCount,
      nextAttemptAt: nextAttemptAt,
      errorCode: errorCode,
      errorMessage: errorMessage,
      outcomeUnknown: outcomeUnknown,
      paused: paused,
      clearError: clearError,
      clearRetryAt: clearRetryAt,
    );
    if (pauseStatus && status == 'queued') {
      pauseStatus = false;
      writePaused.complete();
      await resumeWrite.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late AppDatabase db;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
  });
  tearDown(() async {
    await db.close();
  });

  test('queue serializes work and survives an operation failure', () async {
    final queue = InboxSyncQueue();
    final order = <int>[];
    final gate = Completer<void>();
    final first = queue.enqueue(() async {
      order.add(1);
      await gate.future;
      order.add(2);
    });
    final second = queue.enqueue(() async {
      order.add(3);
      throw StateError('expected');
    });
    final handled = expectLater(second, throwsStateError);
    final third = queue.enqueue(() async {
      order.add(4);
    });
    await Future<void>.delayed(Duration.zero);
    expect(order, [1]);
    gate.complete();
    await first;
    await handled;
    await third;
    expect(order, [1, 2, 3, 4]);
  });
  test('clearing a session discards waiting queue work', () async {
    final queue = InboxSyncQueue();
    final gate = Completer<void>();
    var called = false;
    final first = queue.enqueue(() => gate.future);
    final second = queue.enqueue(() async {
      called = true;
    });
    await Future<void>.delayed(Duration.zero);
    final cleared = queue.clear();
    gate.complete();
    await first;
    await second;
    await cleared;
    expect(called, false);
  });
  test('REST reconciliation never advances account cursor', () async {
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    );
    await sync.reconcileMutation({
      'room': payload(pts: 105, last: message('server')),
    });
    expect((await db.metadata())!.localPts, 0);
    expect((await db.room('room'))!.roomPts, 105);
    await sync.dispose();
  });
  test(
    'optimistic acknowledgement replaces temp row by idempotency key',
    () async {
      await db.upsertMessage(
        message('temp_key', status: 'sending', key: 'key', room: 'draft_peer'),
      );
      await db.transaction(() async {
        await db.remapDraft('draft_peer', 'room');
        await db.upsertMessage(message('server', key: 'key'));
      });
      expect(await db.message('temp_key'), isNull);
      expect((await db.allMessages('room')).map((m) => m.id), ['server']);
    },
  );
  test(
    'startup sweeps sending rows and account switch clears every table',
    () async {
      await db.upsertMessage(message('temp', status: 'sending'));
      await db.initializeSession('me');
      expect((await db.message('temp'))!.status, 'queued');
      expect((await db.message('temp'))!.outcomeUnknown, isTrue);
      await db.upsertRoom(ChatRoom.fromJson(payload()));
      await db.initializeSession('other');
      expect(await db.allMessages('room'), isEmpty);
      expect(await db.room('room'), isNull);
      expect((await db.metadata())!.userId, 'other');
    },
  );
  test('unread clearing never marks own outgoing messages seen', () async {
    await db.upsertMessage(message('outgoing'));
    await db.applyRoomPayload(
      payload(pts: 2, msgPts: 1, event: 'room_unread_cleared'),
      myUserId: 'me',
    );
    final outgoing = (await db.message('outgoing'))!;
    expect(outgoing.seenAt, isNull);
    expect(outgoing.deliveredAt, isNull);
  });
  test(
    'delivered and peer-seen receipts affect only own bounded messages',
    () async {
      await db.upsertMessage(message('own'));
      await db.upsertMessage(message('future', seconds: 500));
      await db.upsertMessage(message('incoming', sender: 'peer'));
      await db.applyRoomPayload(
        payload(event: 'room_delivered'),
        myUserId: 'me',
      );
      expect((await db.message('own'))!.isDelivered, true);
      expect((await db.message('own'))!.seenAt, isNull);
      await db.applyRoomPayload(
        payload(pts: 2, event: 'room_peer_seen'),
        myUserId: 'me',
      );
      expect((await db.message('own'))!.isSeen, true);
      expect((await db.message('future'))!.seenAt, isNull);
      expect((await db.message('incoming'))!.seenAt, isNull);
    },
  );
  test('stale room revision cannot overwrite a newer summary', () async {
    await db.applyRoomPayload(payload(pts: 9), myUserId: 'me');
    await db.applyRoomPayload(payload(pts: 3), myUserId: 'me');
    expect((await db.room('room'))!.roomPts, 9);
  });
  test(
    'open-room contiguous publication keeps content revision synchronized',
    () async {
      await db.upsertRoom(ChatRoom.fromJson(payload(pts: 0)));
      await db.applyRoomPayload(
        payload(pts: 9),
        myUserId: 'me',
        openRoomId: 'room',
      );
      expect((await db.room('room'))!.messagesSyncedPts, 9);
      await db.applyRoomPayload(
        payload(pts: 10),
        myUserId: 'me',
        openRoomId: 'room',
        markOpenSynced: false,
      );
      expect((await db.room('room'))!.messagesSyncedPts, 9);
    },
  );
  test(
    'full sync removes stale off-page rooms and resets synced revisions',
    () async {
      await db.applyRoomPayload(payload(room: 'stale'), myUserId: 'me');
      await db.applyRoomPayload(
        payload(room: 'kept', pts: 2),
        myUserId: 'me',
        openRoomId: 'kept',
      );
      await db.transaction(
        () => db.replaceFullInbox([payload(room: 'kept', pts: 3)]),
      );
      expect(await db.room('stale'), isNull);
      expect((await db.room('kept'))!.messagesSyncedPts, 0);
    },
  );
  test(
    'overlap retains older history and prunes missing recent rows',
    () async {
      await db.upsertRoom(ChatRoom.fromJson(payload(pts: 5)));
      for (var i = 0; i < 5; i++) {
        await db.upsertMessage(message('$i', seconds: i));
      }
      final fresh = [message('new', seconds: 6), message('3', seconds: 3)];
      await db.reconcileLatest('room', fresh, 5, 0, 4);
      expect((await db.allMessages('room')).map((m) => m.id), [
        'new',
        '3',
        '2',
        '1',
        '0',
      ]);
      expect((await db.room('room'))!.messagesSyncedPts, 5);
    },
  );
  test('no overlap resets old history and preserves pending sends', () async {
    await db.upsertRoom(ChatRoom.fromJson(payload(pts: 8)));
    await db.upsertMessage(message('old'));
    await db.upsertMessage(message('pending', status: 'sending'));
    await db.reconcileLatest('room', [message('new', seconds: 100)], 8, 0, 1);
    expect((await db.allMessages('room')).map((m) => m.id).toSet(), {
      'new',
      'pending',
    });
  });
  test('old edit revision forces cache reset despite overlap', () async {
    await db.upsertRoom(ChatRoom.fromJson(payload(pts: 8)));
    await db.upsertMessage(message('old'));
    await db.upsertMessage(message('overlap', seconds: 1));
    await db.reconcileLatest('room', [message('overlap', seconds: 1)], 8, 7, 2);
    expect(await db.message('old'), isNull);
  });
  test('deleted-for-all sanitizes reply snapshots', () async {
    final target = ChatMessage.fromJson({
      ...message('target').toJson(),
      'type': 'image',
      'imageUrl': '/public/uploads/image.jpg',
    });
    await db.upsertMessage(
      message('reply', reply: ReplySnapshot.fromMessage(target)),
    );
    final deleted = ChatMessage.fromJson({
      ...target.toJson(),
      'isDeletedForAll': true,
      'imageUrl': null,
      'text': '🚫 This message was deleted',
    });
    await db.applyRoomPayload(
      payload(event: 'message_deleted_all', updated: deleted),
      myUserId: 'me',
    );
    final reply = (await db.message('reply'))!.replyTo!;
    expect(reply.imageUrl, isNull);
    expect(reply.isDeleted, true);
  });
  test(
    'gap detection pulls delta then ignores already-covered publication',
    () async {
      await db.setCursor(1, 'epoch');
      final api = FakeApi();
      var requests = 0;
      api.handler = (path, query) async {
        requests++;
        return {
          'requiresFullSync': false,
          'pts': 4,
          'epoch': 'epoch',
          'rooms': [payload(pts: 4)],
        };
      };
      final sync = InboxSyncService(
        database: db,
        api: api,
        userId: 'me',
        isCurrentSession: () => true,
      );
      await sync.receivePublication({
        'pts': 4,
        'epoch': 'epoch',
        'room': payload(pts: 4),
      });
      expect(requests, 1);
      expect((await db.metadata())!.localPts, 4);
      await sync.dispose();
    },
  );
  test(
    'contiguous live events apply atomically without a delta request',
    () async {
      await db.setCursor(1, 'epoch');
      final sync = InboxSyncService(
        database: db,
        api: FakeApi(),
        userId: 'me',
        isCurrentSession: () => true,
      );
      await sync.receivePublication({
        'pts': 2,
        'epoch': 'epoch',
        'room': payload(pts: 2),
      });
      expect((await db.metadata())!.localPts, 2);
      expect((await db.room('room'))!.roomPts, 2);
      await sync.dispose();
    },
  );
  test('expired session ignores a response after request completes', () async {
    var valid = true;
    final response = Completer<Map<String, dynamic>>();
    final api = FakeApi()..handler = (_, _) => response.future;
    final sync = InboxSyncService(
      database: db,
      api: api,
      userId: 'me',
      isCurrentSession: () => valid,
    );
    final pending = sync.syncInboxDelta();
    await Future<void>.delayed(Duration.zero);
    valid = false;
    response.complete({
      'requiresFullSync': false,
      'pts': 999,
      'epoch': 'epoch',
      'rooms': [payload(pts: 999)],
    });
    await pending;
    expect((await db.metadata())!.localPts, 0);
    expect(await db.room('room'), isNull);
    await sync.dispose();
  });
  test(
    'opening unchanged cached room makes zero additional message requests',
    () async {
      final api = FakeApi();
      api.handler = (path, query) async {
        if (path == '/rooms/delta') {
          return {
            'requiresFullSync': false,
            'pts': 1,
            'epoch': 'epoch',
            'rooms': query?['sincePts'] == 0
                ? [payload(last: message('latest'))]
                : [],
          };
        }
        if (path.endsWith('/messages')) {
          return {
            'messages': [
              message('latest').toJson(),
              message('older', seconds: -1).toJson(),
            ],
            'hasMore': false,
          };
        }
        throw StateError('unexpected path $path');
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      await controller.debugLogin(1);
      expect(controller.error, isNull);
      await controller.openRoom((await db.room('room'))!);
      await controller.syncNow();
      expect(controller.error, isNull);
      expect(api.messageRequests, 1);
      await controller.closeRoom();
      await controller.openRoom((await db.room('room'))!);
      await controller.syncNow();
      expect(controller.error, isNull);
      expect(api.messageRequests, 1);
      await controller.logout();
    },
  );

  test(
    'failed first message survives and retries with the same idempotency key',
    () async {
      final api = FakeApi();
      api.handler = (path, query) async {
        if (path.startsWith('/rooms/direct-peer/')) {
          return {'exists': false, 'room': null};
        }
        return {
          'requiresFullSync': false,
          'pts': 0,
          'epoch': 'epoch',
          'rooms': [],
        };
      };
      final keys = <String>[];
      var fails = true;
      api.postHandler = (_, body) async {
        keys.add(body!['idempotencyKey'] as String);
        if (fails) {
          throw const ChatApiException(
            'Invalid message',
            statusCode: 400,
            kind: ChatFailureKind.validation,
          );
        }
        final sent = message('server-id', key: keys.last);
        return {'message': sent.toJson(), 'room': payload(last: sent)};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      await controller.debugLogin(1);
      await controller.openDirect(
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      );
      await controller.sendText('hello');
      await controller.outboxIdle;
      final failed = (await db.allMessages('draft_peer')).single;
      expect(failed.status, 'failed');
      expect(failed.peerUserId, 'peer');
      fails = false;
      await controller.retryMessage(failed);
      await controller.outboxIdle;
      expect(controller.error, isNull);
      expect(keys.length, 2);
      expect(keys.first, keys.last);
      expect(await db.allMessages('draft_peer'), isEmpty);
      expect((await db.allMessages('room')).single.status, 'sent');
      await controller.logout();
    },
  );

  test(
    'an old REST response cannot regress a message already reconciled live',
    () async {
      final sync = InboxSyncService(
        database: db,
        api: FakeApi(),
        userId: 'me',
        isCurrentSession: () => true,
      );
      final latest = ChatMessage.fromJson({
        ...message('same').toJson(),
        'text': 'edited',
        'isEdited': true,
      });
      await db.applyRoomPayload(payload(pts: 10, last: latest), myUserId: 'me');
      final stale = message('same');
      await sync.reconcileMutation({
        'room': payload(pts: 9, last: stale),
        'message': stale.toJson(),
      });
      expect((await db.message('same'))!.text, 'edited');
      await sync.dispose();
    },
  );
  test(
    'stale room response still acknowledges an outstanding optimistic send',
    () async {
      final sync = InboxSyncService(
        database: db,
        api: FakeApi(),
        userId: 'me',
        isCurrentSession: () => true,
      );
      await db.upsertMessage(
        message('temp_pending', key: 'pending', status: 'sending'),
      );
      await db.applyRoomPayload(
        payload(pts: 10, last: message('another')),
        myUserId: 'me',
      );
      final acknowledgement = message('server_pending', key: 'pending');
      await sync.reconcileMutation({
        'room': payload(pts: 9, last: acknowledgement),
        'message': acknowledgement.toJson(),
      });
      expect(await db.message('temp_pending'), isNull);
      expect((await db.message('server_pending'))!.status, 'sent');
      expect((await db.room('room'))!.roomPts, 10);
      await sync.dispose();
    },
  );
  test(
    'an image finishing upload is sent to the original conversation',
    () async {
      final api = FakeApi();
      api.handler = (path, query) async {
        if (path.startsWith('/rooms/direct-peer/')) {
          return {'exists': false, 'room': null};
        }
        return {
          'requiresFullSync': false,
          'pts': 0,
          'epoch': 'epoch',
          'rooms': [],
        };
      };
      final upload = Completer<String>();
      api.uploadHandler = (_, _) => upload.future;
      String? recipient;
      api.postHandler = (_, body) async {
        recipient = body!['peerUserId'] as String?;
        final sent = ChatMessage.fromJson({
          ...message(
            'image',
            room: 'room-a',
            key: body['idempotencyKey'] as String,
          ).toJson(),
          'type': 'image',
          'imageUrl': body['imageUrl'],
        });
        return {
          'message': sent.toJson(),
          'room': {
            ...payload(room: 'room-a', last: sent),
            'peerUserId': body['peerUserId'],
          },
        };
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      await controller.debugLogin(1);
      await controller.openDirect(
        const UserProfile(id: 'peer-a', username: 'a', displayName: 'A'),
      );
      final sending = controller.sendImage(
        Uint8List.fromList([1]),
        'photo.png',
      );
      await Future<void>.delayed(Duration.zero);
      await controller.openDirect(
        const UserProfile(id: 'peer-b', username: 'b', displayName: 'B'),
      );
      upload.complete('/public/uploads/image.png');
      await sending;
      await controller.outboxIdle;
      expect(controller.error, isNull);
      expect(recipient, 'peer-a');
      expect(controller.draftPeer!.id, 'peer-b');
      await controller.logout();
    },
  );
  test('queued events after a coalesced open-room gap never certify missing history', () async {
    await db.upsertRoom(
      ChatRoom.fromJson(payload(pts: 1, last: message('1', seconds: 1))),
    );
    await db.markMessagesSynced('room', 1);
    await db.setCursor(1, 'epoch');
    final api = FakeApi()
      ..handler = (_, _) async => {
        'requiresFullSync': false,
        'pts': 40,
        'epoch': 'epoch',
        'rooms': [payload(pts: 40, last: message('40', seconds: 40))],
      };
    final sync = InboxSyncService(
      database: db,
      api: api,
      userId: 'me',
      isCurrentSession: () => true,
    )..openRoomId = 'room';
    final first = sync.receivePublication({
      'pts': 41,
      'epoch': 'epoch',
      'room': payload(pts: 41, last: message('41', seconds: 41)),
    });
    final next = sync.receivePublication({
      'pts': 42,
      'epoch': 'epoch',
      'room': payload(pts: 42, last: message('42', seconds: 42)),
    });
    await Future.wait([first, next]);
    expect((await db.metadata())!.localPts, 42);
    expect((await db.room('room'))!.msgPts, 42);
    expect((await db.room('room'))!.messagesSyncedPts, 1);
    final fresh = List.generate(
      30,
      (i) => message('${42 - i}', seconds: 42 - i),
    );
    await db.reconcileLatest('room', fresh, 42, 0, 1);
    expect((await db.allMessages('room')).length, 30);
    expect(await db.message('1'), isNull);
    expect((await db.room('room'))!.messagesSyncedPts, 42);
    await sync.dispose();
  });

  test('reconnection repairs an already-open room with over 30 missed messages without another publication', () async {
    final api = FakeApi();
    var remotePts = 1;
    api.handler = (path, query) async {
      if (path == '/rooms/delta') {
        return {
          'requiresFullSync': false,
          'pts': remotePts,
          'epoch': 'epoch',
          'rooms': query?['sincePts'] == remotePts
              ? []
              : [
                  payload(
                    pts: remotePts,
                    last: message('$remotePts', seconds: remotePts),
                  ),
                ],
        };
      }
      if (path.endsWith('/messages')) {
        return {
          'messages': List.generate(
            remotePts == 1 ? 1 : 30,
            (i) => message('${remotePts - i}', seconds: remotePts - i).toJson(),
          ),
          'hasMore': remotePts > 30,
        };
      }
      throw StateError(path);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    await controller.openRoom((await db.room('room'))!);
    await controller.syncNow();
    expect(api.messageRequests, 1);
    remotePts = 50;
    await controller.syncNow();
    expect(controller.error, isNull);
    expect(api.messageRequests, 2);
    expect((await db.allMessages('room')).length, 30);
    expect(await db.message('1'), isNull);
    expect((await db.room('room'))!.messagesSyncedPts, 50);
    await controller.logout();
  });

  test('reconnection invalidates old cached history when lastHistoryEditPts advances', () async {
    final api = FakeApi();
    var edited = false;
    api.handler = (path, query) async {
      final revision = edited ? 31 : 30;
      if (path == '/rooms/delta') {
        return {
          'requiresFullSync': false,
          'pts': revision,
          'epoch': 'epoch',
          'rooms': query?['sincePts'] == revision
              ? []
              : [
                  payload(
                    pts: revision,
                    history: edited ? 31 : 0,
                    last: message('30', seconds: 30),
                  ),
                ],
        };
      }
      return {
        'messages': List.generate(
          30,
          (i) => message('${30 - i}', seconds: 30 - i).toJson(),
        ),
        'hasMore': false,
      };
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    await controller.openRoom((await db.room('room'))!);
    await controller.syncNow();
    await db.upsertMessage(message('ancient', seconds: -100));
    edited = true;
    await controller.syncNow();
    expect(controller.error, isNull);
    expect(api.messageRequests, 2);
    expect(await db.message('ancient'), isNull);
    expect((await db.room('room'))!.messagesSyncedPts, 31);
    await controller.logout();
  });

  test('the newest concurrent account selection wins even when older authentication finishes later', () async {
    final api = FakeApi();
    final older = Completer<Map<String, dynamic>>();
    Map<String, dynamic> session(String id) => {
      'user': {'id': id, 'username': id, 'displayName': id},
      'accessToken': id,
      'centrifugoToken': id,
    };
    api.authHandler = (body) async =>
        body['debugUserNumber'] == 1 ? older.future : session('two');
    api.handler = (_, _) async => {
      'requiresFullSync': false,
      'pts': 0,
      'epoch': 'epoch',
      'rooms': [],
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    final first = controller.debugLogin(1);
    await Future<void>.delayed(Duration.zero);
    await controller.debugLogin(2);
    older.complete(session('one'));
    await first;
    expect(controller.currentUser!.id, 'two');
    expect((await db.metadata())!.userId, 'two');
    await controller.logout();
  });

  test('logout cancels an authentication response still in flight', () async {
    final api = FakeApi();
    final pending = Completer<Map<String, dynamic>>();
    api.authHandler = (_) => pending.future;
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    final login = controller.debugLogin(1);
    await Future<void>.delayed(Duration.zero);
    await controller.logout();
    pending.complete({
      'user': {'id': 'old', 'username': 'old', 'displayName': 'old'},
      'accessToken': 'old',
      'centrifugoToken': 'old',
    });
    await login;
    expect(controller.currentUser, isNull);
    expect(await db.metadata(), isNull);
  });

  test(
    'upload failure retains a durable image and retry reuses its identity',
    () async {
      final api = FakeApi();
      var uploadFails = true;
      api.handler = (path, _) async => path.startsWith('/rooms/direct-peer/')
          ? {'exists': false, 'room': null}
          : {
              'requiresFullSync': false,
              'pts': 0,
              'epoch': 'epoch',
              'rooms': [],
            };
      api.uploadHandler = (_, _) async {
        if (uploadFails) {
          throw const ChatApiException(
            'Upload failed',
            statusCode: 400,
            kind: ChatFailureKind.validation,
          );
        }
        return '/public/uploads/image.png';
      };
      api.postHandler = (_, body) async {
        final sent = ChatMessage.fromJson({
          ...message('image', key: body!['idempotencyKey'] as String).toJson(),
          'type': 'image',
          'imageUrl': body['imageUrl'],
        });
        return {'message': sent.toJson(), 'room': payload(last: sent)};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      await controller.debugLogin(1);
      await controller.openDirect(
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      );
      await controller.sendImage(Uint8List.fromList([1]), 'photo.png');
      await controller.outboxIdle;
      expect(controller.error, isNull);
      expect(controller.busy, false);
      final failed = (await db.allMessages('draft_peer')).single;
      expect(failed.status, 'failed');
      expect(failed.lastErrorText, 'Upload failed');
      expect(failed.uploadBytes, [1]);
      uploadFails = false;
      await controller.retryMessage(failed);
      await controller.outboxIdle;
      expect(controller.error, isNull);
      expect((await db.allMessages('room')).single.type, 'image');
      await controller.logout();
    },
  );

  test('an image whose send fails retries uploaded URL and idempotency key without uploading again', () async {
    final api = FakeApi();
    var uploads = 0;
    var sendFails = true;
    final keys = <String>[];
    api.handler = (path, _) async => path.startsWith('/rooms/direct-peer/')
        ? {'exists': false, 'room': null}
        : {'requiresFullSync': false, 'pts': 0, 'epoch': 'epoch', 'rooms': []};
    api.uploadHandler = (_, _) async {
      uploads++;
      return '/public/uploads/image.png';
    };
    api.postHandler = (_, body) async {
      keys.add(body!['idempotencyKey'] as String);
      if (sendFails) {
        throw const ChatApiException(
          'Send failed',
          statusCode: 400,
          kind: ChatFailureKind.validation,
        );
      }
      final sent = ChatMessage.fromJson({
        ...message('image', key: keys.last).toJson(),
        'type': 'image',
        'imageUrl': body['imageUrl'],
      });
      return {'message': sent.toJson(), 'room': payload(last: sent)};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    await controller.openDirect(
      const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
    );
    await controller.sendImage(Uint8List.fromList([1]), 'photo.png');
    await controller.outboxIdle;
    final failed = (await db.allMessages('draft_peer')).single;
    expect(failed.status, 'failed');
    expect(failed.imageUrl, '/public/uploads/image.png');
    sendFails = false;
    await controller.retryMessage(failed);
    await controller.outboxIdle;
    expect(controller.error, isNull);
    expect(uploads, 1);
    expect(keys.first, keys.last);
    await controller.logout();
  });

  test('historical jump slices track live edit, deletion-for-me and quoted deletion-for-all', () {
    final original = message('target');
    final quote = message('quote', reply: ReplySnapshot.fromMessage(original));
    final edited = ChatMessage.fromJson({
      ...original.toJson(),
      'text': 'edited',
      'isEdited': true,
    });
    var slice = reconcileJumpSlice([
      original,
      quote,
    ], payload(event: 'message_edited', updated: edited));
    expect(slice.first.text, 'edited');
    expect(slice.last.replyTo!.text, 'edited');
    final deleted = ChatMessage.fromJson({
      ...edited.toJson(),
      'text': '🚫 This message was deleted',
      'isDeletedForAll': true,
      'imageUrl': null,
    });
    slice = reconcileJumpSlice(
      slice,
      payload(event: 'message_deleted_all', updated: deleted),
    );
    expect(slice.first.isDeletedForAll, true);
    expect(slice.last.replyTo!.isDeleted, true);
    expect(slice.last.replyTo!.imageUrl, isNull);
    slice = reconcileJumpSlice(
      slice,
      payload(event: 'message_deleted_me', updated: deleted),
    );
    expect(slice.map((m) => m.id), ['quote']);
    expect(
      reconcileJumpSlice(
        slice,
        payload(last: message('new-tail')),
      ).map((m) => m.id),
      ['quote'],
    );
  });

  test('uncached reply jump stays in memory and returning restores reactive latest window', () async {
    final api = FakeApi();
    var aroundRequests = 0;
    api.handler = (path, query) async {
      if (path == '/rooms/delta') {
        return {
          'requiresFullSync': false,
          'pts': 1,
          'epoch': 'epoch',
          'rooms': query?['sincePts'] == 1
              ? []
              : [payload(last: message('latest'))],
        };
      }
      if (path.contains('/around/')) {
        aroundRequests++;
        return {
          'targetMessageId': 'ancient',
          'messages': [message('ancient', seconds: -500).toJson()],
        };
      }
      return {
        'messages': [message('latest').toJson()],
        'hasMore': true,
      };
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    await controller.openRoom((await db.room('room'))!);
    await controller.jumpToMessage('ancient');
    expect(controller.error, isNull);
    expect(controller.isJumpMode, true);
    expect(controller.messages.single.id, 'ancient');
    expect(aroundRequests, 1);
    expect(await db.message('ancient'), isNull);
    await controller.returnToLatest();
    await Future<void>.delayed(Duration.zero);
    expect(controller.isJumpMode, false);
    expect(controller.messages.single.id, 'latest');
    expect(api.messageRequests, 1);
    await controller.logout();
  });
  test('disabled production debug-user endpoint does not block a saved session or standard login', () async {
    final api = FakeApi();
    api.usersHandler = (path) async {
      if (path == '/auth/debug-users') {
        throw const ChatApiException('Not found', statusCode: 404);
      }
      return [];
    };
    api.handler = (_, _) async => {
      'requiresFullSync': false,
      'pts': 0,
      'epoch': 'epoch',
      'rooms': [],
    };
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'chat_session',
      '{"user":{"id":"me","username":"me","displayName":"Me"},"accessToken":"test","centrifugoToken":"test"}',
    );
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.initialize();
    expect(controller.initialized, true);
    expect(controller.error, isNull);
    expect(controller.currentUser!.id, 'me');
    expect(controller.debugUsers, isEmpty);
    await controller.logout();
    await controller.login('me@example.com', 'test-password');
    expect(controller.error, isNull);
    expect(controller.currentUser!.id, 'me');
    await controller.logout();
  });

  test('cached messages expand the visible window before requesting an older server page', () async {
    final api = FakeApi();
    api.handler = (path, query) async {
      if (path == '/rooms/delta') {
        return {
          'requiresFullSync': false,
          'pts': 100,
          'epoch': 'epoch',
          'rooms': query?['sincePts'] == 100
              ? []
              : [payload(pts: 100, last: message('100', seconds: 100))],
        };
      }
      if (query?['beforeId'] != null) return {'messages': [], 'hasMore': false};
      return {
        'messages': List.generate(
          30,
          (i) => message('${100 - i}', seconds: 100 - i).toJson(),
        ),
        'hasMore': true,
      };
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    await controller.openRoom((await db.room('room'))!);
    await controller.syncNow();
    for (var i = 1; i <= 70; i++) {
      await db.upsertMessage(message('$i', seconds: i));
    }
    await Future<void>.delayed(Duration.zero);
    expect(controller.messages.length, 50);
    expect(api.messageRequests, 1);
    await controller.loadOlderMessages();
    await Future<void>.delayed(Duration.zero);
    expect(controller.messages.length, 80);
    expect(api.messageRequests, 1);
    expect(controller.hasMoreMessages, true);
    await controller.loadOlderMessages();
    await Future<void>.delayed(Duration.zero);
    expect(controller.messages.length, 100);
    expect(api.messageRequests, 1);
    await controller.loadOlderMessages();
    expect(api.messageRequests, 2);
    expect(controller.hasMoreMessages, false);
    await controller.closeRoom();
    await controller.openRoom((await db.room('room'))!);
    expect(controller.hasMoreMessages, true);
    await controller.loadOlderMessages();
    await Future<void>.delayed(Duration.zero);
    expect(controller.messages.length, 80);
    expect(controller.hasMoreMessages, true);
    expect(api.messageRequests, 2);
    await controller.loadOlderMessages();
    await Future<void>.delayed(Duration.zero);
    expect(controller.messages.length, 100);
    expect(controller.hasMoreMessages, false);
    expect(api.messageRequests, 2);
    await controller.logout();
  });

  test('valid persisted top-page inbox recovers room pagination after an empty delta', () async {
    for (var i = 0; i < 25; i++) {
      await db.upsertRoom(ChatRoom.fromJson(payload(room: 'room-$i')));
    }
    await db.setCursor(25, 'epoch');
    final api = FakeApi()
      ..handler = (path, _) async {
        expect(path, '/rooms/delta');
        return {
          'requiresFullSync': false,
          'pts': 25,
          'epoch': 'epoch',
          'rooms': [],
        };
      };
    bool? persisted;
    final sync = InboxSyncService(
      database: db,
      api: api,
      userId: 'me',
      isCurrentSession: () => true,
      persistHasMoreRooms: (value) async {
        persisted = value;
      },
    );
    await sync.syncInboxDelta();
    expect(sync.hasMoreRooms, true);
    expect(persisted, true);
    expect((await db.metadata())!.localPts, 25);
    await sync.dispose();
    final restored = InboxSyncService(
      database: db,
      api: api,
      userId: 'me',
      isCurrentSession: () => true,
      restoredHasMoreRooms: false,
    );
    await restored.syncInboxDelta();
    expect(restored.hasMoreRooms, false);
    await restored.dispose();
  });

  test('presence batches 102 direct-room peers and availability failures do not block authentication', () async {
    final api = FakeApi()
      ..userList = List.generate(
        102,
        (i) => UserProfile(id: 'user-$i', username: '$i', displayName: '$i'),
      );
    final sizes = <int>[];
    api.handler = (path, query) async {
      if (path == '/rooms/delta') {
        return {
          'requiresFullSync': false,
          'pts': 102,
          'epoch': 'epoch',
          'rooms': List.generate(
            102,
            (i) => {
              ...payload(room: 'room-$i', pts: i + 1),
              'peerUserId': 'user-$i',
            },
          ),
        };
      }
      final ids = (query!['userIds'] as String).split(',');
      sizes.add(ids.length);
      if (sizes.length == 2) {
        throw const ChatApiException('Presence temporarily unavailable');
      }
      return {
        'statuses': {for (final id in ids) id: true},
      };
    };
    api.otherPostHandler = (path, _) async {
      if (path == '/presence/heartbeat') {
        throw const ChatApiException('Presence temporarily unavailable');
      }
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    expect(controller.error, isNull);
    expect(controller.currentUser!.id, 'me');
    expect(sizes, [100, 2]);
    expect(controller.onlineUserIds.length, 100);
    expect(
      (controller.diagnostics['recentEvents'] as List).last['event'],
      'session_started',
    );
    await controller.logout();
  });

  test(
    'delivery receipts are split into authorized batches of at most 100 rooms',
    () async {
      final api = FakeApi();
      final sizes = <int>[];
      api.handler = (_, _) async => {
        'requiresFullSync': false,
        'pts': 102,
        'epoch': 'epoch',
        'rooms': List.generate(
          102,
          (i) => payload(
            room: 'room-$i',
            pts: i + 1,
            last: message('message-$i', room: 'room-$i', sender: 'peer'),
          ),
        ),
      };
      api.otherPostHandler = (path, body) async {
        if (path == '/rooms/delivered-batch') {
          sizes.add((body!['roomIds'] as List).length);
        }
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      await controller.debugLogin(1);
      expect(controller.error, isNull);
      final receiptWait = Stopwatch()..start();
      while (sizes.length < 2 &&
          receiptWait.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(sizes.every((size) => size <= 100), true);
      expect(sizes, containsAll([100, 2]));
      await controller.logout();
    },
  );

  test('pending and failed inbox previews react to messages without changing server counters or draft visibility', () async {
    final server = message('server');
    await db.applyRoomPayload(payload(last: server), myUserId: 'me');
    await db.setCursor(1, 'epoch');
    final statuses = <String>[];
    final subscription = db.watchRooms().listen((rooms) {
      if (rooms.isNotEmpty) statuses.add(rooms.single.lastMessage!.status);
    });
    final pending = message('temp_pending', seconds: 1, status: 'sending');
    await db.upsertMessage(pending);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(statuses.last, 'sending');
    expect((await db.room('room'))!.lastMessage!.id, 'server');
    expect((await db.room('room'))!.roomPts, 1);
    expect((await db.metadata())!.localPts, 1);
    await db.setMessageStatus(pending.id, 'failed');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(statuses.last, 'failed');
    await db.upsertMessage(
      message('draft', room: 'draft_peer', status: 'sending'),
    );
    expect((await db.watchRooms().first).length, 1);
    await db.applyRoomPayload(
      payload(pts: 2, last: message('newer-server', seconds: 2)),
      myUserId: 'me',
    );
    final rooms = await db.watchRooms().first;
    expect(rooms.single.lastMessage!.id, 'newer-server');
    expect(rooms.single.lastMessage!.status, 'sent');
    await subscription.cancel();
  });

  test(
    'account switching cancels a send paused in its optimistic local write',
    () async {
      await db.close();
      final paused = PausableMessageDatabase();
      db = paused;
      final api = FakeApi();
      api.authHandler = (body) async {
        final id = body['debugUserNumber'] == 1 ? 'me' : 'other';
        return {
          'user': {'id': id, 'username': id, 'displayName': id},
          'accessToken': id,
          'centrifugoToken': id,
        };
      };
      api.handler = (path, _) async => path.startsWith('/rooms/direct-peer/')
          ? {'exists': false, 'room': null}
          : {
              'requiresFullSync': false,
              'pts': 0,
              'epoch': 'epoch',
              'rooms': [],
            };
      var submissions = 0;
      api.postHandler = (_, _) async {
        submissions++;
        throw const ChatApiException('Unexpected cross-session submission');
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      await controller.debugLogin(1);
      await controller.openDirect(
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      );
      final originalGeneration = controller.sessionGenerationId;
      paused.pauseInsert = true;
      final sending = controller.sendText(
        'A message belonging to the first account',
      );
      await paused.writePaused.future;
      final switching = controller.debugLogin(2);
      await Future<void>.delayed(Duration.zero);
      expect(controller.sessionGenerationId, greaterThan(originalGeneration));
      paused.resumeWrite.complete();
      await Future.wait([sending, switching]);
      expect(submissions, 0);
      expect(controller.currentUser!.id, 'other');
      expect((await db.metadata())!.userId, 'other');
      expect(await db.allMessages('draft_peer'), isEmpty);
      await controller.logout();
    },
  );

  test(
    'logout cancels a retry paused in its local sending-status write',
    () async {
      await db.close();
      final paused = PausableMessageDatabase();
      db = paused;
      final api = FakeApi()
        ..handler = (_, _) async => {
          'requiresFullSync': false,
          'pts': 0,
          'epoch': 'epoch',
          'rooms': [],
        };
      var submissions = 0;
      api.postHandler = (_, _) async {
        submissions++;
        throw const ChatApiException('Unexpected submission after logout');
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      await controller.debugLogin(1);
      final failed = message('failed', status: 'failed');
      await db.upsertMessage(failed);
      final originalGeneration = controller.sessionGenerationId;
      paused.pauseStatus = true;
      final retrying = controller.retryMessage(failed);
      await paused.writePaused.future;
      final loggingOut = controller.logout();
      await Future<void>.delayed(Duration.zero);
      expect(controller.sessionGenerationId, greaterThan(originalGeneration));
      paused.resumeWrite.complete();
      await Future.wait([retrying, loggingOut]);
      expect(submissions, 0);
      expect(controller.currentUser, isNull);
      expect(await db.metadata(), isNull);
      expect(await db.allMessages('room'), isEmpty);
    },
  );

  test('retry refuses a message belonging to another sender before any local write', () async {
    final api = FakeApi()
      ..handler = (_, _) async => {
        'requiresFullSync': false,
        'pts': 0,
        'epoch': 'epoch',
        'rooms': [],
      };
    var submissions = 0;
    api.postHandler = (_, _) async {
      submissions++;
      throw const ChatApiException('Unexpected submission for another sender');
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    final foreign = message(
      'foreign',
      sender: 'another-account',
      status: 'failed',
    );
    await db.upsertMessage(foreign);
    await controller.retryMessage(foreign);
    expect(submissions, 0);
    expect((await db.message(foreign.id))!.status, 'failed');
    expect(controller.error, isNull);
    await controller.logout();
  });

  test('an upload finishing after an account switch cannot create or submit an image', () async {
    final api = FakeApi();
    api.authHandler = (body) async {
      final id = body['debugUserNumber'] == 1 ? 'me' : 'other';
      return {
        'user': {'id': id, 'username': id, 'displayName': id},
        'accessToken': id,
        'centrifugoToken': id,
      };
    };
    api.handler = (path, _) async => path.startsWith('/rooms/direct-peer/')
        ? {'exists': false, 'room': null}
        : {'requiresFullSync': false, 'pts': 0, 'epoch': 'epoch', 'rooms': []};
    final uploaded = Completer<String>();
    api.uploadHandler = (_, _) => uploaded.future;
    var submissions = 0;
    api.postHandler = (_, _) async {
      submissions++;
      throw const ChatApiException(
        'Unexpected image submission after switching accounts',
      );
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    await controller.openDirect(
      const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
    );
    final sending = controller.sendImage(Uint8List.fromList([1]), 'image.png');
    await Future<void>.delayed(Duration.zero);
    await controller.debugLogin(2);
    uploaded.complete('/public/uploads/image.png');
    await sending;
    expect(submissions, 0);
    expect(controller.currentUser!.id, 'other');
    expect(await db.allMessages('draft_peer'), isEmpty);
    expect((await db.rowCounts())['storedMessageRows'], 0);
    await controller.logout();
  });
}
