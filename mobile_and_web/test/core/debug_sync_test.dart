import 'dart:async';
import 'dart:convert';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test.dart' show FakeApi, message, payload;

List<Map<String, Object?>> events(DebugInspector inspector) =>
    (inspector.snapshot()['events'] as List).cast<Map<String, Object?>>();

Map<String, int> gauges(DebugInspector inspector) =>
    (inspector.snapshot()['gauges'] as Map).cast<String, int>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'queue records the initiating context, cancellation and recovery',
    () async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      inspector.updateContext(userId: 'first', sessionGeneration: 1);
      final queue = InboxSyncQueue(inspector: inspector);
      final gate = Completer<void>();
      final first = queue.enqueue(() => gate.future, operation: 'first');
      var waitingCalled = false;
      final waiting = queue.enqueue(() async {
        waitingCalled = true;
      }, operation: 'waiting');
      await Future<void>.delayed(Duration.zero);
      expect(queue.pendingCount, 1);
      expect(queue.runningCount, 1);
      queue.invalidate();
      expect(queue.pendingCount, 0);
      inspector.updateContext(userId: 'second', sessionGeneration: 2);
      gate.complete();
      await first;
      await waiting;
      expect(waitingCalled, isFalse);
      final cancel = events(inspector)
          .singleWhere((event) => event['name'] == 'cancel');
      expect(cancel['userId'], 'first');
      final finish = events(inspector)
          .singleWhere((event) => event['name'] == 'finish');
      expect(finish['userId'], 'first');
      expect((finish['data'] as Map)['invalidated'], isTrue);
      expect(gauges(inspector)['queue.running'], 0);
      await expectLater(
        queue.enqueue<void>(() async {
          throw StateError('private-queue-error');
        }, operation: 'failure'),
        throwsStateError,
      );
      expect(await queue.enqueue(() async => 42, operation: 'recovered'), 42);
      expect(queue.runningCount, 0);
      expect(gauges(inspector)['queue.pending'], 0);
      expect(
        jsonEncode(inspector.snapshot()),
        isNot(contains('private-queue-error')),
      );
    },
  );

  test('a retired queue cannot clobber its successor gauges', () async {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    final old = InboxSyncQueue(inspector: inspector);
    final oldGate = Completer<void>();
    final oldResult = old.enqueue(() => oldGate.future);
    await Future<void>.delayed(Duration.zero);
    old.retire();
    final next = InboxSyncQueue(inspector: inspector);
    final nextGate = Completer<void>();
    final nextResult = next.enqueue(() => nextGate.future);
    await Future<void>.delayed(Duration.zero);
    oldGate.complete();
    await oldResult;
    expect(gauges(inspector)['queue.running'], 1);
    expect(await old.enqueue(() async => 'must-not-run'), isNull);
    nextGate.complete();
    await nextResult;
    expect(gauges(inspector)['queue.running'], 0);
  });

  test(
    'manual sampling refreshes queue work after enabling and resuming',
    () async {
      final inspector = DebugInspector();
      addTearDown(inspector.dispose);
      final queue = InboxSyncQueue(inspector: inspector);
      final gate = Completer<void>();
      final first = queue.enqueue(() => gate.future);
      final second = queue.enqueue(() async {});
      await Future<void>.delayed(Duration.zero);
      inspector.setEnabled(true);
      queue.refreshInspectorGauges();
      expect(gauges(inspector)['queue.running'], 1);
      expect(gauges(inspector)['queue.pending'], 1);
      inspector.setPaused(true);
      gate.complete();
      await first;
      await second;
      inspector.setPaused(false);
      queue.refreshInspectorGauges();
      expect(gauges(inspector)['queue.running'], 0);
      expect(gauges(inspector)['queue.pending'], 0);
    },
  );

  group('inbox causal records', () {
    late DebugInspector inspector;
    late AppDatabase db;
    late FakeApi api;
    late InboxSyncService sync;
    setUp(() async {
      inspector = DebugInspector(enabled: true);
      inspector.updateContext(userId: 'me', sessionGeneration: 1);
      db = AppDatabase(NativeDatabase.memory(), inspector);
      await db.initializeSession('me');
      await db.setCursor(0, 'epoch');
      api = FakeApi();
      sync = InboxSyncService(
        database: db,
        api: api,
        userId: 'me',
        isCurrentSession: () => true,
        restoredHasMoreRooms: false,
      );
    });
    tearDown(() async {
      await sync.dispose();
      await db.close();
      inspector.dispose();
    });

    test('delta, Drift and cursor application share a causal trace', () async {
      api.handler = (_, _) async => {
        'requiresFullSync': false,
        'pts': 2,
        'epoch': 'epoch',
        'rooms': [payload(pts: 2, last: message('private-message-body'))],
      };
      await sync.syncInboxDelta();
      expect((await db.metadata())!.localPts, 2);
      final applied = events(inspector).singleWhere(
        (event) =>
            event['name'] == 'inbox.apply.delta' && event['phase'] == 'end',
      );
      final traceId = applied['traceId'];
      expect(traceId, isNotNull);
      expect(
        events(inspector).any(
          (event) =>
              event['category'] == 'drift' &&
              event['name'] == 'query.update' &&
              event['traceId'] == traceId,
        ),
        isTrue,
      );
      final cursor = events(inspector)
          .singleWhere((event) => event['name'] == 'cursor.advance');
      expect(cursor['traceId'], traceId);
      expect((cursor['data'] as Map)['toPts'], 2);
      expect(gauges(inspector)['sync.localPts'], 2);
      expect(
        jsonEncode(inspector.snapshot()),
        isNot(contains('private-message-body')),
      );
    });

    test(
      'full recovery and duplicate publications retain cursor behavior',
      () async {
        api.handler = (path, _) async => path == '/rooms/delta'
            ? {'requiresFullSync': true}
            : {
                'pts': 8,
                'epoch': 'epoch',
                'rooms': [payload(pts: 8)],
                'nextCursor': null,
              };
        await sync.syncInboxDelta();
        await sync.receivePublication({
          'pts': 8,
          'epoch': 'epoch',
          'room': payload(pts: 8),
        });
        expect((await db.metadata())!.localPts, 8);
        expect(sync.fullSyncs, 1);
        expect(
          events(inspector).any((event) => event['name'] == 'inbox.apply.full'),
          isTrue,
        );
        expect(
          events(inspector).any((event) => event['name'] == 'publication.skip'),
          isTrue,
        );
        await sync.reconcileMutation({'room': payload(pts: 12)});
        expect((await db.metadata())!.localPts, 8);
        expect(
          events(inspector).where((event) => event['name'] == 'cursor.advance'),
          hasLength(1),
        );
      },
    );

    test(
      'retired HTTP completions never emit an applied cursor record',
      () async {
        final response = Completer<Map<String, dynamic>>();
        final requested = Completer<void>();
        api.handler = (_, _) {
          requested.complete();
          return response.future;
        };
        final pending = sync.syncInboxDelta();
        await requested.future;
        await sync.retire();
        response.complete({
          'pts': 9,
          'epoch': 'epoch',
          'rooms': [payload(pts: 9)],
        });
        await pending;
        expect((await db.metadata())!.localPts, 0);
        expect(
          events(inspector).where((event) => event['name'] == 'cursor.advance'),
          isEmpty,
        );
        expect(gauges(inspector)['queue.running'], 0);
      },
    );
  });
}
