import 'dart:async';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/chat_api.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:chat_workspace/core/outbox_send_queue.dart';
import 'package:chat_workspace/core/server_health_monitor.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage queued(String key) => ChatMessage(
  id: 'temp_$key',
  idempotencyKey: key,
  roomId: 'room',
  senderId: 'me',
  senderName: 'Me',
  type: 'text',
  text: key,
  status: 'queued',
  createdAt: DateTime.utc(2026),
);

Future<void> acknowledge(AppDatabase db, ChatMessage message) =>
    db.upsertMessage(
      ChatMessage.fromJson({
        ...message.toJson(),
        'id': 'server_${message.idempotencyKey}',
        'status': 'sent',
      }),
    );

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), true);
}

class OutboxQueryProbe extends QueryInterceptor {
  int snapshotReads = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.startsWith('WITH counts AS')) ++snapshotReads;
    return executor.runSelect(statement, args);
  }
}

class OutboxProbeDatabase extends AppDatabase {
  OutboxProbeDatabase(this.probe)
    : super(NativeDatabase.memory().interceptWith(probe));

  final OutboxQueryProbe probe;
  int countReads = 0, headReads = 0;
  Future<void> Function(ChatMessage?)? afterHeadRead;

  @override
  Future<OutboundSnapshot> outboundSnapshot(String senderId) async {
    final snapshot = await super.outboundSnapshot(senderId);
    await afterHeadRead?.call(snapshot.head);
    return snapshot;
  }

  @override
  Stream<OutboundSnapshot> watchOutboundSnapshot(String senderId) =>
      super.watchOutboundSnapshot(senderId).asyncMap((snapshot) async {
        await afterHeadRead?.call(snapshot.head);
        return snapshot;
      });

  @override
  Future<({int queued, int failed, int paused})> outboundCounts(
    String senderId,
  ) {
    ++countReads;
    return super.outboundCounts(senderId);
  }

  @override
  Future<ChatMessage?> nextOutboundMessage(String senderId) async {
    ++headReads;
    final head = await super.nextOutboundMessage(senderId);
    await afterHeadRead?.call(head);
    return head;
  }
}

