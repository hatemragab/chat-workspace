import 'dart:convert';

import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/debug_traffic_logger.dart';
import 'package:chat_workspace/core/sqlite_query_details.dart';
import 'package:chat_workspace/ui/flutter_inspector.dart';
import 'package:chat_workspace/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _mount(
  WidgetTester tester,
  DebugInspector inspector, {
  VoidCallback? onRefresh,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildChatTheme(),
      home: Scaffold(
        body: FlutterInspectorDialog(
          inspector: inspector,
          onRefresh: onRefresh,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _recordFixture(DebugInspector inspector) {
  inspector.record(
    'drift',
    'load_rows',
    durationMicros: 2400,
    data: const {'rows': 3, 'outcome': 'cache_hit'},
    context: const DebugTraceContext(
      userId: 'user-a',
      sessionGeneration: 2,
      roomId: 'room-a',
      traceId: 'trace-a',
      spanId: 'span-a',
      parentSpanId: 'parent-a',
    ),
  );
  inspector.record(
    'sync',
    'inbox_received',
    data: const {'pts': 12},
    context: const DebugTraceContext(
      userId: 'user-b',
      sessionGeneration: 4,
      roomId: 'room-b',
      traceId: 'trace-b',
    ),
  );
}

void main() {
  testWidgets(
    'turning realtime detail capture off removes cached expanded JSON',
    (tester) async {
      final inspector = DebugInspector(enabled: true)
        ..setRealtimeDetailsEnabled(true);
      addTearDown(inspector.dispose);
      final logger = DebugTrafficLogger(enabled: true, writer: (_) {});
      inspector.record(
        'realtime',
        'socket.receive.publication',
        realtimeDetails: logger.inspectorRealtimeDetails(
          direction: 'receive',
          operation: 'publication',
          payload: () => {'text': 'Captured realtime payload'},
        ),
      );
      await _mount(tester, inspector);
      await tester.tap(find.text('socket.receive.publication · instant'));
      await tester.pumpAndSettle();
      final event = (inspector.snapshot()['events'] as List).last as Map;
      final json = find.byKey(Key('inspector-event-json-${event['seq']}'));
      expect(
        tester.widget<SelectableText>(json).data,
        contains('Captured realtime payload'),
      );
      inspector.setRealtimeDetailsEnabled(false);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(json).data,
        isNot(contains('Captured realtime payload')),
      );
    },
  );

  testWidgets('turning HTTP detail capture off removes cached expanded JSON', (
    tester,
  ) async {
    final inspector = DebugInspector(enabled: true)
      ..setHttpDetailsEnabled(true);
    addTearDown(inspector.dispose);
    final logger = DebugTrafficLogger(enabled: true, writer: (_) {});
    final request = logger.captureHttpRequest(
      method: 'GET',
      path: '/presence/status',
      params: {},
      query: {'userIds': 'peer-one'},
      body: null,
    );
    inspector
        .begin('http', 'GET:/presence/status')!
        .finish(
          httpDetails: logger.inspectorHttpDetails(
            request: request,
            responseBody: {'text': 'HTTP captured reply'},
          ),
        );
    await _mount(tester, inspector);
    await tester.tap(find.text('GET:/presence/status · end'));
    await tester.pumpAndSettle();
    final event = (inspector.snapshot()['events'] as List).last as Map;
    final json = find.byKey(Key('inspector-event-json-${event['seq']}'));
    expect(
      tester.widget<SelectableText>(json).data,
      contains('HTTP captured reply'),
    );
    inspector.setHttpDetailsEnabled(false);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(json).data,
      isNot(contains('HTTP captured reply')),
    );
  });

  testWidgets('turning full capture off removes cached expanded SQL JSON', (
    tester,
  ) async {
    final inspector = DebugInspector(enabled: true)
      ..setSqliteDetailsEnabled(true);
    addTearDown(inspector.dispose);
    inspector
        .begin(
          'drift',
          'query.select',
          sqlite: () => SqliteQueryDetails.capture('select', 'SELECT ?', [
            'private-sql-parameter',
          ]),
        )!
        .finish(
          sqliteResult: [
            {'text': 'private-sql-result'},
          ],
        );
    await _mount(tester, inspector);
    await tester.tap(find.text('query.select · end'));
    await tester.pumpAndSettle();
    final event = (inspector.snapshot()['events'] as List).last as Map;
    final json = find.byKey(Key('inspector-event-json-${event['seq']}'));
    expect(
      tester.widget<SelectableText>(json).data,
      contains('private-sql-parameter'),
    );
    inspector.setSqliteDetailsEnabled(false);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(json).data,
      isNot(contains('private-sql-')),
    );
  });
  testWidgets('capture has a labeled accessible toggle action and state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final inspector = DebugInspector();
    addTearDown(inspector.dispose);
    try {
      await _mount(tester, inspector);
      final capture = find.bySemanticsLabel('Capture Flutter events');
      expect(capture, findsOneWidget);
      expect(
        tester.getSemantics(capture),
        isSemantics(
          label: 'Capture Flutter events',
          hasToggledState: true,
          isToggled: false,
          hasTapAction: true,
        ),
      );
      tester.semantics.tap(find.semantics.byLabel('Capture Flutter events'));
      await tester.pumpAndSettle();
      expect(inspector.enabled, true);
      expect(
        tester.getSemantics(capture),
        isSemantics(
          label: 'Capture Flutter events',
          hasToggledState: true,
          isToggled: true,
          hasTapAction: true,
        ),
      );
      tester.semantics.tap(find.semantics.byLabel('Capture Flutter events'));
      await tester.pumpAndSettle();
      expect(inspector.enabled, false);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'capture, pause, resume and clear control the independent inspector',
    (tester) async {
      final inspector = DebugInspector();
      addTearDown(inspector.dispose);
      await _mount(tester, inspector);
      final toggle = find.byKey(const Key('inspector-enabled'));
      expect(tester.widget<Switch>(toggle).value, false);
      expect(
        find.text('Enable capture to inspect Flutter operations.'),
        findsOneWidget,
      );

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(inspector.enabled, true);
      inspector.record('sync', 'initial_sync');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('initial_sync · instant'), findsOneWidget);

      await tester.tap(find.byKey(const Key('inspector-pause')));
      await tester.pumpAndSettle();
      expect(inspector.paused, true);
      expect(find.text('Resume'), findsOneWidget);
      inspector.record('sync', 'ignored_while_paused');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('ignored_while_paused · instant'), findsNothing);
      expect((inspector.snapshot()['events'] as List).length, 1);

      await tester.tap(find.byKey(const Key('inspector-pause')));
      await tester.pumpAndSettle();
      inspector.record('sync', 'resumed_sync');
      await tester.pump(const Duration(milliseconds: 300));
      expect(inspector.paused, false);
      expect((inspector.snapshot()['events'] as List).length, 2);

      await tester.tap(find.byKey(const Key('inspector-clear')));
      await tester.pumpAndSettle();
      expect(inspector.snapshot()['events'], isEmpty);
      expect(find.text('No events match these filters.'), findsOneWidget);
      inspector.record('sync', 'before_disable');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(inspector.enabled, false);
      expect(inspector.snapshot()['events'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'timeline filters identity and category and expands causal JSON',
    (tester) async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      _recordFixture(inspector);
      await _mount(tester, inspector);
      final search = find.byKey(const Key('inspector-search'));

      for (final query in ['user-a', 'room-a', 'trace-a', 'load_rows']) {
        await tester.enterText(search, query);
        await tester.pumpAndSettle();
        expect(find.text('load_rows · instant'), findsOneWidget);
        expect(find.text('inbox_received · instant'), findsNothing);
        expect(
          find.text('1 of 2 retained events · newest first'),
          findsOneWidget,
        );
      }
      await tester.enterText(search, 'user-b');
      await tester.pumpAndSettle();
      expect(find.text('inbox_received · instant'), findsOneWidget);
      expect(find.text('load_rows · instant'), findsNothing);

      await tester.enterText(search, '');
      await tester.tap(find.byKey(const Key('inspector-category-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('drift').last);
      await tester.pumpAndSettle();
      expect(find.text('load_rows · instant'), findsOneWidget);
      expect(find.text('inbox_received · instant'), findsNothing);
      expect(find.textContaining('parent parent-a'), findsOneWidget);
      expect(find.textContaining('2.40 ms'), findsOneWidget);
      expect(find.textContaining('cache_hit'), findsOneWidget);

      final event = (inspector.snapshot()['events'] as List).first as Map;
      await tester.tap(find.text('load_rows · instant'));
      await tester.pumpAndSettle();
      final details = tester.widget<SelectableText>(
        find.byKey(Key('inspector-event-json-${event['seq']}')),
      );
      final data = jsonDecode(details.data!) as Map<String, dynamic>;
      expect(data['traceId'], 'trace-a');
      expect(data['parentSpanId'], 'parent-a');
      expect(data['data'], {'rows': 3, 'outcome': 'cache_hit'});

      await tester.tap(find.byKey(const Key('inspector-clear')));
      await tester.pumpAndSettle();
      expect(find.text('No events match these filters.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'copy includes a fresh redacted snapshot and all unfiltered events',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      _recordFixture(inspector);
      await _mount(tester, inspector);
      await tester.enterText(
        find.byKey(const Key('inspector-search')),
        'no_match',
      );
      inspector.record(
        'http',
        'request_finished',
        data: const {
          'status': 201,
          'password': 'never-copy-password',
          'token': 'never-copy-token',
          'messageText': 'never-copy-private-content',
        },
      );
      // Copy reads the latest counters even before the throttled notification.
      await tester.tap(find.byKey(const Key('inspector-copy')));
      await tester.pumpAndSettle();
      final data = jsonDecode(copied!) as Map<String, dynamic>;
      expect((data['events'] as List).length, 3);
      expect(copied, contains('request_finished'));
      expect(copied, isNot(contains('never-copy-')));
      expect(find.text('Inspector snapshot copied'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual refresh shows silent counters without inspector build feedback',
    (tester) async {
      final inspector = DebugInspector(enabled: true)
        ..recordBuild('MessageList');
      addTearDown(inspector.dispose);
      var visibleMessages = 4;
      var samples = 0;
      await _mount(
        tester,
        inspector,
        onRefresh: () {
          samples++;
          inspector.setGauges({'visibleMessages': visibleMessages});
        },
      );
      expect(samples, 1);
      visibleMessages = 6;
      inspector.recordBuild('MessageList');
      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      final counter = find.byKey(const Key('inspector-metric-visibleMessages'));
      expect(
        find.descendant(of: counter, matching: find.text('4')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('inspector-refresh')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: counter, matching: find.text('6')),
        findsOneWidget,
      );
      expect(samples, 2);

      await tester.tap(find.text('Widgets & frames'));
      await tester.pumpAndSettle();
      expect(find.text('Frame timings'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('inspector-widget-MessageList')),
        120,
        scrollable: find.descendant(
          of: find.byKey(const Key('inspector-widgets-frames')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('2 builds'), findsOneWidget);
      expect(find.textContaining('not heap leak proof'), findsOneWidget);
      final before = (inspector.snapshot()['events'] as List).length;
      await tester.pump(const Duration(seconds: 1));
      expect((inspector.snapshot()['events'] as List).length, before);
      expect(inspector.snapshot()['builds'], {'MessageList': 2});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing the dialog removes its listener while capture continues',
    (tester) async {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      await _mount(tester, inspector);
      await tester.pumpWidget(const SizedBox.shrink());
      inspector.record('sync', 'after_dialog_disposed');
      await tester.pump(const Duration(milliseconds: 300));
      expect((inspector.snapshot()['events'] as List).length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(320, 640)]) {
    testWidgets(
      'inspector controls and timeline fit a narrow window at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final inspector = DebugInspector(enabled: true);
        addTearDown(inspector.dispose);
        _recordFixture(inspector);
        await _mount(tester, inspector);
        expect(find.byKey(const Key('inspector-copy')), findsOneWidget);
        expect(find.byKey(const Key('inspector-search')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('inbox_received · instant'),
          100,
          scrollable: find.descendant(
            of: find.byKey(const Key('inspector-timeline')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('inspector-pause')));
        await tester.pumpAndSettle();
        expect(inspector.paused, true);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
