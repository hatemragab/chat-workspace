import 'dart:async';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'database_query_efficiency_test.dart'
    show queries, sequenced, sequenceRoom;
import 'sync_test.dart' show message;

String _statement(Map<String, Object?> event) =>
    ((event['data'] as Map)['sqlite'] as Map)['statement'] as String;

int _selects(DebugInspector inspector, bool Function(String) matches) =>
    queries(inspector)
        .where(
          (event) =>
              event['name'] == 'query.select' && matches(_statement(event)),
        )
        .length;

int _inboxSelects(DebugInspector inspector) =>
    _selects(inspector, (sql) => sql.startsWith('WITH pending_messages'));

int _outboxSelects(DebugInspector inspector) =>
    _selects(inspector, (sql) => sql.startsWith('WITH counts AS'));

int _conversationSelects(DebugInspector inspector) => _selects(
  inspector,
  (sql) =>
      sql.contains('FROM "local_messages"') &&
      sql.contains('ORDER BY "created_at" DESC') &&
      sql.contains('LIMIT'),
);

class _RetainedWatches {
  _RetainedWatches(AppDatabase db, {String roomId = 'room'}) {
    final roomReady = Completer<void>();
    final outboundReady = Completer<void>();
    final messagesReady = Completer<void>();
    ready = Future.wait([
      roomReady.future,
      outboundReady.future,
      messagesReady.future,
    ]).then((_) => pumpEventQueue());
    subscriptions = [
      db.watchRooms(userId: 'me').listen((value) {
        rooms.add(value);
        if (!roomReady.isCompleted) roomReady.complete();
      }, onError: errors.add),
      db.watchOutboundSnapshot('me').listen((value) {
        outbound.add(value);
        if (!outboundReady.isCompleted) outboundReady.complete();
      }, onError: errors.add),
      db.watchMessages(roomId, 100).listen((value) {
        messages.add(value);
        if (!messagesReady.isCompleted) messagesReady.complete();
      }, onError: errors.add),
    ];
  }

  final rooms = <List<ChatRoom>>[];
  final outbound = <OutboundSnapshot>[];
  final messages = <List<ChatMessage>>[];
  final errors = <Object>[];
  late final Future<void> ready;
  late final List<StreamSubscription<Object?>> subscriptions;

  Future<void> cancel() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}

