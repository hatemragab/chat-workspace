import 'package:chat_workspace/ui/presence_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_flows_test.dart' show mount;
import 'fake_chat_controller.dart';

void main() {
  testWidgets(
    'conversation header switches between last seen, online and offline without a timestamp',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      controller.offlineUserIds = {'user-2'};
      controller.lastSeenAtByUserId = {
        'user-2': DateTime(2026, 10, 18, 14, 5).toUtc(),
      };
      await mount(tester, controller);
      expect(find.textContaining('Last seen'), findsOneWidget);
      expect(find.textContaining('2026'), findsOneWidget);
      controller.onlineUserIds = {'user-2'};
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Online'), findsOneWidget);
      expect(find.textContaining('Last seen'), findsNothing);
      controller.onlineUserIds = {};
      controller.lastSeenAtByUserId = {};
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('people picker shows the same offline last-seen label', (
    tester,
  ) async {
    final controller = FakeChatController();
    controller.offlineUserIds = {'user-2'};
    controller.lastSeenAtByUserId = {
      'user-2': DateTime.utc(2026, 10, 18, 10, 15),
    };
    await mount(tester, controller);
    await tester.tap(find.byKey(const Key('new-chat')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last seen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('last seen uses local time and the device 24-hour preference', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: true),
          child: Builder(
            builder: (context) => Text(
              presenceLabel(
                context,
                online: false,
                lastSeenAt: DateTime(2026, 10, 18, 14, 5).toUtc(),
                unknownLabel: 'Unknown',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('14:05'), findsOneWidget);
    expect(find.textContaining('2026'), findsOneWidget);
  });
}
