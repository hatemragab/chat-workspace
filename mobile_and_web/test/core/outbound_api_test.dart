import 'dart:async';
import 'dart:typed_data';

import 'package:chat_workspace/core/chat_api.dart';
import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/models.dart';
import 'package:chat_workspace/core/outbox_send_queue.dart';
import 'package:chat_workspace/core/server_health_monitor.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  FutureOr<ResponseBody> Function(RequestOptions) respond = (_) =>
      ResponseBody.fromString(
        '{"message":"unavailable"}',
        503,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Dio dio;
  late _Adapter adapter;
  late ChatApi api;
  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'http://chat.test'));
    adapter = _Adapter();
    dio.httpClientAdapter = adapter;
    api = ChatApi(
      dio: dio,
      enableHttpLogging: false,
      outboundRetryDelays: const [Duration.zero, Duration.zero],
    );
    api.setToken('old-session', userId: 'me');
  });
  tearDown(() => dio.close(force: true));

  test(
    'only owned message requests retry and exactly three physical attempts',
    () async {
      await expectLater(
        api.post('/messages', {'text': 'not queue owned'}),
        throwsA(isA<ChatApiException>()),
      );
      expect(adapter.requests, hasLength(1));
      adapter.requests.clear();
      var physical = 0;
      await expectLater(
        api.runOutboundAttempt(
          isCurrentSession: () => true,
          onPhysicalAttempt: () async {
            physical++;
          },
          operation: () => api.post('/messages', {'idempotencyKey': 'same'}),
        ),
        throwsA(isA<ChatApiException>()),
      );
      expect(adapter.requests, hasLength(3));
      expect(physical, 3);
      expect(
        adapter.requests.map((r) => r.data['idempotencyKey']),
        everyElement('same'),
      );
      adapter.requests.clear();
      await expectLater(
        api.runOutboundAttempt(
          isCurrentSession: () => true,
          operation: () =>
              api.post('/rooms/group', {'title': 'no global retry'}),
        ),
        throwsA(isA<ChatApiException>()),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'server rejection and rate limit preserve typed fields without fast retry',
    () async {
      for (final status in [400, 401, 403, 409, 413, 422, 429]) {
        adapter.requests.clear();
        adapter.respond = (_) => ResponseBody.fromString(
          '{"detail":"Rejected","code":"message_rejected","retryable":false}',
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
            'retry-after': ['17'],
            'x-request-id': ['request-one'],
          },
        );
        await expectLater(
          api.runOutboundAttempt(
            isCurrentSession: () => true,
            operation: () => api.post('/messages', {}),
          ),
          throwsA(
            isA<ChatApiException>()
                .having((e) => e.statusCode, 'status', status)
                .having((e) => e.code, 'code', 'message_rejected')
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 17),
                )
                .having((e) => e.requestId, 'requestId', 'request-one'),
          ),
        );
        expect(adapter.requests, hasLength(1));
      }
    },
  );

  test(
    'a shared physical budget stops fast retries before exceeding the cap',
    () async {
      var attempts = 2;
      await expectLater(
        api.runOutboundAttempt(
          isCurrentSession: () => true,
          canRetry: () => attempts < 3,
          onPhysicalAttempt: () async {
            attempts++;
          },
          operation: () => api.post('/messages', {}),
        ),
        throwsA(isA<ChatApiException>()),
      );
      expect(attempts, 3);
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'credential replacement prevents a delayed retry using a later account',
    () async {
      final first = Completer<void>();
      dio.close(force: true);
      dio = Dio(BaseOptions(baseUrl: 'http://chat.test'));
      dio.httpClientAdapter = adapter;
      api = ChatApi(
        dio: dio,
        enableHttpLogging: false,
        outboundRetryDelays: const [Duration(milliseconds: 20)],
      );
      api.setToken('old', userId: 'me');
      adapter.respond = (_) {
        if (!first.isCompleted) first.complete();
        return ResponseBody.fromString(
          '{}',
          503,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      };
      var current = true;
      final request = api.runOutboundAttempt(
        isCurrentSession: () => current,
        operation: () => api.post('/messages', {}),
      );
      final assertion = expectLater(request, throwsA(isA<ChatApiException>()));
      await first.future;
      current = false;
      api.setToken('new', userId: 'other');
      await assertion;
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.headers['Authorization'], 'Bearer old');
    },
  );

  test(
    'local image validation is permanent even without an HTTP status',
    () async {
      await expectLater(
        api.uploadImage(Uint8List(0), 'image.png'),
        throwsA(
          isA<ChatApiException>()
              .having((e) => e.kind, 'kind', ChatFailureKind.validation)
              .having((e) => e.isTransient, 'transient', false),
        ),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'queue and interceptor share one budget of three physical requests',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.initializeSession('me');
      await db.upsertMessage(
        ChatMessage(
          id: 'temp_one',
          idempotencyKey: 'one',
          roomId: 'room',
          senderId: 'me',
          senderName: 'Me',
          type: 'text',
          text: 'durable',
          status: 'queued',
          createdAt: DateTime.utc(2026),
        ),
      );
      final health = ServerHealthMonitor(
        healthUri: Uri.parse('http://chat.test/health'),
        probe: () async => true,
      );
      final queue = OutboxSendQueue(
        database: db,
        api: api,
        senderId: 'me',
        healthMonitor: health,
        isCurrentSession: () => true,
        onAuthenticationRequired: () {},
        send: (message) async {
          await api.post('/messages', {
            'idempotencyKey': message.idempotencyKey,
          });
        },
      );
      try {
        queue.wake();
        await queue.idle;
        queue.wake();
        await queue.idle;
        expect(adapter.requests, hasLength(3));
        expect(queue.physicalAttemptCount, 3);
        final head = (await db.nextOutboundMessage('me'))!;
        expect(head.retryCount, 3);
        expect(head.outboxPaused, true);
        expect(queue.pausedCount, 1);
      } finally {
        queue.dispose();
        await db.close();
      }
    },
  );

  test(
    'outbound deadline cancels stalled transfers and leaves no late retry',
    () async {
      dio.close(force: true);
      dio = Dio(BaseOptions(baseUrl: 'http://chat.test'));
      dio.httpClientAdapter = adapter;
      api = ChatApi(
        dio: dio,
        enableHttpLogging: false,
        outboundAttemptTimeout: const Duration(milliseconds: 20),
        outboundRetryDelays: const [Duration.zero],
      );
      final stalled = Completer<ResponseBody>();
      adapter.respond = (_) => stalled.future;
      await expectLater(
        api.runOutboundAttempt(
          isCurrentSession: () => true,
          operation: () =>
              api.uploadImage(Uint8List.fromList([1, 2, 3]), 'image.png'),
        ),
        throwsA(
          isA<ChatApiException>()
              .having((e) => e.kind, 'kind', ChatFailureKind.timeout)
              .having((e) => e.code, 'code', 'outbound_deadline_exceeded'),
        ),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.sendTimeout, const Duration(seconds: 30));
      stalled.complete(
        ResponseBody.fromString(
          '{"imageUrl":"/public/uploads/image.png"}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'timeout followed by 400 in one retry burst remains uncertain and ordered',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.initializeSession('me');
      for (final key in ['one', 'two']) {
        await db.upsertMessage(
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
      var requests = 0;
      adapter.respond = (options) {
        if (++requests == 1) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return ResponseBody.fromString(
          '{"message":"Invalid reply"}',
          400,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      };
      final health = ServerHealthMonitor(
        healthUri: Uri.parse('http://chat.test/health'),
        probe: () async => true,
      );
      final queue = OutboxSendQueue(
        database: db,
        api: api,
        senderId: 'me',
        healthMonitor: health,
        isCurrentSession: () => true,
        onAuthenticationRequired: () {},
        send: (message) async {
          await api.post('/messages', {
            'idempotencyKey': message.idempotencyKey,
          });
        },
      );
      try {
        queue.wake();
        await queue.idle;
        queue.wake();
        await queue.idle;
        expect(requests, 2);
        final head = (await db.nextOutboundMessage('me'))!;
        expect(head.idempotencyKey, 'one');
        expect(head.status, 'queued');
        expect(head.outboxPaused, true);
        expect(head.outcomeUnknown, true);
      } finally {
        queue.dispose();
        await db.close();
      }
    },
  );
}
