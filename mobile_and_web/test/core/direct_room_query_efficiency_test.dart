import 'dart:async';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, waitForController;
import 'sync_test.dart' show FakeApi, message, payload, testServerHealth;

ChatMessage _message(int sequence) => ChatMessage.fromJson({
  ...message('message-$sequence', sender: 'peer', seconds: sequence).toJson(),
  'messageSeq': sequence,
});

Map<String, dynamic> _room(int head, {int pts = 1}) => {
  ...payload(pts: pts, last: _message(head)),
  'contentPts': pts,
  'receiptProtocol': 'sequence',
};

Map<String, dynamic> _page(int head, {int pts = 1}) => {
  'messages': [for (var seq = head; seq > 0; seq--) _message(seq).toJson()],
  'hasMore': false,
  'receipts': {'hasGaps': false},
  'receiptState': {
    'ownDeliveredSeq': 0,
    'ownSeenSeq': 0,
    'peerDeliveredSeq': 0,
    'peerSeenSeq': 0,
  },
  'coverage': {
    'roomPts': pts,
    'msgPts': pts,
    'contentPts': pts,
    'lastHistoryEditPts': 0,
    'headSeq': head,
    'fromSeq': 1,
    'throughSeq': head,
  },
};

List<Map<String, Object?>> _queries(DebugInspector inspector) =>
    (inspector.snapshot()['events'] as List<Map<String, Object?>>)
        .where(
          (event) =>
              event['category'] == 'drift' &&
              (event['name'] as String).startsWith('query.') &&
              event['phase'] == 'end',
        )
        .toList();

String _statement(Map<String, Object?> query) =>
    ((query['data'] as Map<String, Object?>)['sqlite']
            as Map<String, Object?>)['statement']
        as String;

Future<void> _waitForDatabase(Future<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError('Expected database state did not settle');
}

class _PausedFirstWatchDatabase extends AppDatabase {
  _PausedFirstWatchDatabase() : super(NativeDatabase.memory()) {
    _paused.onListen = () => firstWatchStarted.complete();
  }

  final firstWatchStarted = Completer<void>();
  final _paused = StreamController<List<ChatMessage>>();
  bool _pauseFirstRoom = true;

  @override
  Stream<List<ChatMessage>> watchMessages(String roomId, int limit) {
    if (roomId == 'room' && _pauseFirstRoom) {
      _pauseFirstRoom = false;
      return _paused.stream;
    }
    return super.watchMessages(roomId, limit);
  }

