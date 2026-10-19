import 'dart:async';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session, waitForController;
import 'sync_test.dart' show FakeApi, instant, message, payload;

ChatMessage _sequenced(int sequence, {String sender = 'peer'}) =>
    ChatMessage.fromJson({
      ...message('message-$sequence', sender: sender).toJson(),
      'messageSeq': sequence,
    });

Map<String, dynamic> _room(int head, {int pts = 1}) => {
  ...payload(pts: pts, last: _sequenced(head)),
  'contentPts': 1,
  'peerDeliveredSeq': 0,
  'peerSeenSeq': 0,
  'receiptProtocol': 'sequence',
};

Map<String, dynamic> _page(int head) => {
  'messages': [for (var seq = head; seq > 0; seq--) _sequenced(seq).toJson()],
  'hasMore': false,
  'receipts': {'deliveredThrough': null, 'seenThrough': null, 'hasGaps': false},
  'receiptState': {
    'ownDeliveredSeq': 0,
    'ownSeenSeq': 0,
    'peerDeliveredSeq': 0,
    'peerSeenSeq': 0,
  },
  'coverage': {
    'roomPts': 1,
    'msgPts': 1,
    'contentPts': 1,
    'lastHistoryEditPts': 0,
    'headSeq': head,
    'fromSeq': 1,
    'throughSeq': head,
  },
};

class _ReceiptSnapshotDatabase extends AppDatabase {
  _ReceiptSnapshotDatabase({this.pauseFirstSnapshot = false})
    : super(NativeDatabase.memory());

  final bool pauseFirstSnapshot;
  final firstSnapshotRead = Completer<void>();
  final releaseFirstSnapshot = Completer<void>();
  int pendingReceiptReads = 0;

