import 'dart:async';
import 'dart:typed_data';

import 'package:chat_workspace/core/exports.dart';
import 'package:chat_workspace/ui/messages_pane.dart';
import 'package:chat_workspace/ui/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v_chat_bubbles/v_chat_bubbles.dart';
import 'package:v_chat_input_ui/v_chat_input_ui.dart';

final _instant = DateTime.utc(2026, 10, 16, 12);
const _peerA = UserProfile(id: 'peer-a', username: 'a', displayName: 'Peer A');
const _peerB = UserProfile(id: 'peer-b', username: 'b', displayName: 'Peer B');

ChatRoom _room(String id, {String peer = 'peer-a', int revision = 1}) =>
    ChatRoom(
      roomId: id,
      roomType: 'direct',
      peerUserId: peer,
      displayTitle: peer,
      sortTimestamp: _instant,
      roomPts: revision,
      msgPts: revision,
    );

ChatMessage _message(
  String id,
  String roomId, {
  String text = 'Existing message',
}) => ChatMessage(
  id: id,
  idempotencyKey: id,
  roomId: roomId,
  senderId: 'peer-a',
  senderName: 'Peer A',
  type: 'text',
  text: text,
  createdAt: _instant,
);

// The widget exercises the actual controller, inbox queue, REST reconciliation,
// and SQLite. Only the remote API is controlled to stop at real async boundaries.
class _SendApi extends ChatApi {
  final sent = <Map<String, dynamic>>[];
  final uploads = <String>[];
  String account = 'me';
  Completer<void>? uploadGate, latestGate, sendGate;
  final uploadStarted = Completer<void>.sync();
  final latestStarted = Completer<void>.sync();
  final sendStarted = Completer<void>.sync();
  final _pendingGates = <Completer<void>>{};

  Future<void> _waitForGate(Completer<void> gate) async {
    _pendingGates.add(gate);
    try {
      await gate.future;
    } finally {
      _pendingGates.remove(gate);
    }
  }

  void releaseRequests() {
    for (final gate in [..._pendingGates, uploadGate, latestGate, sendGate]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<({List<UserProfile> users, String? nextCursor})> directoryPage({
    String? cursor,
  }) async => (users: await getUsers('/users'), nextCursor: null);
  @override
  Future<List<UserProfile>> getUsers(String path) async => [];

  @override
  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/rooms/delta') {
      return {
        'requiresFullSync': false,
        'pts': 0,
        'epoch': 'test-epoch',
        'rooms': [],
      };
    }
    if (path.startsWith('/rooms/direct-peer/')) return {'room': null};
    if (path.contains('/messages/around/')) {
      return {
        'messages': [_message('historical', 'room-a').toJson()],
      };
    }
    if (path.endsWith('/messages')) {
      if (latestGate != null) {
        final gate = latestGate!;
        latestGate = null;
        latestStarted.complete();
        await _waitForGate(gate);
      }
      return {
        'messages': [
          _message('latest-${path.split('/')[2]}', path.split('/')[2]).toJson(),
        ],
        'hasMore': false,
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<String> uploadImage(Uint8List bytes, String filename) async {
    uploads.add(filename);
    if (uploads.length == 1 && uploadGate != null) {
      uploadStarted.complete();
      await _waitForGate(uploadGate!);
    }
    return '/public/uploads/$filename';
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/auth/debug-login') {
      account = body!['debugUserNumber'] == 1 ? 'me' : 'other';
      return {
        'user': {'id': account, 'username': account, 'displayName': account},
        'accessToken': 'test-token',
        'centrifugoToken': 'test-realtime-token',
      };
    }
    if (path != '/messages') return {'ok': true};
    final sender = account;
    sent.add(Map.of(body!));
    final index = sent.length;
    if (sendGate != null && index == 1) {
      sendStarted.complete();
      await _waitForGate(sendGate!);
    }
    final roomId = body['roomId'] as String? ?? 'server-room';
    final message = {
      ...body,
      'id': 'server-$index',
      'roomId': roomId,
      'senderId': sender,
      'senderName': sender,
      'createdAt': _instant.add(Duration(seconds: index)).toIso8601String(),
    };
    return {
      'message': message,
      'room': {
        ..._room(
          roomId,
          peer:
              body['peerUserId'] as String? ??
              (roomId == 'room-b' ? 'peer-b' : 'peer-a'),
          revision: index + 10,
        ).toJson(),
        'lastMessage': message,
        'eventType': 'message_new',
      },
    };
  }
}

class _TestDatabase extends AppDatabase {
  _TestDatabase() : super(NativeDatabase.memory());
  final closed = Completer<void>.sync();
  @override
  Future<void> close() async {
    await super.close();
    if (!closed.isCompleted) closed.complete();
  }
}

class _Harness {
  _Harness(this.api) : db = _TestDatabase();
  final _SendApi api;
  final _TestDatabase db;
  late final ChatController controller;
  late final ProviderContainer scope;

  Future<void> mount(WidgetTester tester, {bool draft = false}) async {
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      scope = ProviderContainer(
        overrides: [chatControllerProvider.overrideWith((ref) => controller)],
      );
      await controller.debugLogin(1);
      if (draft) {
        await controller.openDirect(_peerA);
      } else {
        await openRoom('room-a');
      }
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          theme: buildChatTheme(),
          home: const Scaffold(body: MessagesPane()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!draft) {
      await _pumpUntil(tester, () => controller.messages.isNotEmpty);
    }
    addTearDown(() async {
      api.releaseRequests();
      var stopped = false;
      await tester.runAsync(() async {
        unawaited(controller.logout().whenComplete(() => stopped = true));
      });
      await _pumpUntil(tester, () => stopped);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        scope.dispose();
      });
      await _pumpUntil(tester, () => db.closed.isCompleted);
    });
  }

