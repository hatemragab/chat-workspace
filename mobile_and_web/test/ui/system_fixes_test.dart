import 'package:chat_workspace/ui/auth_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_flows_test.dart' show mount;
import 'fake_chat_controller.dart';

void main() {
  testWidgets(
    'ordinary state changes reuse MaterialApp theme and do not rebuild auth shell',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      await mount(tester, controller);
      final before = tester.widget<MaterialApp>(find.byType(MaterialApp));
      controller.debugInspector.setEnabled(true);
      controller.clearError();
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final after = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(identical(before.theme, after.theme), true);
      expect(identical(before.darkTheme, after.darkTheme), true);
      expect(
        (controller.debugInspector.snapshot()['builds'] as Map)['ChatApp'],
        isNull,
      );
    },
  );

  testWidgets(
    'expired session keeps cached chat and exposes accessible reauthentication',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      controller.requiresReauthentication = true;
      await mount(tester, controller);
      expect(
        find.textContaining('Saved messages and pending images are retained'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('message-actions-message-1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('reauthenticate')));
      await tester.pumpAndSettle();
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byKey(const Key('auth-email')), findsOneWidget);
      expect(find.byKey(const Key('auth-password')), findsOneWidget);
    },
  );
}
