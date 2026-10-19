import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:chat_workspace/core/exports.dart';
import 'package:chat_workspace/ui/chat_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';
import 'package:v_platform/v_platform.dart';

import 'fake_chat_controller.dart';

Finder _input() => find.descendant(
  of: find.byType(VMessageInputWidget),
  matching: find.byType(EditableText),
);

Future<void> _mount(WidgetTester tester, FakeChatController controller) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [chatControllerProvider.overrideWith((ref) => controller)],
      child: const ChatApp(),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await controller.database.close();
  });
}

void _expectDraft(
  WidgetTester tester, {
  required State<StatefulWidget> originalComposer,
  required EditableText originalInput,
  required String text,
}) {
  final input = tester.widget<EditableText>(_input());
  expect(
    tester.state(find.byType(VMessageInputWidget)),
    same(originalComposer),
  );
  expect(input.controller, same(originalInput.controller));
  expect(input.focusNode, same(originalInput.focusNode));
  expect(input.controller.text, text);
  expect(input.focusNode.hasFocus, isTrue);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'focused text field keeps its semantics identity as the send button toggles',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      await _mount(tester, controller);
      await tester.tap(_input());
      await tester.pumpAndSettle();

      final initialInput = tester.widget<EditableText>(_input());
      expect(initialInput.focusNode.hasFocus, isTrue);
      final initialNode = tester.getSemantics(_input());
      final initialNodeId = initialNode.id;
      expect(initialNode.flagsCollection.isTextField, isTrue);
      expect(initialNode.flagsCollection.isFocused, Tristate.isTrue);
      expect(initialNode.getSemanticsData().value, isEmpty);
      expect(find.byTooltip('Send message'), findsNothing);

      for (final text in ['f', '']) {
        tester.testTextInput.enterText(text);
        await tester.pumpAndSettle();
        final node = tester.getSemantics(_input());
        expect(
          node.id,
          initialNodeId,
          reason:
              'Showing or hiding Send must not replace the editable '
              'semantics node used by the browser text input.',
        );
        expect(node.flagsCollection.isTextField, isTrue);
        expect(node.flagsCollection.isFocused, Tristate.isTrue);
        expect(node.getSemanticsData().value, text);
        final input = tester.widget<EditableText>(_input());
        expect(input.controller, same(initialInput.controller));
        expect(input.controller.text, text);
        expect(input.focusNode, same(initialInput.focusNode));
        expect(input.focusNode.hasFocus, isTrue);
        expect(
          find.byTooltip('Send message'),
          text.isEmpty ? findsNothing : findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first typed draft and focus survive initial subscription completing',
    (tester) async {
      final controller = FakeChatController()
        ..openFixture()
        ..connectionStatus = 'Connecting';
      await _mount(tester, controller);
      final originalComposer = tester.state(find.byType(VMessageInputWidget));
      await tester.enterText(_input(), 'Keep my first input');
      await tester.pumpAndSettle();
      final originalInput = tester.widget<EditableText>(_input());
      expect(originalInput.focusNode.hasFocus, isTrue);

      controller.connectionStatus = 'Subscribed';
      controller.publishMessages(controller.messages);
      await tester.pumpAndSettle();

      expect(find.textContaining('Realtime Connecting.'), findsNothing);
      _expectDraft(
        tester,
        originalComposer: originalComposer,
        originalInput: originalInput,
        text: 'Keep my first input',
      );
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(controller.sentText, 'Keep my first input');
    },
  );

  testWidgets('a connection warning never replaces the focused composer', (
    tester,
  ) async {
    final controller = FakeChatController()..openFixture();
    await _mount(tester, controller);
    final originalComposer = tester.state(find.byType(VMessageInputWidget));
    await tester.enterText(_input(), 'Keep this reconnect draft');
    await tester.pumpAndSettle();
    final originalInput = tester.widget<EditableText>(_input());

    for (final status in ['Disconnected', 'Connecting', 'Connected']) {
      controller.connectionStatus = status;
      controller.publishMessages(controller.messages);
      await tester.pumpAndSettle();
      _expectDraft(
        tester,
        originalComposer: originalComposer,
        originalInput: originalInput,
        text: 'Keep this reconnect draft',
      );
    }
  });

  for (final status in ['Connected', 'Disconnected']) {
    testWidgets('attachment progress preserves the composer while $status', (
      tester,
    ) async {
      final gate = Completer<void>();
      final controller = FakeChatController()
        ..openFixture()
        ..connectionStatus = status
        ..imageSendGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await _mount(tester, controller);
      final originalComposer = tester.state(find.byType(VMessageInputWidget));
      await tester.enterText(_input(), 'Keep the next text message');
      await tester.pumpAndSettle();
      final originalInput = tester.widget<EditableText>(_input());

      tester
          .widget<VMessageInputWidget>(find.byType(VMessageInputWidget))
          .onSubmitMedia([
            VPlatformFile.fromBytes(
              name: 'photo.png',
              bytes: [137, 80, 78, 71, 13, 10, 26, 10],
            ),
          ]);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      _expectDraft(
        tester,
        originalComposer: originalComposer,
        originalInput: originalInput,
        text: 'Keep the next text message',
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      _expectDraft(
        tester,
        originalComposer: originalComposer,
        originalInput: originalInput,
        text: 'Keep the next text message',
      );
      expect(controller.sentImages, ['photo.png']);
    });
  }
}
