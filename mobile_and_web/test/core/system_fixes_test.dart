import 'dart:async';
import 'dart:typed_data';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session, waitForController;
import 'schema_migration_test.dart' show legacyCacheSql;
import 'sync_test.dart'
    show FakeApi, instant, message, payload, testServerHealth;

class BoundedDatabase extends AppDatabase {
  BoundedDatabase() : super(NativeDatabase.memory());
  @override
  Future<List<ChatMessage>> allMessages(String roomId) =>
      throw StateError('Production navigation must use bounded queries');
}

class FailingPublicationDatabase extends AppDatabase {
  FailingPublicationDatabase() : super(NativeDatabase.memory());
  @override
  Future<bool> applyRoomPayload(
    Map<String, dynamic> payload, {
    required String myUserId,
    String? openRoomId,
    bool markOpenSynced = true,
  }) {
    if (payload['roomPts'] == 32) throw StateError('Synthetic local failure');
    return super.applyRoomPayload(
      payload,
      myUserId: myUserId,
      openRoomId: openRoomId,
      markOpenSynced: markOpenSynced,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('failed publication batch rolls back every message and cursor, then queue recovers', () async {
    final db = FailingPublicationDatabase();
    await db.initializeSession('me');
    await db.setCursor(0, 'epoch');
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    );
    await expectLater(
      Future.wait(
        List.generate(
          64,
          (i) => sync.receivePublication({
            'pts': i + 1,
            'epoch': 'epoch',
            'room': payload(pts: i + 1, last: message('m-$i')),
          }),
        ),
      ),
      throwsStateError,
    );
    expect((await db.metadata())!.localPts, 0);
    expect(await db.messageCount('room'), 0);
    await sync.receivePublication({
      'pts': 1,
      'epoch': 'epoch',
      'room': payload(pts: 1, last: message('recovered')),
    });
    expect((await db.metadata())!.localPts, 1);
    expect(await db.messageCount('room'), 1);
    await sync.dispose();
    await db.close();
  });

  test('bulk receipt boundaries preserve delivered-before-seen ordering and pending exclusions', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    await db.upsertRoom(ChatRoom.fromJson(payload()));
    final read = message('read'), delivered = message('delivered', seconds: 15);
    await db.upsertMessage(read);
    await db.upsertMessage(delivered);
    await db.upsertMessage(message('pending', status: 'failed'));
    final seenBoundary = instant.add(const Duration(seconds: 10));
    final deliveredBoundary = instant.add(const Duration(seconds: 20));
    await db.reconcileLatest(
      'room',
      [delivered, read],
      1,
      0,
      0,
      receipts: ReceiptWatermarks(
        deliveredThrough: deliveredBoundary,
        seenThrough: seenBoundary,
      ),
      myUserId: 'me',
    );
    expect((await db.message('read'))!.isDelivered, true);
    expect((await db.message('read'))!.deliveredAt, isNull);
    expect((await db.message('read'))!.isSeen, true);
    expect((await db.message('read'))!.seenAt, isNull);
    expect((await db.message('delivered'))!.isDelivered, true);
    expect((await db.message('delivered'))!.deliveredAt, isNull);
    expect((await db.message('delivered'))!.seenAt, isNull);
    expect((await db.message('pending'))!.deliveredAt, isNull);
    await db.close();
  });