  Future<void> closePausedWatch() => _paused.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('opening a direct room displays cache immediately and persists a fetched page with one multi-row upsert', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final inspector = DebugInspector(enabled: true);
    final api = FakeApi();
    final latestStarted = Completer<void>();
    final latest = Completer<Map<String, dynamic>>();
    var inboxRequests = 0;
    final seen = <Map<String, dynamic>>[];
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        return {'statuses': <String, bool>{}};
      }
      if (path == '/rooms/delta') {
        return delta(1, ++inboxRequests == 1 ? [_room(30)] : []);
      }
      if (path.endsWith('/messages')) {
        latestStarted.complete();
        return latest.future;
      }
      throw StateError('Unexpected $path');
    };
    api.otherPostHandler = (path, body) async {
      if (path.endsWith('/seen')) seen.add(Map.of(body!));
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      debugInspector: inspector,
      healthMonitorFactory: testServerHealth,
    );
    inspector.setSqliteDetailsEnabled(true);
    try {
      await controller.debugLogin(1);
      await controller.outboxIdle;
      final room = (await db.room('room'))!;
      expect(room.messagesSyncedPts, 0);
      inspector.clear();

      await controller.openRoom(room).timeout(const Duration(seconds: 1));
      expect(controller.messages.map((m) => m.id), ['message-30']);
      await latestStarted.future.timeout(const Duration(seconds: 1));
      final initialWindows = _queries(inspector).where((query) {
        final statement = _statement(query);
        return query['name'] == 'query.select' &&
            statement.contains('FROM "local_messages"') &&
            statement.contains('ORDER BY') &&
            statement.contains('LIMIT');
      });
      expect(initialWindows, hasLength(1));

      latest.complete(_page(30));
      await waitForController(
        () => controller.messages.length == 30 && seen.isNotEmpty,
      );
      // Count SQL before assertion reads add their own instrumentation.
      final queries = _queries(inspector);
      final inserts = queries.where(
        (query) =>
            query['name'] == 'query.insert' &&
            _statement(query).contains('local_messages'),
      );
      expect(inserts, hasLength(1));
      expect(_statement(inserts.single), matches(RegExp(r'\)\s*,\s*\(')));
      expect(
        queries.where(
          (query) =>
              _statement(query)
                  .startsWith('SELECT COUNT(*) AS total FROM local_messages'),
        ),
        isEmpty,
      );
      expect(seen, [
        {'upToSeq': 30},
      ]);
      await _waitForDatabase(
        () async => (await db.pendingReceiptTargets()).isEmpty,
      );
      final certified = (await db.room('room'))!;
      expect(certified.messagesSyncedPts, 1);
      expect(certified.ownSeenSeq, 30);
      expect(await db.messageCount('room'), 30);
      expect((await db.metadata())!.localPts, 1);
      expect(controller.hasMoreMessages, false);

      await controller.closeRoom();
      final requestsBeforeReopen = api.messageRequests;
      final inboxBeforeReopen = inboxRequests;
      await controller.openRoom(certified);
      await waitForController(() => inboxRequests > inboxBeforeReopen);
      await controller.syncNow();
      expect(api.messageRequests, requestsBeforeReopen);
      expect(controller.messages, hasLength(30));
      expect(controller.hasMoreMessages, false);
    } finally {
      if (!latest.isCompleted) latest.complete(_page(30));
      await controller.logout();
      inspector.dispose();
      await db.close();
    }
  });

  test('opening an old verified room snapshot reconciles inbox before skipping message recovery', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    var head = 1;
    api.handler = (path, query) async {
      if (path == '/presence/status') {
        return {'statuses': <String, bool>{}};
      }
      if (path == '/rooms/delta') {
        return delta(
          head,
          query?['sincePts'] == head ? [] : [_room(head, pts: head)],
        );
      }
      if (path.endsWith('/messages')) return _page(head, pts: head);
      throw StateError('Unexpected $path');
    };
    final seen = <int>[];
    api.otherPostHandler = (path, body) async {
      if (path.endsWith('/seen')) seen.add(body!['upToSeq'] as int);
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    try {
      await controller.debugLogin(1);
      await controller.openRoom((await db.room('room'))!);
      await waitForController(() => seen.contains(1));
      final oldSnapshot = (await db.room('room'))!;
      expect(oldSnapshot.messagesSyncedPts, oldSnapshot.msgPts);
      await controller.closeRoom();

      head = 2;
      final requestsBeforeOpen = api.messageRequests;
      await controller.openRoom(oldSnapshot);
      await waitForController(() => seen.contains(2));
      expect(api.messageRequests - requestsBeforeOpen, 1);
      expect(controller.messages.map((m) => m.id), ['message-2', 'message-1']);
      final current = (await db.room('room'))!;
      expect(current.msgPts, 2);
      expect(current.messagesSyncedPts, 2);
      expect((await db.metadata())!.localPts, 2);
      await _waitForDatabase(
        () async => (await db.pendingReceiptTargets()).isEmpty,
      );
      expect((await db.room('room'))!.ownSeenSeq, 2);
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test('navigating away cancels an opening that has not received its first cached snapshot', () async {
    final db = _PausedFirstWatchDatabase();
    final api = FakeApi();
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        return {'statuses': <String, bool>{}};
      }
      if (path == '/rooms/delta') {
        return delta(1, [
          _room(1),
          payload(
            room: 'second-room',
            last: message('second', room: 'second-room', sender: 'peer'),
          ),
        ]);
      }
      if (path.endsWith('/messages')) {
        return {
          'messages': [
            message('second', room: 'second-room', sender: 'peer').toJson(),
          ],
          'hasMore': false,
          'receipts': {'hasGaps': false},
        };
      }
      throw StateError('Unexpected $path');
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    Future<void>? firstOpen;
    try {
      await controller.debugLogin(1);
      firstOpen = controller.openRoom((await db.room('room'))!);
      await db.firstWatchStarted.future.timeout(const Duration(seconds: 1));

      await controller
          .openRoom((await db.room('second-room'))!)
          .timeout(const Duration(seconds: 1));
      await firstOpen.timeout(const Duration(seconds: 1));
      expect(controller.selectedRoom!.roomId, 'second-room');
      expect(controller.messages.map((m) => m.id), ['second']);
    } finally {
      await controller.logout();
      await db.closePausedWatch();
      await firstOpen;
      await db.close();
    }
  });
}
