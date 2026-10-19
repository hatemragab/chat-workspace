import 'dart:async';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session, waitForController;
import 'sync_test.dart'
    show FakeApi, instant, message, payload, testServerHealth;

ChatMessage _message(int sequence) => ChatMessage.fromJson({
  ...message('message-$sequence', sender: 'peer', seconds: sequence).toJson(),
  'messageSeq': sequence,
});

Map<String, dynamic> _page(int high, int low, {int revision = 1}) => {
  'messages': [for (var seq = high; seq >= low; seq--) _message(seq).toJson()],
  'hasMore': low > 1,
  'receipts': {'hasGaps': false},
  'receiptState': {
    'ownDeliveredSeq': 0,
    'ownSeenSeq': 0,
    'peerDeliveredSeq': 0,
    'peerSeenSeq': 0,
  },
  'coverage': {
    'roomPts': revision,
    'msgPts': revision,
    'contentPts': revision,
    'lastHistoryEditPts': 0,
    'headSeq': high,
    'fromSeq': low,
    'throughSeq': high,
  },
};

class _Harness {
  _Harness({AppDatabase? database})
    : db = database ?? AppDatabase(NativeDatabase.memory()) {
    api.authHandler = (body) async =>
        session(body['debugUserNumber'] == 2 ? 'other' : 'me');
    api.handler = (path, query) async {
      if (path == '/presence/status') return {'statuses': <String, bool>{}};
      if (path == '/rooms/delta') {
        return delta(1, [
          if (controller.currentUser?.id == 'me' && query?['sincePts'] != 1)
            {
              ...payload(last: _message(90)),
              'contentPts': 1,
              'receiptProtocol': 'sequence',
            },
        ]);
      }
      if (path.endsWith('/messages')) {
        if (query?['beforeId'] == null) {
          return latestHandler?.call() ?? _page(90, 61);
        }
        olderQueries.add(Map.of(query!));
        return olderHandler?.call(query) ?? _page(60, 31);
      }
      throw StateError('Unexpected $path');
    };
    controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
  }

  final AppDatabase db;
  final api = FakeApi();
  late final ChatController controller;
  final olderQueries = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function()? latestHandler;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? olderHandler;

  Future<void> open() async {
    await controller.debugLogin(1);
    await controller.outboxIdle;
    await controller.openRoom((await db.room('room'))!);
    await waitForController(() => controller.messages.length == 30);
    await controller.syncNow();
  }

  Future<void> close() async {
    await controller.logout();
    await db.close();
  }
}

class _WatchedDatabase extends AppDatabase {
  _WatchedDatabase() : super(NativeDatabase.memory());

  final watchedLimits = <int>[];

  @override
  Stream<List<ChatMessage>> watchMessages(String roomId, int limit) {
    watchedLimits.add(limit);
    return super.watchMessages(roomId, limit);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'older pagination ignores older queued and failed outbox rows',
    () async {
      final h = _Harness();
      try {
        await h.open();
        await h.db.upsertMessages([
          ChatMessage.fromJson({
            ...message('pending', status: 'queued', seconds: -2).toJson(),
            'outboxPaused': true,
            'enqueueOrder': 1,
          }),
          message('failed', status: 'failed', seconds: -1),
        ]);
        await waitForController(() => h.controller.messages.length == 32);

        await h.controller.loadOlderMessages();
        await waitForController(() => h.controller.messages.length == 62);

        expect(h.olderQueries.single['beforeId'], 'message-61');
        expect(
          h.olderQueries.single['beforeCreatedAt'],
          _message(61).createdAt.toIso8601String(),
        );
        final pending = (await h.db.message('pending'))!;
        expect(pending.status, 'queued');
        expect(pending.outboxPaused, isTrue);
        expect(pending.idempotencyKey, 'pending');
        expect((await h.db.message('failed'))!.status, 'failed');
        expect((await h.db.metadata())!.localPts, 1);
      } finally {
        await h.close();
      }
    },
  );

  test('pagination preserves the timestamp and ID tie break', () async {
    final h = _Harness();
    final sameTime = instant.add(const Duration(seconds: 61));
    ChatMessage tied(int number) => ChatMessage.fromJson({
      ..._message(number).toJson(),
      'id': 'tied-${number.toString().padLeft(3, '0')}',
      'createdAt': sameTime.toIso8601String(),
    });
    h.latestHandler = () async => {
      ..._page(30, 1),
      'messages': [for (var seq = 30; seq >= 1; seq--) tied(seq).toJson()],
      'hasMore': true,
    };
    h.olderHandler = (_) async => {
      'messages': [tied(0).toJson()],
      'hasMore': false,
    };
    try {
      await h.open();
      await h.controller.loadOlderMessages();
      await waitForController(() => h.controller.messages.length == 31);

      expect(h.olderQueries.single['beforeId'], 'tied-001');
      expect(
        h.olderQueries.single['beforeCreatedAt'],
        sameTime.toIso8601String(),
      );
      expect(h.controller.messages.last.id, 'tied-000');
      expect(h.controller.messages.map((m) => m.id).toSet(), hasLength(31));
      expect(h.controller.hasMoreMessages, isFalse);
    } finally {
      await h.close();
    }
  });

