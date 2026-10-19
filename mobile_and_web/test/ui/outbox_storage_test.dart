import 'package:chat_workspace/core/exports.dart';
import 'package:chat_workspace/ui/chat_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';

import 'fake_chat_controller.dart';

class _FullStorageController extends FakeChatController {
  @override
  Future<bool> sendText(
    String text, {
    ChatMessage? replyTo,
    MessageSendContext? context,
  }) async => false;
}

void main() {
  testWidgets(
    'unsaved text remains recoverable when the package composer clears',
    (tester) async {
      final controller = _FullStorageController()..openFixture();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatControllerProvider.overrideWith((ref) => controller)],
          child: const ChatApp(),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(VMessageInputWidget),
        matching: find.byType(EditableText),
      );
      await tester.enterText(input, 'Preserve this unsaved message');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      final recovery = tester.widget<SelectableText>(
        find.byKey(const Key('unsaved-message-text')),
      );
      expect(recovery.data, 'Preserve this unsaved message');
      expect(find.text('Copy unsaved text'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await controller.database.close();
    },
  );
}
