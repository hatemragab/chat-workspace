import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_workspace/core/chat_api.dart';
import 'package:chat_workspace/core/debug_traffic_logger.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await requestStream?.drain<void>();
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response({
  int status = 200,
  Object body = const {'ok': true},
  List<String>? requestIds = const ['trace-safe_123.abc'],
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
    'X-Request-ID': ?requestIds,
    ...headers,
  },
);

Map<String, Object?> _headerNamesLowercase(Object? value) => {
  for (final entry in (value! as Map).entries)
    (entry.key as String).toLowerCase(): entry.value,
};

class _Harness {
  _Harness({
    bool enableHttpLogging = true,
    void Function(Map<String, Object?>)? writer,
    DebugTrafficLogger? trafficLogger,
  }) {
    dio = Dio(BaseOptions(baseUrl: 'https://private-host.example'));
    adapter = _Adapter((_) => _response());
    dio.httpClientAdapter = adapter;
    api = ChatApi(
      dio: dio,
      enableHttpLogging: enableHttpLogging,
      httpLogWriter: writer ?? records.add,
      trafficLogger: trafficLogger,
    );
    addTearDown(dio.close);
  }
  late final Dio dio;
  late final _Adapter adapter;
  late final ChatApi api;
  final records = <Map<String, Object?>>[];
}

