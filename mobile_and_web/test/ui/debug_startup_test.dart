import 'package:chat_workspace/core/chat_controller.dart';
import 'package:chat_workspace/core/app_database.dart';
import 'package:drift/native.dart';
import 'package:chat_workspace/ui/flutter_inspector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'debug startup enables capture, sharing and full traffic before initialization',
    (tester) async {
      final controller = ChatController(
        database: AppDatabase(NativeDatabase.memory()),
        enableRealtime: false,
        enableDebugLogging: kDebugMode,
      );
      addTearDown(controller.dispose);
      final inspector = controller.debugInspector;
      expect(controller.initialized, false);
      expect(inspector.enabled, kDebugMode);
      const fullTraffic =
          kDebugMode &&
          bool.fromEnvironment(
            'DEBUG_TRAFFIC_LOGGING_ENABLED',
            defaultValue: true,
          );
      expect(controller.debugTrafficLoggingEnabled, fullTraffic);
      expect(inspector.sqliteDetailsEnabled, fullTraffic);
      expect((inspector.snapshot()['localLogs'] as Map)['enabled'], kDebugMode);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FlutterInspectorDialog(inspector: inspector)),
        ),
      );
      final capture = find.byKey(const Key('inspector-enabled'));
      final share = find.byKey(const Key('inspector-local-logs'));
      expect(tester.widget<Switch>(capture).value, true);
      expect(tester.widget<Switch>(share).value, true);

      await tester.tap(share);
      await tester.pump();
      expect((inspector.snapshot()['localLogs'] as Map)['enabled'], false);
      await tester.tap(capture);
      await tester.pump();
      expect(inspector.enabled, false);
      controller.setDebugTrafficLoggingEnabled(false);
      expect(inspector.sqliteDetailsEnabled, false);
      expect(controller.debugTrafficLoggingEnabled, false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