void main() {
  late AppDatabase db;
  late DebugInspector inspector;

  setUp(() async {
    inspector = DebugInspector();
    db = AppDatabase(NativeDatabase.memory(), inspector);
    await db.initializeSession('me');
    await db.upsertRoom(sequenceRoom(last: sequenced(60)));
    await db.upsertMessage(sequenced(60));
    inspector.setEnabled(true);
    inspector.setSqliteDetailsEnabled(true);
  });

  tearDown(() async {
    await db.close();
    inspector.dispose();
  });

  Future<_RetainedWatches> retain({String roomId = 'room'}) async {
    final watches = _RetainedWatches(db, roomId: roomId);
    addTearDown(watches.cancel);
    await watches.ready;
    inspector.clear();
    return watches;
  }

  test('older sent page refreshes conversation once while inbox and durable outbox stay subscribed without rereads', () async {
    await db.enqueueOutboundMessage(
      message('queued', status: 'queued', seconds: 1),
    );
    final watches = await retain();
    final page = List.generate(
      30,
      (index) => sequenced(index + 30, sender: 'peer'),
    );
    await db.storeOlderMessagePage(
      'room',
      page,
      coverage: {'fromSeq': 30, 'throughSeq': 59},
      userId: 'me',
    );
    await pumpEventQueue();

    expect(_inboxSelects(inspector), 0);
    expect(_outboxSelects(inspector), 0);
    expect(_conversationSelects(inspector), 1);
    expect(
      queries(inspector).where((event) => event['name'] == 'query.insert'),
      hasLength(1),
    );
    expect(watches.rooms, hasLength(1));
    expect(watches.outbound, hasLength(1));
    expect(watches.messages, hasLength(2));
    expect(watches.messages.last, hasLength(32));
    expect(watches.rooms.single.single.lastMessage!.id, 'queued');
    expect(watches.outbound.single.head!.id, 'queued');
    expect(watches.outbound.single.queued, 1);
    final row = (await db.roomRow('room'))!;
    expect(row.receivedRangesJson, '[[30,60]]');
    expect(row.messagesSyncedPts, 0);
    expect((await db.metadata())!.localPts, 0);
    expect(watches.errors, isEmpty);
  });

  test('receipt advancement learned from older page refreshes visible ticks without refreshing the outbox', () async {
    final watches = await retain();
    await db.storeOlderMessagePage(
      'room',
      [sequenced(30, sender: 'peer')],
      coverage: {'fromSeq': 30, 'throughSeq': 30},
      receiptState: {'peerDeliveredSeq': 60, 'peerSeenSeq': 60},
      userId: 'me',
    );
    await pumpEventQueue();

    expect(_inboxSelects(inspector), 1);
    expect(_outboxSelects(inspector), 0);
    expect(_conversationSelects(inspector), 1);
    expect(watches.rooms.last.single.lastMessage!.isSeen, true);
    expect(
      watches.messages.last
          .singleWhere((message) => message.id == 'message_me60')
          .isSeen,
      true,
    );
    expect(watches.outbound, hasLength(1));
    expect((await db.roomRow('room'))!.peerSeenSeq, 60);
    expect(watches.errors, isEmpty);
  });

  test('history acknowledgement of an existing pending identity wakes inbox and outbox without a delete or draft remap', () async {
    await db.enqueueOutboundMessage(
      message('message_me1', key: 'stable-key', status: 'queued', seconds: 1),
    );
    final watches = await retain();
    await db.storeOlderMessagePage(
      'room',
      [sequenced(1, key: 'stable-key')],
      coverage: {'fromSeq': 1, 'throughSeq': 1},
      userId: 'me',
    );
    await pumpEventQueue();

    expect(_inboxSelects(inspector), 1);
    expect(_outboxSelects(inspector), 1);
    expect(_conversationSelects(inspector), 1);
    expect(
      queries(inspector).where((event) => event['name'] == 'query.delete'),
      isEmpty,
    );
    expect(watches.outbound.last.queued, 0);
    expect(watches.outbound.last.head, isNull);
    expect(watches.rooms.last.single.lastMessage!.id, 'message_me60');
    expect(
      watches.messages.last
          .singleWhere((message) => message.id == 'message_me1')
          .status,
      'sent',
    );
    expect(watches.errors, isEmpty);
  });

  test('history acknowledgement adopts pending identity and remaps the remaining draft queue', () async {
    const peer = UserProfile(id: 'peer', username: 'peer', displayName: 'Peer');
    await db.enqueueOutboundMessage(
      message(
        'optimistic',
        key: 'stable-key',
        room: 'draft_peer',
        status: 'queued',
        seconds: 1,
      ),
      peer: peer,
    );
    await db.enqueueOutboundMessage(
      message('next-pending', room: 'draft_peer', status: 'queued', seconds: 2),
      peer: peer,
    );
    final watches = await retain(roomId: 'draft_peer');
    await db.storeOlderMessagePage(
      'room',
      [sequenced(1, key: 'stable-key')],
      coverage: {'fromSeq': 1, 'throughSeq': 1},
      userId: 'me',
    );
    await pumpEventQueue();

    expect(_inboxSelects(inspector), 1);
    expect(_outboxSelects(inspector), 1);
    expect(_conversationSelects(inspector), 1);
    expect(watches.rooms.last.map((room) => room.roomId), ['room']);
    expect(watches.rooms.last.single.lastMessage!.id, 'next-pending');
    expect(watches.outbound.last.queued, 1);
    expect(watches.outbound.last.head!.id, 'next-pending');
    expect(watches.outbound.last.head!.roomId, 'room');
    expect(watches.outbound.last.head!.enqueueOrder, 2);
    expect(watches.messages.last, isEmpty);
    expect(await db.message('optimistic'), isNull);
    expect((await db.message('message_me1'))!.status, 'sent');
    expect((await db.metadata())!.localPts, 0);
    expect(watches.errors, isEmpty);
  });

  test('ordinary enqueue, failure, retry, status, remove and account cleanup still wake every affected watcher', () async {
    final watches = await retain();
    Future<void> mutate(Future<void> Function() change) async {
      inspector.clear();
      await change();
      await pumpEventQueue();
      expect(_inboxSelects(inspector), 1);
      expect(_outboxSelects(inspector), 1);
      expect(_conversationSelects(inspector), 1);
      expect(watches.errors, isEmpty);
    }

    await mutate(
      () => db.enqueueOutboundMessage(
        message('queued', status: 'queued', seconds: 1),
      ),
    );
    expect(watches.outbound.last.head!.id, 'queued');
    expect(watches.rooms.last.single.lastMessage!.id, 'queued');
    await mutate(
      () => db.updateOutboundState(
        'me',
        'queued',
        status: 'failed',
        retryCount: 1,
        paused: true,
        errorCode: 'temporary',
      ),
    );
    expect(watches.outbound.last.failed, 1);
    expect(watches.outbound.last.head, isNull);
    expect(watches.rooms.last.single.lastMessage!.status, 'failed');
    await mutate(() => db.retryOutboundMessage('me', 'queued'));
    expect(watches.outbound.last.queued, 1);
    expect(watches.outbound.last.head!.retryCount, 0);
    expect(watches.outbound.last.head!.outboxPaused, false);
    await mutate(() => db.setMessageStatus('queued', 'sending'));
    expect(watches.outbound.last.head!.status, 'sending');
    await mutate(() => db.removeMessage('queued'));
    expect(watches.outbound.last.queued, 0);
    expect(watches.rooms.last.single.lastMessage!.id, 'message_me60');
    await mutate(
      () => db.enqueueOutboundMessage(
        message('cleanup-pending', status: 'queued', seconds: 2),
      ),
    );
    await mutate(() => db.initializeSession('other-account'));
    expect(watches.rooms.last, isEmpty);
    expect(watches.outbound.last.head, isNull);
    expect(watches.outbound.last.queued, 0);
    expect(watches.messages.last, isEmpty);
  });

  test('history and ordinary enqueue in one outer transaction retain the ordinary watcher notifications', () async {
    final watches = await retain();
    await db.transaction(() async {
      await db.storeOlderMessagePage(
        'room',
        [sequenced(30, sender: 'peer')],
        coverage: {'fromSeq': 30, 'throughSeq': 30},
        userId: 'me',
      );
      await db.enqueueOutboundMessage(
        message('mixed-pending', status: 'queued', seconds: 1),
      );
    });
    await pumpEventQueue();

    expect(_inboxSelects(inspector), 1);
    expect(_outboxSelects(inspector), 1);
    expect(_conversationSelects(inspector), 1);
    expect(watches.rooms.last.single.lastMessage!.id, 'mixed-pending');
    expect(watches.outbound.last.head!.id, 'mixed-pending');
    expect(watches.messages.last, hasLength(3));
    expect(watches.errors, isEmpty);
  });

  test('rolled-back history and enqueue never publish uncommitted rows and listeners continue after rollback', () async {
    final watches = await retain();
    await expectLater(
      db.transaction(() async {
        await db.storeOlderMessagePage(
          'room',
          [sequenced(30, sender: 'peer')],
          coverage: {'fromSeq': 30, 'throughSeq': 30},
          receiptState: {'peerSeenSeq': 60},
          userId: 'me',
        );
        await db.enqueueOutboundMessage(
          message('rolled-back', status: 'queued', seconds: 1),
        );
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    await pumpEventQueue();

    expect(
      watches.rooms.every(
        (rooms) =>
            rooms.single.lastMessage!.id == 'message_me60' &&
            !rooms.single.lastMessage!.isSeen,
      ),
      true,
    );
    expect(watches.outbound.every((snapshot) => snapshot.queued == 0), true);
    expect(
      watches.messages.every(
        (messages) =>
            messages.length == 1 &&
            messages.single.id == 'message_me60' &&
            !messages.single.isSeen,
      ),
      true,
    );
    expect(await db.message('rolled-back'), isNull);
    expect(await db.message('message_peer30'), isNull);
    expect((await db.roomRow('room'))!.peerSeenSeq, 0);
    inspector.clear();
    await db.enqueueOutboundMessage(
      message('after-rollback', status: 'queued', seconds: 2),
    );
    await pumpEventQueue();
    expect(_inboxSelects(inspector), 1);
    expect(_outboxSelects(inspector), 1);
    expect(_conversationSelects(inspector), 1);
    expect(watches.rooms.last.single.lastMessage!.id, 'after-rollback');
    expect(watches.outbound.last.head!.id, 'after-rollback');
    expect(watches.messages.last, hasLength(2));
    expect(watches.errors, isEmpty);
  });
}
