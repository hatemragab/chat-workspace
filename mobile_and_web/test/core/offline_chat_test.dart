import 'dart:async';
import 'dart:convert';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session;
import 'sync_test.dart' show instant, message, payload;

const _peer = UserProfile(
  id: 'peer',
  username: 'peer',
  displayName: 'Cached Peer',
);
const _newPeer = UserProfile(
  id: 'new-peer',
  username: 'new',
  displayName: 'New Peer',
);
const _otherPeer = UserProfile(
  id: 'other-peer',
  username: 'other',
  displayName: 'Other Peer',
);

class _OfflineApi extends ChatApi {
  _OfflineApi() : super(enableHttpLogging: false);
  bool unavailable = false, failMessages = true;
  Completer<Map<String, dynamic>>? inboxGate,
      latestGate,
      directGate,
      sendGate,
      aroundGate;
  Map<String, dynamic> inbox = delta(7, []);
  List<ChatMessage> fresh = [];
  final requests = <String>[];
  final sends = <Map<String, dynamic>>[];
  final latestStarted = Completer<void>();

  @override
  Future<({List<UserProfile> users, String? nextCursor})> directoryPage({
    String? cursor,
  }) async => (users: await getUsers('/users'), nextCursor: null);
  @override
  Future<List<UserProfile>> getUsers(String path) async {
    if (path == '/auth/debug-users') return [];
    if (unavailable) throw const ChatApiException('offline');
    return [_peer, _newPeer, _otherPeer];
  }

  @override
  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requests.add(path);
    if (path == '/rooms/delta' && inboxGate != null) return inboxGate!.future;
    if (path.endsWith('/messages') && latestGate != null) {
      if (!latestStarted.isCompleted) latestStarted.complete();
      return latestGate!.future;
    }
    if (path.endsWith('/direct-peer/${_newPeer.id}') && directGate != null) {
      return directGate!.future;
    }
    if (path.contains('/messages/around/') && aroundGate != null) {
      return aroundGate!.future;
    }
    if (unavailable) throw const ChatApiException('offline');
    if (path == '/rooms/delta') return inbox;
    if (path == '/presence/status') return {'statuses': <String, bool>{}};
    if (path.startsWith('/rooms/direct-peer/')) return {'room': null};
    if (path.endsWith('/messages')) {
      if (!latestStarted.isCompleted) latestStarted.complete();
      return latestPage();
    }
    throw StateError('Unexpected $path');
  }

  Map<String, dynamic> latestPage() => {
    'messages': fresh.map((m) => m.toJson()).toList(),
    'hasMore': false,
    'receipts': {
      'deliveredThrough': null,
      'seenThrough': null,
      'hasGaps': false,
    },
  };

  @override
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/auth/debug-login') return session('me');
    if (path == '/presence/offline') return {'ok': true};
    if (path == '/messages') {
      sends.add(Map.of(body!));
      if (sendGate != null) return sendGate!.future;
      if (unavailable) {
        throw const ChatApiException(
          'offline',
          kind: ChatFailureKind.transport,
        );
      }
      if (failMessages) {
        throw const ChatApiException(
          'Invalid message',
          statusCode: 400,
          kind: ChatFailureKind.validation,
        );
      }
      final sent = {
        ...body,
        'id': 'ack-${sends.length}',
        'roomId': body['roomId'] ?? 'created-room',
        'senderId': 'me',
        'senderName': 'Me',
        'createdAt': instant
            .add(Duration(minutes: sends.length))
            .toIso8601String(),
      };
      return {
        'message': sent,
        'room': {
          ...payload(
            room: sent['roomId'] as String,
            pts: 10,
            last: ChatMessage.fromJson(sent),
          ),
          'peerUserId': body['peerUserId'] ?? _peer.id,
        },
      };
    }
    if (unavailable) throw const ChatApiException('offline');
    return {'ok': true};
  }

  void release() {
    if (inboxGate != null && !inboxGate!.isCompleted) {
      inboxGate!.complete(delta(7, []));
    }
    if (latestGate != null && !latestGate!.isCompleted) {
      latestGate!.complete(latestPage());
    }
    if (directGate != null && !directGate!.isCompleted) {
      directGate!.complete({'room': null});
    }
    if (aroundGate != null && !aroundGate!.isCompleted) {
      aroundGate!.complete({'messages': []});
    }
    if (sendGate != null && !sendGate!.isCompleted) {
      sendGate!.completeError(const ChatApiException('offline'));
    }
  }
}

