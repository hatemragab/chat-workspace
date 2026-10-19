import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/chat_api.dart';
import 'package:chat_workspace/core/debug_traffic_logger.dart';
import 'package:chat_workspace/core/local_log_exporter.dart';
import 'package:chat_workspace/core/sqlite_query_details.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  final firstRequest = Completer<void>();
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!firstRequest.isCompleted) firstRequest.complete();
    await requestStream?.drain<void>();
    return respond(options);
  }

  @override
  void close({bool force = false}) => closed = true;
}

class _Harness {
  _Harness({String? endpoint, Duration? flushInterval}) {
    final client = Dio();
    adapter = _Adapter((_) => ResponseBody.fromString('', 202));
    client.httpClientAdapter = adapter;
    exporter = LocalLogExporter(
      client: client,
      endpoint: endpoint ?? 'http://127.0.0.1:8083/events',
      flushInterval: flushInterval ?? const Duration(days: 1),
      instanceId: 'test-instance',
    );
    inspector = DebugInspector(enabled: true, localLogExporter: exporter);
    addTearDown(inspector.dispose);
  }

  late final _Adapter adapter;
  late final LocalLogExporter exporter;
  late final DebugInspector inspector;

  List<Map<String, Object?>> get exported => [
    for (final request in adapter.requests)
      ...((jsonDecode(request.data as String) as Map)['events'] as List)
          .cast<Map<String, Object?>>(),
  ];

  void share() => inspector.setShareWithLocalLogs(true);
}