  for (final pinAll in [false, true]) {
    test(
      'authoritative page survives old delta and pinAll=$pinAll across service recreation',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = FakeApi();
        await db.initializeSession('me');
        await db.setCursor(25, 'epoch');
        await db.saveRoomPage('epoch', {
          'beforeRoomId': 'page-boundary',
          'beforeSortTimestamp': instant.toIso8601String(),
        });
        for (var i = 1; i <= 25; i++) {
          await db.upsertRoom(
            ChatRoom.fromJson({
              ...payload(room: 'room-$i'),
              'pinAt': pinAll ? instant.toIso8601String() : null,
            }),
          );
        }
        await db.applyRoomPayload({
          ...payload(room: 'old-room', pts: 26),
          'sortTimestamp': instant
              .subtract(const Duration(days: 30))
              .toIso8601String(),
          'pinAt': pinAll ? instant.toIso8601String() : null,
        }, myUserId: 'me');
        final sync = InboxSyncService(
          database: db,
          api: api,
          userId: 'me',
          isCurrentSession: () => true,
          restoredHasMoreRooms: true,
        );
        var pages = 0;
        api.handler = (path, query) async {
          expect(path, '/rooms');
          expect(query!['beforeRoomId'], 'page-boundary');
          pages++;
          return {
            'rooms': [payload(room: 'next')],
            'nextCursor': null,
          };
        };
        await sync.loadMoreRooms();
        expect(pages, 1);
        expect(await db.room('next'), isNotNull);
        expect((await db.metadata())!.roomPageCursorJson, isNull);
        expect(sync.hasMoreRooms, false);
        await sync.dispose();
        await db.close();
      },
    );
  }

  test(
    'epoch change discards the previous authoritative page boundary',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.initializeSession('me');
      await db.setCursor(20, 'new-epoch');
      await db.saveRoomPage('old-epoch', {'beforeRoomId': 'old'});
      final api = FakeApi()
        ..handler = (path, query) async {
          expect(query!.containsKey('beforeRoomId'), false);
          return {'rooms': <Object>[], 'nextCursor': null};
        };
      final sync = InboxSyncService(
        database: db,
        api: api,
        userId: 'me',
        isCurrentSession: () => true,
        restoredHasMoreRooms: true,
      );
      await sync.loadMoreRooms();
      expect((await db.metadata())!.roomPageEpoch, 'new-epoch');
      await sync.dispose();
      await db.close();
    },
  );

  test('contiguous burst retains every message and cursor with one atomic transaction', () async {
    final inspector = DebugInspector(enabled: true);
    final db = AppDatabase(NativeDatabase.memory(), inspector);
    await db.initializeSession('me');
    await db.setCursor(0, 'epoch');
    inspector.clear();
    final sync = InboxSyncService(
      database: db,
      api: FakeApi(),
      userId: 'me',
      isCurrentSession: () => true,
    );
    await Future.wait(
      List.generate(
        64,
        (index) => sync.receivePublication({
          'pts': index + 1,
          'epoch': 'epoch',
          'room': payload(
            pts: index + 1,
            last: message('message-$index', seconds: index),
          ),
        }),
      ),
    );
    expect((await db.metadata())!.localPts, 64);
    expect(await db.messageCount('room'), 64);
    final aggregates = (inspector.snapshot()['aggregates'] as List).cast<Map>();
    expect(
      aggregates.singleWhere(
        (event) =>
            event['category'] == 'drift' && event['name'] == 'transaction',
      )['count'],
      1,
    );
    await sync.dispose();
    await db.close();
    inspector.dispose();
  });

  test('version3 upgrade preserves certification, rows, receipts and initializes new bounded storage fields', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute(
            legacyCacheSql(
              2,
            ).replaceAll('PRAGMA user_version = 2', 'PRAGMA user_version = 3'),
          );
        },
      ),
    );
    expect((await db.room('room'))!.messagesSyncedPts, 15);
    expect((await db.metadata())!.localPts, 17);
    expect((await db.message('sent'))!.seenAt!.millisecondsSinceEpoch, 3000);
    expect((await db.metadata())!.roomPageKnown, false);
    expect((await db.message('failed'))!.uploadBytes, isNull);
    await db.close();
  });

  test('large cached history opens and jumps through bounded queries without full history reads', () async {
    final db = BoundedDatabase();
    final api = FakeApi()..handler = (_, _) async => delta(1, []);
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    await db.upsertRoom(ChatRoom.fromJson(payload()));
    await db.markMessagesSynced('room', 1);
    for (var i = 0; i < 300; i++) {
      await db.upsertMessage(message('m-$i', seconds: i));
    }
    await controller.openRoom((await db.room('room'))!);
    expect(controller.messages.length, 50);
    await controller.jumpToMessage('m-10');
    expect(controller.messages.length, lessThanOrEqualTo(31));
    expect(controller.messages.any((m) => m.id == 'm-10'), true);
    expect(controller.isJumpMode, true);
    await controller.logout();
    await db.close();
  });

  for (final status in [401, 503]) {
    test(
      'current session HTTP$status preserves failed image bytes and same-account reauth work',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = FakeApi()..handler = (_, _) async => delta(0, []);
        var reject = false;
        api.authHandler = (_) async => session('me');
        api.handler = (_, _) async {
          if (reject) {
            throw ChatApiException(
              'temporarily unavailable or retired',
              statusCode: status,
            );
          }
          return delta(0, []);
        };
        api.uploadHandler = (_, _) async =>
            throw const ChatApiException('offline');
        final controller = ChatController(
          database: db,
          api: api,
          enableRealtime: false,
          healthMonitorFactory: testServerHealth,
        );
        await controller.debugLogin(1);
        await controller.openDirect(
          const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
        );
        await controller.sendImage(Uint8List.fromList([1, 2, 3]), 'image.png');
        final pending = (await db.allMessages('draft_peer')).single;
        reject = true;
        await controller.syncNow();
        expect(controller.requiresReauthentication, status == 401);
        expect((await db.message(pending.id))!.uploadBytes, [1, 2, 3]);
        expect(
          (await SharedPreferences.getInstance()).getString('chat_session'),
          isNotNull,
        );
        reject = false;
        await controller.debugLogin(1);
        expect((await db.message(pending.id))!.uploadBytes, [1, 2, 3]);
        api.authHandler = (_) async => session('other');
        await controller.debugLogin(2);
        expect(await db.message(pending.id), isNull);
        await controller.logout();
        await db.close();
      },
    );
  }

  test(
    'hidden open room is delivered but never seen until foreground resume',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi()..handler = (_, _) async => delta(0, []);
      var seen = 0;
      api.otherPostHandler = (path, _) async {
        if (path.endsWith('/seen')) seen++;
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      await controller.debugLogin(1);
      await db.upsertRoom(ChatRoom.fromJson(payload(pts: 0)));
      await db.upsertMessage(message('cached'));
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await controller.openRoom((await db.room('room'))!);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen, 0);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitForController(() => seen > 0);
      await controller.logout();
      await db.close();
    },
  );

  test('all selected batch images are persisted before first upload and quota stays bounded', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()..handler = (_, _) async => delta(0, []);
    final started = Completer<void>(), release = Completer<void>();
    api.uploadHandler = (_, _) async {
      if (!started.isCompleted) started.complete();
      await release.future;
      throw const ChatApiException(
        'Invalid upload',
        statusCode: 400,
        kind: ChatFailureKind.validation,
      );
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      healthMonitorFactory: testServerHealth,
    );
    await controller.debugLogin(1);
    await controller.openDirect(
      const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
    );
    final batch = controller.sendImageBatch([
      (bytes: Uint8List.fromList([1]), filename: 'a.png'),
      (bytes: Uint8List.fromList([2]), filename: 'b.png'),
    ], context: controller.captureSendContext()!);
    await started.future;
    expect(await db.messageCount('draft_peer'), 2);
    release.complete();
    await batch;
    await controller.outboxIdle;
    expect(
      (await db.allMessages('draft_peer'))
          .every((m) => m.status == 'failed' && m.uploadBytes != null),
      true,
    );
    await expectLater(db.checkUploadQuota(6 * 1024 * 1024), throwsStateError);
    await controller.logout();
    await db.close();
  });
}
