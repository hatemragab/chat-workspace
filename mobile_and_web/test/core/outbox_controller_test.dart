import 'dart:async';
import 'dart:convert';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session;
import 'sync_test.dart' show FakeApi, instant, message, payload;

Future<void> _until(FutureOr<bool> Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Outbox did not reach the expected state');
}

class _Harness {
  _Harness({AppDatabase? database})
    : db = database ?? AppDatabase(NativeDatabase.memory());
  final AppDatabase db;
  final api = FakeApi();
  late final ChatController controller;
  bool offline = false, loseAcknowledgement = false;
  final requests = <String>[];
  final accepted = <String, ChatMessage>{};
  final requestsByKey = <String, int>{};
  int active = 0, maximumActive = 0;

  Future<void> start() async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    await db.initializeSession('me');
    await db.setCursor(1, 'epoch');
    await db.upsertRoom(ChatRoom.fromJson(payload(pts: 1)));
    api.handler = (path, _) async {
      if (path == '/rooms/delta') return delta(1, []);
      if (path == '/presence/status') return {'statuses': <String, bool>{}};
      if (path.endsWith('/messages')) {
        return {
          'messages': accepted.values.map((m) => m.toJson()).toList(),
          'hasMore': false,
          'receipts': {
            'deliveredThrough': null,
            'seenThrough': null,
            'hasGaps': false,
          },
        };
      }
      throw StateError('Unexpected test request: $path');
    };
    api.postHandler = (_, body) async {
      final key = body!['idempotencyKey'] as String;
      final text = body['text'] as String;
      requests.add(text);
      requestsByKey.update(key, (n) => n + 1, ifAbsent: () => 1);
      maximumActive = maximumActive < ++active ? active : maximumActive;
      try {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if (offline) {
          throw const ChatApiException(
            'Connection unavailable',
            kind: ChatFailureKind.transport,
          );
        }
        if (text == 'invalid') {
          throw const ChatApiException(
            'Message data is invalid',
            statusCode: 400,
            code: 'VALIDATION_FAILED',
            kind: ChatFailureKind.validation,
          );
        }
        final sent = accepted.putIfAbsent(
          key,
          () => ChatMessage(
            id: 'server-${accepted.length}',
            idempotencyKey: key,
            roomId: 'room',
            senderId: 'me',
            senderName: 'Me',
            type: body['type'] as String,
            text: text,
            imageUrl: body['imageUrl'] as String?,
            createdAt: instant.add(Duration(seconds: accepted.length)),
          ),
        );
        if (loseAcknowledgement) {
          loseAcknowledgement = false;
          offline = true;
          throw const ChatApiException(
            'Acknowledgement timed out',
            kind: ChatFailureKind.timeout,
          );
        }
        return {'message': sent.toJson(), 'room': payload(pts: 2, last: sent)};
      } finally {
        --active;
      }
    };
    controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: () => ServerHealthMonitor(
        healthUri: Uri.parse('http://localhost/health'),
        probe: () async => !offline,
        recoveryInterval: const Duration(milliseconds: 20),
      ),
    );
    await controller.initialize();
    await controller.openRoom((await db.room('room'))!);
  }

  Future<void> close() async {
    await controller.logout();
    await controller.outboxIdle;
    await db.close();
  }
}

