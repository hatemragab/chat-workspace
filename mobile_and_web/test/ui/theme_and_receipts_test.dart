import 'package:chat_workspace/core/exports.dart';
import 'package:chat_workspace/ui/auth_screen.dart';
import 'package:chat_workspace/ui/chat_app.dart';
import 'package:chat_workspace/ui/chat_shell.dart';
import 'package:chat_workspace/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v_chat_bubbles/v_chat_bubbles.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';

import 'fake_chat_controller.dart';

Future<void> mount(
  WidgetTester tester,
  FakeChatController controller, {
  Brightness? brightness,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [chatControllerProvider.overrideWith((ref) => controller)],
      child: brightness == null
          ? const ChatApp()
          : MaterialApp(
              theme: buildChatTheme(brightness: brightness),
              home: const ChatShell(),
            ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await controller.database.close();
  });
}

void main() {
  testWidgets('authentication defaults to dark even on a light system', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await mount(tester, FakeChatController(authenticated: false));
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final context = tester.element(find.byType(AuthScreen));
    expect(app.themeMode, ThemeMode.dark);
    expect(app.theme!.brightness, Brightness.light);
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(
      Theme.of(context).scaffoldBackgroundColor.computeLuminance(),
      lessThan(.05),
    );
    final input = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('auth-email')),
        matching: find.byType(EditableText),
      ),
    );
    expect(input.style.color!.computeLuminance(), greaterThan(.7));
    expect(
      Theme.of(context).inputDecorationTheme.fillColor!.computeLuminance(),
      lessThan(.05),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark chat, composer and dialogs use dark surfaces', (
    tester,
  ) async {
    final controller = FakeChatController()..openFixture();
    await mount(tester, controller);
    final context = tester.element(find.byType(VMessageInputWidget));
    final palette = ChatColors.of(context);
    final inputTheme = Theme.of(context).extension<VInputTheme>()!;
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(inputTheme.containerDecoration.color, palette.surface);
    expect(inputTheme.textFieldTextStyle.color, palette.ink);
    expect(
      (inputTheme.attachmentTheme.panelDecoration as BoxDecoration).color!
          .computeLuminance(),
      lessThan(.05),
    );
    expect(
      tester.widget<Container>(find.byKey(const Key('message-composer'))).color,
      palette.surface,
    );
    final bubbles = tester.widget<VBubbleScope>(find.byType(VBubbleScope));
    expect(bubbles.theme!.incomingBubbleColor.computeLuminance(), lessThan(.1));
    expect(bubbles.theme!.textColor(false).computeLuminance(), greaterThan(.7));
    await tester.tap(find.byKey(const Key('new-chat')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Dialog))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('receipt icons stay distinct in ${brightness.name} mode', (
      tester,
    ) async {
      final controller = FakeChatController()..openFixture();
      final sent = ChatMessage.fromJson({
        ...controller.messages.single.toJson(),
        'deliveredAt': null,
        'seenAt': null,
      });
      await mount(tester, controller, brightness: brightness);
      final states = [
        (sent, Icons.check, ChatColors.delivered, 'Message sent'),
        (
          sent.copyWith(deliveredAt: DateTime.utc(2026, 10, 16, 12, 1)),
          Icons.done_all,
          ChatColors.delivered,
          'Message delivered',
        ),
        (
          sent.copyWith(seenAt: DateTime.utc(2026, 10, 16, 12, 2)),
          Icons.done_all,
          ChatColors.seen,
          'Message seen',
        ),
        (
          ChatMessage.fromJson({
            ...sent.toJson(),
            'messageSeq': 1,
            'deliveredByCursor': true,
          }),
          Icons.done_all,
          ChatColors.delivered,
          'Message delivered',
        ),
        (
          ChatMessage.fromJson({
            ...sent.toJson(),
            'messageSeq': 1,
            'seenByCursor': true,
          }),
          Icons.done_all,
          ChatColors.seen,
          'Message seen',
        ),
      ];
      for (final (message, icon, color, label) in states) {
        controller.publishMessages([message]);
        controller.publishRooms([
          ChatRoom.fromJson({
            ...controller.selectedRoom!.toJson(),
            'lastMessage': message.toJson(),
          }),
        ]);
        await tester.pumpAndSettle();
        final preview = find.byKey(const Key('room-preview-status-room-1'));
        final previewIcon = tester.widget<Icon>(
          find.descendant(of: preview, matching: find.byType(Icon)),
        );
        expect(previewIcon.icon, icon);
        expect(previewIcon.color, color);
        expect(tester.widget<Semantics>(preview).properties.label, label);
        final bubble = find.byType(VTextBubble);
        final receipt = find.descendant(
          of: bubble,
          matching: find.byIcon(icon),
        );
        expect(receipt, findsOneWidget);
        expect(tester.widget<Icon>(receipt).color, color);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
