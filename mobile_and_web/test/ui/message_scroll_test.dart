import 'package:chat_workspace/core/exports.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:v_chat_bubbles/v_chat_bubbles.dart';

import 'chat_flows_test.dart' show mount;
import 'fake_chat_controller.dart';

ChatMessage _message(int index) => ChatMessage(
  id: 'scroll-$index',
  idempotencyKey: 'scroll-key-$index',
  roomId: 'room-1',
  senderId: FakeChatController.me.id,
  senderName: FakeChatController.me.displayName,
  type: 'text',
  text: 'Chat message $index',
  createdAt: DateTime.utc(2026, 10, 16, 12, index),
);

Finder _bubble(int index) => find.byWidgetPredicate(
  (widget) => widget is VTextBubble && widget.messageId == 'scroll-$index',
);

Finder get _scroll => find.byKey(const Key('messages-scroll'));

void main() {
  for (final size in [const Size(1200, 900), const Size(390, 844)]) {
    testWidgets('short chat starts at the bottom at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FakeChatController()..openFixture();
      controller.messages = [_message(2), _message(1)];
      await mount(tester, controller);

      final viewport = tester.getRect(_scroll);
      final canvas = tester.getRect(
        find.ancestor(of: _scroll, matching: find.byType(Stack)).first,
      );
      final oldest = tester.getRect(_bubble(1));
      final newest = tester.getRect(_bubble(2));
      expect(viewport, canvas);
      expect(newest.bottom, greaterThan(viewport.bottom - 64));
      expect(newest.bottom, lessThan(viewport.bottom));
      expect(oldest.bottom, lessThan(newest.top));
      expect(tester.widget<CustomScrollView>(_scroll).reverse, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new messages grow upward from the latest edge', (tester) async {
    final controller = FakeChatController()..openFixture();
    controller.messages = [_message(1)];
    await mount(tester, controller);
    final originalBottom = tester.getRect(_bubble(1)).bottom;

    controller.publishMessages([_message(2), _message(1)]);
    await tester.pumpAndSettle();
    expect(tester.getRect(_bubble(2)).bottom, closeTo(originalBottom, 1));
    expect(
      tester.getRect(_bubble(1)).bottom,
      lessThan(tester.getRect(_bubble(2)).top),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short historical slice stays above Return to Latest', (
    tester,
  ) async {
    final controller = FakeChatController()..openFixture();
    controller.messages = [_message(1)];
    controller.isJumpMode = true;
    await mount(tester, controller);

    final target = tester.getRect(_bubble(1));
    final button = tester.getRect(find.byKey(const Key('return-to-latest')));
    expect(target.bottom, lessThan(button.top));
    expect(target.overlaps(tester.getRect(_scroll)), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long chats open on the newest message and scroll toward history',
    (tester) async {
      final controller = FakeChatController()..openFixture();
      controller.messages = List.generate(40, (index) => _message(40 - index));
      await mount(tester, controller);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: _scroll, matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.pixels, 0);
      expect(
        tester.getRect(_bubble(40)).overlaps(tester.getRect(_scroll)),
        isTrue,
      );
      expect(_bubble(1), findsNothing, reason: 'Older rows are built lazily.');

      await tester.drag(_scroll, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
}
