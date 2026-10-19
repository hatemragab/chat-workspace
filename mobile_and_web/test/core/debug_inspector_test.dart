import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnreadableMap extends MapBase<String, Object?> {
  @override
  Iterable<String> get keys => throw StateError('Debug data was inspected.');
  @override
  Object? operator [](Object? key) => throw StateError('Debug data was read.');
  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

class _PrivateFailure implements Exception {
  @override
  String toString() =>
      throw StateError('Private exceptions must not stringify.');
}

List<Map<String, Object?>> _events(DebugInspector inspector) =>
    (inspector.snapshot()['events']! as List).cast<Map<String, Object?>>();

Map<String, Object?> _resources(DebugInspector inspector) =>
    inspector.snapshot()['resources']! as Map<String, Object?>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default off does not inspect metadata or change action results',
    () async {
      final inspector = DebugInspector();
      addTearDown(inspector.dispose);
      final unreadable = _UnreadableMap();
      inspector.record('test', 'disabled', data: unreadable);
      expect(inspector.begin('test', 'disabled', data: unreadable), isNull);
      final result = await inspector.trace(
        'test',
        'disabled',
        () async => 42,
        data: unreadable,
      );
      inspector.recordBuild('MessageList');
      expect(result, 42);
      expect(inspector.enabled, isFalse);
      expect(_events(inspector), isEmpty);
      expect(inspector.snapshot()['builds'], isEmpty);
      expect(_resources(inspector)['activeSpans'], 0);
    },
  );

  test('events, active spans, aggregates, builds and gauges stay bounded', () {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    for (var i = 0; i < 600; i++) {
      inspector.record('test', 'operation_$i');
    }
    expect(_events(inspector), hasLength(DebugInspector.eventLimit));
    expect(_events(inspector).first['seq'], 101);
    expect(_resources(inspector)['droppedEvents'], 100);
    expect(_resources(inspector)['aggregateCount'], 100);
    expect(_resources(inspector)['aggregateOverflow'], 500);
    final spans = [
      for (var i = 0; i < DebugInspector.activeSpanLimit; i++)
        inspector.begin('test', 'span'),
    ];
    expect(spans.every((span) => span != null), isTrue);
    final overflow = inspector.begin('test', 'overflow');
    expect(overflow, isNotNull);
    expect(_resources(inspector)['activeSpans'], 65);
    expect(_resources(inspector)['trackedSpans'], 64);
    expect(_resources(inspector)['overflowSpans'], 1);
    expect(_resources(inspector)['droppedSpans'], 0);
    for (var i = 0; i < 80; i++) {
      inspector.recordBuild('Widget_$i');
      inspector.setGauges({'resource_$i': i});
    }
    expect(inspector.snapshot()['builds'], hasLength(64));
    expect(inspector.snapshot()['gauges'], hasLength(64));
    expect(_resources(inspector)['buildOverflow'], 16);
    expect(_resources(inspector)['gaugeOverflow'], 16);
    for (final span in spans) {
      span!.finish();
    }
    overflow!.finish();
    expect(_resources(inspector)['activeSpans'], 0);
    expect(_events(inspector), hasLength(500));
  });

  test(
    'overflow operations retain paired failures without an unbounded registry',
    () {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      inspector.updateContext(userId: 'user-a', sessionGeneration: 1);
      final spans = [
        for (var i = 0; i < 174; i++) inspector.begin('http', 'request_$i')!,
      ];
      expect(_resources(inspector)['activeSpans'], 174);
      expect(_resources(inspector)['trackedSpans'], 64);
      expect(_resources(inspector)['overflowSpans'], 110);
      for (var i = 0; i < spans.length; i++) {
        spans[i].finish(error: i == 173 ? StateError('private-body') : null);
      }
      final events = _events(inspector);
      expect(events, hasLength(348));
      for (var i = 0; i < spans.length; i++) {
        final pair = events
            .where((event) => event['name'] == 'request_$i')
            .toList();
        expect(pair.map((event) => event['phase']), ['begin', 'end']);
        expect(pair.first['spanId'], pair.last['spanId']);
        expect(pair.last['userId'], 'user-a');
      }
      expect((events.last['data']! as Map)['errorType'], 'StateError');
      expect(jsonEncode(events), isNot(contains('private-body')));
      expect(_resources(inspector)['activeSpans'], 0);
      expect(_resources(inspector)['trackedSpans'], 0);
      expect(_resources(inspector)['droppedSpans'], 0);
    },
  );

  test('clear fences caller-owned overflow handles and later capture', () {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    final spans = [
      for (var i = 0; i < 80; i++) inspector.begin('sync', 'before_clear')!,
    ];
    inspector.clear();
    for (final span in spans) {
      span.finish(error: StateError('old-session'));
    }
    expect(_events(inspector), isEmpty);
    expect(_resources(inspector)['activeSpans'], 0);
    final current = inspector.begin('sync', 'current')!;
    current.finish();
    expect(_events(inspector).map((event) => event['phase']), ['begin', 'end']);
    expect(_resources(inspector)['activeSpans'], 0);
  });

  test('widget noise cannot evict a retained error or operation timeline', () {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    final span = inspector.begin('sync', 'recover')!;
    span.finish(error: StateError('private-failure'));
    for (var i = 0; i < 1000; i++) {
      inspector.recordBuild('MessagesPane');
    }
    final events = _events(inspector);
    expect(events, hasLength(500));
    expect(events.where((event) => event['name'] == 'recover'), hasLength(2));
    expect(_resources(inspector)['droppedEvents'], 502);
  });

  test(
    'nested async traces retain parent and initiating session identity',
    () async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      inspector.updateContext(
        userId: 'user-a',
        sessionGeneration: 1,
        roomId: 'room-a',
      );
      final resumed = Completer<void>();
      final parent = inspector.trace('controller', 'send', () async {
        await resumed.future;
        await inspector.trace('http', 'POST', () async {
          inspector.record('db', 'reconcile');
        });
      });
      inspector.updateContext(
        userId: 'user-b',
        sessionGeneration: 2,
        roomId: 'room-b',
      );
      resumed.complete();
      await parent;
      final events = _events(inspector);
      final outer = events.first;
      final inner = events.singleWhere(
        (event) => event['name'] == 'POST' && event['phase'] == 'begin',
      );
      expect(inner['traceId'], outer['traceId']);
      expect(inner['parentSpanId'], outer['spanId']);
      expect(inner['spanId'], isNot(outer['spanId']));
      final reconcile = events.singleWhere(
        (event) => event['name'] == 'reconcile',
      );
      expect(reconcile['spanId'], inner['spanId']);
      for (final event in events) {
        expect(event['userId'], 'user-a');
        expect(event['sessionGeneration'], 1);
        expect(event['roomId'], 'room-a');
      }
      expect((inspector.snapshot()['context']! as Map)['userId'], 'user-b');
      expect(events.last['phase'], 'end');
      expect(events.last['durationMicros'], isNonNegative);
      expect(DateTime.parse(events.last['timestamp']! as String).isUtc, isTrue);
    },
  );

  test(
    'explicit context copies retain causal identity and are immutable',
    () async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      inspector.updateContext(userId: 'user-a', sessionGeneration: 3);
      late DebugTraceContext captured;
      await inspector.trace('controller', 'operation', () async {
        captured = inspector.captureContext();
      });
      final changed = captured
          .copyWithIdentity('user-b')
          .copyWithRoom('room-target');
      inspector.record('widget', 'notification', context: changed);
      final event = _events(inspector).last;
      expect(event['traceId'], captured.traceId);
      expect(event['spanId'], captured.spanId);
      expect(event['userId'], 'user-b');
      expect(event['roomId'], 'room-target');
      expect(event['sessionGeneration'], 3);
      expect(captured.userId, 'user-a');
      expect(captured.roomId, isNull);
    },
  );

  test(
    'independent callbacks renew stale registration zones and identity',
    () async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      inspector.updateContext(
        userId: 'user-a',
        sessionGeneration: 1,
        roomId: 'room-a',
      );
      late Future<int> Function() callback;
      late DebugTraceContext registered;
      await inspector.trace('action', 'registration', () async {
        registered = inspector.captureContext();
        callback = Zone.current.bindCallback(
          () => inspector.runIndependent(
            () => inspector.trace('timer', 'tick', () async {
              await Future<void>.value();
              await inspector.trace('http', 'request', () async {
                inspector.record('state', 'updated');
              });
              return 42;
            }),
          ),
        );
      });
      inspector.updateContext(
        userId: 'user-b',
        sessionGeneration: 2,
        roomId: 'room-b',
      );
      inspector.clear();
      expect(await callback(), 42);
      final events = _events(inspector);
      final timer = events.first;
      expect(timer['name'], 'tick');
      expect(timer['parentSpanId'], isNull);
      expect(timer['traceId'], isNot(registered.traceId));
      final http = events.singleWhere(
        (event) => event['name'] == 'request' && event['phase'] == 'begin',
      );
      expect(http['traceId'], timer['traceId']);
      expect(http['parentSpanId'], timer['spanId']);
      for (final event in events) {
        expect(event['userId'], 'user-b');
        expect(event['sessionGeneration'], 2);
        expect(event['roomId'], 'room-b');
      }
      expect(_resources(inspector)['activeSpans'], 0);
      inspector.runIndependent(() {
        inspector.record('lifecycle', 'resumed');
      });
      expect(_events(inspector).last['traceId'], isNull);
    },
  );

  test(
    'detached capture uses current base without changing an active trace',
    () async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      inspector.updateContext(userId: 'user-a', sessionGeneration: 1);
      await inspector.trace('action', 'operation', () async {
        final original = inspector.captureContext();
        inspector.updateContext(userId: 'user-b', sessionGeneration: 2);
        final detached = inspector.captureContext(detached: true);
        expect(detached.userId, 'user-b');
        expect(detached.sessionGeneration, 2);
        expect(detached.traceId, isNull);
        expect(inspector.captureContext().traceId, original.traceId);
        expect(inspector.captureContext().userId, 'user-a');
      });
    },
  );

  for (final change in ['clear', 'disable', 'pause']) {
    test('$change invalidates spans and later async children', () async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      final resumed = Completer<void>();
      final action = inspector.trace('test', 'old', () async {
        await resumed.future;
        inspector.record('test', 'old_instant');
        await inspector.trace('test', 'old_child', () async => 1);
        return 42;
      });
      final captured = inspector.captureContext();
      switch (change) {
        case 'clear':
          inspector.clear();
        case 'disable':
          inspector.setEnabled(false);
          inspector.setEnabled(true);
        case 'pause':
          inspector.setPaused(true);
          inspector.setPaused(false);
      }
      final countAfterChange = _events(inspector).length;
      inspector.record('test', 'stale_context', context: captured);
      resumed.complete();
      expect(await action, 42);
      expect(_resources(inspector)['activeSpans'], 0);
      expect(_events(inspector), hasLength(countAfterChange));
      inspector.record('test', 'new_work');
      expect(_events(inspector).last['name'], 'new_work');
    });
  }

  test(
    'raw bodies, credentials, SQL arguments and errors never enter export',
    () async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      final fields = ['busy', 'roomId'];
      final data = <String, Object?>{
        'body': {'text': 'private-body'},
        'text': 'private-message',
        'sql': 'private-statement',
        'sqlArgs': ['private-argument'],
        'token': 'private-token',
        'password': 'private-password',
        'method': 'GET',
        'path': 'https://private-user:private-password@host.test/rooms?token=private-query#private-fragment',
        'reason': 'Bearer private-token',
        'source': 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.jwtSignature',
        'changed': fields,
        'rows': {'count': 2, 'text': 'private-nested-message'},
      };
      inspector.record('http', 'request', data: data);
      fields.add('later');
      final record = _events(inspector).single;
      final saved = record['data']! as Map;
      expect(saved['method'], 'GET');
      expect(saved['path'], '/rooms');
      expect(saved['changed'], ['busy', 'roomId']);
      expect(saved['rows'], {'count': 2});
      expect(saved['reason'], '[invalid]');
      expect(saved['source'], '[redacted]');
      final failure = _PrivateFailure();
      await expectLater(
        inspector.trace<void>('test', 'failure', () async => throw failure),
        throwsA(same(failure)),
      );
      final end = _events(inspector).last;
      expect((end['data']! as Map)['errorType'], '_PrivateFailure');
      final encoded = jsonEncode(inspector.snapshot());
      expect(encoded, isNot(contains('private-')));
      expect(encoded, isNot(contains('eyJ')));
      expect(encoded, isNot(contains('sqlArgs')));
      expect(encoded, isNot(contains('password')));
    },
  );

  test('metadata strings, collections and nested data have fixed limits', () {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    inspector.record(
      'test',
      'bounds',
      data: {
        'reason': 'x' * 1000,
        'changed': List.filled(1000, 'roomId'),
        'rows': {
          'rows': {
            'rows': {'count': 1},
          },
        },
      },
    );
    final data = _events(inspector).single['data']! as Map;
    expect((data['reason']! as String).length, 120);
    expect(data['changed'], hasLength(16));
    expect((((data['rows']! as Map)['rows']! as Map)['rows']), isEmpty);
  });

  test('public context causal IDs use the same metadata guard', () {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    inspector.record(
      'test',
      'context',
      context: const DebugTraceContext(
        userId: 'private user',
        roomId: 'private room',
        traceId: 'Bearer private-token',
        spanId: 'private span',
        parentSpanId: 'private parent',
      ),
    );
    final encoded = jsonEncode(inspector.snapshot());
    expect(encoded, isNot(contains('private')));
    expect(_events(inspector).single['traceId'], '[invalid]');
  });

  test('snapshots have no mutable aliases and survive later changes', () {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    inspector.record(
      'test',
      'sample',
      data: {
        'changed': ['busy'],
      },
    );
    inspector.setGauges({'subscriptions': 1});
    final snapshot = inspector.snapshot();
    final events = snapshot['events']! as List;
    final event = events.single as Map;
    final metadata = event['data']! as Map;
    inspector.record('test', 'later');
    inspector.setGauges({'subscriptions': 0});
    expect(events, hasLength(1));
    expect(snapshot['gauges'], {'subscriptions': 1});
    expect(() => snapshot['enabled'] = false, throwsUnsupportedError);
    expect(() => events.clear(), throwsUnsupportedError);
    expect(() => event['name'] = 'changed', throwsUnsupportedError);
    expect(() => metadata['count'] = 4, throwsUnsupportedError);
    expect(
      () => (metadata['changed']! as List).clear(),
      throwsUnsupportedError,
    );
    expect(() => (snapshot['gauges']! as Map).clear(), throwsUnsupportedError);
    expect(() => (snapshot['frames']! as Map).clear(), throwsUnsupportedError);
  });

  test('instrumentation failures cannot change application results', () async {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    final unreadable = _UnreadableMap();
    inspector.record('test', 'malformed', data: unreadable);
    expect(_events(inspector), isEmpty);
    expect(
      await inspector.trace(
        'test',
        'malformed',
        () async => 7,
        data: unreadable,
      ),
      7,
    );
    final span = inspector.begin('test', 'finish')!;
    span.finish(data: unreadable);
    span.finish();
    expect(_resources(inspector)['activeSpans'], 0);
    final failure = StateError('application failure');
    await expectLater(
      inspector.trace<void>(
        'test',
        'malformed',
        () async => throw failure,
        data: unreadable,
      ),
      throwsA(same(failure)),
    );
  });

  testWidgets('timeline refreshes coalesce; builds and gauges never notify', (
    tester,
  ) async {
    final inspector = DebugInspector(enabled: true);
    addTearDown(inspector.dispose);
    var notifications = 0;
    inspector.addListener(() => notifications++);
    for (var i = 0; i < 20; i++) {
      inspector.record('test', 'burst');
    }
    expect(notifications, 0);
    await tester.pump(const Duration(milliseconds: 249));
    expect(notifications, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(notifications, 1);
    inspector.recordBuild('MessageList', notificationId: 7);
    inspector.setGauges({'subscriptions': 1});
    inspector.setGauges({'timers': 2});
    await tester.pump(const Duration(seconds: 1));
    expect(notifications, 1);
    expect(inspector.snapshot()['gauges'], {'subscriptions': 1, 'timers': 2});
    expect(_events(inspector).last['name'], 'build:MessageList');
    expect((_events(inspector).last['data']! as Map)['notificationId'], 7);
    inspector.record('test', 'cancelled_refresh');
    inspector.clear();
    expect(notifications, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(notifications, 2);
  });

  testWidgets(
    'disable and dispose release spans, records, callbacks and timers',
    (tester) async {
      final inspector = DebugInspector(enabled: true);
      var notifications = 0;
      inspector.addListener(() => notifications++);
      final oldSpan = inspector.begin('test', 'unfinished')!;
      inspector.setEnabled(false);
      expect(_resources(inspector)['activeSpans'], 0);
      expect(_events(inspector), isEmpty);
      expect(
        (inspector.snapshot()['frames']! as Map)['callbackAttached'],
        isFalse,
      );
      oldSpan.finish();
      inspector.setEnabled(true);
      final resumed = Completer<void>();
      final trace = inspector.trace('test', 'shutdown', () => resumed.future);
      inspector.dispose();
      resumed.complete();
      await trace;
      final lastNotification = notifications;
      inspector.record('test', 'after_dispose');
      inspector.setEnabled(true);
      inspector.setPaused(true);
      inspector.clear();
      inspector.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(notifications, lastNotification);
      expect(_events(inspector), isEmpty);
      expect(_resources(inspector)['activeSpans'], 0);
      expect(inspector.enabled, isFalse);
      expect(
        (inspector.snapshot()['frames']! as Map)['callbackAttached'],
        isFalse,
      );
    },
  );
}
