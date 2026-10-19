import 'dart:async';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, waitForController;
import 'sync_test.dart' show FakeApi, message, payload, testServerHealth;

ChatMessage _message(int sequence) => ChatMessage.fromJson({
  ...message(
    'message-$sequence',
    sender: sequence <= 60 ? 'me' : 'peer',
    seconds: sequence,
  ).toJson(),
  'messageSeq': sequence,
});

Map<String, dynamic> _page(int high, int low, {required bool hasMore}) => {
  'messages': [for (var seq = high; seq >= low; seq--) _message(seq).toJson()],
  'hasMore': hasMore,
  'receipts': {'hasGaps': false},
  'receiptState': {
    'ownDeliveredSeq': 0,
    'ownSeenSeq': 0,
    'peerDeliveredSeq': high <= 60 ? 60 : 0,
    'peerSeenSeq': high <= 60 ? 50 : 0,
  },
  'coverage': {
    'roomPts': 1,
    'msgPts': 1,
    'contentPts': 1,
    'lastHistoryEditPts': 0,
    'headSeq': 90,
    'fromSeq': low,
    'throughSeq': high,
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

Map<String, Object?> _sqlite(Map<String, Object?> query) =>
    (query['data'] as Map<String, Object?>)['sqlite'] as Map<String, Object?>;

String _statement(Map<String, Object?> query) =>
    _sqlite(query)['statement'] as String;

void _expectSharedPageReads(List<Map<String, Object?>> queries) {
  final selects = queries.where((q) => q['name'] == 'query.select').toList();
  expect(selects.length, inInclusiveRange(4, 5));
  expect(
    selects.where((q) => _statement(q).startsWith('WITH counts AS')),
    isEmpty,
  );
  expect(
    selects.where((q) => _statement(q).contains('FROM "sync_metadata"')),
    isEmpty,
  );
  expect(
    selects.where((q) => _statement(q).contains('FROM "local_rooms"')),
    hasLength(1),
  );
  final windows = selects.where(
    (q) =>
        _statement(q).startsWith('SELECT * FROM "local_messages"') &&
        _statement(q).contains('ORDER BY'),
  );
  // One widened initial snapshot supplies the cursor; its retained watch reads
  // the committed page once. No separate oldest lookup or old narrow watch.
  expect(windows, hasLength(2));
  expect(windows.every((q) => !_statement(q).contains(' ASC')), isTrue);
  expect(windows.map((q) => _statement(q)).toSet(), hasLength(1));
}

class _HistoryHarness {
  _HistoryHarness() {
    api.handler = (path, query) async {
      if (path == '/presence/status') return {'statuses': <String, bool>{}};
      if (path == '/rooms/delta') {
        return delta(1, [
          if (query?['sincePts'] != 1)
            {
              ...payload(last: _message(90)),
              'contentPts': 1,
              'receiptProtocol': 'sequence',
            },
        ]);
      }
      if (path.endsWith('/messages')) {
        if (query?['beforeId'] == null) return _page(90, 61, hasMore: true);
        olderQueries.add(Map.of(query!));
        if (olderHandler != null) return olderHandler!(query);
        return query['beforeId'] == 'message-61'
            ? _page(60, 31, hasMore: true)
            : _page(30, 1, hasMore: false);
      }
      throw StateError('Unexpected $path');
    };
    api.otherPostHandler = (path, body) async {
      if (path.endsWith('/seen')) seen.add(Map.of(body!));
      return {'ok': true};
    };
    controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      debugInspector: inspector,
      healthMonitorFactory: testServerHealth,
    );
    inspector.setSqliteDetailsEnabled(true);
  }

  final db = AppDatabase(NativeDatabase.memory());
  final inspector = DebugInspector(enabled: true);
  final api = FakeApi();
  late final ChatController controller;
  final olderQueries = <Map<String, dynamic>>[];
  final seen = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? olderHandler;

  Future<void> open() async {
    await controller.debugLogin(1);
    await controller.outboxIdle;
    await controller.openRoom((await db.room('room'))!);
    await waitForController(
      () => controller.messages.length == 30 && seen.isNotEmpty,
    );
    // Finish the existing foreground receipt acknowledgement before measuring
    // the independent history page; do not count assertion reads as app work.
    for (var attempt = 0; attempt < 500; attempt++) {
      if ((await db.pendingReceiptTargets()).isEmpty &&
          (await db.room('room'))!.ownSeenSeq == 90) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    throw StateError('Initial room receipts did not settle');
  }

  Future<void> close() async {
    await controller.logout();
    inspector.dispose();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('each older history page uses one multi-row upsert and bounded reads while preserving pagination and receipts', () async {
    final h = _HistoryHarness();
    try {
      await h.open();
      h.inspector.clear();

      await h.controller.loadOlderMessages();
      await waitForController(() => h.controller.messages.length == 60);
      final queries = _queries(h.inspector);
      final messageInserts = queries.where(
        (query) =>
            query['name'] == 'query.insert' &&
            _statement(query).contains('local_messages'),
      );
      expect(messageInserts, hasLength(1));
      expect((messageInserts.single['data'] as Map)['argumentCount'], 900);
      expect(
        _statement(messageInserts.single),
        matches(RegExp(r'\)\s*,\s*\(')),
      );
      _expectSharedPageReads(queries);
      expect(h.olderQueries.single['beforeId'], 'message-61');
      expect(
        h.olderQueries.single['beforeCreatedAt'],
        _message(61).createdAt.toIso8601String(),
      );
      expect(h.olderQueries.single['limit'], 30);
      expect(h.controller.hasMoreMessages, true);
      expect((await h.db.message('message-50'))!.isSeen, true);
      expect((await h.db.message('message-51'))!.isSeen, false);
      expect((await h.db.message('message-60'))!.isDelivered, true);
      final room = (await h.db.room('room'))!;
      expect(room.peerSeenSeq, 50);
      expect(room.peerDeliveredSeq, 60);
      expect(room.ownSeenSeq, 90);
      expect(room.messagesSyncedPts, 1);
      expect(await h.db.receiptTarget('room'), 90);
      expect((await h.db.metadata())!.localPts, 1);

      h.inspector.clear();
      await h.controller.loadOlderMessages();
      await waitForController(() => h.controller.messages.length == 90);
      final second = _queries(h.inspector);
      expect(
        second.where(
          (q) =>
              q['name'] == 'query.insert' &&
              _statement(q).contains('local_messages'),
        ),
        hasLength(1),
      );
      _expectSharedPageReads(second);
      expect(h.olderQueries.last['beforeId'], 'message-31');
      expect(h.controller.hasMoreMessages, false);
      expect(await h.db.messageCount('room'), 90);
      expect((await h.db.metadata())!.localPts, 1);
      expect(h.seen, [
        {'upToSeq': 90},
      ]);
    } finally {
      await h.close();
    }
  });

  test('scrolling through cached older messages only expands the watched window without HTTP or writes', () async {
    final h = _HistoryHarness();
    try {
      await h.open();
      await h.db.upsertMessages([
        for (var seq = 60; seq > 0; seq--) _message(seq),
      ]);
      await waitForController(() => h.controller.messages.length == 50);
      h.inspector.clear();
      final requests = h.api.messageRequests;

      await h.controller.loadOlderMessages();
      await waitForController(() => h.controller.messages.length == 80);
      final queries = _queries(h.inspector);
      expect(h.api.messageRequests, requests);
      expect(h.olderQueries, isEmpty);
      expect(queries, hasLength(1));
      expect(queries.single['name'], 'query.select');
      expect(_statement(queries.single), contains('LIMIT'));
      expect(h.controller.messages.last.id, 'message-11');
    } finally {
      await h.close();
    }
  });

  test('an older page arriving after navigation cannot write messages, coverage or receipt state', () async {
    final h = _HistoryHarness();
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
      await h.controller.closeRoom();
      h.inspector.clear();
      response.complete(_page(60, 31, hasMore: true));
      await loading;

      expect(_queries(h.inspector), isEmpty);
      expect(await h.db.messageCount('room'), 30);
      expect(await h.db.message('message-60'), isNull);
      expect((await h.db.room('room'))!.peerSeenSeq, 0);
      expect((await h.db.metadata())!.localPts, 1);
      expect(h.controller.messages, isEmpty);
    } finally {
      if (!response.isCompleted) {
        response.complete(_page(60, 31, hasMore: true));
      }
      await loading;
      await h.close();
    }
  });
}
