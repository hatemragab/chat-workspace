import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_flows_test.dart' show mount;
import 'fake_chat_controller.dart';

Map<String, dynamic> _diagnostics(WidgetTester tester) => jsonDecode(
  tester
      .widget<SelectableText>(find.byKey(const Key('diagnostics-data')))
      .data!,
) as Map<String, dynamic>;

void main() {
  testWidgets(
    'diagnostics toggles full traffic and shows bounded per-user HTTP and realtime counts',
    (tester) async {
      final controller = FakeChatController();
      controller.api.setToken('synthetic-private-token', userId: 'user-1');
      await mount(tester, controller);
      await tester.tap(find.byKey(const Key('sync-diagnostics')));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('debug-traffic-logging'));
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.debugTrafficLoggingEnabled, true);
      expect(controller.debugInspector.sqliteDetailsEnabled, true);

      final logger = controller.api.trafficLogger;
      final request = logger.captureHttpRequest(
        method: 'POST',
        path: '/messages',
        params: {},
        query: {},
        body: {'text': 'Full request text', 'password': 'never-print-password'},
      );
      logger.recordHttpCompletion(
        request: request,
        metadata: {
          'timestamp': DateTime.utc(2026, 10, 16).toIso8601String(),
          'method': 'POST',
          'route': '/messages',
          'status': 201,
          'durationMs': 2,
          'requestId': 'traffic-widget-request',
        },
        responseBody: {
          'message': {'text': 'Full response text'},
        },
      );
      for (final userId in ['user-1', 'user-2']) {
        logger.recordRealtimePublication(
          {
            'pts': 9,
            'epoch': 'epoch',
            'room': {
              'roomId': 'room-1',
              'eventType': 'message_new',
              'lastMessage': {'text': 'Full realtime text'},
            },
          },
          channel: 'inbox:user#$userId',
          userId: userId,
        );
      }
      controller.clearError();
      await tester.pumpAndSettle();
      final data = _diagnostics(tester);
      expect(data['recentTrafficCounts'], {
        'retainedRecords': 3,
        'httpRequests': 1,
        'realtimePublications': 2,
        'byUser': {
          'user-1': {'httpRequests': 1, 'realtimePublications': 1},
          'user-2': {'httpRequests': 0, 'realtimePublications': 1},
        },
      });
      final encoded = jsonEncode(data['recentTrafficRecords']);
      expect(encoded, contains('Full request text'));
      expect(encoded, contains('Full response text'));
      expect(encoded, contains('Full realtime text'));
      expect(encoded, isNot(contains('never-print-password')));
      expect(encoded, isNot(contains('synthetic-private-token')));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.debugTrafficLoggingEnabled, false);
      expect(controller.debugInspector.sqliteDetailsEnabled, false);
      expect(_diagnostics(tester)['recentTrafficRecords'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