void main() {
  Map<String, Object?> httpCompletion(DebugInspector inspector) =>
      (inspector.snapshot()['events']! as List)
          .cast<Map<String, Object?>>()
          .lastWhere(
            (event) => event['category'] == 'http' && event['phase'] == 'end',
          );

  test('inspector HTTP completion includes detached query and redacted response JSON', () async {
    final h = _Harness(
      trafficLogger: DebugTrafficLogger(enabled: true, writer: (_) {}),
    );
    final inspector = DebugInspector(enabled: true);
    h.api.debugInspector = inspector;
    addTearDown(inspector.dispose);
    h.api.setToken('private-bearer', userId: 'request-user');
    inspector.updateContext(userId: 'request-user', sessionGeneration: 3);
    final query = <String, dynamic>{
      'userIds': 'peer-one,peer-two',
      'token': 'private-query',
    };
    h.adapter.respond = (_) => _response(
      body: {
        'statuses': {'peer-one': true, 'peer-two': false},
        'lastSeenAt': {'peer-two': '2026-10-19T01:00:00Z'},
        'nested': {'accessToken': 'private-response'},
      },
    );
    await h.api.getMap('/presence/status', query: query);
    query['userIds'] = 'changed-later';
    final event = httpCompletion(inspector);
    final data = event['data']! as Map;
    final http = data['http']! as Map;
    expect(event['name'], 'GET:/presence/status');
    expect(event['userId'], 'request-user');
    expect(data['requestId'], 'trace-safe_123.abc');
    expect(http['query'], {
      'userIds': 'peer-one,peer-two',
      'token': '[REDACTED]',
    });
    expect(http['requestBody'], isNull);
    expect((http['responseBody']! as Map)['statuses'], {
      'peer-one': true,
      'peer-two': false,
    });
    expect(
      _headerNamesLowercase(http['requestHeaders'])['authorization'],
      '[REDACTED]',
    );
    expect(jsonEncode(event), isNot(contains('private-')));
    expect(
      () => (http['query']! as Map)['userIds'] = 'mutation',
      throwsUnsupportedError,
    );
  });

  test(
    'inspector retains HTTP error response and binary upload metadata',
    () async {
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(enabled: true, writer: (_) {}),
      );
      final inspector = DebugInspector(enabled: true);
      h.api.debugInspector = inspector;
      addTearDown(inspector.dispose);
      h.adapter.respond = (_) => _response(
        status: 403,
        body: {
          'message': 'Membership required',
          'password': 'private-error-password',
        },
      );
      await expectLater(
        h.api.post('/messages', {'text': 'Outgoing text'}),
        throwsA(isA<ChatApiException>()),
      );
      var data = httpCompletion(inspector)['data']! as Map;
      expect(data['status'], 403);
      expect((data['http']! as Map)['requestBody'], {'text': 'Outgoing text'});
      expect((data['http']! as Map)['responseBody'], {
        'message': 'Membership required',
        'password': '[REDACTED]',
      });
      h.adapter.respond = (_) =>
          _response(body: {'imageUrl': '/public/uploads/image.png'});
      await h.api.uploadImage(
        Uint8List.fromList(utf8.encode('private-image-bytes')),
        'photo.png',
      );
      data = httpCompletion(inspector)['data']! as Map;
      final body = (data['http']! as Map)['requestBody']! as Map;
      expect(body['type'], 'multipart/form-data');
      expect(
        (((body['files']! as List).single as Map)['file']! as Map)['filename'],
        'photo.png',
      );
      expect(jsonEncode(inspector.snapshot()), isNot(contains('private-')));
    },
  );

  test('inspector network failures retain request data without inventing a response', () async {
    final h = _Harness(
      trafficLogger: DebugTrafficLogger(enabled: true, writer: (_) {}),
    );
    final inspector = DebugInspector(enabled: true);
    h.api.debugInspector = inspector;
    addTearDown(inspector.dispose);
    h.adapter.respond = (options) => throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionTimeout,
      message: 'private-network-error',
    );
    await expectLater(
      h.api.post('/messages', {'text': 'Offline text'}),
      throwsA(isA<ChatApiException>()),
    );
    final data = httpCompletion(inspector)['data']! as Map;
    expect(data['status'], isNull);
    expect(data['outcome'], 'connectionTimeout');
    expect((data['http']! as Map)['requestBody'], {'text': 'Offline text'});
    expect((data['http']! as Map)['responseBody'], isNull);
    expect(
      jsonEncode(inspector.snapshot()),
      isNot(contains('private-network-error')),
    );
  });

  test('inspector HTTP payload opt-out clears retained data and fences in-flight capture', () async {
    final h = _Harness(
      trafficLogger: DebugTrafficLogger(enabled: true, writer: (_) {}),
    );
    final inspector = DebugInspector(enabled: true);
    h.api.debugInspector = inspector;
    addTearDown(inspector.dispose);
    await h.api.post('/messages', {'text': 'Previously captured'});
    final started = Completer<void>(), release = Completer<void>();
    h.adapter.respond = (_) async {
      started.complete();
      await release.future;
      return _response(body: {'text': 'Late response'});
    };
    final pending = h.api.post('/messages', {'text': 'In flight'});
    await started.future;
    h.api.setDebugTrafficLoggingEnabled(false);
    expect(
      jsonEncode(inspector.snapshot()),
      isNot(contains('Previously captured')),
    );
    h.api.setDebugTrafficLoggingEnabled(true);
    release.complete();
    await pending;
    expect(
      (httpCompletion(inspector)['data']! as Map).containsKey('http'),
      isFalse,
    );
    expect(jsonEncode(inspector.snapshot()), isNot(contains('Late response')));
    h.api.setDebugTrafficLoggingEnabled(false);
    h.adapter.respond = (_) => _response();
    await h.api.post('/messages', {'text': 'Metadata only'});
    expect(
      (httpCompletion(inspector)['data']! as Map).containsKey('http'),
      isFalse,
    );
  });

  test('oversized inspector HTTP body is explicitly omitted without losing the completion', () async {
    final h = _Harness(
      trafficLogger: DebugTrafficLogger(enabled: true, writer: (_) {}),
    );
    final inspector = DebugInspector(enabled: true);
    h.api.debugInspector = inspector;
    addTearDown(inspector.dispose);
    h.adapter.respond = (_) => _response(body: {'text': 'x' * 40000});
    await h.api.getMap('/presence/status', query: {'userIds': 'peer-one'});
    final data = httpCompletion(inspector)['data']! as Map;
    final http = data['http']! as Map;
    expect(data['status'], 200);
    expect(http['query'], {'userIds': 'peer-one'});
    expect((http['responseBody']! as Map)['payloadOmitted'], isTrue);
    expect(
      utf8.encode(jsonEncode(http)).length,
      lessThanOrEqualTo(DebugHttpTrafficDetails.maxBytes),
    );
  });

  test('retiring presence cancels only ephemeral polls and records cancellation without failure', () async {
    final h = _Harness();
    final inspector = DebugInspector(enabled: true);
    h.api.debugInspector = inspector;
    addTearDown(inspector.dispose);
    final pollsStarted = Completer<void>();
    final remainingStarted = Completer<void>();
    final pollingResponse = Completer<void>();
    final otherResponse = Completer<void>();
    var polls = 0, others = 0;
    h.adapter.respond = (options) {
      if (options.path == '/presence/heartbeat' ||
          options.path == '/presence/status') {
        if (++polls == 2) pollsStarted.complete();
        return pollingResponse.future.then((_) => _response());
      }
      if (++others == 3) remainingStarted.complete();
      return otherResponse.future.then((_) => _response());
    };
    final heartbeat = h.api.post('/presence/heartbeat');
    final status = h.api.getMap('/presence/status');
    final heartbeatCancelled = expectLater(
      heartbeat,
      throwsA(isA<ChatApiException>()),
    );
    final statusCancelled = expectLater(
      status,
      throwsA(isA<ChatApiException>()),
    );
    final otherRequests = Future.wait([
      h.api.post('/presence/offline'),
      h.api.getMap('/rooms/delta'),
      h.api.post('/messages', {'text': 'private-body'}),
    ]);
    await Future.wait([pollsStarted.future, remainingStarted.future]);
    h.api.cancelPresenceRequests();
    await Future.wait([heartbeatCancelled, statusCancelled]);
    expect(
      h.adapter.requests
          .where((request) => request.cancelToken?.isCancelled == true)
          .map((request) => request.path),
      unorderedEquals(['/presence/heartbeat', '/presence/status']),
    );
    otherResponse.complete();
    expect(await otherRequests, hasLength(3));
    pollingResponse.complete();
    final events = (inspector.snapshot()['events']! as List)
        .cast<Map<String, Object?>>();
    final cancelled = events.where(
      (event) =>
          event['phase'] == 'end' &&
          (event['data']! as Map)['outcome'] == 'cancel',
    );
    expect(cancelled, hasLength(2));
    expect(
      cancelled.every(
        (event) => !(event['data']! as Map).containsKey('errorType'),
      ),
      true,
    );
  });

  test(
    'HTTP completion records correlate safely without changing requests',
    () async {
      final h = _Harness();
      h.api.setToken('private-access-token');
      final result = await h.api.request(
        'GET',
        '/rooms/private-room-id/messages/around/private-target-id'
            '?secret=private-inline-query',
        data: {'password': 'private-password', 'text': 'private-message-body'},
        query: {'secret': 'private-query'},
      );

      expect(result, {'ok': true});
      expect(h.records, hasLength(1));
      final record = h.records.single;
      expect(record['event'], 'http_request');
      expect(record['method'], 'GET');
      expect(
        record['route'],
        '/rooms/:roomId/messages/around/:targetMessageId',
      );
      expect(record['status'], 200);
      expect(record['durationMs'], greaterThanOrEqualTo(0));
      expect(DateTime.parse(record['timestamp']! as String).isUtc, isTrue);
      expect(record['requestId'], 'trace-safe_123.abc');
      expect(record['outcome'], 'response');
      expect(h.api.recentApiRequests, [record]);
      expect(
        h.adapter.requests.single.headers['Authorization'],
        'Bearer private-access-token',
      );
      expect(
        h.adapter.requests.single.headers.keys.any(
          (name) => name.toLowerCase() == 'x-request-id',
        ),
        isFalse,
      );
      final logged = jsonEncode(h.records);
      for (final secret in [
        'private-host',
        'private-room-id',
        'private-target-id',
        'private-inline-query',
        'private-query',
        'private-password',
        'private-message-body',
        'private-access-token',
      ]) {
        expect(logged, isNot(contains(secret)));
      }
    },
  );

  test(
    'known dynamic endpoints log only their approved route templates',
    () async {
      final h = _Harness();
      for (final (path, template) in [
        ('/rooms/direct-peer/private-peer', '/rooms/direct-peer/:peerUserId'),
        ('/rooms/private-room/preferences', '/rooms/:roomId/preferences'),
        ('/rooms/private-room/messages', '/rooms/:roomId/messages'),
        ('/rooms/private-room/delivered', '/rooms/:roomId/delivered'),
        ('/rooms/private-room/seen', '/rooms/:roomId/seen'),
        ('/messages/private-message', '/messages/:messageId'),
        ('/messages/private-message/for-all', '/messages/:messageId/for-all'),
        ('/messages/private-message/for-me', '/messages/:messageId/for-me'),
      ]) {
        await h.api.request('GET', path);
        expect(h.records.last['route'], template);
      }
      expect(h.records, hasLength(8));
      expect(jsonEncode(h.records), isNot(contains('private-')));
    },
  );

  test(
    'HTTP failures log exactly once without response or exception content',
    () async {
      final h = _Harness();
      for (final status in [400, 503]) {
        h.adapter.respond = (_) => _response(
          status: status,
          body: {'detail': 'private-server-detail', 'token': 'private-token'},
        );
        await expectLater(
          h.api.post('/messages', {'text': 'private-text'}),
          throwsA(isA<ChatApiException>()),
        );
        expect(h.records.last['status'], status);
        expect(h.records.last['outcome'], 'badResponse');
        expect(h.records.last['requestId'], 'trace-safe_123.abc');
      }
      expect(h.records, hasLength(2));
      expect(jsonEncode(h.records), isNot(contains('private-')));
    },
  );

  test(
    'network failures have no fabricated server correlation or leaked error',
    () async {
      final h = _Harness();
      h.adapter.respond = (options) => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'private-network-message at https://private-host.example',
        error: StateError('private-exception'),
      );
      await expectLater(
        h.api.getMap('/rooms/private-room/messages'),
        throwsA(isA<ChatApiException>()),
      );
      expect(h.records, hasLength(1));
      expect(h.records.single['route'], '/rooms/:roomId/messages');
      expect(h.records.single['status'], isNull);
      expect(h.records.single['requestId'], isNull);
      expect(h.records.single['outcome'], 'connectionError');
      expect(jsonEncode(h.records), isNot(contains('private-')));
    },
  );

  test(
    'multipart upload success and failure share the safe completion logger',
    () async {
      final h = _Harness();
      h.adapter.respond = (_) => _response(
        body: {'imageUrl': '/public/uploads/private-stored-file.png'},
      );
      final bytes = Uint8List.fromList(utf8.encode('private-image-bytes'));
      expect(
        await h.api.uploadImage(bytes, 'private-local-file.png'),
        '/public/uploads/private-stored-file.png',
      );
      h.adapter.respond = (_) =>
          _response(status: 503, body: {'message': 'private-upload-error'});
      await expectLater(
        h.api.uploadImage(bytes, 'private-local-file.png'),
        throwsA(isA<ChatApiException>()),
      );
      expect(h.adapter.requests, hasLength(2));
      expect(h.adapter.requests.first.data, isA<FormData>());
      expect(h.records, hasLength(2));
      expect(h.records.map((record) => record['route']), [
        '/uploads/image',
        '/uploads/image',
      ]);
      expect(h.records.map((record) => record['status']), [200, 503]);
      expect(jsonEncode(h.records), isNot(contains('private-')));
    },
  );

  test(
    'unknown routes and methods never fall back to raw request values',
    () async {
      final h = _Harness();
      await h.api.request(
        'private-method',
        'https://private-host.example/private-path?token=private-query',
      );
      expect(h.records.single['route'], '[unmatched]');
      expect(h.records.single['method'], 'OTHER');
      expect(jsonEncode(h.records), isNot(contains('private-')));
    },
  );

  test(
    'response correlation rejects malformed, oversized and ambiguous IDs',
    () async {
      final h = _Harness();
      for (final ids in <List<String>?>[
        null,
        [],
        [''],
        ['trace with spaces'],
        ['a' * 65],
        ['trace\r\nprivate-header'],
        ['trace\n'],
        ['é'],
        ['first', 'second'],
      ]) {
        h.adapter.respond = (_) => _response(requestIds: ids);
        await h.api.getMap('/health');
        expect(h.records.last['requestId'], isNull);
      }
      expect(h.records, hasLength(9));
      expect(jsonEncode(h.records), isNot(contains('private-header')));
    },
  );

  test('disabled HTTP logging emits and retains no metadata', () async {
    final h = _Harness(enableHttpLogging: false);
    expect(await h.api.getMap('/health'), {'ok': true});
    expect(h.adapter.requests, hasLength(1));
    expect(h.records, isEmpty);
    expect(h.api.recentApiRequests, isEmpty);
  });

  test(
    'recent API metadata is bounded and returned as immutable snapshots',
    () async {
      final h = _Harness();
      await h.api.getMap('/health');
      final firstSnapshot = h.api.recentApiRequests;
      for (var index = 1; index <= 60; index++) {
        h.adapter.respond = (_) => _response(requestIds: ['trace-$index']);
        await h.api.getMap('/health');
      }
      final recent = h.api.recentApiRequests;
      expect(h.records, hasLength(61));
      expect(recent, hasLength(60));
      expect(recent.first['requestId'], 'trace-1');
      expect(recent.last['requestId'], 'trace-60');
      expect(firstSnapshot, hasLength(1));
      expect(firstSnapshot.single['requestId'], 'trace-safe_123.abc');
      expect(() => recent.clear(), throwsUnsupportedError);
      expect(() => recent.first['route'] = 'changed', throwsUnsupportedError);
      expect(
        () => h.records.first['route'] = 'changed',
        throwsUnsupportedError,
      );
      expect(h.api.recentApiRequests.first['route'], '/health');
    },
  );

  test(
    'a diagnostic writer failure never changes the HTTP result or retries',
    () async {
      final h = _Harness(
        writer: (_) => throw StateError('private-writer-error'),
      );
      expect(await h.api.getMap('/health'), {'ok': true});
      expect(h.adapter.requests, hasLength(1));
      expect(h.api.recentApiRequests, hasLength(1));
      expect(h.api.recentApiRequests.single['status'], 200);
    },
  );

  test('opt-in HTTP JSON preserves business fields and recursively redacts credentials', () async {
    final traffic = <Map<String, Object?>>[];
    final h = _Harness(
      trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
    );
    h.api.setToken('header-private-token', userId: 'user-a');
    h.dio.options.headers['Cookie'] = 'header-private-cookie';
    h.dio.options.headers['X-API-Key'] = 'header-private-key';
    h.adapter.respond = (_) => _response(
      headers: {
        'Set-Cookie': ['response-private-cookie'],
        'X-API-Key': ['response-private-key'],
        'X-Application-Version': ['1'],
      },
      body: {
        'message': {'id': 'message-a', 'text': 'Visible business reply'},
        'accessToken': 'response-private-token',
        'nested': [
          {
            'credentials': {'password': 'response-private-password'},
          },
        ],
      },
    );

    await h.api.request(
      'PATCH',
      '/messages/message-a?cursor=next&access_token=inline-private-token',
      query: {'limit': 30, 'apiKey': 'query-private-key'},
      data: {
        'text': 'Visible business message',
        'participantIds': ['user-a', 'user-b'],
        'nested': [
          {'password': 'request-private-password', 'displayName': 'A person'},
          {
            'Authorization': 'request-private-authorization',
            'set-cookie': 'request-private-cookie',
            'x_api_key': 'request-private-key',
          },
        ],
      },
    );

    expect(traffic, hasLength(1));
    final record = traffic.single;
    expect(record['event'], 'http_request');
    expect(record['source'], 'flutter');
    expect(record['userId'], 'user-a');
    expect(record['requestId'], 'trace-safe_123.abc');
    expect(record['params'], {'messageId': 'message-a'});
    expect(record['query'], {
      'cursor': 'next',
      'access_token': '[REDACTED]',
      'limit': 30,
      'apiKey': '[REDACTED]',
    });
    expect((record['requestBody'] as Map)['text'], 'Visible business message');
    expect((record['requestBody'] as Map)['participantIds'], [
      'user-a',
      'user-b',
    ]);
    expect((record['responseBody'] as Map)['message'], {
      'id': 'message-a',
      'text': 'Visible business reply',
    });
    expect((record['responseBody'] as Map)['accessToken'], '[REDACTED]');
    // Dio preserves the spelling supplied by the adapter. Compare HTTP names
    // without assuming the key spelling in the detached JSON snapshot.
    final requestHeaders = _headerNamesLowercase(record['requestHeaders']);
    expect(requestHeaders['authorization'], '[REDACTED]');
    expect(requestHeaders['cookie'], '[REDACTED]');
    expect(requestHeaders['x-api-key'], '[REDACTED]');
    final responseHeaders = _headerNamesLowercase(record['responseHeaders']);
    expect(responseHeaders['set-cookie'], '[REDACTED]');
    expect(responseHeaders['x-api-key'], '[REDACTED]');
    expect(responseHeaders['x-application-version'], ['1']);
    expect(h.api.recentTrafficRecords, [record]);
    expect(h.api.recentApiRequests.single.containsKey('requestBody'), isFalse);
    expect(
      h.records,
      hasLength(1),
      reason: 'The existing metadata writer remains compatible.',
    );
    expect(jsonEncode(traffic), isNot(contains('-private-')));
  });

  test(
    'HTTP identity and JSON are captured before an account change',
    () async {
      final traffic = <Map<String, Object?>>[];
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
      );
      final started = Completer<void>(), release = Completer<void>();
      h.adapter.respond = (_) async {
        started.complete();
        await release.future;
        return _response(body: {'ok': true});
      };
      h.api.setToken('first-token', userId: 'first-user');
      final body = {
        'nested': {'text': 'Original text'},
      };
      final sending = h.api.post('/messages', body);
      await started.future;
      h.api.setToken('second-token', userId: 'second-user');
      body['nested']!['text'] = 'Changed later';
      release.complete();
      await sending;

      expect(h.api.trafficLogger.userId, 'second-user');
      expect(traffic.single['userId'], 'first-user');
      expect(h.records.single['userId'], 'first-user');
      expect(traffic.single['requestBody'], {
        'nested': {'text': 'Original text'},
      });
      expect(
        () => (traffic.single['requestBody'] as Map)['text'] = 'mutation',
        throwsUnsupportedError,
      );
      expect(
        () =>
            ((traffic.single['requestBody'] as Map)['nested'] as Map)['text'] =
                'mutation',
        throwsUnsupportedError,
      );
      h.api.setToken(null);
      expect(h.api.trafficLogger.userId, isNull);
    },
  );

  test(
    'runtime traffic opt-in affects new requests and OPTIONS is omitted',
    () async {
      final traffic = <Map<String, Object?>>[];
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(enabled: false, writer: traffic.add),
      );
      await h.api.post('/messages', {'text': 'Not captured'});
      expect(traffic, isEmpty);
      expect(h.api.debugTrafficLoggingEnabled, isFalse);
      h.api.setDebugTrafficLoggingEnabled(true);
      expect(h.api.debugTrafficLoggingEnabled, isTrue);
      await h.api.post('/messages', {'text': 'Captured after opt-in'});
      expect(traffic, hasLength(1));
      expect(
        (traffic.single['requestBody'] as Map)['text'],
        'Captured after opt-in',
      );
      final metadataCount = h.records.length;
      await h.api.request('OPTIONS', '/messages');
      expect(h.records, hasLength(metadataCount));
      expect(traffic, hasLength(1));
      h.api.setDebugTrafficLoggingEnabled(false);
      expect(h.api.recentTrafficRecords, isEmpty);
      await h.api.post('/messages', {'text': 'Not captured after opt-out'});
      expect(traffic, hasLength(1));
    },
  );

  test(
    'opting out during an HTTP request prevents later payload emission',
    () async {
      final traffic = <Map<String, Object?>>[];
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
      );
      final started = Completer<void>(), release = Completer<void>();
      h.adapter.respond = (_) async {
        started.complete();
        await release.future;
        return _response(body: {'text': 'Later response'});
      };
      final sending = h.api.post('/messages', {'text': 'Earlier request'});
      await started.future;
      h.api.setDebugTrafficLoggingEnabled(false);
      h.api.setDebugTrafficLoggingEnabled(true);
      release.complete();
      await sending;
      expect(traffic, isEmpty);
      expect(h.api.recentTrafficRecords, isEmpty);
      expect(h.api.recentApiRequests, hasLength(1));
    },
  );

  test(
    'full upload traffic contains file metadata and never raw image bytes',
    () async {
      final traffic = <Map<String, Object?>>[];
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
      );
      h.adapter.respond = (_) =>
          _response(body: {'imageUrl': '/public/uploads/image.png'});
      final bytes = Uint8List.fromList(
        utf8.encode('raw-image-bytes-are-not-JSON'),
      );
      await h.api.uploadImage(bytes, 'chosen-photo.png');
      final body = traffic.single['requestBody'] as Map;
      expect(body['type'], 'multipart/form-data');
      final file = ((body['files'] as List).single as Map)['file'] as Map;
      expect(file['filename'], 'chosen-photo.png');
      expect(file['length'], bytes.length);
      expect(file['contentType'], 'image/png');
      expect(
        jsonEncode(traffic),
        isNot(contains('raw-image-bytes-are-not-JSON')),
      );
    },
  );

  test(
    'full HTTP failure traffic preserves JSON errors without credentials',
    () async {
      final traffic = <Map<String, Object?>>[];
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
      );
      h.adapter.respond = (_) => _response(
        status: 403,
        body: {
          'detail': 'Membership required',
          'requestId': 'trace-safe_123.abc',
          'nested': {'refreshToken': 'error-private-token'},
        },
      );
      await expectLater(
        h.api.post('/messages', {'text': 'Unsent text'}),
        throwsA(isA<ChatApiException>()),
      );
      expect(traffic, hasLength(1));
      expect(traffic.single['status'], 403);
      expect(
        (traffic.single['responseBody'] as Map)['detail'],
        'Membership required',
      );
      expect(jsonEncode(traffic), isNot(contains('error-private-token')));
    },
  );

  test(
    'a failing full-traffic writer cannot change a request result',
    () async {
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(
          enabled: true,
          writer: (_) => throw StateError('writer failed'),
        ),
      );
      expect(await h.api.getMap('/health'), {'ok': true});
      expect(h.api.recentTrafficRecords, hasLength(1));
      expect(h.api.recentApiRequests, hasLength(1));
    },
  );

  test(
    'full network failure records the request without raw exception data',
    () async {
      final traffic = <Map<String, Object?>>[];
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
      );
      h.adapter.respond = (options) => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
        message: 'private-network-message',
        error: StateError('private-network-exception'),
      );
      await expectLater(
        h.api.post('/messages', {'text': 'Offline draft'}),
        throwsA(isA<ChatApiException>()),
      );
      expect(traffic, hasLength(1));
      expect(traffic.single['status'], isNull);
      expect(traffic.single['requestId'], isNull);
      expect(traffic.single['responseBody'], isNull);
      expect(traffic.single['requestBody'], {'text': 'Offline draft'});
      expect(traffic.single['outcome'], 'connectionTimeout');
      expect(jsonEncode(traffic), isNot(contains('private-network-')));
    },
  );

  test(
    'explicit HTTP logging disable also prevents full HTTP payload capture',
    () async {
      final traffic = <Map<String, Object?>>[];
      final h = _Harness(
        enableHttpLogging: false,
        trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
      );
      await h.api.post('/messages', {'text': 'No HTTP capture'});
      expect(h.records, isEmpty);
      expect(traffic, isEmpty);
      expect(h.api.recentApiRequests, isEmpty);
      h.api.trafficLogger.recordRealtimePublication({'pts': 1});
      expect(traffic.single['event'], 'realtime_publication');
    },
  );

  for (final (initiatingUser, nextUser) in <(String?, String?)>[
    ('first-user', 'second-user'),
    ('first-user', null),
    (null, 'second-user'),
  ]) {
    test(
      'immediate identity change $initiatingUser to $nextUser preserves the request bearer identity',
      () async {
        final traffic = <Map<String, Object?>>[];
        final h = _Harness(
          trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
        );
        h.api.setToken(
          initiatingUser == null ? null : 'original-token',
          userId: initiatingUser,
        );
        final pending = h.api.post('/messages', {'text': 'Already initiated'});
        // No await: Dio copied the bearer but has not run its interceptor yet.
        h.api.setToken(
          nextUser == null ? null : 'replacement-token',
          userId: nextUser,
        );
        await pending;
        expect(
          h.adapter.requests.single.headers['Authorization'],
          initiatingUser == null ? null : 'Bearer original-token',
        );
        expect(h.records.single['userId'], initiatingUser);
        expect(traffic.single['userId'], initiatingUser);
        expect(h.api.trafficLogger.userId, nextUser);
      },
    );
  }

  test(
    'an immediate account switch preserves the upload initiating identity',
    () async {
      final traffic = <Map<String, Object?>>[];
      final h = _Harness(
        trafficLogger: DebugTrafficLogger(enabled: true, writer: traffic.add),
      );
      h.adapter.respond = (_) =>
          _response(body: {'imageUrl': '/public/uploads/image.png'});
      h.api.setToken('upload-token', userId: 'upload-user');
      final pending = h.api.uploadImage(
        Uint8List.fromList([1, 2, 3]),
        'image.png',
      );
      h.api.setToken('replacement-token', userId: 'replacement-user');
      await pending;
      expect(
        h.adapter.requests.single.headers['Authorization'],
        'Bearer upload-token',
      );
      expect(h.records.single['userId'], 'upload-user');
      expect(traffic.single['userId'], 'upload-user');
      expect(h.api.trafficLogger.userId, 'replacement-user');
    },
  );
}