Future<void> _waitUntil(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError('Expected local operation did not complete');
}

class _Harness {
  final db = AppDatabase(NativeDatabase.memory());
  final api = _OfflineApi();
  late final ChatController controller;
  late ChatRoom room;

  Future<void> seed({
    int count = 100,
    int synced = 0,
    bool recoverInterrupted = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    await db.initializeSession('me');
    await db.setCursor(7, 'epoch');
    room = ChatRoom.fromJson({
      ...payload(pts: 7),
      'displayTitle': _peer.displayName,
    });
    await db.transaction(() async {
      await db.upsertRoom(room);
      await db.markMessagesSynced('room', synced);
      for (var i = 0; i < count; i++) {
        await db.upsertMessage(message('cached-$i', seconds: i));
      }
      await db.upsertMessage(
        message(
          'interrupted',
          status: recoverInterrupted ? 'sending' : 'failed',
          seconds: count,
        ),
      );
      await db.upsertMessage(
        message('retained-failed', status: 'failed', seconds: count + 1),
      );
    });
    api.fresh = List.generate(
      30,
      (i) => message('cached-${count - 1 - i}', seconds: count - 1 - i),
    );
    controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: () => ServerHealthMonitor(
        healthUri: Uri.parse('http://test.invalid/health'),
        probe: () async => !api.unavailable,
      ),
    );
  }