class _FullStorageDatabase extends AppDatabase {
  _FullStorageDatabase() : super(NativeDatabase.memory());
  @override
  Future<void> enqueueOutboundMessage(
    ChatMessage message, {
    UserProfile? peer,
  }) {
    throw StateError('Local storage is full');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('first healthy send does not repeat completed inbox startup', () async {
    final h = _Harness();
    await h.start();
    try {
      await _until(
        () async => (await h.db.room('room'))!.messagesSyncedPts == 1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final previous = h.api.handler!;
      var deltas = 0;
      h.api.handler = (path, query) {
        if (path == '/rooms/delta') deltas++;
        return previous(path, query);
      };
      await h.controller.sendText('healthy-first');
      await h.controller.outboxIdle;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.accepted.values.single.text, 'healthy-first');
      expect((await h.db.allMessages('room')).single.status, 'sent');
      expect(deltas, 0);
      expect(h.controller.error, isNull);
    } finally {
      await h.close();
    }
  });

  test(
    'offline sends recover automatically in global FIFO without manual sync',
    () async {
      final h = _Harness()..offline = true;
      await h.start();
      try {
        await h.controller.sendText('first');
        await h.controller.sendText('second');
        await h.controller.outboxIdle;
        final queued = await h.db.allMessages('room');
        expect(queued.where((m) => m.status == 'queued'), hasLength(2));
        expect(h.accepted, isEmpty);
        h.offline = false;
        await _until(
          () async =>
              (await h.db.allMessages('room'))
                  .where((m) => m.status == 'sent')
                  .length ==
              2,
        );
        expect(h.accepted.values.map((m) => m.text), ['first', 'second']);
        expect(h.maximumActive, 1);
        expect((await h.db.metadata())!.localPts, 1);
      } finally {
        await h.close();
      }
    },
  );

  test('a bad request fails once and later valid messages continue', () async {
    final h = _Harness();
    await h.start();
    try {
      await h.controller.sendText('invalid');
      await h.controller.sendText('valid');
      await _until(() async => h.accepted.length == 1);
      await h.controller.outboxIdle;
      final invalid = (await h.db.allMessages('room'))
          .singleWhere((m) => m.text == 'invalid');
      expect(invalid.status, 'failed');
      expect(invalid.lastErrorCode, 'VALIDATION_FAILED');
      for (var i = 0; i < 3; i++) {
        await h.controller.syncNow();
      }
      await h.controller.outboxIdle;
      expect(h.requests.where((text) => text == 'invalid'), hasLength(1));
      expect(h.accepted.values.single.text, 'valid');
    } finally {
      await h.close();
    }
  });

  test(
    'lost acknowledgement resolves the existing message before the next send',
    () async {
      final h = _Harness()..loseAcknowledgement = true;
      await h.start();
      try {
        await h.controller.sendText('accepted before disconnect');
        await h.controller.sendText('after recovery');
        await _until(() => h.offline && h.accepted.length == 1);
        final firstKey = h.accepted.keys.single;
        h.offline = false;
        await _until(
          () async =>
              (await h.db.allMessages('room'))
                  .where((m) => m.status == 'sent')
                  .length ==
              2,
        );
        expect(h.accepted.length, 2);
        expect(h.requestsByKey[firstKey], 2);
        expect(h.accepted.values.map((m) => m.text), [
          'accepted before disconnect',
          'after recovery',
        ]);
        expect(h.maximumActive, 1);
      } finally {
        await h.close();
      }
    },
  );

  test('persisted interrupted work recovers on startup', () async {
    final h = _Harness();
    await h.db.initializeSession('me');
    await h.db.enqueueOutboundMessage(
      message('interrupted', status: 'sending'),
    );
    await h.start();
    try {
      await _until(
        () async =>
            (await h.db.messageByIdempotencyKey('me', 'interrupted'))?.status ==
            'sent',
      );
      expect(h.accepted, hasLength(1));
    } finally {
      await h.close();
    }
  });

  test(
    'a mismatched acknowledgment cannot insert or remap another conversation',
    () async {
      final h = _Harness();
      await h.start();
      h.api.postHandler = (_, body) async => {
        'message': message('unrelated', room: 'foreign').toJson(),
        'room': payload(room: 'foreign', pts: 2),
      };
      try {
        await h.controller.sendText('keep this conversation');
        await _until(
          () async =>
              (await h.db.nextOutboundMessage('me'))?.outboxPaused == true,
        );
        final pending = (await h.db.nextOutboundMessage('me'))!;
        expect(pending.roomId, 'room');
        expect(pending.lastErrorCode, 'acknowledgment_identity_mismatch');
        expect(await h.db.message('unrelated'), isNull);
        expect(await h.db.room('foreign'), isNull);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'local persistence failure reports unsaved text and never dispatches it',
    () async {
      final h = _Harness(database: _FullStorageDatabase());
      await h.start();
      try {
        expect(await h.controller.sendText('retain this text'), isFalse);
        await h.controller.outboxIdle;
        expect(h.requests, isEmpty);
        expect(await h.db.nextOutboundMessage('me'), isNull);
        expect(h.controller.error, contains('Local storage is full'));
      } finally {
        await h.close();
      }
    },
  );
}
