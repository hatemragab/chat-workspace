import 'package:chat_workspace/core/exports.dart';
import 'package:chat_workspace/ui/chat_shell.dart';
import 'package:chat_workspace/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_controller.dart';

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> mount(
  WidgetTester tester,
  FakeChatController controller, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [chatControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        theme: buildChatTheme(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
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
  for (final draft in [false, true]) {
    testWidgets(
      'system Back closes ${draft ? 'a draft' : 'a room'} before exiting',
      (tester) async {
        setSize(tester, const Size(375, 812));
        final controller = FakeChatController()..openFixture();
        if (draft) await controller.openDirect(FakeChatController.peer);
        final platformCalls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            platformCalls.add(call.method);
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });
        await mount(tester, controller);
        final route = ModalRoute.of(tester.element(find.byType(ChatShell)))!;
        expect(route.popDisposition, RoutePopDisposition.doNotPop);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(controller.selectedRoom, isNull);
        expect(controller.draftPeer, isNull);
        expect(find.byKey(const Key('rooms-list')), findsOneWidget);
        expect(platformCalls, isNot(contains('SystemNavigator.pop')));
        expect(route.popDisposition, RoutePopDisposition.bubble);
        await tester.binding.handlePopRoute();
        expect(platformCalls, contains('SystemNavigator.pop'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Back dismisses the conversation menu before closing the room', (
    tester,
  ) async {
    setSize(tester, const Size(375, 812));
    final controller = FakeChatController()..openFixture();
    await mount(tester, controller);
    await tester.tap(find.byTooltip('Conversation options'));
    await tester.pumpAndSettle();
    expect(find.text('Pin chat'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Pin chat'), findsNothing);
    expect(controller.selectedRoom, isNotNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(controller.selectedRoom, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Material AppBar Back restores the inbox search and filter state',
    (tester) async {
      setSize(tester, const Size(375, 812));
      final controller = FakeChatController()..openFixture();
      final room = controller.selectedRoom!;
      controller.selectedRoom = null;
      await mount(tester, controller);
      await tester.enterText(
        find.byKey(const Key('search-conversations')),
        ' user 2 ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('room-${room.roomId}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation-app-bar')), findsOneWidget);
      await tester.tap(find.byTooltip('Back to conversations'));
      await tester.pumpAndSettle();
      final search = tester.widget<TextField>(
        find.byKey(const Key('search-conversations')),
      );
      expect(search.controller!.text, ' user 2 ');
      expect(controller.selectedRoom, isNull);
      expect(find.byType(AppBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact conversation menu preserves pin and mute actions', (
    tester,
  ) async {
    setSize(tester, const Size(375, 812));
    final controller = FakeChatController()..openFixture();
    await mount(tester, controller);
    for (final action in ['pin-chat', 'mute-chat']) {
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(action)));
      await tester.pumpAndSettle();
    }
    expect(controller.preferenceChanges, [
      'room-1:pin=true:mute=null',
      'room-1:pin=null:mute=true',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty filtered inbox can clear its search and unread filter', (
    tester,
  ) async {
    setSize(tester, const Size(375, 812));
    final controller = FakeChatController()..openFixture();
    controller.selectedRoom = null;
    await mount(tester, controller);
    await tester.enterText(
      find.byKey(const Key('search-conversations')),
      'Nobody',
    );
    await tester.tap(find.text('Unread'));
    await tester.pumpAndSettle();
    expect(find.text('No matching conversations'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-room-1')), findsOneWidget);
    expect(find.byTooltip('Clear search'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull to refresh synchronizes even a short inbox', (
    tester,
  ) async {
    setSize(tester, const Size(375, 812));
    final controller = FakeChatController()..openFixture();
    controller.selectedRoom = null;
    await mount(tester, controller);
    await tester.drag(
      find.byKey(const Key('rooms-list')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(controller.syncs, 1);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(320, 640),
      const Size(375, 812),
      const Size(844, 390),
      const Size(1024, 768),
    ]) {
      testWidgets('${brightness.name} layout at $size supports large text', (
        tester,
      ) async {
        setSize(tester, size);
        final controller = FakeChatController()..openFixture();
        final room = ChatRoom.fromJson({
          ...controller.selectedRoom!.toJson(),
          'displayTitle': 'A conversation with a particularly long name',
        });
        controller.selectedRoom = room;
        controller.rooms = [room];
        await mount(tester, controller, brightness: brightness, textScale: 2);
        expect(find.byKey(const Key('conversation-title')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('inbox-app-bar')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