  Future<void> close() async {
    await controller.logout();
    api.release();
    await Future<void>.delayed(Duration.zero);
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saved cache, local paging, reply jump and latest view never wait for startup HTTP', () async {
    final h = _Harness();
    await h.seed(recoverInterrupted: true);
    h.api.inboxGate = Completer<Map<String, dynamic>>();
    try {
      await h.controller.initialize().timeout(const Duration(seconds: 1));
      expect(h.controller.initialized, true);
      expect(h.controller.busy, false);
      expect(h.controller.currentUser!.id, 'me');
      expect(h.controller.rooms.single.roomId, 'room');
      expect(h.controller.users.any((u) => u.id == _peer.id), true);
      expect((await h.db.message('interrupted'))!.status, 'queued');
      expect((await h.db.message('interrupted'))!.outcomeUnknown, isTrue);
      await h.controller.openRoom(h.room).timeout(const Duration(seconds: 1));
      expect(h.controller.messages.length, 50);
      await h.controller.loadOlderMessages().timeout(
        const Duration(seconds: 1),
      );
      expect(h.controller.messages.length, 80);
      await h.controller
          .jumpToMessage('cached-0')
          .timeout(const Duration(seconds: 1));
      expect(h.controller.messages.any((m) => m.id == 'cached-0'), true);
      expect(h.controller.highlightMessageId, 'cached-0');
      await h.controller.returnToLatest().timeout(const Duration(seconds: 1));
      expect(h.controller.messages.length, 50);
      await h.controller.openDirect(_peer).timeout(const Duration(seconds: 1));
      expect(h.controller.selectedRoom!.roomId, 'room');
      expect(
        h.api.requests.where((p) => p.startsWith('/rooms/direct-peer/')),
        isEmpty,
      );
      expect(h.api.messageRequests, 0);
      expect((await h.db.metadata())!.localPts, 7);
      expect((await h.db.room('room'))!.messagesSyncedPts, 0);
      expect(h.api.inboxGate!.isCompleted, false);
      expect(h.api.requests.where((p) => p == '/rooms/delta'), hasLength(1));
    } finally {
      await h.close();
    }
  });

  test(
    'cached navigation remains usable while latest-page HTTP is pending',
    () async {
      final h = _Harness();
      await h.seed();
      try {
        await h.controller.initialize();
        await h.controller.syncNow();
        h.api.latestGate = Completer<Map<String, dynamic>>();
        await h.controller.openRoom(h.room).timeout(const Duration(seconds: 1));
        await h.api.latestStarted.future;
        expect(h.controller.messages.length, 50);
        await h.controller.loadOlderMessages().timeout(
          const Duration(seconds: 1),
        );
        expect(h.controller.messages.length, 80);
        await h.controller
            .jumpToMessage('cached-0')
            .timeout(const Duration(seconds: 1));
        expect(h.controller.messages.any((m) => m.id == 'cached-0'), true);
        await h.controller.returnToLatest().timeout(const Duration(seconds: 1));
        for (var i = 0; i < 5; i++) {
          await h.controller.openRoom(h.room);
        }
        expect(h.api.messageRequests, 1);
        expect((await h.db.room('room'))!.messagesSyncedPts, 0);
        h.api.latestGate!.complete(h.api.latestPage());
        await h.controller.syncNow();
        expect((await h.db.room('room'))!.messagesSyncedPts, 7);
        expect(h.api.messageRequests, 1);
        expect(h.controller.messages.isNotEmpty, true);
      } finally {
        await h.close();
      }
    },
  );

  test('failed recovery preserves cached and failed rows until ordinary successful reconciliation', () async {
    final h = _Harness();
    await h.seed();
    h.api.unavailable = true;
    try {
      await h.controller.initialize();
      await h.controller.openRoom(h.room);
      await _waitUntil(() => h.controller.connectionStatus == 'Offline');
      expect(h.controller.messages.any((m) => m.id == 'retained-failed'), true);
      await h.controller.sendText('Written offline');
      await h.controller.outboxIdle;
      final failed = (await h.db.allMessages('room'))
          .singleWhere((m) => m.text == 'Written offline');
      expect(failed.status, 'queued');
      expect(failed.outcomeUnknown, isTrue);
      expect((await h.db.metadata())!.localPts, 7);
      h.api.unavailable = false;
      h.api.inbox = delta(9, [
        payload(pts: 9, history: 8, last: h.api.fresh.first),
      ]);
      await h.controller.syncNow();
      expect((await h.db.metadata())!.localPts, 9);
      expect((await h.db.room('room'))!.messagesSyncedPts, 9);
      await h.controller.outboxIdle;
      expect(await h.db.message('cached-0'), isNull);
      // The earlier transport failure could have committed. A later rejection
      // cannot prove it did not, so retain this FIFO head for explicit Retry.
      expect((await h.db.message(failed.id))!.status, 'queued');
      expect((await h.db.message(failed.id))!.outboxPaused, isTrue);
      expect(h.controller.connectionStatus, 'Connected');
      h.api.failMessages = false;
      await h.controller.retryMessage(failed);
      await h.controller.outboxIdle;
      expect(
        h.api.sends.last['idempotencyKey'],
        h.api.sends.first['idempotencyKey'],
      );
      expect(
        (await h.db.messageByIdempotencyKey(
          'me',
          failed.idempotencyKey,
        ))!.status,
        'sent',
      );
      expect((await h.db.metadata())!.localPts, 9);
    } finally {
      await h.close();
    }
  });

  test('a failed local draft remains reopenable while direct lookup never responds and late lookup cannot navigate', () async {
    final h = _Harness();
    await h.seed();
    h.api.directGate = Completer<Map<String, dynamic>>();
    try {
      await h.controller.initialize();
      await h.controller
          .openDirect(_newPeer)
          .timeout(const Duration(seconds: 1));
      await h.controller.sendText('Offline first message');
      await h.controller.outboxIdle;
      final failed = (await h.db.allMessages('draft_new-peer')).single;
      expect(failed.status, 'failed');
      final draft = (await h.db.room('draft_new-peer'))!;
      await h.controller.closeRoom();
      await h.controller.openRoom(draft).timeout(const Duration(seconds: 1));
      expect(h.controller.draftPeer!.id, _newPeer.id);
      expect(h.controller.selectedRoom, isNull);
      expect(h.controller.messages.single.id, failed.id);
      await h.controller.jumpToMessage(failed.id);
      expect(h.controller.highlightMessageId, failed.id);
      await h.controller.jumpToMessage('uncached-reply');
      expect(h.controller.isJumpMode, true);
      expect(h.controller.messages.single.id, failed.id);
      expect(h.controller.error, 'This message is not cached on this device.');
      expect(
        h.api.requests.any((path) => path.startsWith('/rooms/draft_')),
        false,
      );
      await h.controller.openDirect(_otherPeer);
      h.api.directGate!.complete({'room': payload(room: 'late-room')});
      await Future<void>.delayed(Duration.zero);
      expect(h.controller.draftPeer!.id, _otherPeer.id);
      expect(await h.db.room('late-room'), isNull);
      h.api.failMessages = false;
      await h.controller.retryMessage(failed);
      await h.controller.outboxIdle;
      await _waitUntil(
        () async =>
            (await h.db.messageByIdempotencyKey(
              'me',
              failed.idempotencyKey,
            ))?.status ==
            'sent',
      );
      expect(h.api.sends.last['idempotencyKey'], failed.idempotencyKey);
      expect(
        (await h.db.messageByIdempotencyKey(
          'me',
          failed.idempotencyKey,
        ))!.roomId,
        'created-room',
      );
      expect(await h.db.room('draft_new-peer'), isNull);
      expect(h.controller.draftPeer!.id, _otherPeer.id);
    } finally {
      await h.close();
    }
  });

  test('learning a real room while lookup stalls remaps old failed drafts and new pending sends visibly', () async {
    final h = _Harness();
    await h.seed();
    h.api.directGate = Completer<Map<String, dynamic>>();
    try {
      await h.controller.initialize();
      await h.controller.openDirect(_newPeer);
      final context = h.controller.captureSendContext()!;
      await h.controller.sendText('Older failed draft', context: context);
      await h.controller.outboxIdle;
      final old = (await h.db.allMessages('draft_new-peer')).single;
      await h.db.transaction(
        () async => h.db.applyRoomPayload(
          {
            ...payload(room: 'learned-room', pts: 8),
            'peerUserId': _newPeer.id,
            'displayTitle': _newPeer.displayName,
          },
          myUserId: 'me',
          markOpenSynced: false,
        ),
      );
      h.api.sendGate = Completer<Map<String, dynamic>>();
      final sending = h.controller.sendText(
        'New pending message',
        context: context,
      );
      await _waitUntil(() => h.api.sends.length == 2);
      expect(h.controller.selectedRoom!.roomId, 'learned-room');
      expect(h.controller.draftPeer, isNull);
      expect(
        h.controller.messages.any(
          (m) => m.id == old.id && m.status == 'failed',
        ),
        true,
      );
      expect(
        h.controller.messages.any(
          (m) => m.text == 'New pending message' && m.status == 'sending',
        ),
        true,
      );
      expect(await h.db.allMessages('draft_new-peer'), isEmpty);
      expect(await h.db.room('draft_new-peer'), isNull);
      expect(h.api.sends.last['roomId'], 'learned-room');
      h.api.sendGate!.completeError(
        const ChatApiException(
          'Invalid message',
          statusCode: 400,
          kind: ChatFailureKind.validation,
        ),
      );
      await sending;
      await h.controller.outboxIdle;
      expect(
        (await h.db.allMessages('learned-room'))
            .where((m) => m.status == 'failed'),
        hasLength(2),
      );
    } finally {
      await h.close();
    }
  });

  test(
    'periodic recovery repairs an offline-started open cache without manual sync or resume',
    () async {
      final h = _Harness();
      await h.seed();
      h.api.unavailable = true;
      try {
        await h.controller.initialize();
        await h.controller.openRoom(h.room);
        await _waitUntil(() {
          final events = h.controller.diagnostics['recentEvents'] as List;
          return events.any(
                (event) => event['event'] == 'session_recovery_unavailable',
              ) &&
              events.any(
                (event) => event['event'] == 'room_recovery_unavailable',
              );
        });
        expect(h.api.latestStarted.isCompleted, false);
        h.api.unavailable = false;
        h.api.inbox = delta(9, [
          payload(pts: 9, history: 8, last: h.api.fresh.first),
        ]);
        final interval = const int.fromEnvironment(
          'PRESENCE_REFRESH_SECONDS',
          defaultValue: 30,
        ).clamp(1, 3600);
        await h.api.latestStarted.future.timeout(
          Duration(seconds: interval + 5),
        );
        await _waitUntil(
          () async => (await h.db.room('room'))!.messagesSyncedPts == 9,
        );
        expect((await h.db.metadata())!.localPts, 9);
        expect(h.controller.connectionStatus, 'Connected');
        expect(
          h.controller.messages.any((m) => m.id == 'retained-failed'),
          true,
        );
      } finally {
        await h.close();
      }
    },
    timeout: Timeout(
      Duration(
        seconds:
            const int.fromEnvironment(
              'PRESENCE_REFRESH_SECONDS',
              defaultValue: 30,
            ).clamp(1, 3600) +
            10,
      ),
    ),
  );

  test('manual recovery retries session setup after a later outage and a failed retry', () async {
    final h = _Harness();
    await h.seed();
    try {
      await h.controller.initialize();
      await h.controller.syncNow();
      expect(h.controller.diagnostics['remoteStartupComplete'], true);
      expect(h.controller.connectionStatus, 'Connected');

      h.api.unavailable = true;
      await h.controller.openRoom(h.room);
      await _waitUntil(() {
        final events = h.controller.diagnostics['recentEvents'] as List;
        return events.any(
          (event) => event['event'] == 'room_recovery_unavailable',
        );
      });
      expect(h.controller.connectionStatus, 'Offline');
      expect(h.controller.messages.any((m) => m.id == 'retained-failed'), true);
      await h.controller.syncNow();
      expect(h.controller.connectionStatus, 'Offline');
      expect(h.controller.error, 'offline');
      expect(h.controller.diagnostics['remoteStartupComplete'], true);
      expect((await h.db.metadata())!.localPts, 7);
      expect((await h.db.room('room'))!.messagesSyncedPts, 0);

      h.api.unavailable = false;
      h.api.inbox = delta(9, [
        payload(pts: 9, history: 8, last: h.api.fresh.first),
      ]);
      await h.controller.syncNow();
      expect(h.controller.connectionStatus, 'Connected');
      expect(h.controller.error, isNull);
      expect((await h.db.metadata())!.localPts, 9);
      expect((await h.db.room('room'))!.messagesSyncedPts, 9);
      expect((await h.db.message('retained-failed'))!.status, 'failed');
      expect(h.controller.messages.any((m) => m.id == 'retained-failed'), true);
    } finally {
      await h.close();
    }
  });

  test('cached real-peer opening merges its older failed draft without waiting for lookup', () async {
    final h = _Harness();
    await h.seed();
    h.api.directGate = Completer<Map<String, dynamic>>();
    try {
      await h.controller.initialize();
      await h.controller.openDirect(_newPeer);
      await h.controller.sendText('Existing failed draft');
      await h.controller.outboxIdle;
      final failed = (await h.db.allMessages('draft_new-peer')).single;
      await h.controller.openDirect(_otherPeer);
      await h.db.upsertRoom(
        ChatRoom.fromJson({
          ...payload(room: 'known-real', pts: 8),
          'peerUserId': _newPeer.id,
          'displayTitle': _newPeer.displayName,
        }),
      );
      await h.controller
          .openDirect(_newPeer)
          .timeout(const Duration(seconds: 1));
      expect(h.controller.selectedRoom!.roomId, 'known-real');
      expect(
        h.controller.messages.any(
          (m) => m.id == failed.id && m.status == 'failed',
        ),
        true,
      );
      expect((await h.db.message(failed.id))!.roomId, 'known-real');
      expect(await h.db.allMessages('draft_new-peer'), isEmpty);
      expect(await h.db.room('draft_new-peer'), isNull);
      expect(h.api.directGate!.isCompleted, false);
    } finally {
      await h.close();
    }
  });

  test('live ACK wins a lost REST response and late lookup preserves a newer historical view', () async {
    final h = _Harness();
    await h.seed();
    h.api.directGate = Completer<Map<String, dynamic>>();
    try {
      await h.controller.initialize();
      await h.controller.openDirect(_newPeer);
      final context = h.controller.captureSendContext()!;
      await h.controller.sendText('Older failed draft', context: context);
      await h.controller.outboxIdle;
      final older = (await h.db.allMessages('draft_new-peer')).single;
      h.api.sendGate = Completer<Map<String, dynamic>>();
      final sending = h.controller.sendText(
        'Accepted before REST failed',
        context: context,
      );
      await _waitUntil(() => h.api.sends.length == 2);
      final key = h.api.sends.last['idempotencyKey'] as String;
      final foreign = message(
        'foreign-same-key',
        room: 'ack-room',
        sender: 'another-sender',
        key: key,
      );
      final acknowledged = ChatMessage.fromJson({
        ...message('acknowledged', room: 'ack-room', key: key).toJson(),
        'text': 'Accepted before REST failed',
      });
      final ackRoom = {
        ...payload(room: 'ack-room', pts: 8, last: acknowledged),
        'peerUserId': _newPeer.id,
        'displayTitle': _newPeer.displayName,
      };
      await h.db.transaction(() async {
        await h.db.upsertMessage(foreign);
        await h.db.applyRoomPayload(
          ackRoom,
          myUserId: 'me',
          markOpenSynced: false,
        );
      });
      await _waitUntil(
        () =>
            h.controller.selectedRoom?.roomId == 'ack-room' &&
            h.controller.messages.any((m) => m.id == acknowledged.id),
      );
      expect(h.controller.messages.any((m) => m.id == older.id), true);
      expect((await h.db.message(older.id))!.roomId, 'ack-room');
      expect(await h.db.room('draft_new-peer'), isNull);
      expect(h.api.sendGate!.isCompleted, false);

      await h.db.markMessagesSynced('ack-room', 8);
      final historical = message(
        'newer-historical-view',
        room: 'ack-room',
        seconds: -600,
      );
      h.controller.isJumpMode = true;
      h.controller.messages = [historical];
      h.api.directGate!.complete({'room': ackRoom});
      await h.controller.syncNow();
      expect(h.controller.isJumpMode, true);
      expect(h.controller.messages.single.id, historical.id);
      h.api.sendGate!.completeError(
        const ChatApiException('lost REST response'),
      );
      await sending;
      await h.controller.outboxIdle;
      expect(h.controller.error, isNull);
      expect((await h.db.message(acknowledged.id))!.status, 'sent');
      expect(
        (await h.db.messageByIdempotencyKey('me', key))!.id,
        acknowledged.id,
      );
      expect(
        (await h.db.messageByIdempotencyKey('another-sender', key))!.id,
        foreign.id,
      );
      expect(h.controller.isJumpMode, true);
      expect(h.controller.messages.single.id, historical.id);
    } finally {
      await h.close();
    }
  });

  for (final pendingInbox in [true, false]) {
    test(
      'initial uncached reply jump keeps cached tail while ${pendingInbox ? 'inbox stays pending' : 'around request fails'}',
      () async {
        final h = _Harness();
        await h.seed(synced: 7);
        if (pendingInbox) h.api.inboxGate = Completer<Map<String, dynamic>>();
        try {
          await h.controller.initialize();
          if (!pendingInbox) await h.controller.syncNow();
          await h.controller.openRoom(h.room);
          if (!pendingInbox) {
            await h.controller.syncNow();
            h.api.aroundGate = Completer<Map<String, dynamic>>();
          }
          final visible = h.controller.messages.map((m) => m.id).toList();
          final jumping = h.controller.jumpToMessage('not-cached');
          await _waitUntil(() => h.controller.isJumpMode);
          expect(h.controller.messages.map((m) => m.id), visible);
          if (!pendingInbox) {
            await _waitUntil(
              () => h.api.requests.any(
                (path) => path.contains('/around/not-cached'),
              ),
            );
            h.api.aroundGate!.completeError(const ChatApiException('offline'));
            await jumping;
            expect(h.controller.messages.map((m) => m.id), visible);
            expect(h.controller.error, 'offline');
          }
          await h.controller.returnToLatest().timeout(
            const Duration(seconds: 1),
          );
          expect(h.controller.isJumpMode, false);
          expect(h.controller.messages.map((m) => m.id), visible);
          if (pendingInbox) {
            h.api.inboxGate!.complete(delta(7, []));
            await jumping;
          }
        } finally {
          await h.close();
        }
      },
    );
  }
}
