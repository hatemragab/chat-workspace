import 'dart:async';
import 'dart:convert';
import 'dart:io';

// This test server speaks the SDK's pinned protobuf wire protocol, so the real
// controller ingress runs instead of bypassing it with a mocked sync call.
// ignore: implementation_imports
import 'package:centrifuge/src/proto/client.pb.dart' as protocol;
import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session, waitForController;
import 'sequence_receipts_test.dart' show sequenced;
import 'sync_test.dart' show FakeApi, message, payload;

class _RecoveryProbeDatabase extends AppDatabase {
  _RecoveryProbeDatabase() : super(NativeDatabase.memory());
  int windowReads = 0, countReads = 0;

  @override
  Future<List<ChatMessage>> messageWindow(String roomId, int limit) {
    windowReads++;
    return super.messageWindow(roomId, limit);
  }

  @override
  Future<int> messageCount(String roomId, {bool sentOnly = false}) {
    countReads++;
    return super.messageCount(roomId, sentOnly: sentOnly);
  }
}

class _InboxSocket {
  _InboxSocket(this.server);
  final HttpServer server;
  final ready = Completer<WebSocket>();
  final connections = <WebSocket>[];

  static Future<_InboxSocket> start() async {
    final inbox = _InboxSocket(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    inbox.server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (_) => 'centrifuge-protobuf',
      );
      inbox.connections.add(socket);
      socket.listen((frame) {
        final bytes = frame as List<int>;
        var offset = 0;
        while (offset < bytes.length) {
          var length = 0, shift = 0, next = 0;
          do {
            next = bytes[offset++];
            length |= (next & 127) << shift;
            shift += 7;
          } while (next >= 128);
          final command = protocol.Command.fromBuffer(
            bytes.sublist(offset, offset + length),
          );
          offset += length;
          if (command.hasConnect()) {
            inbox._send(
              socket,
              protocol.Reply(
                id: command.id,
                connect: protocol.ConnectResult(
                  client: 'test-client',
                  version: '6',
                  subs: [MapEntry('inbox:user#me', protocol.SubscribeResult())],
                ),
              ),
            );
            if (!inbox.ready.isCompleted) inbox.ready.complete(socket);
          }
        }
      });
    });
    return inbox;
  }

  void _send(WebSocket socket, protocol.Reply reply) {
    final body = reply.writeToBuffer();
    final prefix = <int>[];
    var size = body.length;
    while (size >= 128) {
      prefix.add((size & 127) | 128);
      size >>= 7;
    }
    prefix.add(size);
    socket.add([...prefix, ...body]);
  }

  Future<void> publish(Map<String, dynamic> data) async {
    _send(
      await ready.future,
      protocol.Reply(
        push: protocol.Push(
          channel: 'inbox:user#me',
          pub: protocol.Publication(data: utf8.encode(jsonEncode(data))),
        ),
      ),
    );
  }

  Future<void> close() async {
    for (final socket in connections) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

Map<String, dynamic> _room({
  int pts = 1,
  int unread = 3,
  int peerSeen = 0,
  int ownSeen = 0,
  String event = 'message_new',
}) => {
  ...payload(pts: pts, last: sequenced('outgoing', 1), event: event),
  'contentPts': 1,
  'unreadCount': unread,
  'receiptProtocol': 'sequence',
  'peerDeliveredSeq': peerSeen,
  'peerSeenSeq': peerSeen,
  'ownDeliveredSeq': ownSeen,
  'ownSeenSeq': ownSeen,
};

Map<String, dynamic> _unread(int pts, {int count = 0}) => {
  'epoch': 'epoch',
  'pts': pts,
  'unread': {
    'roomId': 'room',
    'eventType': 'room_unread_cleared',
    'unreadCount': count,
    'ownDeliveredSeq': 1,
    'ownSeenSeq': 1,
  },
};

Future<void> _waitForCursor(AppDatabase db, int pts) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if ((await db.metadata())?.localPts == pts) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError('Inbox did not reach $pts');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mode in ['foreground', 'hidden', 'navigated']) {
    final hidden = mode != 'foreground';
    test(
      '20 queued publications coalesce receipt work while $mode and preserve earlier incoming work under own echoes',
      () async {
        SharedPreferences.setMockInitialValues({
          'chat_session': jsonEncode(session('me')),
          'chat_room_pagination': jsonEncode({'userId': 'me', 'hasMore': true}),
        });
        final inbox = await _InboxSocket.start();
        final db = _RecoveryProbeDatabase();
        await db.initializeSession('me');
        await db.setCursor(1, 'epoch');
        Map<String, dynamic> room(int pts, int seq, {String sender = 'me'}) => {
          ...payload(
            pts: pts,
            last: sequenced('burst-$seq', seq, sender: sender),
          ),
          'contentPts': pts,
          'receiptProtocol': 'sequence',
          'ownDeliveredSeq': 1,
          'ownSeenSeq': 1,
        };
        await db.applyRoomPayload(room(1, 1), myUserId: 'me');
        await db.markMessagesSynced('room', 1);
        final started = Completer<void>();
        final release = Completer<Map<String, dynamic>>();
        final api = FakeApi()
          ..handler = (path, _) async {
            if (path == '/rooms') {
              if (!started.isCompleted) started.complete();
              return release.future;
            }
            if (path.endsWith('/messages')) {
              throw StateError('Certified batch must not fetch history');
            }
            return delta(1, []);
          };
        final seen = <int>[];
        final delivered = <int>[];
        api.otherPostHandler = (path, body) async {
          if (path.endsWith('/seen')) seen.add(body!['upToSeq'] as int);
          if (path == '/rooms/delivered-batch') {
            delivered.add(
              jsonMap((body!['targets'] as List).single)['upToSeq'] as int,
            );
          }
          return path == '/auth/centrifugo-token'
              ? {'centrifugoToken': 'test-token'}
              : {'ok': true};
        };
        final inspector = DebugInspector()..setEnabled(true);
        final controller = ChatController(
          database: db,
          api: api,
          debugInspector: inspector,
          realtimeUrl: 'ws://127.0.0.1:${inbox.server.port}',
        );
        try {
          await controller.initialize();
          await inbox.ready.future.timeout(const Duration(seconds: 3));
          await controller.openRoom((await db.room('room'))!);
          await Future<void>.delayed(const Duration(milliseconds: 180));
          expect(seen, isEmpty);
          expect(delivered, isEmpty);
          inspector.clear();
          final loading = controller.loadMoreRooms();
          await started.future;
          if (mode == 'hidden') {
            controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
          } else if (mode == 'navigated') {
            await controller.closeRoom();
          }
          for (var index = 0; index < 20; index++) {
            await inbox.publish({
              'epoch': 'epoch',
              'pts': index + 2,
              'room': room(
                index + 2,
                index + 2,
                sender: index == 0 ? 'peer' : 'me',
              ),
            });
          }
          await waitForController(
            () =>
                (inspector.snapshot()['events'] as List)
                    .cast<Map>()
                    .where((event) => event['name'] == 'publication.received')
                    .length ==
                20,
          );
          release.complete({'rooms': [], 'nextCursor': null});
          await loading;
          await _waitForCursor(db, 21);
          await waitForController(
            () => hidden ? delivered.isNotEmpty : seen.isNotEmpty,
          );
          await Future<void>.delayed(const Duration(milliseconds: 170));
          expect(seen, hidden ? isEmpty : [21]);
          expect(delivered, hidden ? [21] : isEmpty);
          final events = (inspector.snapshot()['events'] as List).cast<Map>();
          expect(
            events.where(
              (event) =>
                  event['name'] == 'receipts.room.queue' &&
                  event['phase'] == 'end',
            ),
            hasLength(1),
          );
          expect(
            events
                .where((event) => event['name'] == 'publication.batch')
                .single['data'],
            {'count': 20},
          );
          expect(api.messageRequests, 0);
          expect(await db.pendingReceiptTargets(), isEmpty);
          // An echo of the already confirmed head creates neither a task read nor
          // another HTTP receipt, even though the inbox room revision advances.
          await inbox.publish({
            'epoch': 'epoch',
            'pts': 22,
            'room': {
              ...room(22, 21),
              'ownDeliveredSeq': 21,
              'ownSeenSeq': hidden ? 1 : 21,
            },
          });
          await _waitForCursor(db, 22);
          await Future<void>.delayed(const Duration(milliseconds: 170));
          expect(seen, hidden ? isEmpty : [21]);
          expect(delivered, hidden ? [21] : isEmpty);
          expect(controller.error, isNull);
        } finally {
          if (!release.isCompleted) {
            release.complete({'rooms': [], 'nextCursor': null});
          }
          await controller.logout();
          await inbox.close();
          await db.close();
          inspector.dispose();
        }
      },
    );
  }

  for (final sender in ['me', 'peer']) {
    test(
      'certified $sender publication uses the live window and only incoming Seen',
      () async {
        final inbox = await _InboxSocket.start();
        final db = _RecoveryProbeDatabase();
        final initial = message('initial');
        final api = FakeApi()
          ..handler = (_, _) async => delta(1, [payload(last: initial)]);
        var seenRequests = 0;
        api.otherPostHandler = (path, _) async {
          if (path.endsWith('/seen')) seenRequests++;
          return path == '/auth/centrifugo-token'
              ? {'centrifugoToken': 'test-token'}
              : {'ok': true};
        };
        final controller = ChatController(
          database: db,
          api: api,
          realtimeUrl: 'ws://127.0.0.1:${inbox.server.port}',
        );
        try {
          await controller.debugLogin(1);
          await inbox.ready.future.timeout(const Duration(seconds: 3));
          await db.markMessagesSynced('room', 1);
          await controller.openRoom((await db.room('room'))!);
          await waitForController(() => seenRequests == 1);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          db.windowReads = db.countReads = 0;
          final next = message('next', sender: sender, seconds: 1);
          await inbox.publish({
            'epoch': 'epoch',
            'pts': 2,
            'room': payload(pts: 2, last: next),
          });
          await _waitForCursor(db, 2);
          await waitForController(
            () => controller.messages.any((m) => m.id == next.id),
          );
          await Future<void>.delayed(const Duration(milliseconds: 170));
          expect(db.windowReads, 0);
          expect(db.countReads, 0);
          expect(api.messageRequests, 0);
          expect(seenRequests, sender == 'me' ? 1 : 2);
          expect((await db.room('room'))!.messagesSyncedPts, 2);
          expect(controller.error, isNull);
        } finally {
          await controller.logout();
          await inbox.close();
          await db.close();
        }
      },
    );
  }

  test('an outgoing publication still acknowledges unread recovery', () async {
    final inbox = await _InboxSocket.start();
    final db = _RecoveryProbeDatabase();
    final api = FakeApi()
      ..handler = (_, _) async => delta(1, [payload(last: message('initial'))]);
    var seenRequests = 0;
    api.otherPostHandler = (path, _) async {
      if (path.endsWith('/seen')) seenRequests++;
      return path == '/auth/centrifugo-token'
          ? {'centrifugoToken': 'test-token'}
          : {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      realtimeUrl: 'ws://127.0.0.1:${inbox.server.port}',
    );
    try {
      await controller.debugLogin(1);
      await inbox.ready.future.timeout(const Duration(seconds: 3));
      await db.markMessagesSynced('room', 1);
      await controller.openRoom((await db.room('room'))!);
      await waitForController(() => seenRequests == 1);
      await inbox.publish({
        'epoch': 'epoch',
        'pts': 2,
        'room': {
          ...payload(pts: 2, last: message('outgoing', seconds: 1)),
          'unreadCount': 1,
        },
      });
      await _waitForCursor(db, 2);
      await waitForController(() => seenRequests == 2);
      expect(api.messageRequests, 0);
      expect(controller.error, isNull);
    } finally {
      await controller.logout();
      await inbox.close();
      await db.close();
    }
  });

  test(
    'live lookahead exposes older cached messages without count recovery',
    () async {
      final inbox = await _InboxSocket.start();
      final db = _RecoveryProbeDatabase();
      final initial = List.generate(
        30,
        (i) => message('initial-${29 - i}', seconds: 29 - i),
      );
      final api = FakeApi()
        ..handler = (path, _) async => path.endsWith('/messages')
            ? {
                'messages': initial.map((m) => m.toJson()).toList(),
                'hasMore': false,
                'receipts': {'hasGaps': false},
              }
            : delta(1, [payload(last: initial.first)]);
      api.otherPostHandler = (path, _) async => path == '/auth/centrifugo-token'
          ? {'centrifugoToken': 'test-token'}
          : {'ok': true};
      final controller = ChatController(
        database: db,
        api: api,
        realtimeUrl: 'ws://127.0.0.1:${inbox.server.port}',
      );
      try {
        await controller.debugLogin(1);
        await inbox.ready.future.timeout(const Duration(seconds: 3));
        await controller.openRoom((await db.room('room'))!);
        await waitForController(
          () => controller.messages.length == 30 && api.messageRequests == 1,
        );
        await waitForController(() => !controller.hasMoreMessages);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        db.windowReads = db.countReads = 0;
        for (var i = 0; i < 21; i++) {
          await inbox.publish({
            'epoch': 'epoch',
            'pts': i + 2,
            'room': payload(
              pts: i + 2,
              last: message('live-$i', seconds: i + 30),
            ),
          });
        }
        await _waitForCursor(db, 22);
        await waitForController(
          () => controller.messages.length == 50 && controller.hasMoreMessages,
        );
        expect(db.windowReads, 0);
        expect(db.countReads, 0);
        expect(api.messageRequests, 1);
        await controller.loadOlderMessages();
        await waitForController(() => controller.messages.length == 51);
        expect(controller.messages.last.id, 'initial-0');
        expect(controller.hasMoreMessages, false);
        expect(api.messageRequests, 1);
      } finally {
        await controller.logout();
        await inbox.close();
        await db.close();
      }
    },
  );

  for (final stale in [false, true]) {
    test(
      stale
          ? 'compact unread cannot overwrite a newer REST resource or trigger seen feedback'
          : 'real websocket unread ingress updates only badge and own progress without feedback',
      () async {
        final inbox = await _InboxSocket.start();
        final db = AppDatabase(NativeDatabase.memory());
        final api = FakeApi()..handler = (_, _) async => delta(1, [_room()]);
        var seenRequests = 0;
        api.otherPostHandler = (path, _) async {
          if (path.endsWith('/seen')) seenRequests++;
          return path == '/auth/centrifugo-token'
              ? {'centrifugoToken': 'test-token'}
              : {'ok': true};
        };
        final controller = ChatController(
          database: db,
          api: api,
          realtimeUrl: 'ws://127.0.0.1:${inbox.server.port}',
        );
        try {
          await controller.debugLogin(1);
          await inbox.ready.future.timeout(const Duration(seconds: 3));
          await db.markMessagesSynced('room', 1);
          await controller.openRoom((await db.room('room'))!);
          await waitForController(() => seenRequests == 1);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (stale) {
            await db.upsertRoom(ChatRoom.fromJson(_room(pts: 5, unread: 4)));
            await db.markMessagesSynced('room', 5);
          }
          final before = (await db.room('room'))!;
          await inbox.publish(_unread(2, count: 1));
          await _waitForCursor(db, 2);
          await Future<void>.delayed(const Duration(milliseconds: 160));
          final after = (await db.room('room'))!;
          expect(after.unreadCount, stale ? 4 : 1);
          expect(after.roomPts, stale ? 5 : 2);
          expect(after.msgPts, before.msgPts);
          expect(after.contentPts, before.contentPts);
          expect(after.messagesSyncedPts, before.messagesSyncedPts);
          expect(after.lastHistoryEditPts, before.lastHistoryEditPts);
          expect(after.sortTimestamp, before.sortTimestamp);
          expect(after.peerSeenSeq, 0);
          expect(after.ownSeenSeq, 1);
          expect(after.lastMessage!.isSeen, false);
          expect((await db.message('outgoing'))!.isSeen, false);
          expect(controller.messages.single.isSeen, false);
          expect(seenRequests, 1);
          expect(api.messageRequests, 0);
          expect(controller.error, isNull);
        } finally {
          await controller.logout();
          await inbox.close();
          await db.close();
        }
      },
    );
  }

  test(
    'gap recovery restores missed own unread and peer seen independently',
    () async {
      final inbox = await _InboxSocket.start();
      final db = AppDatabase(NativeDatabase.memory());
      var missed = false, seenRequests = 0;
      final api = FakeApi();
      api.handler = (path, _) async {
        if (path.endsWith('/messages')) {
          return {
            'messages': [sequenced('outgoing', 1).toJson()],
            'hasMore': false,
            'receipts': {'hasGaps': false},
            'receiptState': {
              'ownDeliveredSeq': 1,
              'ownSeenSeq': 1,
              'peerDeliveredSeq': 1,
              'peerSeenSeq': 1,
            },
            'coverage': {
              'roomPts': 4,
              'msgPts': 4,
              'contentPts': 1,
              'lastHistoryEditPts': 0,
              'headSeq': 1,
              'fromSeq': 1,
              'throughSeq': 1,
            },
          };
        }
        return missed
            ? delta(3, [
                _room(
                  pts: 3,
                  unread: 0,
                  ownSeen: 1,
                  peerSeen: 1,
                  event: 'room_peer_seen',
                ),
              ])
            : delta(1, [_room()]);
      };
      api.otherPostHandler = (path, _) async {
        if (path.endsWith('/seen')) seenRequests++;
        return path == '/auth/centrifugo-token'
            ? {'centrifugoToken': 'test-token'}
            : {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        realtimeUrl: 'ws://127.0.0.1:${inbox.server.port}',
      );
      try {
        await controller.debugLogin(1);
        await inbox.ready.future.timeout(const Duration(seconds: 3));
        await db.markMessagesSynced('room', 1);
        await db.upsertMessage(sequenced('failed-send', 2, status: 'failed'));
        await controller.openRoom((await db.room('room'))!);
        await waitForController(() => seenRequests == 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect((await db.message('outgoing'))!.isSeen, false);
        missed = true;
        // Device B missed pts2 (own unread) and pts3 (peer seen). A later push
        // must recover both persistent states from the coalesced REST snapshot.
        await inbox.publish({
          'epoch': 'epoch',
          'pts': 4,
          'receipt': {
            'roomId': 'room',
            'eventType': 'room_peer_seen',
            'peerDeliveredSeq': 1,
            'peerSeenSeq': 1,
            'contentPts': 1,
          },
        });
        await _waitForCursor(db, 4);
        await waitForController(() => api.messageRequests == 1);
        await Future<void>.delayed(const Duration(milliseconds: 160));
        final room = (await db.room('room'))!;
        expect(room.unreadCount, 0);
        expect(room.ownSeenSeq, 1);
        expect(room.peerSeenSeq, 1);
        expect(room.msgPts, 4);
        expect(room.messagesSyncedPts, 4);
        expect((await db.message('outgoing'))!.isSeen, true);
        expect((await db.message('failed-send'))!.status, 'failed');
        expect((await db.message('failed-send'))!.isSeen, false);
        expect(seenRequests, 1);
        expect(controller.error, isNull);
      } finally {
        await controller.logout();
        await inbox.close();
        await db.close();
      }
    },
  );
}