void main() {
  late OutboxProbeDatabase db;
  late ChatApi api;
  late ServerHealthMonitor health;
  OutboxSendQueue? queue;
  var ready = true;
  var current = true;
  setUp(() async {
    db = OutboxProbeDatabase(OutboxQueryProbe());
    await db.initializeSession('me');
    api = ChatApi(enableHttpLogging: false);
    ready = true;
    current = true;
    health = ServerHealthMonitor(
      healthUri: Uri.parse('http://localhost/health'),
      probe: () async => ready,
      recoveryInterval: const Duration(milliseconds: 20),
    );
  });
  tearDown(() async {
    current = false;
    queue?.dispose();
    queue = null;
    health.dispose();
    api.dio.close(force: true);
    await db.close();
  });

  OutboxSendQueue create(
    Future<void> Function(ChatMessage) send, {
    void Function()? auth,
    void Function()? onStateChanged,
  }) => queue = OutboxSendQueue(
    database: db,
    api: api,
    senderId: 'me',
    send: send,
    healthMonitor: health,
    isCurrentSession: () => current,
    onAuthenticationRequired: auth ?? () {},
    onStateChanged: onStateChanged,
    retryDelay: const Duration(milliseconds: 20),
    random: () => 0,
  );

  test('ten acknowledgments do not reread counts or watch every write', () async {
    for (var i = 0; i < 10; ++i) {
      await db.enqueueOutboundMessage(queued('batch_$i'));
    }
    final starts = <String>[];
    var notifications = 0;
    final q = create((message) async {
      starts.add(message.idempotencyKey);
      await acknowledge(db, message);
    }, onStateChanged: () => ++notifications);
    q.wake();
    await q.idle;
    // Allow the parked observer's initial read to finish. It must not launch an
    // extra empty drain after observing the state the worker already read.
    await until(() => db.probe.snapshotReads > 0);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await q.idle;
    expect(starts, [for (var i = 0; i < 10; ++i) 'batch_$i']);
    expect(db.countReads, 0);
    expect(db.headReads, 0);
    expect(db.probe.snapshotReads, lessThanOrEqualTo(12));
    expect(q.queuedCount, 0);
    expect(q.failedCount, 0);
    expect(notifications, lessThanOrEqualTo(31));
    final beforeIdleWake = notifications;
    q.wake();
    await q.idle;
    expect(notifications, beforeIdleWake);
  });

  test(
    'ten independent sends reuse each observed head and empty snapshot',
    () async {
      final starts = <String>[];
      final q = create((message) async {
        starts.add(message.idempotencyKey);
        await acknowledge(db, message);
      });
      await until(() => db.probe.snapshotReads > 0);
      await q.idle;
      db.probe.snapshotReads = 0;
      for (var i = 0; i < 10; ++i) {
        await db.enqueueOutboundMessage(queued('isolated_$i'));
        q.wakeAfterEnqueue();
        await q.idle;
        expect(starts.length, i + 1);
        expect(q.queuedCount, 0);
        expect(q.isRunning, false);
        await Future<void>.delayed(Duration.zero);
      }
      expect(starts, [for (var i = 0; i < 10; ++i) 'isolated_$i']);
      expect(db.countReads, 0);
      expect(db.headReads, 0);
      expect(db.probe.snapshotReads, lessThanOrEqualTo(20));
    },
  );

  test('observer catches enqueue after the drain reads its final empty head', () async {
    await db.enqueueOutboundMessage(queued('a'));
    var inserted = false;
    db.afterHeadRead = (head) async {
      if (head == null && !inserted) {
        inserted = true;
        // Deliberately no explicit wake: this commits after the empty read and
        // before the worker reattaches its parked-head observer.
        await db.enqueueOutboundMessage(queued('b'));
      }
    };
    final starts = <String>[];
    final q = create((message) async {
      starts.add(message.idempotencyKey);
      await acknowledge(db, message);
    });
    q.wake();
    await until(() => starts.length == 2);
    await q.idle;
    expect(starts, ['a', 'b']);
    expect(q.queuedCount, 0);
  });

  test(
    'readiness acknowledgment retires the head before HTTP submission',
    () async {
      await db.enqueueOutboundMessage(queued('a'));
      await db.enqueueOutboundMessage(queued('b'));
      final checkStarted = Completer<void>();
      final allowReady = Completer<bool>();
      health.dispose();
      health = ServerHealthMonitor(
        healthUri: Uri.parse('http://localhost/health'),
        probe: () {
          if (!checkStarted.isCompleted) checkStarted.complete();
          return allowReady.future;
        },
        recoveryInterval: const Duration(hours: 1),
      )..markUnavailable();
      final starts = <String>[];
      final q = create((message) async {
        starts.add(message.idempotencyKey);
        await acknowledge(db, message);
      });
      q.wake();
      await checkStarted.future;
      await acknowledge(db, (await db.messageByIdempotencyKey('me', 'a'))!);
      allowReady.complete(true);
      await q.idle;
      expect(starts, ['b']);
      expect(q.queuedCount, 0);
    },
  );

  test('new sends and repeated wakes share one durable FIFO lane', () async {
    final gate = Completer<void>();
    final starts = <String>[];
    var active = 0, maximum = 0;
    for (final key in ['a', 'b', 'c']) {
      await db.upsertMessage(queued(key));
    }
    final q = create((message) async {
      starts.add(message.idempotencyKey);
      active++;
      if (active > maximum) maximum = active;
      if (message.idempotencyKey == 'a') await gate.future;
      await acknowledge(db, message);
      active--;
    });
    q.wake();
    await until(() => starts.isNotEmpty);
    q.wake();
    q.wake();
    expect(starts, ['a']);
    gate.complete();
    await q.idle;
    expect(starts, ['a', 'b', 'c']);
    expect(maximum, 1);
    expect(await db.nextOutboundMessage('me'), isNull);
  });

  test(
    'definitive invalid message stops retrying and allows the next',
    () async {
      await db.upsertMessage(queued('bad'));
      await db.upsertMessage(queued('good'));
      final starts = <String>[];
      final q = create((message) async {
        starts.add(message.idempotencyKey);
        if (message.idempotencyKey == 'bad') {
          throw const ChatApiException(
            'Missing text.',
            statusCode: 400,
            kind: ChatFailureKind.validation,
            code: 'invalid_message',
          );
        }
        await acknowledge(db, message);
      });
      q.wake();
      await q.idle;
      q.wake();
      await q.idle;
      expect(starts, ['bad', 'good']);
      final bad = (await db.messageByIdempotencyKey('me', 'bad'))!;
      expect(bad.status, 'failed');
      expect(bad.outcomeUnknown, false);
    },
  );

  test(
    'unknown local error pauses the head rather than becoming offline',
    () async {
      await db.upsertMessage(queued('a'));
      await db.upsertMessage(queued('b'));
      var calls = 0;
      final q = create((_) async {
        calls++;
        throw StateError('coding failure');
      });
      q.wake();
      await q.idle;
      q.wake();
      await q.idle;
      expect(calls, 1);
      final head = (await db.nextOutboundMessage('me'))!;
      expect(head.outboxPaused, true);
      expect(head.outcomeUnknown, true);
      expect(head.status, 'queued');
    },
  );

  test(
    'explicit Retry replaces the observed paused head before sending',
    () async {
      await db.enqueueOutboundMessage(queued('a'));
      var fail = true;
      var calls = 0;
      final q = create((message) async {
        ++calls;
        if (fail) throw StateError('unconfirmed local outcome');
        await acknowledge(db, message);
      });
      q.wake();
      await q.idle;
      final head = (await db.nextOutboundMessage('me'))!;
      expect(head.outboxPaused, true);
      fail = false;
      await q.retry(head);
      await q.idle;
      expect(calls, 2);
      expect((await db.messageByIdempotencyKey('me', 'a'))!.status, 'sent');
      expect(q.pausedCount, 0);
      expect(q.queuedCount, 0);
    },
  );

  test(
    'Retry during stale paused-snapshot delivery retains its refresh',
    () async {
      await db.upsertMessage(queued('a').copyWith(outboxPaused: true));
      final snapshotRead = Completer<void>();
      final releaseSnapshot = Completer<void>();
      var held = false;
      db.afterHeadRead = (head) async {
        if (!held && head?.outboxPaused == true) {
          held = true;
          snapshotRead.complete();
          await releaseSnapshot.future;
        }
      };
      var sends = 0;
      final q = create((message) async {
        ++sends;
        await acknowledge(db, message);
      });
      q.wake();
      await snapshotRead.future;
      final head = (await db.messageByIdempotencyKey('me', 'a'))!;
      await q.retry(head);
      releaseSnapshot.complete();
      await q.idle;
      expect(sends, 1);
      expect((await db.messageByIdempotencyKey('me', 'a'))!.status, 'sent');
      expect(q.queuedCount, 0);
      expect(q.pausedCount, 0);
    },
  );

  test(
    'offline recovery retains the same head and does not burn its budget',
    () async {
      await db.upsertMessage(queued('a'));
      await db.upsertMessage(queued('b'));
      final starts = <String>[];
      ready = false;
      var fail = true;
      final q = create((message) async {
        starts.add(message.idempotencyKey);
        if (fail) {
          throw const ChatApiException(
            'Offline',
            kind: ChatFailureKind.transport,
          );
        }
        await acknowledge(db, message);
      });
      q.wake();
      await q.idle;
      expect(starts, ['a']);
      expect((await db.nextOutboundMessage('me'))!.retryCount, 0);
      expect((await db.nextOutboundMessage('me'))!.outcomeUnknown, true);
      fail = false;
      ready = true;
      await health.check(force: true);
      await until(() => starts.length == 3);
      await q.idle;
      expect(starts, ['a', 'a', 'b']);
    },
  );

  test(
    'healthy repeated server failures pause after three total attempts',
    () async {
      await db.upsertMessage(queued('a'));
      await db.upsertMessage(queued('b'));
      var calls = 0;
      final q = create((_) async {
        calls++;
        throw const ChatApiException(
          'Server failure',
          statusCode: 500,
          kind: ChatFailureKind.unavailable,
        );
      });
      q.wake();
      await until(() => calls == 3);
      await q.idle;
      q.wake();
      await q.idle;
      expect(calls, 3);
      expect((await db.nextOutboundMessage('me'))!.outboxPaused, true);
      expect((await db.nextOutboundMessage('me'))!.retryCount, 3);
    },
  );

  test(
    '429 deadline survives healthy wakeups and blocks later messages',
    () async {
      await db.upsertMessage(queued('a'));
      await db.upsertMessage(queued('b'));
      var calls = 0;
      final q = create((_) async {
        calls++;
        throw const ChatApiException(
          'Slow down',
          statusCode: 429,
          retryAfter: Duration(hours: 1),
        );
      });
      q.wake();
      await q.idle;
      final deadline = (await db.nextOutboundMessage('me'))!.nextAttemptAt;
      health.markReady();
      q.wake();
      await q.idle;
      expect(calls, 1);
      expect((await db.nextOutboundMessage('me'))!.nextAttemptAt, deadline);
      expect((await db.nextOutboundMessage('me'))!.retryCount, 0);
    },
  );

  test('racing inbox acknowledgment wins over a failed HTTP result', () async {
    await db.upsertMessage(queued('a'));
    final q = create((message) async {
      await acknowledge(db, message);
      throw const ChatApiException('Timeout', kind: ChatFailureKind.timeout);
    });
    q.wake();
    await q.idle;
    expect((await db.messageByIdempotencyKey('me', 'a'))!.status, 'sent');
    expect(await db.nextOutboundMessage('me'), isNull);
  });

  test('401 pauses all work until same-account resume', () async {
    await db.upsertMessage(queued('a'));
    await db.upsertMessage(queued('b'));
    var expired = 0, calls = 0, reject = true;
    final q = create((message) async {
      calls++;
      if (reject) throw const ChatApiException('Sign in', statusCode: 401);
      await acknowledge(db, message);
    }, auth: () => expired++);
    q.wake();
    await q.idle;
    q.wake();
    await q.idle;
    expect(calls, 1);
    expect(expired, 1);
    expect(q.isPaused, true);
    reject = false;
    q.resume();
    await q.idle;
    expect(calls, 3);
    expect(await db.nextOutboundMessage('me'), isNull);
  });

  test(
    'a rejection after an earlier uncertain attempt parks the head',
    () async {
      await db.upsertMessage(queued('a').copyWith(outcomeUnknown: true));
      await db.upsertMessage(queued('b'));
      var calls = 0;
      final q = create((_) async {
        calls++;
        throw const ChatApiException('Invalid reply', statusCode: 400);
      });
      q.wake();
      await q.idle;
      q.wake();
      await q.idle;
      expect(calls, 1);
      final head = (await db.nextOutboundMessage('me'))!;
      expect(head.idempotencyKey, 'a');
      expect(head.status, 'queued');
      expect(head.outboxPaused, true);
      expect(head.outcomeUnknown, true);
    },
  );

  test(
    '503 Retry-After cannot bypass the healthy failure attempt budget',
    () async {
      await db.upsertMessage(queued('a'));
      await db.upsertMessage(queued('b'));
      var calls = 0;
      final q = create((_) async {
        calls++;
        throw const ChatApiException(
          'Unavailable',
          statusCode: 503,
          kind: ChatFailureKind.unavailable,
          retryAfter: Duration.zero,
        );
      });
      q.wake();
      await until(() => calls == 3);
      await q.idle;
      q.wake();
      await q.idle;
      expect(calls, 3);
      final head = (await db.nextOutboundMessage('me'))!;
      expect(head.retryCount, 3);
      expect(head.outboxPaused, true);
    },
  );

  test(
    'restart cannot grant more attempts to an exhausted durable head',
    () async {
      await db.upsertMessage(
        queued('a').copyWith(retryCount: 3, outcomeUnknown: true),
      );
      await db.upsertMessage(queued('b'));
      var calls = 0;
      final q = create((message) async {
        calls++;
        await acknowledge(db, message);
      });
      q.wake();
      await q.idle;
      expect(calls, 0);
      expect((await db.nextOutboundMessage('me'))!.outboxPaused, true);
    },
  );

  test('external acknowledgment of a parked head wakes the next operation', () async {
    await db.upsertMessage(queued('a'));
    await db.upsertMessage(queued('b'));
    final starts = <String>[];
    final q = create((message) async {
      starts.add(message.idempotencyKey);
      if (message.idempotencyKey == 'a') {
        throw const ChatApiException(
          'Could not interpret acknowledgment.',
          kind: ChatFailureKind.protocol,
        );
      }
      await acknowledge(db, message);
    });
    q.wake();
    await until(() => starts.length == 1);
    await q.idle;
    expect((await db.nextOutboundMessage('me'))!.outboxPaused, true);
    await acknowledge(db, (await db.messageByIdempotencyKey('me', 'a'))!);
    // No new enqueue, manual wake, resume or health transition follows the ack.
    await until(() => starts.length == 2);
    await q.idle;
    expect(starts, ['a', 'b']);
    expect(await db.nextOutboundMessage('me'), isNull);
  });
}