  test(
    'older page from a retired account cannot enter the next account',
    () async {
      final h = _Harness();
      final started = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      Future<void>? loading;
      h.olderHandler = (_) {
        started.complete();
        return response.future;
      };
      try {
        await h.open();
        loading = h.controller.loadOlderMessages();
        await started.future.timeout(const Duration(seconds: 1));
        final switching = h.controller.debugLogin(2);
        await waitForController(() => h.controller.currentUser?.id == 'other');
        response.complete(_page(60, 31));
        await Future.wait([loading, switching]);

        expect((await h.db.metadata())!.userId, 'other');
        expect(await h.db.room('room'), isNull);
        expect(await h.db.allMessages('room'), isEmpty);
        expect(h.controller.messages, isEmpty);
      } finally {
        if (!response.isCompleted) response.complete(_page(60, 31));
        await loading;
        await h.close();
      }
    },
  );

  test(
    'scroll cursor uses the cache after an earlier queued recovery commits',
    () async {
      final h = _Harness();
      final latestStarted = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      Future<void>? recovery, loading;
      try {
        await h.open();
        await h.db.upsertRoom(
          ChatRoom.fromJson({
            ...payload(pts: 2, msgPts: 2, last: _message(120)),
            'contentPts': 2,
            'receiptProtocol': 'sequence',
          }),
        );
        h.latestHandler = () {
          if (!latestStarted.isCompleted) latestStarted.complete();
          return response.future;
        };
        h.olderHandler = (_) async => _page(90, 61, revision: 2);
        recovery = h.controller.syncNow();
        await latestStarted.future.timeout(const Duration(seconds: 1));
        loading = h.controller.loadOlderMessages();
        response.complete(_page(120, 91, revision: 2));
        await Future.wait([recovery, loading]);
        await waitForController(() => h.controller.messages.length == 60);

        expect(h.olderQueries.single['beforeId'], 'message-91');
        expect(
          h.olderQueries.single['beforeCreatedAt'],
          _message(91).createdAt.toIso8601String(),
        );
        expect(h.controller.messages.first.id, 'message-120');
        expect(h.controller.messages.last.id, 'message-61');
        expect(await h.db.message('message-31'), isNull);
        expect((await h.db.room('room'))!.messagesSyncedPts, 2);
        expect((await h.db.metadata())!.localPts, 1);
      } finally {
        if (!response.isCompleted) {
          response.complete(_page(120, 91, revision: 2));
        }
        await recovery;
        await loading;
        await h.close();
      }
    },
  );

  test('failed older HTTP restores the bounded watch, renders live writes and retries the same cursor', () async {
    final db = _WatchedDatabase();
    final h = _Harness(database: db);
    var failuresRemaining = 2;
    h.olderHandler = (_) async {
      if (failuresRemaining > 0) {
        failuresRemaining--;
        throw const ChatApiException('offline');
      }
      return _page(60, 31);
    };
    try {
      await h.open();
      db.watchedLimits.clear();
      await h.controller.loadOlderMessages();
      await h.controller.loadOlderMessages();
      expect(h.controller.error, contains('offline'));
      expect(h.controller.messages, hasLength(30));
      expect(h.controller.hasMoreMessages, isTrue);
      // Failed requests cannot leave an ever-growing +30-row window behind.
      // Each attempt widens 50 to 80, then restores the original watch; the
      // query includes one extra row to detect further cached history.
      expect(db.watchedLimits, [81, 51, 81, 51]);

      await h.db.upsertMessage(_message(91));
      await waitForController(() => h.controller.messages.length == 31);
      expect(h.controller.messages.first.id, 'message-91');
      await h.controller.loadOlderMessages();
      await waitForController(() => h.controller.messages.length == 61);

      expect(h.controller.error, isNull);
      expect(h.olderQueries, hasLength(3));
      expect(db.watchedLimits, [81, 51, 81, 51, 81]);
      expect(h.olderQueries.first, h.olderQueries.last);
      expect(h.olderQueries[1], h.olderQueries.last);
      expect(h.olderQueries.last['beforeId'], 'message-61');
      expect(h.controller.messages.last.id, 'message-31');
      expect((await h.db.metadata())!.localPts, 1);
    } finally {
      await h.close();
    }
  });
}
