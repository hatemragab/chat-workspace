import 'dart:async';
import 'dart:typed_data';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'database_query_efficiency_test.dart'
    show queries, queryCount, sequenced, sequenceRoom;
import 'sync_test.dart' show instant, message, payload;

void main() {
  late DebugInspector inspector;
  late AppDatabase db;

  setUp(() async {
    inspector = DebugInspector();
    db = AppDatabase(NativeDatabase.memory(), inspector);
    await db.initializeSession('me');
    inspector.setEnabled(true);
    inspector.setSqliteDetailsEnabled(true);
  });
  tearDown(() async {
    await db.close();
    inspector.dispose();
  });

  test('30 rows use one parameterized multi-row execution and identical rows skip writes', () async {
    await db.upsertRoom(sequenceRoom());
    final page = List.generate(30, (index) => sequenced(index + 1));
    page[0] = ChatMessage.fromJson({
      ...page[0].toJson(),
      'text': "quoted'); DELETE FROM local_messages; --",
    });
    inspector.clear();
    await db.upsertMessages(page);
    final inserts = queries(inspector)
        .where((e) => e['name'] == 'query.insert')
        .toList();
    expect(inserts, hasLength(1));
    final data = inserts.single['data'] as Map;
    final sql = (data['sqlite'] as Map)['statement'] as String;
    expect(sql, contains('ON CONFLICT ("id") DO UPDATE SET'));
    expect(RegExp(r'\), \(').allMatches(sql), hasLength(29));
    expect(sql, isNot(contains(page.first.text)));
    expect(data['argumentCount'], lessThanOrEqualTo(900));
    expect(await db.messageCount('room'), 30);
    expect((await db.message(page.first.id))!.text, page.first.text);
    inspector.clear();
    await db.upsertMessages(page);
    expect(queryCount(inspector, 'insert'), 0);
  });

  test(
    'large pages bound statements and roll back all earlier chunks on failure',
    () async {
      final page = List.generate(61, (index) => sequenced(index + 1));
      await db.customStatement(
        '''CREATE TRIGGER reject_later_chunk BEFORE INSERT ON local_messages
      WHEN NEW.id = 'message_me31' BEGIN SELECT RAISE(ABORT, 'later chunk rejected'); END''',
      );
      await expectLater(
        db.upsertMessages(page),
        throwsA(
          predicate(
            (error) => error.toString().contains('later chunk rejected'),
          ),
        ),
      );
      expect(await db.messageCount('room'), 0);
      expect((await db.metadata())!.localPts, 0);
      await db.customStatement('DROP TRIGGER reject_later_chunk');
      inspector.clear();
      await db.upsertMessages(page);
      final inserts = queries(inspector)
          .where((e) => e['name'] == 'query.insert')
          .toList();
      expect(inserts, hasLength(3));
      for (final event in inserts) {
        expect((event['data'] as Map)['argumentCount'], lessThanOrEqualTo(900));
      }
      expect(await db.messageCount('room'), 61);
    },
  );

  test(
    'repeated sender identities adopt drafts and preserve sent state',
    () async {
      const peer = UserProfile(
        id: 'peer',
        username: 'peer',
        displayName: 'Peer',
      );
      final pending = message(
        'local',
        room: 'draft_peer',
        status: 'queued',
        key: 'shared',
      );
      await db.upsertDraftRoom(peer, pending);
      final later = message('later', room: 'draft_peer', status: 'queued')
          .copyWith(
            enqueueOrder: 7,
            retryCount: 2,
            outboxPaused: true,
            lastErrorCode: 'temporary',
          );
      await db.upsertMessages([
        pending,
        later,
        message('server', key: 'shared'),
        pending,
        message('peer-server', sender: 'peer', key: 'shared'),
      ]);
      expect(await db.message('local'), isNull);
      expect((await db.messageByIdempotencyKey('me', 'shared'))!.id, 'server');
      expect((await db.message('server'))!.status, 'sent');
      expect(
        (await db.messageByIdempotencyKey('peer', 'shared'))!.id,
        'peer-server',
      );
      final remapped = (await db.message('later'))!;
      expect(remapped.roomId, 'room');
      expect(remapped.enqueueOrder, 7);
      expect(remapped.retryCount, 2);
      expect(remapped.outboxPaused, true);
      expect(remapped.lastErrorCode, 'temporary');
      expect(await db.room('draft_peer'), isNull);
    },
  );

  test(
    'merges retain upload metadata, exact receipts and monotonic cursor flags',
    () async {
      final original = message('kept').copyWith(
        deliveredAt: instant,
        seenAt: instant.add(const Duration(seconds: 2)),
        seenByCursor: true,
        deliveredByCursor: true,
      );
      final upload = ChatMessage(
        id: 'image',
        idempotencyKey: 'image',
        roomId: 'room',
        senderId: 'me',
        senderName: 'Me',
        type: 'image',
        text: '',
        status: 'queued',
        createdAt: instant,
        uploadFilename: 'pending.png',
        uploadBytes: Uint8List.fromList([0, 1, 255]),
        enqueueOrder: 5,
        retryCount: 2,
      );
      await db.upsertMessages([
        original,
        message('kept'),
        upload,
        upload.copyWith(status: 'sending'),
      ]);
      final stored = (await db.message('kept'))!;
      expect(stored.deliveredAt, original.deliveredAt);
      expect(stored.seenAt, original.seenAt);
      expect(stored.deliveredByCursor, true);
      expect(stored.seenByCursor, true);
      final storedUpload = (await db.message('image'))!;
      expect(storedUpload.uploadBytes, [0, 1, 255]);
      expect(storedUpload.uploadFilename, 'pending.png');
      expect(storedUpload.enqueueOrder, 5);
      expect(storedUpload.retryCount, 2);
      expect(storedUpload.status, 'sending');
    },
  );

  test('multi-row writes notify message watchers once after commit', () async {
    final emissions = <List<ChatMessage>>[];
    final initial = Completer<void>();
    final inserted = Completer<void>();
    final subscription = db.watchMessages('room', 100).listen((rows) {
      emissions.add(rows);
      if (!initial.isCompleted) initial.complete();
      if (rows.length == 61 && !inserted.isCompleted) inserted.complete();
    });
    addTearDown(subscription.cancel);
    await initial.future;
    await db.upsertMessages(List.generate(61, (index) => sequenced(index + 1)));
    await inserted.future;
    expect(emissions.map((rows) => rows.length), [0, 61]);
  });

  test('legacy receipts notify only changed rows and never regress', () async {
    final outgoing = message('legacy');
    await db.upsertRoom(ChatRoom.fromJson(payload(last: outgoing)));
    await db.reconcileLatest('room', [outgoing], 1, 0, 0);
    final emissions = <List<ChatMessage>>[];
    final initial = Completer<void>();
    final seen = Completer<void>();
    final subscription = db.watchMessages('room', 30).listen((rows) {
      emissions.add(rows);
      if (!initial.isCompleted) initial.complete();
      if (rows.single.isSeen && !seen.isCompleted) seen.complete();
    });
    addTearDown(subscription.cancel);
    await initial.future;
    inspector.clear();
    await db.reconcileLatest(
      'room',
      [outgoing],
      1,
      0,
      1,
      receipts: const ReceiptWatermarks(),
      myUserId: 'me',
    );
    await pumpEventQueue();
    expect(emissions, hasLength(1));
    expect(queryCount(inspector, 'update'), 0);
    final watermarks = ReceiptWatermarks(
      deliveredThrough: instant,
      seenThrough: instant,
    );
    await db.reconcileLatest(
      'room',
      [outgoing],
      1,
      0,
      1,
      receipts: watermarks,
      myUserId: 'me',
    );
    await seen.future;
    expect(emissions, hasLength(2));
    expect(emissions.last.single.isDelivered, true);
    inspector.clear();
    await db.reconcileLatest(
      'room',
      [outgoing],
      1,
      0,
      1,
      receipts: watermarks,
      myUserId: 'me',
    );
    await pumpEventQueue();
    expect(emissions, hasLength(2));
    expect(queryCount(inspector, 'update'), 1);
    final update = queries(inspector)
        .singleWhere((e) => e['name'] == 'query.update');
    expect((update['data'] as Map)['affectedRows'], 0);
    expect((await db.message(outgoing.id))!.isSeen, true);
  });

  test('replacement sequence history skips legacy watermark updates', () async {
    await db.upsertRoom(sequenceRoom());
    inspector.clear();
    await db.reconcileLatest(
      'room',
      List.generate(30, (index) => sequenced(index + 1)),
      1,
      0,
      0,
      myUserId: 'me',
      receipts: ReceiptWatermarks(
        deliveredThrough: instant,
        seenThrough: instant,
      ),
    );
    final updates = queries(inspector)
        .where((e) => e['name'] == 'query.update');
    expect(
      updates.every(
        (e) => !((e['data'] as Map)['sqlite'] as Map)['statement']
            .toString()
            .contains('UPDATE local_messages'),
      ),
      true,
    );
  });
}
