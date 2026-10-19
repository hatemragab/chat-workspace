import 'dart:convert';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/chat_api.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/local_log_exporter.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:chat_workspace/core/outbox_send_queue.dart';
import 'package:chat_workspace/core/server_health_monitor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'outbox correlation and retry metadata survive content-free inspection',
    () {
      final inspector = DebugInspector(enabled: true);
      inspector.updateContext(
        userId: 'me',
        sessionGeneration: 9,
        roomId: 'room',
      );
      inspector.record(
        'outbox',
        'waiting',
        data: {
          'operationId': 'stable-operation',
          'enqueueOrder': 7,
          'retryCount': 2,
          'attempt': 3,
          'physicalAttempts': 3,
          'sessionPhysicalAttempts': 12,
          'queuedCount': 2,
          'failedCount': 1,
          'pausedCount': 0,
          'running': false,
          'queuePaused': false,
          'healthStatus': 'unavailable',
          'outcomeUnknown': true,
          'nextRetryAt': '2026-10-18T11:00:00.000Z',
          'reason': 'service_unavailable',
          'text': 'private-message-body',
          'token': 'private-bearer',
          'uploadBytes': [1, 2, 3],
        },
      );
      final snapshot = inspector.snapshot();
      final events = (snapshot['events']! as List).cast<Map<String, Object?>>();
      final event = events.lastWhere((e) => e['category'] == 'outbox');
      final data = event['data']! as Map;
      expect(data['operationId'], 'stable-operation');
      expect(data['enqueueOrder'], 7);
      expect(data['nextRetryAt'], '2026-10-18T11:00:00.000Z');
      expect(data['physicalAttempts'], 3);
      expect(data['sessionPhysicalAttempts'], 12);
      expect(data['queuedCount'], 2);
      expect(data['failedCount'], 1);
      expect(data['pausedCount'], 0);
      expect(data['running'], false);
      expect(data['queuePaused'], false);
      expect(data['healthStatus'], 'unavailable');
      expect(data['outcomeUnknown'], true);
      expect(event['userId'], 'me');
      expect(event['roomId'], 'room');
      final encoded = jsonEncode(snapshot);
      expect(encoded, isNot(contains('private-message-body')));
      expect(encoded, isNot(contains('private-bearer')));
      expect(encoded, isNot(contains('uploadBytes')));
      inspector.dispose();
    },
  );

  test('queue transitions export fresh counts without refreshing inspector metrics', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initializeSession('me');
    final api = ChatApi(enableHttpLogging: false);
    final inspector = DebugInspector(enabled: true);
    final health = ServerHealthMonitor(
      healthUri: Uri.parse('http://localhost/health'),
      probe: () async => true,
      inspector: inspector,
    );
    for (final key in ['bad', 'good']) {
      await db.enqueueOutboundMessage(
        ChatMessage(
          id: 'temp_$key',
          idempotencyKey: key,
          roomId: 'room',
          senderId: 'me',
          senderName: 'Me',
          type: 'text',
          text: key,
          status: 'queued',
          createdAt: DateTime.utc(2026),
        ),
      );
    }
    final queue = OutboxSendQueue(
      database: db,
      api: api,
      senderId: 'me',
      healthMonitor: health,
      inspector: inspector,
      isCurrentSession: () => true,
      onAuthenticationRequired: () {},
      send: (message) async {
        if (message.idempotencyKey == 'bad') {
          throw const ChatApiException(
            'Invalid.',
            statusCode: 400,
            kind: ChatFailureKind.validation,
            code: 'invalid_message',
          );
        }
        await db.upsertMessage(
          ChatMessage.fromJson({
            ...message.toJson(),
            'id': 'canonical',
            'status': 'sent',
          }),
        );
      },
    );
    try {
      queue.wake();
      await queue.idle;
      final events = (inspector.snapshot()['events']! as List)
          .cast<Map<String, Object?>>()
          .where((event) => event['category'] == 'outbox')
          .toList();
      final rejected =
          events.singleWhere((event) => event['name'] == 'rejected')['data']!
              as Map;
      expect(rejected['operationId'], 'bad');
      expect(rejected['enqueueOrder'], 1);
      expect(rejected['queuedCount'], 1);
      expect(rejected['failedCount'], 1);
      expect(rejected['pausedCount'], 0);
      final acknowledged =
          events.singleWhere(
                (event) => event['name'] == 'acknowledged',
              )['data']!
              as Map;
      expect(acknowledged['operationId'], 'good');
      expect(acknowledged['queuedCount'], 0);
      expect(acknowledged['failedCount'], 1);
      for (final event in events.where(
        (event) => event['phase'] == 'instant',
      )) {
        final data = event['data']! as Map;
        expect(data.containsKey('queuedCount'), true);
        expect(data.containsKey('failedCount'), true);
        expect(data.containsKey('pausedCount'), true);
        expect(data.containsKey('sessionPhysicalAttempts'), true);
        expect(data.containsKey('healthStatus'), true);
      }
    } finally {
      queue.dispose();
      inspector.dispose();
      api.dio.close(force: true);
      await db.close();
    }
  });

  test(
    'enqueue behind an offline head reports the new depth without a send',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.initializeSession('me');
      final api = ChatApi(enableHttpLogging: false);
      final inspector = DebugInspector(enabled: true);
      final health = ServerHealthMonitor(
        healthUri: Uri.parse('http://localhost/health'),
        probe: () async => false,
        recoveryInterval: const Duration(hours: 1),
        inspector: inspector,
      )..markUnavailable();
      Future<void> enqueue(String key) => db.enqueueOutboundMessage(
        ChatMessage(
          id: 'temp_$key',
          idempotencyKey: key,
          roomId: 'room',
          senderId: 'me',
          senderName: 'Me',
          type: 'text',
          text: key,
          status: 'queued',
          createdAt: DateTime.utc(2026),
        ),
      );
      await enqueue('head');
      var sends = 0;
      final queue = OutboxSendQueue(
        database: db,
        api: api,
        senderId: 'me',
        healthMonitor: health,
        inspector: inspector,
        isCurrentSession: () => true,
        onAuthenticationRequired: () {},
        send: (_) async {
          sends++;
        },
      );
      Map waitingSnapshot() =>
          (inspector.snapshot()['events']! as List)
                  .cast<Map<String, Object?>>()
                  .lastWhere(
                    (event) =>
                        event['category'] == 'outbox' &&
                        event['name'] == 'waiting_for_server',
                  )['data']!
              as Map;
      try {
        queue.wake();
        await queue.idle;
        expect(waitingSnapshot()['queuedCount'], 1);
        await enqueue('next');
        queue.wake();
        await queue.idle;
        final waiting = waitingSnapshot();
        expect(waiting['queuedCount'], 2);
        expect(waiting['failedCount'], 0);
        expect(waiting['pausedCount'], 0);
        expect(waiting['operationId'], 'head');
        expect(waiting['healthStatus'], 'unavailable');
        expect(waiting['reason'], 'server_unavailable');
        expect(waiting['retryCount'], 0);
        expect(sends, 0);
        expect(queue.physicalAttemptCount, 0);
      } finally {
        queue.dispose();
        inspector.dispose();
        api.dio.close(force: true);
        await db.close();
      }
    },
  );

  test(
    'critical outbox and health transitions have reserved exporter priority',
    () {
      for (final name in [
        'rejected',
        'needs_attention',
        'waiting_for_server',
        'paused',
      ]) {
        expect(
          LocalLogExporter.priorityForRecord({
            'category': 'outbox',
            'phase': 'instant',
            'name': name,
          }),
          2,
        );
      }
      expect(
        LocalLogExporter.priorityForRecord({
          'category': 'health',
          'phase': 'instant',
          'name': 'unavailable',
        }),
        2,
      );
      expect(
        LocalLogExporter.priorityForRecord({
          'category': 'outbox',
          'phase': 'instant',
          'name': 'acknowledged',
        }),
        1,
      );
    },
  );
}