List<Map<String, Object?>> _events(DebugInspector inspector) =>
    (inspector.snapshot()['events']! as List).cast<Map<String, Object?>>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HTTP request and response details reach local export and opt-out retires queued payloads', () async {
    final h = _Harness();
    h.share();
    final client = Dio(BaseOptions(baseUrl: 'https://synthetic.example'));
    client.httpClientAdapter = _Adapter(
      (_) => ResponseBody.fromString(
        '{"statuses":{"peer-one":true},"token":"private-response-token"}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'x-request-id': ['presence-request'],
        },
      ),
    );
    addTearDown(client.close);
    final api = ChatApi(
      dio: client,
      debugInspector: h.inspector,
      trafficLogger: DebugTrafficLogger(enabled: true, writer: (_) {}),
    );
    api.setToken('private-bearer', userId: 'user-one');
    await api.getMap('/presence/status', query: {'userIds': 'peer-one'});
    await h.exporter.flush();
    final completion = h.exported.singleWhere(
      (event) => event['category'] == 'http' && event['phase'] == 'end',
    );
    expect(completion['requestId'], 'presence-request');
    final http = (completion['data']! as Map)['http']! as Map;
    expect(http['query'], {'userIds': 'peer-one'});
    expect(http['responseBody'], {
      'statuses': {'peer-one': true},
      'token': '[REDACTED]',
    });
    expect(jsonEncode(h.exported), isNot(contains('private-')));
    await api.post('/messages', {'text': 'Retire before exporting'});
    api.setDebugTrafficLoggingEnabled(false);
    await h.exporter.flush();
    expect(jsonEncode(h.exported), isNot(contains('Retire before exporting')));
    expect(
      jsonEncode(_events(h.inspector)),
      isNot(contains('Retire before exporting')),
    );
  });

  test('local export retains bounded SQL parameters and results only after explicit full-debug capture', () async {
    final h = _Harness();
    h.share();
    h.inspector.setSqliteDetailsEnabled(true);
    h.inspector
        .begin(
          'drift',
          'query.select',
          sqlite: () => SqliteQueryDetails.capture(
            'select',
            'SELECT ? AS text',
            ['sqlite parameter'],
          ),
        )!
        .finish(
          sqliteResult: [
            {'text': 'sqlite result', 'token': 'private-token'},
          ],
        );
    await h.exporter.flush();
    final encoded = jsonEncode(h.exported);
    expect(encoded, contains('SELECT ? AS text'));
    expect(encoded, contains('sqlite parameter'));
    expect(encoded, contains('sqlite result'));
    expect(encoded, isNot(contains('private-token')));
    h.inspector.setSqliteDetailsEnabled(false);
    expect(
      jsonEncode(_events(h.inspector)),
      isNot(contains('sqlite parameter')),
    );
  });

  test(
    'configuration accepts only loopback HTTP without credentials or query',
    () {
      for (final value in [
        'http://127.0.0.1:8083/events',
        'http://localhost:8083/events',
        'http://[::1]:8083/events',
      ]) {
        expect(LocalLogExporter.parseEndpoint(value), isNotNull, reason: value);
      }
      for (final value in [
        '',
        '/events',
        'https://127.0.0.1:8083/events',
        'http://example.com/events',
        'http://127.0.0.1.example.com/events',
        'http://127.0.0.2:8083/events',
        'http://0.0.0.0:8083/events',
        'http://localhost:0/events',
        'http://localhost:65536/events',
        'http://user:password@localhost:8083/events',
        'http://@localhost:8083/events',
        'http://localhost:8083/events?token=private',
        'http://localhost:8083/events?',
        'http://localhost:8083/events#private',
      ]) {
        expect(LocalLogExporter.parseEndpoint(value), isNull, reason: value);
      }
    },
  );

  test(
    'default sharing off sends nothing and enabling never replays history',
    () async {
      final h = _Harness();
      h.inspector.record('state', 'before_sharing');
      await h.exporter.flush();
      expect(h.adapter.requests, isEmpty);
      expect(h.exporter.snapshot()['enabled'], false);

      h.share();
      await h.exporter.flush();
      expect(h.adapter.requests, isEmpty);
      h.inspector.record('state', 'after_sharing');
      await h.exporter.flush();
      expect(h.exported.map((event) => event['name']), ['after_sharing']);
      expect(_events(h.inspector), hasLength(2));
      expect(h.exporter.snapshot()['sentEvents'], 1);
    },
  );

  test(
    'append exports exact sanitized span metadata and captured identity once',
    () async {
      final h = _Harness()..share();
      h.inspector.updateContext(
        userId: 'user-a',
        sessionGeneration: 2,
        roomId: 'room-a',
      );
      final metadata = <String, Object?>{
        'requestId': 'request-a',
        'count': 4,
        'password': 'private-password',
        'text': 'private-message-body',
        'query': 'private-sql-arguments',
        'path': '/rooms?secret=private-query',
      };
      final span = h.inspector.begin(
        'realtime',
        'inbox.publication',
        data: metadata,
      )!;
      metadata['count'] = 99;
      h.inspector.updateContext(
        userId: 'user-b',
        sessionGeneration: 3,
        roomId: 'room-b',
      );
      span.finish(data: const {'outcome': 'completed'});
      final retained = _events(h.inspector);
      await h.exporter.flush();
      await h.exporter.flush();

      expect(h.exported, hasLength(2));
      for (var i = 0; i < retained.length; i++) {
        expect(h.exported[i], {
          ...retained[i],
          'source': 'flutter',
          'event': 'flutter_inspector',
          'level': 'info',
          'requestId': 'request-a',
        });
        expect(h.exported[i]['userId'], 'user-a');
        expect(h.exported[i]['sessionGeneration'], 2);
        expect(h.exported[i]['roomId'], 'room-a');
        expect((h.exported[i]['data']! as Map)['count'], 4);
      }
      expect(h.exported.first['phase'], 'begin');
      expect(h.exported.last['phase'], 'end');
      expect(h.exported.last['durationMicros'], isA<int>());
      final request = h.adapter.requests.single;
      expect(
        (jsonDecode(request.data as String) as Map)['instanceId'],
        'test-instance',
      );
      expect(request.followRedirects, false);
      expect(request.maxRedirects, 0);
      expect(
        request.headers.keys.any((key) => key.toLowerCase() == 'authorization'),
        false,
      );
      expect(request.receiveTimeout, const Duration(seconds: 2));
      expect(
        h.adapter.requests.single.uri.toString(),
        'http://127.0.0.1:8083/events',
      );
      final encoded = request.data as String;
      expect(encoded, isNot(contains('private-')));
      expect(_events(h.inspector), retained);
    },
  );

  test('explicit counter snapshots export bounded metadata without self measurement', () async {
    final h = _Harness()..share();
    h.inspector.setGauges({'drift.subscriptions': 2});
    h.inspector.recordBuild('MessageList');
    h.inspector.record(
      'drift',
      'query.select',
      durationMicros: 2400,
      data: const {'rows': 3},
    );
    final before = h.inspector.snapshot();
    h.inspector.snapshot();
    expect(_events(h.inspector), hasLength(2));
    h.inspector.exportMetricsSnapshot();
    final after = h.inspector.snapshot();
    expect(after['gauges'], before['gauges']);
    expect(after['builds'], before['builds']);
    expect(after['aggregates'], before['aggregates']);
    final metrics = _events(h.inspector)
        .where((event) => event['category'] == 'inspector')
        .toList();
    expect(metrics, isNotEmpty);
    expect(
      metrics.map((event) => event['name']),
      containsAll([
        'metric.gauges.drift.subscriptions',
        'metric.builds.MessageList',
        'aggregate.drift/query.select',
      ]),
    );
    expect(
      metrics.map((event) => event['data']),
      contains(
        equals({
          'source': 'gauges',
          'operation': 'drift.subscriptions',
          'count': 2,
        }),
      ),
    );
    expect(
      metrics.map((event) => event['data']),
      contains(
        equals({'source': 'builds', 'operation': 'MessageList', 'count': 1}),
      ),
    );
    expect(
      metrics.map((event) => event['data']),
      contains(
        equals({
          'source': 'aggregates',
          'operation': 'drift/query.select',
          'count': 1,
          'microseconds': 2400,
          'durationMs': 2.4,
        }),
      ),
    );
    h.inspector.exportMetricsSnapshot();
    expect(h.inspector.snapshot()['aggregates'], before['aggregates']);
    while ((h.exporter.snapshot()['queuedEvents']! as int) > 0) {
      await h.exporter.flush();
    }
    expect(
      h.exported.where((event) => event['category'] == 'inspector'),
      hasLength(metrics.length * 2),
    );
    final gauge = h.exported.firstWhere(
      (event) => event['metricName'] == 'metric.gauges.drift.subscriptions',
    );
    expect(gauge['metricValue'], 2);
    expect(gauge['metricGroup'], 'gauges');
    expect(gauge['data'], {
      'source': 'gauges',
      'operation': 'drift.subscriptions',
      'count': 2,
    });
    expect(
      h.exported
          .where((event) => event['name'] == 'aggregate.drift/query.select')
          .every((event) => !event.containsKey('metricName')),
      true,
    );
    expect(h.exporter.snapshot()['queuedEvents'], 0);
    h.inspector.setShareWithLocalLogs(false);
    final count = _events(h.inspector).length;
    h.inspector.exportMetricsSnapshot();
    expect(_events(h.inspector), hasLength(count));
  });

  test(
    'errored spans export safe severity and error type without error text',
    () async {
      final h = _Harness()..share();
      final span = h.inspector.begin('sync', 'recover')!;
      span.finish(error: StateError('private-error-description'));
      await h.exporter.flush();
      expect(h.exported.last['level'], 'error');
      expect((h.exported.last['data']! as Map)['errorType'], 'StateError');
      expect(jsonEncode(h.exported), isNot(contains('private-error')));
    },
  );

  test(
    'explicit safe warnings retain critical priority through widget noise',
    () async {
      final h = _Harness()..share();
      h.inspector.record(
        'realtime',
        'reconnecting',
        data: const {'level': 'warn', 'reason': 'transport_closed'},
      );
      h.inspector.record('sync', 'failed', data: const {'level': 'error'});
      for (var i = 0; i < 1000; i++) {
        h.inspector.recordBuild('MessagesPane');
      }
      while ((h.exporter.snapshot()['queuedEvents']! as int) > 0) {
        await h.exporter.flush();
      }
      expect(h.exported.first['level'], 'warn');
      expect(h.exported[1]['level'], 'error');
      expect(h.exporter.snapshot()['droppedCriticalEvents'], 0);
      final errorAggregate = (h.inspector.snapshot()['aggregates']! as List)
          .cast<Map>()
          .singleWhere((row) => row['name'] == 'failed');
      expect(errorAggregate['errorCount'], 1);
    },
  );

  test(
    'batched requests respect record limit and never send concurrently',
    () async {
      final h = _Harness()..share();
      final pending = Completer<ResponseBody>();
      h.adapter.respond = (_) => pending.future;
      for (var i = 0; i < 121; i++) {
        h.inspector.record('state', 'operation_$i');
      }
      final first = h.exporter.flush();
      await h.adapter.firstRequest.future;
      expect(h.adapter.requests, hasLength(1));
      await h.exporter.flush();
      expect(h.adapter.requests, hasLength(1));
      expect(h.exporter.snapshot()['queuedEvents'], 71);
      pending.complete(ResponseBody.fromString('', 202));
      await first;
      h.adapter.respond = (_) => ResponseBody.fromString('', 200);
      await h.exporter.flush();
      await h.exporter.flush();
      expect(
        h.adapter.requests.map(
          (request) =>
              ((jsonDecode(request.data as String) as Map)['events'] as List)
                  .length,
        ),
        [50, 50, 21],
      );
      expect(
        h.exported.map((event) => event['seq']),
        List.generate(121, (i) => i + 1),
      );
      expect(h.exporter.snapshot()['sentEvents'], 121);
      for (final request in h.adapter.requests) {
        expect(
          utf8.encode(request.data as String).length,
          lessThanOrEqualTo(LocalLogExporter.batchByteLimit),
        );
      }
    },
  );

  test(
    'queue overflow is bounded and independent of timeline retention',
    () async {
      final h = _Harness()..share();
      for (var i = 0; i < 600; i++) {
        h.inspector.record('state', 'operation_$i');
      }
      expect(h.exporter.snapshot()['queuedEvents'], 450);
      expect(h.exporter.snapshot()['droppedEvents'], 150);
      expect(h.exporter.snapshot()['droppedImportantEvents'], 150);
      expect(_events(h.inspector), hasLength(500));
      expect(_events(h.inspector).first['seq'], 101);
      await h.exporter.flush();
      // Append-time delivery preserves older queued events after ring eviction.
      expect(h.exported.first['seq'], 1);
    },
  );

  test(
    'queue byte bound and oversized record rejection preserve batch byte bound',
    () async {
      final h = _Harness()..share();
      final technicalLabel = List.filled(120, 'a').join();
      final data = <String, Object?>{
        for (final key in [
          'method',
          'status',
          'reason',
          'source',
          'eventType',
          'requestId',
          'operation',
          'table',
          'transactionId',
          'connectionState',
          'outcome',
          'widget',
          'mode',
          'generation',
          'roomId',
          'userId',
          'epoch',
          'limit',
          'attempt',
          'fromPts',
          'toPts',
          'busy',
          'changed',
          'queueDepth',
          'count',
          'rows',
          'pending',
          'localPts',
          'targetPts',
          'roomPts',
          'msgPts',
          'sincePts',
        ])
          key: technicalLabel,
      };
      for (var i = 0; i < 500; i++) {
        h.inspector.record('state', 'operation_$i', data: data);
      }
      expect(h.exporter.snapshot()['queuedEvents'], lessThan(500));
      expect(
        h.exporter.snapshot()['queuedBytes'],
        lessThanOrEqualTo(LocalLogExporter.queueByteLimit),
      );
      expect(h.exporter.snapshot()['droppedEvents'], greaterThan(0));
      final before = h.exporter.snapshot()['queuedEvents'];
      h.exporter.addInspectorRecord({
        'data': {
          'count': List.filled(LocalLogExporter.batchByteLimit, 'a').join(),
        },
      });
      expect(h.exporter.snapshot()['queuedEvents'], before);
      await h.exporter.flush();
      expect(
        utf8.encode(h.adapter.requests.single.data as String).length,
        lessThanOrEqualTo(LocalLogExporter.batchByteLimit),
      );
    },
  );

  test(
    'temporary failures retain identical batch identity until acknowledged',
    () async {
      final h = _Harness()..share();
      h.adapter.respond = (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      );
      h.inspector.record('http', 'POST');
      await h.exporter.flush();
      expect(h.adapter.requests, hasLength(1));
      expect(h.exporter.snapshot()['failedBatches'], 1);
      expect(h.exporter.snapshot()['droppedEvents'], 0);
      expect(h.exporter.snapshot()['pendingRetryEvents'], 1);
      expect(h.exporter.snapshot()['pendingImportantEvents'], 1);
      expect(h.exporter.snapshot()['lastFailure'], 'connectionError');
      expect(_events(h.inspector), hasLength(1));
      h.adapter.respond = (_) => ResponseBody.fromString('', 202);
      await h.exporter.flush();
      expect(h.exporter.snapshot()['sentEvents'], 1);
      expect(h.exporter.snapshot()['lastFailure'], isNull);
      expect(h.adapter.requests, hasLength(2));
      expect(h.adapter.requests.first.data, h.adapter.requests.last.data);
      final batch = jsonDecode(h.adapter.requests.first.data as String) as Map;
      expect(batch['batchId'], matches(RegExp(r'^[a-f0-9-]{36}$')));
      expect(h.exporter.snapshot()['pendingRetryEvents'], 0);
      expect(h.exporter.snapshot()['retriedBatches'], 1);
      expect(_events(h.inspector), hasLength(1));
    },
  );

  test(
    'noise burst preserves 174 complete operation pairs and terminal error',
    () async {
      final h = _Harness()..share();
      for (var i = 0; i < 1000; i++) {
        h.inspector.recordBuild('MessagesPane');
      }
      final spans = [
        for (var i = 0; i < 174; i++)
          h.inspector.begin('sync', 'operation_$i')!,
      ];
      for (var i = 0; i < spans.length; i++) {
        spans[i].finish(error: i == 173 ? StateError('private-failure') : null);
      }
      expect(h.exporter.snapshot()['queuedEvents'], lessThanOrEqualTo(500));
      expect(h.exporter.snapshot()['evictedNoiseEvents'], greaterThan(0));
      expect(h.exporter.snapshot()['droppedImportantEvents'], 0);
      expect(h.exporter.snapshot()['droppedCriticalEvents'], 0);
      expect(h.exporter.snapshot()['droppedEvents'], 0);
      expect(
        (h.inspector.snapshot()['resources']! as Map)['overflowSpans'],
        110,
      );
      while ((h.exporter.snapshot()['queuedEvents']! as int) > 0) {
        await h.exporter.flush();
      }
      final operations = h.exported.where(
        (event) => event['category'] == 'sync',
      );
      expect(operations, hasLength(348));
      for (var i = 0; i < spans.length; i++) {
        final pair = operations.where(
          (event) => event['name'] == 'operation_$i',
        );
        expect(pair.map((event) => event['phase']), ['begin', 'end']);
        expect(pair.first['spanId'], pair.last['spanId']);
      }
      expect(operations.last['level'], 'error');
      expect(
        jsonEncode(operations.toList()),
        isNot(contains('private-failure')),
      );
    },
  );

  test(
    'critical reserve survives operational saturation and noise afterwards',
    () async {
      final h = _Harness()..share();
      for (var i = 0; i < 450; i++) {
        h.inspector.record('state', 'cursor_$i');
      }
      for (var i = 0; i < 50; i++) {
        h.inspector.record('http', 'request_$i', data: const {'status': 503});
      }
      for (var i = 0; i < 1000; i++) {
        h.inspector.recordBuild('MessagesPane');
      }
      expect(h.exporter.snapshot()['queuedEvents'], 500);
      expect(h.exporter.snapshot()['droppedEvents'], 0);
      expect(h.exporter.snapshot()['sampledEvents'], 1000);
      while ((h.exporter.snapshot()['queuedEvents']! as int) > 0) {
        await h.exporter.flush();
      }
      expect(
        h.exported.where((event) => event['level'] == 'warn'),
        hasLength(50),
      );
      expect(h.exporter.snapshot()['droppedCriticalEvents'], 0);
    },
  );

  test(
    'important-only exhaustion is bounded and explicitly reports critical loss',
    () {
      final h = _Harness()..share();
      for (var i = 0; i < 501; i++) {
        h.inspector.record(
          'sync',
          'failure_$i',
          data: const {'errorType': 'StateError'},
        );
      }
      expect(h.exporter.snapshot()['queuedEvents'], 500);
      expect(h.exporter.snapshot()['droppedEvents'], 1);
      expect(h.exporter.snapshot()['droppedImportantEvents'], 1);
      expect(h.exporter.snapshot()['droppedCriticalEvents'], 1);
      expect(h.exporter.snapshot()['lastFailure'], 'important_queue_overflow');
      expect(h.exporter.snapshot()['lastFailureAt'], isNotNull);
    },
  );

  test('transient statuses retry identical payload but permanent rejection retires poison batch', () async {
    final h = _Harness()..share();
    final statuses = [503, 429, 408, 400];
    var attempt = 0;
    h.adapter.respond = (_) => ResponseBody.fromString('', statuses[attempt++]);
    h.inspector.record(
      'sync',
      'recover',
      data: const {'errorType': 'StateError'},
    );
    for (var i = 0; i < statuses.length; i++) {
      await h.exporter.flush();
    }
    expect(
      h.adapter.requests.map((request) => request.data).toSet(),
      hasLength(1),
    );
    expect(h.exporter.snapshot()['failedBatches'], 4);
    expect(h.exporter.snapshot()['retriedBatches'], 3);
    expect(h.exporter.snapshot()['pendingRetryEvents'], 0);
    expect(h.exporter.snapshot()['droppedImportantEvents'], 1);
    expect(h.exporter.snapshot()['droppedCriticalEvents'], 1);
    expect(h.exporter.snapshot()['lastFailure'], 'http_400');
    h.adapter.respond = (_) => ResponseBody.fromString('', 202);
    h.inspector.record('state', 'new_batch');
    await h.exporter.flush();
    expect(h.exporter.snapshot()['sentEvents'], 1);
    final first = jsonDecode(h.adapter.requests.first.data as String) as Map;
    final last = jsonDecode(h.adapter.requests.last.data as String) as Map;
    expect(last['batchId'], isNot(first['batchId']));
  });

  test(
    'sharing off explicitly retires retained failed batch without replay',
    () async {
      final h = _Harness()..share();
      h.adapter.respond = (_) => ResponseBody.fromString('', 503);
      h.inspector.record('sync', 'before_off');
      await h.exporter.flush();
      expect(h.exporter.snapshot()['pendingRetryEvents'], 1);
      h.inspector.setShareWithLocalLogs(false);
      expect(h.exporter.snapshot()['retiredEvents'], 1);
      expect(h.exporter.snapshot()['pendingImportantEvents'], 0);
      h.share();
      h.adapter.respond = (_) => ResponseBody.fromString('', 202);
      await h.exporter.flush();
      expect(h.adapter.requests, hasLength(1));
    },
  );

  testWidgets(
    'failed batch retries automatically while its ordinary queue is empty',
    (tester) async {
      final h = _Harness(flushInterval: const Duration(milliseconds: 100))
        ..share();
      var attempt = 0;
      h.adapter.respond = (_) =>
          ResponseBody.fromString('', attempt++ == 0 ? 503 : 202);
      h.inspector.record('state', 'scheduled');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(h.adapter.requests, hasLength(1));
      expect(h.exporter.snapshot()['pendingRetryEvents'], 1);
      await tester.pump(const Duration(milliseconds: 99));
      expect(h.adapter.requests, hasLength(1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(h.adapter.requests, hasLength(2));
      expect(h.exporter.snapshot()['sentEvents'], 1);
      expect(h.exporter.snapshot()['droppedEvents'], 0);
      h.inspector.dispose();
    },
  );

  test('capture pause/off and sharing off retire queue while selection survives capture', () async {
    final h = _Harness()..share();
    h.inspector.record('state', 'before_pause');
    h.inspector.setPaused(true);
    h.inspector.record('state', 'ignored');
    h.inspector.setPaused(false);
    await h.exporter.flush();
    expect(h.adapter.requests, isEmpty);
    expect(h.exporter.snapshot()['retiredEvents'], 1);
    expect(h.exporter.enabled, true);
    h.inspector.record('state', 'before_capture_off');
    h.inspector.setEnabled(false);
    h.inspector.setEnabled(true);
    await h.exporter.flush();
    expect(h.adapter.requests, isEmpty);
    expect(h.exporter.enabled, true);
    h.inspector.record('state', 'before_share_off');
    h.inspector.setShareWithLocalLogs(false);
    h.share();
    await h.exporter.flush();
    expect(h.adapter.requests, isEmpty);
    h.inspector.record('state', 'new_only');
    await h.exporter.flush();
    expect(h.exported.map((event) => event['name']), ['new_only']);
    expect(h.exporter.snapshot()['retiredEvents'], 3);
  });

  test(
    'clear and late completion cannot restore retired accounting or rows',
    () async {
      final h = _Harness()..share();
      final pending = Completer<ResponseBody>();
      h.adapter.respond = (_) => pending.future;
      h.inspector.record('state', 'in_flight');
      final first = h.exporter.flush();
      await h.adapter.firstRequest.future;
      h.inspector.record('state', 'queued');
      h.inspector.clear();
      pending.complete(ResponseBody.fromString('', 202));
      await first;
      expect(h.exporter.snapshot()['sentEvents'], 0);
      expect(h.exporter.snapshot()['droppedEvents'], 0);
      expect(h.exporter.snapshot()['failedBatches'], 0);
      expect(h.exporter.snapshot()['queuedEvents'], 0);
      expect(_events(h.inspector), isEmpty);
      h.adapter.respond = (_) => ResponseBody.fromString('', 202);
      h.inspector.record('state', 'after_clear');
      await h.exporter.flush();
      expect(h.exporter.snapshot()['sentEvents'], 1);
      expect(h.exported.map((event) => event['name']), [
        'in_flight',
        'after_clear',
      ]);
    },
  );

  test(
    'invalid endpoint and disposal never send or retain a backlog',
    () async {
      final h = _Harness(endpoint: 'https://remote.example/events')..share();
      h.inspector.record('state', 'local_only');
      await h.exporter.flush();
      expect(h.adapter.requests, isEmpty);
      expect(h.exporter.available, false);
      expect(h.exporter.snapshot()['queuedEvents'], 0);
      expect(h.exporter.snapshot()['lastFailure'], 'invalid_local_endpoint');
      h.inspector.dispose();
      h.inspector.record('state', 'after_dispose');
      h.exporter.addInspectorRecord(const {});
      await h.exporter.flush();
      expect(h.adapter.closed, true);
      expect(h.adapter.requests, isEmpty);
    },
  );

  testWidgets(
    'new records flush after the bounded delay without a UI subscriber',
    (tester) async {
      final h = _Harness(flushInterval: const Duration(milliseconds: 500))
        ..share();
      h.inspector.record('state', 'scheduled');
      await tester.pump(const Duration(milliseconds: 499));
      expect(h.adapter.requests, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(h.adapter.requests, hasLength(1));
      expect(h.exporter.snapshot()['sentEvents'], 1);
      h.inspector.dispose();
    },
  );
  test(
    'backlog drains promptly and accepts a sustained stream beyond 500 records',
    () async {
      final h = _Harness(flushInterval: const Duration(milliseconds: 500))
        ..share();
      for (var batch = 0; batch < 12; batch++) {
        for (var i = 0; i < 100; i++) {
          h.inspector.record('state', 'steady_${batch}_$i');
        }
        await h.exporter.flush();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      for (
        var i = 0;
        i < 100 && h.exporter.snapshot()['sentEvents'] != 1200;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(h.exporter.snapshot()['sentEvents'], 1200);
      expect(h.exporter.snapshot()['queuedEvents'], 0);
      expect(h.exporter.snapshot()['droppedEvents'], 0);
      expect(h.exporter.snapshot()['lastSuccessAt'], isNotNull);
      for (final request in h.adapter.requests) {
        expect(
          ((jsonDecode(request.data as String) as Map)['events'] as List)
              .length,
          lessThanOrEqualTo(50),
        );
      }
      h.inspector.dispose();
    },
  );

  test('pressure samples only widget/watch instant observations and exposes counts', () async {
    final h = _Harness()..share();
    for (var i = 0; i < 600; i++) {
      h.inspector.record('widget', 'build:MessagesPane');
    }
    h.inspector.record('state', 'cursor.advance');
    final span = h.inspector.begin('drift', 'query.select')!;
    span.finish(data: const {'outcome': 'cancelled'});
    expect(h.exporter.snapshot()['sampledEvents'], greaterThan(0));
    expect(h.exporter.snapshot()['droppedEvents'], 0);
    await h.exporter.flush();
    for (
      var i = 0;
      i < 100 &&
          ((h.exporter.snapshot()['queuedEvents']! as int) > 0 ||
              h.exporter.snapshot()['inFlightEvents'] != 0);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(h.exporter.snapshot()['queuedEvents'], 0);
    expect(
      h.exported.where((event) => event['name'] == 'cursor.advance'),
      hasLength(1),
    );
    final cancelled = h.exported
        .where((event) => event['name'] == 'query.select')
        .last;
    expect(cancelled['level'], 'info');
    expect((cancelled['data']! as Map)['outcome'], 'cancelled');
    expect((cancelled['data']! as Map).containsKey('errorType'), false);
    final aggregate = (h.inspector.snapshot()['aggregates']! as List)
        .cast<Map>()
        .where((row) => row['name'] == 'query.select')
        .single;
    expect(aggregate['errorCount'], 0);
    h.inspector.dispose();
  });
}
