import 'dart:async';
import 'dart:convert';

import 'package:chat_workspace/core/exports.dart';
import 'package:chat_workspace/ui/chat_app.dart';
import 'package:chat_workspace/ui/dialogs.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v_chat_bubbles/v_chat_bubbles.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';

final _instant = DateTime.utc(2026, 10, 16, 12);
final _room = ChatRoom(
  roomId: 'cached-room',
  roomType: 'direct',
  peerUserId: 'cached-peer',
  displayTitle: 'Cached Peer',
  sortTimestamp: _instant,
  roomPts: 7,
  msgPts: 7,
);

ChatMessage _message(String id, String text, String status, int seconds) =>
    ChatMessage(
      id: id,
      idempotencyKey: 'key-$id',
      roomId: _room.roomId,
      senderId: 'me',
      senderName: 'Me',
      type: 'text',
      text: text,
      status: status,
      createdAt: _instant.add(Duration(seconds: seconds)),
    );

class _OfflineApi extends ChatApi {
  _OfflineApi() : super(enableHttpLogging: false);
  final inboxGate = Completer<void>();
  final directoryGate = Completer<void>();
  final directGate = Completer<void>();
  final firstSendGate = Completer<void>();
  final sentBodies = <Map<String, dynamic>>[];
  bool inboxStarted = false, inboxFinished = false, directoryStarted = false;

  @override
  Future<({List<UserProfile> users, String? nextCursor})> directoryPage({
    String? cursor,
  }) async => (users: await getUsers('/users'), nextCursor: null);
  @override
  Future<List<UserProfile>> getUsers(String path) async {
    if (path == '/auth/debug-users') return [];
    directoryStarted = true;
    await directoryGate.future;
    throw const ChatApiException('Cannot reach the chat server.');
  }

  @override
  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/rooms/delta') {
      inboxStarted = true;
      await inboxGate.future;
      inboxFinished = true;
    } else if (path.startsWith('/rooms/direct-peer/')) {
      await directGate.future;
    }
    throw const ChatApiException('Cannot reach the chat server.');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/presence/offline') return {'ok': true};
    if (path == '/messages') {
      sentBodies.add(Map.of(body!));
      if (sentBodies.length == 1) await firstSendGate.future;
      throw const ChatApiException(
        'The synthetic message is invalid.',
        statusCode: 400,
        kind: ChatFailureKind.validation,
      );
    }
    throw const ChatApiException('Cannot reach the chat server.');
  }

  void releaseRequests() {
    for (final gate in [inboxGate, directoryGate, directGate, firstSendGate]) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

class _TestDatabase extends AppDatabase {
  _TestDatabase() : super(NativeDatabase.memory());
  final closed = Completer<void>();

  @override
  Future<void> close() async {
    await super.close();
    if (!closed.isCompleted) closed.complete();
  }
}

class _Harness {
  final api = _OfflineApi();
  final db = _TestDatabase();
  late final ChatController controller;
  late final ProviderContainer scope;

  Future<void> mount(WidgetTester tester, {bool openRoom = true}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({
        'chat_session': jsonEncode({
          'user': {'id': 'me', 'username': 'me', 'displayName': 'Me'},
          'accessToken': 'synthetic-offline-token',
          'centrifugoToken': 'synthetic-realtime-token',
        }),
      });
      await db.initializeSession('me');
      await db.upsertRoom(_room);
      await db.upsertMessage(
        _message('sent', 'Cached sent message', 'sent', 0),
      );
      await db.upsertMessage(
        _message('failed', 'Cached failed message', 'failed', 1),
      );
      // Legacy interrupted failures remain manual, leaving the new-send lane
      // available for this widget's independent rejection/Retry regression.
      await db.upsertMessage(
        _message('interrupted', 'Interrupted pending message', 'failed', 2),
      );
      controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: () => ServerHealthMonitor(
          healthUri: Uri.parse('http://test.invalid/health'),
          probe: () async => false,
        ),
      );
      scope = ProviderContainer(
        overrides: [chatControllerProvider.overrideWith((ref) => controller)],
      );
      scope.read(chatControllerProvider);
    });
    addTearDown(() async {
      api.releaseRequests();
      await tester.pumpWidget(const SizedBox());
      final loggingOut = controller.logout();
      await _pumpUntil(tester, () => controller.currentUser == null);
      await loggingOut;
      await tester.runAsync(() async => scope.dispose());
      await _pumpUntil(tester, () => db.closed.isCompleted);
    });
    await tester.runAsync(() async {
      await controller.initialize().timeout(const Duration(seconds: 3));
      if (openRoom) {
        await controller.openRoom(_room).timeout(const Duration(seconds: 3));
      }
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: scope, child: const ChatApp()),
    );
    await _pumpUntil(
      tester,
      () => controller.rooms.any((room) => room.roomId == _room.roomId),
    );
    if (openRoom) {
      await _pumpUntil(
        tester,
        () => _bubble('Cached sent message').evaluate().isNotEmpty,
      );
    }
  }
}

Finder _input() => find.descendant(
  of: find.byType(VMessageInputWidget),
  matching: find.byType(EditableText),
);