  Future<void> openRoom(String id) async {
    final value = _room(id, peer: id == 'room-b' ? _peerB.id : _peerA.id);
    await db.upsertRoom(value);
    await controller.openRoom(value);
  }
}

Finder _input() => find.descendant(
  of: find.byType(VMessageInputWidget),
  matching: find.byType(EditableText),
);

VMessageInputWidget _composer(WidgetTester tester) =>
    tester.widget<VMessageInputWidget>(find.byType(VMessageInputWidget));

List<VPlatformFile> _images() => [
  for (final name in ['first.png', 'second.png'])
    VPlatformFile.fromBytes(
      name: name,
      bytes: [137, 80, 78, 71, 13, 10, 26, 10],
    ),
];

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('The expected asynchronous operation did not finish');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var frame = 0; frame < 200; frame++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  throw StateError('The expected widget operation did not finish');
}

void main() {
  testWidgets(
    'text keeps its original room while return-to-latest is pending',
    (tester) async {
      final api = _SendApi();
      final h = _Harness(api);
      await h.mount(tester);
      await tester.runAsync(() async {
        await h.controller.jumpToMessage('historical');
        await h.db.upsertRoom(_room('room-a', revision: 2));
      });
      await tester.pumpAndSettle();
      final gate = Completer<void>.sync();
      api.latestGate = gate;
      await tester.runAsync(() async {
        _composer(tester).onSubmitText('Private to A');
        await api.latestStarted.future.timeout(const Duration(seconds: 3));
      });
      late Future<void> switching;
      await tester.runAsync(() async {
        switching = h.openRoom('room-b');
        await _waitUntil(() => h.controller.selectedRoom?.roomId == 'room-b');
      });
      await tester.pump();
      await tester.runAsync(() async {
        gate.complete();
        await switching;
        await _waitUntil(() => api.sent.isNotEmpty);
        await _waitUntil(() => !h.controller.busy);
      });
      await tester.pumpAndSettle();
      expect(api.sent.single['roomId'], 'room-a');
      expect(api.sent.single['text'], 'Private to A');
      expect(h.controller.selectedRoom?.roomId, 'room-b');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an image batch keeps its original room after switching chats', (
    tester,
  ) async {
    final api = _SendApi()..uploadGate = Completer<void>.sync();
    final h = _Harness(api);
    await h.mount(tester);
    await tester.runAsync(() async {
      _composer(tester).onSubmitMedia(_images());
      await api.uploadStarted.future;
      await h.openRoom('room-b');
    });
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.runAsync(() async {
      api.uploadGate!.complete();
      await _waitUntil(() => api.sent.length == 2);
      await _waitUntil(() => !h.controller.busy);
    });
    await tester.pumpAndSettle();
    expect(api.sent.map((m) => m['roomId']), ['room-a', 'room-a']);
    expect(h.controller.selectedRoom?.roomId, 'room-b');
    expect(
      (await tester.runAsync(() => h.db.allMessages('room-b')))!
          .where((m) => m.type == 'image'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('account switching cancels every remaining image in the batch', (
    tester,
  ) async {
    final api = _SendApi()..uploadGate = Completer<void>.sync();
    final h = _Harness(api);
    await h.mount(tester);
    await tester.runAsync(() async {
      _composer(tester).onSubmitMedia(_images());
      await api.uploadStarted.future;
      await h.controller.debugLogin(2);
      await h.openRoom('room-b');
    });
    await tester.pumpAndSettle();
    await tester.enterText(_input(), 'New account draft');
    await tester.runAsync(() async {
      api.uploadGate!.complete();
      await _waitUntil(() => !h.controller.busy);
    });
    await tester.pumpAndSettle();
    expect(api.uploads, ['first.png']);
    expect(api.sent, isEmpty);
    expect(h.controller.currentUser?.id, 'other');
    expect(
      tester.widget<EditableText>(_input()).controller.text,
      'New account draft',
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final rows = await tester.runAsync(() => h.db.allMessages('room-b'));
    expect(rows!.where((m) => m.type == 'image'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lazy direct acknowledgement preserves the next draft and focus',
    (tester) async {
      final api = _SendApi()..sendGate = Completer<void>.sync();
      final h = _Harness(api);
      await h.mount(tester, draft: true);
      final originalState = tester.state(find.byType(VMessageInputWidget));
      await tester.enterText(_input(), 'First message');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send message'));
      // Native SQLite and nested transactions can resume in the widget test's
      // fake async zone. Pump frames while waiting instead of starving it in
      // an unbounded runAsync wait for the HTTP callback.
      await _pumpUntil(tester, () => api.sendStarted.isCompleted);
      await tester.pumpAndSettle();
      await tester.enterText(_input(), 'Keep this next draft');
      await tester.pump();
      expect(tester.widget<EditableText>(_input()).focusNode.hasFocus, isTrue);
      api.sendGate!.complete();
      await _pumpUntil(
        tester,
        () => h.controller.selectedRoom?.roomId == 'server-room',
      );
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(VMessageInputWidget)),
        same(originalState),
      );
      expect(
        tester.widget<EditableText>(_input()).controller.text,
        'Keep this next draft',
      );
      expect(tester.widget<EditableText>(_input()).focusNode.hasFocus, isTrue);
      expect(h.controller.draftPeer, isNull);
      expect(api.sent.single['peerUserId'], _peerA.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('composer text clears on conversation and account changes', (
    tester,
  ) async {
    final h = _Harness(_SendApi());
    await h.mount(tester);
    await tester.enterText(_input(), 'Only for A');
    await tester.runAsync(() => h.openRoom('room-b'));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(_input()).controller.text, isEmpty);
    await tester.enterText(_input(), 'Only for the first account');
    await tester.runAsync(() async {
      await h.controller.debugLogin(2);
      await h.openRoom('room-b');
    });
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(_input()).controller.text, isEmpty);
    await tester.enterText(_input(), 'Only for this session');
    await tester.runAsync(() async {
      await h.controller.debugLogin(2);
      await h.openRoom('room-b');
    });
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(_input()).controller.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an image batch keeps its peer through lazy room creation', (
    tester,
  ) async {
    final api = _SendApi()..uploadGate = Completer<void>.sync();
    final h = _Harness(api);
    await h.mount(tester, draft: true);
    await tester.runAsync(() async {
      _composer(tester).onSubmitMedia(_images());
      await api.uploadStarted.future;
      // Keep this routing test independent from native image-cache plugins.
      // The separate lazy text test verifies preservation in the open draft.
      await h.openRoom('room-b');
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      api.uploadGate!.complete();
      await _waitUntil(() => api.sent.length == 2);
      await _waitUntil(() => !h.controller.busy);
    });
    await tester.pumpAndSettle();
    expect(api.sent.first['peerUserId'], _peerA.id);
    expect(api.sent.first.containsKey('roomId'), isFalse);
    expect(api.sent.last['roomId'], 'server-room');
    expect(api.sent.last.containsKey('peerUserId'), isFalse);
    final originalRoom = await tester.runAsync(() => h.db.room('server-room'));
    expect(originalRoom!.peerUserId, _peerA.id);
    expect(h.controller.selectedRoom?.roomId, 'room-b');
    final images = await tester.runAsync(() => h.db.allMessages('server-room'));
    expect(images!.where((m) => m.type == 'image').length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finishing an older upload does not clear a newly chosen reply', (
    tester,
  ) async {
    final api = _SendApi()..uploadGate = Completer<void>.sync();
    final h = _Harness(api);
    await h.mount(tester);
    await tester.runAsync(() async {
      _composer(tester).onSubmitMedia(_images().take(1).toList());
      await api.uploadStarted.future;
      await h.openRoom('room-b');
    });
    await _pumpUntil(tester, () => h.controller.messages.isNotEmpty);
    tester
        .widget<VBubbleScope>(find.byType(VBubbleScope))
        .callbacks
        .onSwipeReply!('latest-room-b');
    await tester.pump();
    expect(find.text('Reply to Peer A'), findsOneWidget);
    await tester.runAsync(() async {
      api.uploadGate!.complete();
      await _waitUntil(
        () => (h.controller.diagnostics['recentEvents'] as List).any(
          (event) => event['event'] == 'message_sent',
        ),
      );
    });
    await tester.pumpAndSettle();
    expect(find.text('Reply to Peer A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
