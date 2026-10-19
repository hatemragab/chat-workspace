import 'dart:async';

import 'package:chat_workspace/core/exports.dart';
import 'package:chat_workspace/ui/chat_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';
import 'package:v_chat_bubbles/v_chat_bubbles.dart';

import 'fake_chat_controller.dart';

Future<void> mount(WidgetTester tester, FakeChatController controller) async {
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

void main() {
  testWidgets('people picker opens a draft without inserting an inbox room', (
    tester,
  ) async {
    final controller = FakeChatController();
    await mount(tester, controller);
    await tester.tap(find.byKey(const Key('new-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('person-user-2')));
    await tester.pumpAndSettle();
    expect(controller.openedDrafts, 1);
    expect(controller.rooms, isEmpty);
    expect(find.byKey(const Key('conversation-title')), findsOneWidget);
    expect(find.text('Say hello to User 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group creation validates title and selected participants', (
    tester,
  ) async {
    await mount(tester, FakeChatController());
    await tester.tap(find.byKey(const Key('new-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-group-submit')));
    await tester.pumpAndSettle();
    expect(
      find.text('Add a group name and choose at least one person.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply sends snapshot through the required composer', (
    tester,
  ) async {
    final controller = FakeChatController()..openFixture();
    await mount(tester, controller);
    await tester.tap(find.byKey(const Key('message-actions-message-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.text('Reply to User 1'), findsOneWidget);
    final input = find.descendant(
      of: find.byType(VMessageInputWidget),
      matching: find.byType(EditableText),
    );
    await tester.enterText(input, 'A thoughtful reply');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(controller.sentText, 'A thoughtful reply');
    expect(controller.repliedTo?.id, 'message-1');
    expect(find.text('Reply to User 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit and delete for me are distinct message actions', (
    tester,
  ) async {
    final controller = FakeChatController()..openFixture();
    await mount(tester, controller);
    await tester.tap(find.byKey(const Key('message-actions-message-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit message'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('edit-message-text')),
      'Edited message',
    );
    await tester.tap(find.byKey(const Key('save-message-edit')));
    await tester.pumpAndSettle();
    expect(controller.messages.single.text, 'Edited message');
    expect(controller.messages.single.isEdited, isTrue);
    await tester.tap(find.byKey(const Key('message-actions-message-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete for me'));
    await tester.pumpAndSettle();
    expect(controller.deletedMessages, ['message-1']);
    expect(controller.deletedForEveryone, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact layout offers a route back to inbox', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeChatController()..openFixture();
    await mount(tester, controller);
    expect(find.byTooltip('Back to conversations'), findsOneWidget);
    expect(find.byKey(const Key('conversation-title')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'connected state stays clear and room preferences call distinct mutations',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      await mount(tester, controller);
      expect(find.textContaining('Messages will recover'), findsNothing);
      await tester.tap(find.byKey(const Key('pin-chat')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mute-chat')));
      await tester.pumpAndSettle();
      expect(controller.preferenceChanges, [
        'room-1:pin=true:mute=null',
        'room-1:pin=null:mute=true',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'diagnostics display a read-only SQLite snapshot without token fields',
    (tester) async {
      final controller = FakeChatController();
      await mount(tester, controller);
      await tester.tap(find.byKey(const Key('sync-diagnostics')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('diagnostics-data')), findsOneWidget);
      await tester.ensureVisible(find.text('SQLite database rows'));
      await tester.tap(find.text('SQLite database rows'));
      await tester.pumpAndSettle();
      final snapshot = tester
          .widget<SelectableText>(find.byKey(const Key('sqlite-rows')))
          .data!;
      expect(snapshot, contains('localPts'));
      expect(snapshot, contains('7'));
      expect(snapshot, isNot(contains('accessToken')));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cached reply jump waits for the expanded message window before scrolling and highlighting',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      final old = fixtureMessage(
        'old-target',
        'An older cached message',
        age: 100,
      );
      final recent = List.generate(
        50,
        (i) => fixtureMessage('recent-$i', 'Recent message $i', age: i),
      );
      final reply = ChatMessage.fromJson({
        ...recent.first.toJson(),
        'replyTo': ReplySnapshot.fromMessage(old).toJson(),
      });
      controller.messages = [reply, ...recent.skip(1)];
      controller.jumpResults = [...controller.messages, old];
      controller.jumpDelay = const Duration(milliseconds: 100);
      await mount(tester, controller);
      final scope = tester.widget<VBubbleScope>(find.byType(VBubbleScope));
      scope.callbacks.onReplyPreviewTap!(old.id);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      final bubble = find.byWidgetPredicate(
        (w) => w is VTextBubble && w.messageId == old.id,
      );
      expect(controller.requestedJump, old.id);
      expect(bubble, findsOneWidget);
      expect(tester.widget<VTextBubble>(bubble).isHighlighted, isTrue);
      final bounds = tester.getRect(bubble);
      final viewport = tester.getRect(find.byKey(const Key('messages-scroll')));
      expect(
        bounds.overlaps(viewport),
        isTrue,
        reason: 'The expanded cached target must actually be in view.',
      );
      await tester.pump(const Duration(milliseconds: 1501));
      expect(tester.widget<VTextBubble>(bubble).isHighlighted, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'around reply jump renders live edits and deletion then returns to latest messages',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      final target = fixtureMessage(
        'around-target',
        'Original historical text',
        age: 500,
      );
      final latest = ChatMessage.fromJson({
        ...controller.messages.single.toJson(),
        'replyTo': ReplySnapshot.fromMessage(target).toJson(),
      });
      controller.messages = [latest];
      controller.latestMessages = [latest];
      controller.jumpResults = [target];
      controller.jumpUsesAround = true;
      await mount(tester, controller);
      tester
          .widget<VBubbleScope>(find.byType(VBubbleScope))
          .callbacks
          .onReplyPreviewTap!(target.id);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('return-to-latest')), findsOneWidget);
      expect(
        tester
            .widget<VTextBubble>(
              find.byWidgetPredicate(
                (w) => w is VTextBubble && w.messageId == target.id,
              ),
            )
            .text,
        'Original historical text',
      );
      final edited = ChatMessage.fromJson({
        ...target.toJson(),
        'text': 'Live historical edit',
        'isEdited': true,
      });
      controller.publishMessages([edited]);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VTextBubble>(
              find.byWidgetPredicate(
                (w) => w is VTextBubble && w.messageId == target.id,
              ),
            )
            .text,
        'Live historical edit',
      );
      expect(find.text('Original historical text'), findsNothing);
      controller.publishMessages([
        ChatMessage.fromJson({
          ...edited.toJson(),
          'isDeletedForAll': true,
          'text': 'This message was deleted',
        }),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(VDeletedBubble), findsOneWidget);
      expect(find.text('Live historical edit'), findsNothing);
      await tester.tap(find.byKey(const Key('return-to-latest')));
      await tester.pumpAndSettle();
      expect(controller.returnToLatestCalls, 1);
      expect(find.byKey(const Key('return-to-latest')), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is VTextBubble && w.messageId == latest.id,
        ),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image attachment validation and upload failure leave the composer usable',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      await mount(tester, controller);
      var composer = tester.widget<VMessageInputWidget>(
        find.byType(VMessageInputWidget),
      );
      composer.onSubmitMedia([
        VPlatformFile.fromBytes(name: 'not-an-image.txt', bytes: [65, 66]),
      ]);
      await tester.pumpAndSettle();
      expect(controller.sentImages, isEmpty);
      expect(
        find.text('Choose a JPEG, PNG, WebP, or GIF image up to 5 MB.'),
        findsOneWidget,
      );
      tester
          .widget<VBubbleScope>(find.byType(VBubbleScope))
          .callbacks
          .onSwipeReply!('message-1');
      await tester.pumpAndSettle();
      controller.failImageSend = true;
      composer = tester.widget<VMessageInputWidget>(
        find.byType(VMessageInputWidget),
      );
      composer.onSubmitMedia([
        VPlatformFile.fromBytes(
          name: 'photo.png',
          bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(controller.sentImages, ['photo.png']);
      expect(find.text('Image upload failed'), findsOneWidget);
      expect(find.text('Reply to User 1'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      final input = find.descendant(
        of: find.byType(VMessageInputWidget),
        matching: find.byType(EditableText),
      );
      await tester.enterText(input, 'Still able to type');
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(input).controller.text,
        'Still able to type',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a pending image cannot clear a reply cancelled and reselected meanwhile',
    (tester) async {
      final gate = Completer<void>();
      final controller = FakeChatController()
        ..openFixture()
        ..imageSendGate = gate;
      await mount(tester, controller);
      void chooseReply() => tester
          .widget<VBubbleScope>(find.byType(VBubbleScope))
          .callbacks
          .onSwipeReply!('message-1');
      chooseReply();
      await tester.pump();
      tester
          .widget<VMessageInputWidget>(find.byType(VMessageInputWidget))
          .onSubmitMedia([
            VPlatformFile.fromBytes(
              name: 'photo.png',
              bytes: [137, 80, 78, 71, 13, 10, 26, 10],
            ),
          ]);
      await tester.pump();
      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pump();
      chooseReply();
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(controller.sentImages, ['photo.png']);
      expect(find.text('Reply to User 1'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed uploaded image retries the existing message instead of selecting the file again',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      final failed = fixtureMessage(
        'failed-image',
        'Photo awaiting retry',
        type: 'image',
        status: 'failed',
      );
      controller.messages = [failed];
      await mount(tester, controller);
      await tester.tap(find.text('Not sent · Retry'));
      await tester.pumpAndSettle();
      expect(controller.retriedMessages, ['failed-image']);
      expect(controller.messages.single.status, 'sent');
      expect(controller.sentImages, isEmpty);
      expect(find.text('Not sent · Retry'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'character-by-character platform input retains the first letter through parent rebuilds',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      await mount(tester, controller);
      final input = find.descendant(
        of: find.byType(VMessageInputWidget),
        matching: find.byType(EditableText),
      );
      await tester.showKeyboard(input);
      for (final text in ['H', 'He', 'Hel', 'Hell', 'Hello']) {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
        await tester.pump();
        controller.publishMessages(List.of(controller.messages));
        await tester.pump();
        final field = tester.widget<EditableText>(input);
        expect(field.controller.text, text);
        expect(field.focusNode.hasFocus, isTrue);
      }
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(controller.sentText, 'Hello');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'inbox preview shows sending clock and failure instead of sent receipts',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      final outgoing = controller.messages.single;
      final room = controller.selectedRoom!;
      controller.rooms = [
        ChatRoom.fromJson({
          ...room.toJson(),
          'lastMessage': outgoing.copyWith(status: 'sending').toJson(),
        }),
      ];
      await mount(tester, controller);
      final status = find.byKey(const Key('room-preview-status-room-1'));
      expect(
        find.descendant(
          of: status,
          matching: find.byIcon(Icons.schedule_outlined),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Semantics>(status).properties.label,
        'Sending message',
      );
      controller.publishRooms([
        ChatRoom.fromJson({
          ...room.toJson(),
          'lastMessage': outgoing.copyWith(status: 'failed').toJson(),
        }),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: status, matching: find.byIcon(Icons.error_outline)),
        findsOneWidget,
      );
      expect(
        tester.widget<Semantics>(status).properties.label,
        'Message not sent',
      );
      expect(
        find.descendant(of: status, matching: find.byIcon(Icons.done_all)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

ChatMessage fixtureMessage(
  String id,
  String text, {
  int age = 0,
  String type = 'text',
  String status = 'sent',
}) => ChatMessage(
  id: id,
  idempotencyKey: 'key-$id',
  roomId: 'room-1',
  senderId: 'user-2',
  senderName: 'User 2',
  type: type,
  text: text,
  status: status,
  createdAt: DateTime.utc(2026, 10, 16, 12).subtract(Duration(minutes: age)),
);