Finder _bubble(String text) => find.byWidgetPredicate(
  (widget) => widget is VTextBubble && widget.text == text,
);

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var frame = 0; frame < 300; frame++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  throw StateError('The expected offline UI operation did not finish.');
}

void _expectCachedMessages(WidgetTester tester) {
  expect(_bubble('Cached sent message'), findsOneWidget);
  expect(_bubble('Cached failed message'), findsOneWidget);
  expect(_bubble('Interrupted pending message'), findsOneWidget);
  expect(
    tester.widget<VTextBubble>(_bubble('Cached sent message')).status,
    VMessageStatus.sent,
  );
  expect(
    tester.widget<VTextBubble>(_bubble('Cached failed message')).status,
    VMessageStatus.error,
  );
  expect(
    tester.widget<VTextBubble>(_bubble('Interrupted pending message')).status,
    VMessageStatus.error,
  );
  expect(find.text('Say hello to Cached Peer'), findsNothing);
}

void main() {
  testWidgets(
    'cached chat renders during stalled recovery and rejected sends remain visible and retryable',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(h.api.inboxStarted, isTrue);
      expect(h.api.inboxGate.isCompleted, isFalse);
      _expectCachedMessages(tester);
      expect(find.textContaining('Realtime Disconnected.'), findsOneWidget);

      await tester.enterText(_input(), 'A new offline message');
      await tester.pump();
      await tester.tap(find.byTooltip('Send message'));
      await _pumpUntil(
        tester,
        () =>
            h.api.sentBodies.length == 1 &&
            _bubble('A new offline message').evaluate().isNotEmpty,
      );
      expect(
        tester.widget<VTextBubble>(_bubble('A new offline message')).status,
        VMessageStatus.sending,
      );
      _expectCachedMessages(tester);

      await tester.enterText(_input(), 'Keep composing offline');
      await tester.pump();
      final composerState = tester.state(find.byType(VMessageInputWidget));
      h.api.firstSendGate.complete();
      await _pumpUntil(
        tester,
        () => h.controller.messages.any(
          (message) =>
              message.text == 'A new offline message' &&
              message.status == 'failed',
        ),
      );
      await tester.pump();
      expect(
        tester.widget<VTextBubble>(_bubble('A new offline message')).status,
        VMessageStatus.error,
      );
      expect(
        tester.state(find.byType(VMessageInputWidget)),
        same(composerState),
      );
      expect(
        tester.widget<EditableText>(_input()).controller.text,
        'Keep composing offline',
      );
      expect(tester.widget<EditableText>(_input()).focusNode.hasFocus, isTrue);

      final failed = h.controller.messages.singleWhere(
        (message) => message.text == 'A new offline message',
      );
      await tester.tap(find.byKey(Key('message-actions-${failed.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry sending'));
      await _pumpUntil(
        tester,
        () =>
            h.api.sentBodies.length == 2 &&
            h.controller.messages.any(
              (message) =>
                  message.id == failed.id && message.status == 'failed',
            ),
      );
      expect(
        h.api.sentBodies.last['idempotencyKey'],
        h.api.sentBodies.first['idempotencyKey'],
      );
      expect(h.api.inboxGate.isCompleted, isFalse);
      _expectCachedMessages(tester);
      expect(_bubble('A new offline message'), findsOneWidget);
      expect(
        tester.widget<EditableText>(_input()).controller.text,
        'Keep composing offline',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed recovery keeps cached rows and the focused draft onscreen',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await tester.enterText(_input(), 'First input while offline');
      await tester.pump();
      final composerState = tester.state(find.byType(VMessageInputWidget));
      h.api.inboxGate.complete();
      await _pumpUntil(tester, () => h.api.inboxFinished);
      await tester.pumpAndSettle();

      _expectCachedMessages(tester);
      expect(h.controller.currentUser?.id, 'me');
      expect(
        tester.state(find.byType(VMessageInputWidget)),
        same(composerState),
      );
      expect(
        tester.widget<EditableText>(_input()).controller.text,
        'First input while offline',
      );
      expect(tester.widget<EditableText>(_input()).focusNode.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached people stay selectable while the server directory is unavailable',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, openRoom: false);
      await tester.tap(find.byKey(const Key('new-chat')));
      await tester.pump();
      await _pumpUntil(tester, () => h.api.directoryStarted);

      expect(find.byType(PeopleDialog), findsOneWidget);
      expect(find.byKey(const Key('person-cached-peer')), findsOneWidget);
      expect(h.api.directoryGate.isCompleted, isFalse);
      await tester.tap(find.byKey(const Key('person-cached-peer')));
      await _pumpUntil(
        tester,
        () =>
            find.byType(PeopleDialog).evaluate().isEmpty &&
            _bubble('Cached sent message').evaluate().isNotEmpty,
      );

      _expectCachedMessages(tester);
      expect(h.controller.selectedRoom?.roomId, _room.roomId);
      expect(h.api.directoryGate.isCompleted, isFalse);
      expect(h.api.inboxGate.isCompleted, isFalse);
      expect(find.byType(VMessageInputWidget), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
