import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/local_log_exporter.dart';
import 'package:chat_workspace/ui/flutter_inspector.dart';
import 'package:chat_workspace/ui/theme.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 202;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await requestStream?.drain<void>();
    return ResponseBody.fromString('', status);
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _mount(WidgetTester tester, DebugInspector inspector) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildChatTheme(),
      home: Scaffold(body: FlutterInspectorDialog(inspector: inspector)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'local sharing opt-in persists on reopen without replaying capture',
    (tester) async {
      final client = Dio();
      final adapter = _Adapter();
      client.httpClientAdapter = adapter;
      final exporter = LocalLogExporter(
        client: client,
        flushInterval: const Duration(days: 1),
      );
      final inspector = DebugInspector(localLogExporter: exporter);
      addTearDown(inspector.dispose);
      await _mount(tester, inspector);
      final toggle = find.byKey(const Key('inspector-local-logs'));
      expect(tester.widget<Switch>(toggle).value, false);
      expect(find.textContaining('Local logs off'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, true);
      expect(
        find.textContaining('Local logs waiting for capture'),
        findsOneWidget,
      );
      expect(adapter.requests, isEmpty);

      await tester.tap(find.byKey(const Key('inspector-enabled')));
      await tester.pumpAndSettle();
      inspector.record('realtime', 'inbox.publication');
      await tester.runAsync(exporter.flush);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('Local logs sharing · 1 sent'),
        findsOneWidget,
      );
      expect(adapter.requests, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(tester, inspector);
      expect(tester.widget<Switch>(toggle).value, true);
      await tester.runAsync(exporter.flush);
      expect(adapter.requests, hasLength(1));
      final events =
          (jsonDecode(adapter.requests.single.data as String) as Map)['events']
              as List;
      expect(events, hasLength(1));
      expect((events.single as Map)['name'], 'inbox.publication');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only an explicit refresh shares counter samples, automatic reads do not',
    (tester) async {
      final client = Dio();
      final adapter = _Adapter();
      client.httpClientAdapter = adapter;
      final exporter = LocalLogExporter(
        client: client,
        flushInterval: const Duration(days: 1),
      );
      final inspector = DebugInspector(
        enabled: true,
        localLogExporter: exporter,
      )..setShareWithLocalLogs(true);
      addTearDown(inspector.dispose);
      inspector.setGauges({'drift.subscriptions': 2});
      await _mount(tester, inspector);
      expect(inspector.snapshot()['events'], isEmpty);
      await tester.tap(find.byKey(const Key('inspector-refresh')));
      await tester.pumpAndSettle();
      final count = (inspector.snapshot()['events'] as List).length;
      expect(count, greaterThan(0));
      await tester.runAsync(exporter.flush);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(tester, inspector);
      expect(inspector.snapshot()['events'], hasLength(count));
      await tester.runAsync(exporter.flush);
      expect(adapter.requests, hasLength(1));
      final events =
          (jsonDecode(adapter.requests.single.data as String) as Map)['events']
              as List;
      expect(events.any((event) => event['data']['source'] == 'gauges'), true);
      expect(inspector.snapshot()['aggregates'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('delivery failures remain visible and cannot interrupt capture', (
    tester,
  ) async {
    final client = Dio();
    final adapter = _Adapter()..status = 503;
    client.httpClientAdapter = adapter;
    final exporter = LocalLogExporter(
      client: client,
      flushInterval: const Duration(days: 1),
    );
    final inspector = DebugInspector(enabled: true, localLogExporter: exporter)
      ..setShareWithLocalLogs(true);
    addTearDown(inspector.dispose);
    await _mount(tester, inspector);
    inspector.record('sync', 'completed');
    await tester.runAsync(exporter.flush);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('0 important dropped'), findsOneWidget);
    expect(find.textContaining('1 retry pending'), findsOneWidget);
    expect(exporter.snapshot()['failedBatches'], greaterThanOrEqualTo(1));
    expect(exporter.snapshot()['droppedEvents'], 0);
    expect(find.text('completed · instant'), findsOneWidget);
    expect(inspector.enabled, true);

    adapter.status = 202;
    await tester.runAsync(exporter.flush);
    expect(exporter.snapshot()['pendingRetryEvents'], 0);
    await tester.tap(find.byKey(const Key('inspector-refresh')));
    await tester.pump();
    expect(find.textContaining('0 retry pending'), findsOneWidget);
    expect(find.textContaining('1 sent'), findsOneWidget);
    expect(exporter.snapshot()['droppedImportantEvents'], 0);

    await tester.tap(find.byKey(const Key('inspector-pause')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(find.byKey(const Key('inspector-local-logs')))
          .value,
      true,
    );
    expect(
      find.textContaining('Local logs waiting for capture'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('inspector-clear')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('inspector-local-logs-status')))
          .data,
      contains('0 important dropped'),
    );
    expect(find.textContaining('0 failed batches'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid remote endpoint disables sharing with local configuration guidance',
    (tester) async {
      final inspector = DebugInspector(
        localLogExporter: LocalLogExporter(
          endpoint: 'https://remote.example/events',
        ),
      );
      addTearDown(inspector.dispose);
      await _mount(tester, inspector);
      final toggle = tester.widget<Switch>(
        find.byKey(const Key('inspector-local-logs')),
      );
      expect(toggle.onChanged, isNull);
      expect(
        find.textContaining('configure a loopback HTTP LOCAL_LOGS_URL'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