  @override
  Future<List<ReceiptTarget>> pendingReceiptTargets() async {
    final targets = await super.pendingReceiptTargets();
    pendingReceiptReads++;
    if (pendingReceiptReads == 1) {
      firstSnapshotRead.complete();
      if (pauseFirstSnapshot) await releaseFirstSnapshot.future;
    }
    return targets;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an empty receipt flush reads pending targets only once', () async {
    final db = _ReceiptSnapshotDatabase();
    final api = FakeApi()..handler = (_, _) async => delta(0, []);
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      await db.firstSnapshotRead.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(db.pendingReceiptReads, 1);
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test('a sync wake during an empty receipt snapshot still sends new work', () async {
    final db = _ReceiptSnapshotDatabase(pauseFirstSnapshot: true);
    final api = FakeApi()..handler = (_, _) async => delta(0, []);
    final deliveries = <Map<String, dynamic>>[];
    api.otherPostHandler = (path, body) async {
      if (path == '/rooms/delivered-batch') deliveries.add(body!);
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      await db.firstSnapshotRead.future.timeout(const Duration(seconds: 2));
      // The initial SELECT has returned no work, but its flush is still active.
      await db.upsertRoom(ChatRoom.fromJson(_room(1)));
      await db.queueReceipt('room', deliveredThroughSeq: 1);
      await controller.syncNow();
      expect(db.pendingReceiptReads, 1);
      expect(deliveries, isEmpty);

      db.releaseFirstSnapshot.complete();
      await waitForController(() => deliveries.isNotEmpty);
      expect(deliveries, [
        {
          'targets': [
            {'roomId': 'room', 'upToSeq': 1},
          ],
        },
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await db.pendingReceiptTargets(), isEmpty);
    } finally {
      if (!db.releaseFirstSnapshot.isCompleted) {
        db.releaseFirstSnapshot.complete();
      }
      await controller.logout();
      await db.close();
    }
  });

  test('delivery batches the highest verified target per room', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()..handler = (_, _) async => delta(1, [_room(3)]);
    final deliveries = <Map<String, dynamic>>[];
    api.otherPostHandler = (path, body) async {
      if (path == '/rooms/delivered-batch') deliveries.add(body!);
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      // The inbox's last message alone does not fill the missing prefix.
      await Future<void>.delayed(const Duration(milliseconds: 170));
      expect(deliveries, isEmpty);
      await db.recordMessageCoverage('room', {'fromSeq': 1, 'throughSeq': 2});
      await db.queueReceipt('room', deliveredThroughSeq: 1);
      await db.queueReceipt('room', deliveredThroughSeq: 3);
      await controller.syncNow();
      await waitForController(() => deliveries.isNotEmpty);
      expect(deliveries, [
        {
          'targets': [
            {'roomId': 'room', 'upToSeq': 3},
          ],
        },
      ]);
      await waitForController(
        () => controller.diagnostics['connection'] == 'Connected',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await db.pendingReceiptTargets(), isEmpty);
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test(
    'foreground seen replaces delivery for the same pending boundary',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      api.handler = (path, _) async =>
          path.endsWith('/messages') ? _page(1) : delta(1, [_room(1)]);
      final seen = <Map<String, dynamic>>[];
      final delivered = <Map<String, dynamic>>[];
      api.otherPostHandler = (path, body) async {
        if (path.endsWith('/seen')) seen.add(body!);
        if (path == '/rooms/delivered-batch') delivered.add(body!);
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        await controller.openRoom((await db.room('room'))!);
        await waitForController(() => seen.isNotEmpty);
        expect(seen, [
          {'upToSeq': 1},
        ]);
        expect(delivered, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(await db.pendingReceiptTargets(), isEmpty);
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test(
    'background selection can deliver but cannot create a seen target',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      api.handler = (path, _) async =>
          path.endsWith('/messages') ? _page(1) : delta(1, [_room(1)]);
      final routes = <String>[];
      api.otherPostHandler = (path, _) async {
        routes.add(path);
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
        await controller.openRoom((await db.room('room'))!);
        await waitForController(
          () => routes.contains('/rooms/delivered-batch'),
        );
        expect(routes.where((route) => route.endsWith('/seen')), isEmpty);
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test(
    'legacy seen captures a timestamp instead of acknowledging server now',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final legacy = message('legacy', sender: 'peer');
      final room = payload(last: legacy);
      final api = FakeApi();
      api.handler = (path, _) async => path.endsWith('/messages')
          ? {
              'messages': [legacy.toJson()],
              'hasMore': false,
              'receipts': {'hasGaps': false},
            }
          : delta(1, [room]);
      final seen = <Map<String, dynamic>>[];
      api.otherPostHandler = (path, body) async {
        if (path.endsWith('/seen')) seen.add(body!);
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        await controller.openRoom((await db.room('room'))!);
        await waitForController(() => seen.isNotEmpty);
        expect(seen.single, {'upToTimestamp': instant.toIso8601String()});
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test(
    'legacy publication mode uses timestamp ACKs for sequenced messages',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final room = {..._room(1), 'receiptProtocol': 'legacy'};
      final api = FakeApi();
      api.handler = (path, _) async =>
          path.endsWith('/messages') ? _page(1) : delta(1, [room]);
      final receipts = <Map<String, dynamic>>[];
      api.otherPostHandler = (path, body) async {
        if (path.endsWith('/seen') || path.contains('/delivered')) {
          receipts.add(body!);
        }
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        await controller.openRoom((await db.room('room'))!);
        await waitForController(() => receipts.isNotEmpty);
        expect(receipts, [
          {'upToTimestamp': instant.toIso8601String()},
        ]);
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test(
    'an old account receipt completion cannot confirm a new account target',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      api.authHandler = (body) async =>
          session(body['debugUserNumber'] == 1 ? 'me' : 'other');
      api.handler = (_, _) async =>
          api.dio.options.headers['Authorization'] == 'Bearer me'
          ? delta(1, [_room(1)])
          : delta(0, []);
      final started = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      api.otherPostHandler = (path, _) async {
        if (path == '/rooms/delivered-batch' && !started.isCompleted) {
          started.complete();
          return response.future;
        }
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        await started.future;
        await controller.debugLogin(2);
        await db.upsertRoom(ChatRoom.fromJson(_room(1)));
        await db.queueReceipt('room', deliveredThroughSeq: 1);
        response.complete({'ok': true});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final pending = await db.pendingReceiptTargets();
        expect(pending.single.deliveredThroughSeq, 1);
        expect(controller.currentUser!.id, 'other');
      } finally {
        if (!response.isCompleted) response.complete({'ok': true});
        await controller.logout();
        await db.close();
      }
    },
  );

  test(
    'confirmation keeps a higher delivery target queued during HTTP',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi()..handler = (_, _) async => delta(1, [_room(1)]);
      final started = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      final boundaries = <int>[];
      api.otherPostHandler = (path, body) async {
        if (path == '/rooms/delivered-batch') {
          final targets = body!['targets'] as List;
          boundaries.add(jsonMap(targets.single)['upToSeq'] as int);
          if (!started.isCompleted) {
            started.complete();
            return response.future;
          }
        }
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        await started.future;
        await db.upsertMessage(_sequenced(2));
        await db.queueReceipt('room', deliveredThroughSeq: 2);
        response.complete({'ok': true});
        await waitForController(() => boundaries.length == 2);
        expect(boundaries, [1, 2]);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(await db.pendingReceiptTargets(), isEmpty);
      } finally {
        if (!response.isCompleted) response.complete({'ok': true});
        await controller.logout();
        await db.close();
      }
    },
  );

  test('failed seen retries its persisted boundary after navigation', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    api.handler = (path, _) async =>
        path.endsWith('/messages') ? _page(1) : delta(1, [_room(1)]);
    final boundaries = <int>[];
    api.otherPostHandler = (path, body) async {
      if (path.endsWith('/seen')) {
        boundaries.add(body!['upToSeq'] as int);
        if (boundaries.length == 1) throw const ChatApiException('offline');
      }
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      await controller.openRoom((await db.room('room'))!);
      await waitForController(() => boundaries.isNotEmpty);
      await controller.closeRoom();
      expect((await db.pendingReceiptTargets()).single.seenThroughSeq, 1);
      // A later snapshot must not expand the captured offline read target.
      await db.recordMessageCoverage('room', {
        'headSeq': 100,
      }, verifyHead: true);
      await Future<void>.delayed(const Duration(milliseconds: 2150));
      expect(boundaries, [1, 1]);
      expect(await db.pendingReceiptTargets(), isEmpty);
    } finally {
      await controller.logout();
      await db.close();
    }
  });
}
