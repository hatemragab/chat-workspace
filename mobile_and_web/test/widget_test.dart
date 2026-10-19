import 'package:chat_workspace/core/exports.dart';
import 'package:chat_workspace/ui/chat_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/fake_chat_controller.dart';

void main() {
  testWidgets(
    'startup exposes five debug accounts and validates normal login',
    (tester) async {
      final controller = FakeChatController(authenticated: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatControllerProvider.overrideWith((ref) => controller)],
          child: const ChatApp(),
        ),
      );
      await tester.pumpAndSettle();
      for (var number = 1; number <= 5; number++) {
        expect(find.byKey(Key('debug-user-$number')), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(find.text('Use at least 8 characters'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('debug-user-2')));
      await tester.tap(find.byKey(const Key('debug-user-2')));
      await tester.pumpAndSettle();
      expect(controller.debugNumber, 2);
      expect(find.byKey(const Key('inbox-app-bar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
