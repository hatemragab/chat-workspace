import 'dart:collection';
import 'dart:convert';

import 'package:chat_workspace/core/debug_traffic_logger.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnreadableMap extends MapBase<String, Object?> {
  @override
  Iterable<String> get keys =>
      throw StateError('Payload was inspected while disabled.');
  @override
  Object? operator [](Object? key) =>
      throw StateError('Payload was inspected while disabled.');
  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

void main() {
  for (final publication in {
    'room': {
      'eventType': 'message_new',
      'roomId': 'room-a',
      'lastMessage': {'id': 'message-a', 'text': 'Hello'},
    },
    'receipt': {
      'eventType': 'room_peer_seen',
      'roomId': 'room-a',
      'peerDeliveredSeq': 8,
      'peerSeenSeq': 7,
      'contentPts': 39,
    },
    'unread': {
      'eventType': 'room_unread_cleared',
      'roomId': 'room-a',
      'unreadCount': 2,
      'ownDeliveredSeq': 8,
      'ownSeenSeq': 7,
    },
  }.entries) {
    test(
      '${publication.key} publications retain their event classification and original wire envelope',
      () {
        final records = <Map<String, Object?>>[];
        final logger = DebugTrafficLogger(enabled: true, writer: records.add);
        final data = {
          'pts': 42,
          'epoch': 'epoch-a',
          publication.key: publication.value,
        };
        final original = jsonEncode(data);
        logger.recordRealtimePublication(
          data,
          userId: 'receiving-session',
          channel: 'inbox:user#receiving-session',
        );
        final record = records.single;
        expect(record['eventType'], publication.value['eventType']);
        expect(record['pts'], 42);
        expect(record['recipientUserId'], 'receiving-session');
        expect(record['actorUserId'], isNull);
        expect(record['data'], data);
        expect(jsonEncode(data), original);
        expect((record['data'] as Map).keys.toSet(), {
          'pts',
          'epoch',
          publication.key,
        });
      },
    );
  }

  test('disabled full traffic never inspects or retains business data', () {
    final records = <Map<String, Object?>>[];
    final logger = DebugTrafficLogger(enabled: false, writer: records.add);
    final unreadable = _UnreadableMap();
    expect(
      logger.captureHttpRequest(
        method: 'POST',
        path: '/messages',
        params: {},
        query: {},
        body: unreadable,
      ),
      isNull,
    );
    logger.recordRealtimePublication(unreadable);
    expect(logger.recentTrafficRecords, isEmpty);
    expect(records, isEmpty);
  });

  test(
    'realtime JSON uses the HTTP envelope and the actual recipient identity',
    () {
      final records = <Map<String, Object?>>[];
      final logger = DebugTrafficLogger(enabled: true, writer: records.add);
      logger.setUserId('current-user');
      final payload = {
        'pts': 42,
        'epoch': 'epoch-a',
        'room': {
          'roomId': 'room-a',
          'eventType': 'room_peer_seen',
          'lastMessage': {
            'senderId': 'another-message-sender',
            'text': 'Hello',
          },
          'nested': {'accessToken': 'private-realtime-token'},
        },
      };
      logger.recordRealtimePublication(
        payload,
        channel: 'inbox:user#receiving-session',
        userId: 'receiving-session',
      );
      final record = records.single;
      expect(record['event'], 'realtime_publication');
      expect(record['source'], 'flutter');
      expect(record['direction'], 'receive');
      expect(DateTime.parse(record['timestamp']! as String).isUtc, isTrue);
      expect(record['userId'], 'receiving-session');
      expect(record['recipientUserId'], 'receiving-session');
      expect(record['actorUserId'], isNull);
      expect(record['requestId'], isNull);
      expect(record['channel'], 'inbox:user#receiving-session');
      expect(record['pts'], 42);
      expect(record['eventType'], 'room_peer_seen');
      expect((record['data'] as Map)['epoch'], 'epoch-a');
      expect(jsonEncode(record), contains('Hello'));
      expect(jsonEncode(record), isNot(contains('private-realtime-token')));
    },
  );

  test(
    'business traffic is captured deeply and returned without mutable aliases',
    () {
      final records = <Map<String, Object?>>[];
      final logger = DebugTrafficLogger(enabled: true, writer: records.add);
      logger.setUserId('user-a');
      final data = {
        'pts': 1,
        'room': {'eventType': 'message_new', 'text': 'Original text'},
        'rows': [
          {'text': 'Original row', 'api_key': 'private-key'},
        ],
      };
      logger.recordRealtimePublication(data);
      final before = logger.recentTrafficRecords;
      (data['room']! as Map)['text'] = 'Changed later';
      ((data['rows']! as List).single as Map)['text'] = 'Changed row';
      logger.setUserId('user-b');
      logger.recordRealtimePublication({
        'pts': 2,
        'room': {'eventType': 'room_preferences'},
      });
      expect(before, hasLength(1));
      final saved = before.single['data'] as Map;
      expect((saved['room'] as Map)['text'], 'Original text');
      expect(((saved['rows'] as List).single as Map)['text'], 'Original row');
      expect(((saved['rows'] as List).single as Map)['api_key'], '[REDACTED]');
      expect(before.single['userId'], 'user-a');
      expect(logger.recentTrafficRecords.last['userId'], 'user-b');
      expect(() => before.clear(), throwsUnsupportedError);
      expect(() => records.first['userId'] = 'changed', throwsUnsupportedError);
      expect(
        () => (saved['room'] as Map)['text'] = 'changed',
        throwsUnsupportedError,
      );
      expect(() => (saved['rows'] as List).clear(), throwsUnsupportedError);
    },
  );

  test('the unified HTTP and realtime history retains only 60 records', () {
    final logger = DebugTrafficLogger(enabled: true, writer: (_) {});
    for (var index = 0; index < 61; index++) {
      if (index.isEven) {
        logger.recordRealtimePublication({'pts': index});
      } else {
        final request = logger.captureHttpRequest(
          method: 'POST',
          path: '/messages',
          params: {},
          query: {},
          body: {'number': index},
        );
        logger.recordHttpCompletion(
          request: request,
          metadata: {
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'number': index,
          },
          responseBody: {'ok': true},
        );
      }
    }
    final recent = logger.recentTrafficRecords;
    expect(recent, hasLength(60));
    expect(recent.first['number'], 1);
    expect(recent.last['pts'], 60);
    expect(recent.map((record) => record['event']).toSet(), {
      'http_request',
      'realtime_publication',
    });
  });

  test(
    'text JSON and cyclic data are safe to inspect without losing delivery',
    () {
      final records = <Map<String, Object?>>[];
      final logger = DebugTrafficLogger(enabled: true, writer: records.add);
      final circular = <String, Object?>{'text': 'Visible text'};
      circular['again'] = circular;
      logger.recordRealtimePublication({
        'room': circular,
        'nestedJson': '{"text":"Readable text","password":"private-password","accessToken":"private-nested-token","imageUrl":"/photo?token=private-nested-url&roomId=room-a"}',
      });
      final logged = jsonEncode(records);
      expect(logged, contains('Visible text'));
      expect(logged, contains('Readable text'));
      expect(logged, contains('[Circular]'));
      expect(logged, isNot(contains('private-password')));
      expect(logged, isNot(contains('private-nested-token')));
      expect(logged, isNot(contains('private-nested-url')));
      expect(logged, contains('roomId=room-a'));
    },
  );

  test(
    'runtime opt-out clears retained payloads and stops realtime output',
    () {
      final records = <Map<String, Object?>>[];
      final logger = DebugTrafficLogger(enabled: true, writer: records.add);
      logger.recordRealtimePublication({'pts': 1});
      expect(logger.recentTrafficRecords, hasLength(1));
      logger.setDebugTrafficLoggingEnabled(false);
      logger.recordRealtimePublication({'pts': 2});
      expect(logger.isEnabled, isFalse);
      expect(logger.recentTrafficRecords, isEmpty);
      expect(records, hasLength(1));
      logger.setDebugTrafficLoggingEnabled(true);
      logger.recordRealtimePublication({'pts': 3});
      expect(logger.recentTrafficRecords.single['pts'], 3);
      expect(records, hasLength(2));
    },
  );

  test('credential strings and signed URL secrets redact without hiding business text or IDs', () {
    final records = <Map<String, Object?>>[];
    final logger = DebugTrafficLogger(enabled: true, writer: records.add);
    const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.jwtSignature';
    const businessText =
        'A full message for user-42: https://example.test/photo?roomId=room-a&size=large';
    final room = {
      'text': businessText,
      'roomId': 'room-a',
      'imageUrl': '/img?id=photo-a&token=private-image-token&size=100',
      'link': 'https://example.test/?api%5Fkey=private-url-key&roomId=room-a',
      'note':
          'prefix Bearer private-bearer-token; middle Basic dXNlcjpwYXNz end',
      'example': jwt,
      'signature': 'private-signature',
    };
    logger.recordRealtimePublication({'pts': 1, 'room': room});
    final saved = ((records.single['data'] as Map)['room'] as Map);
    expect(saved['text'], businessText);
    expect(saved['roomId'], 'room-a');
    expect(saved['imageUrl'], '/img?id=photo-a&token=[REDACTED]&size=100');
    expect(
      saved['link'],
      'https://example.test/?api%5Fkey=[REDACTED]&roomId=room-a',
    );
    expect(saved['note'], 'prefix [REDACTED]; middle [REDACTED] end');
    expect(saved['example'], '[REDACTED]');
    expect(saved['signature'], '[REDACTED]');
    expect(jsonEncode(records), isNot(contains('private-')));
    expect(jsonEncode(records), isNot(contains(jwt)));
    expect(room['imageUrl'], contains('private-image-token'));
  });

  test('URL userinfo and encoded JSON credentials redact without changing ordinary text', () {
    final records = <Map<String, Object?>>[];
    final logger = DebugTrafficLogger(enabled: true, writer: records.add);
    const ordinary =
        '  { "text": "Preserve business formatting", "id": "room-a" }  ';
    const queryEmail = 'https://host.test?email=name@example.com';
    const fragmentEmail = 'https://host.test#email=name@example.com';
    final nested = jsonEncode({
      'note': jsonEncode({
        'accessToken': 'private-encoded-token',
        'text': 'Keep this text',
      }),
    });
    logger.recordRealtimePublication({
      'room': {
        'imageUrl': 'https://private-user:private-password@example.test/photo.png?width=400',
        'encodedUrl': 'https://private%40user:private%3Apassword@example.test/photo.png?roomId=room-a',
        'embeddedAt': 'https://private-user:p@ssword@example.test/photo.png',
        'metadata': jsonEncode(nested),
        'ordinary': ordinary,
        'queryEmail': queryEmail,
        'fragmentEmail': fragmentEmail,
      },
    });
    final room = ((records.single['data'] as Map)['room'] as Map);
    expect(
      room['imageUrl'],
      'https://[REDACTED]@example.test/photo.png?width=400',
    );
    expect(
      room['encodedUrl'],
      'https://[REDACTED]@example.test/photo.png?roomId=room-a',
    );
    expect(room['embeddedAt'], 'https://[REDACTED]@example.test/photo.png');
    final decoded =
        jsonDecode(jsonDecode(room['metadata'] as String) as String) as Map;
    expect(jsonDecode(decoded['note'] as String), {
      'accessToken': '[REDACTED]',
      'text': 'Keep this text',
    });
    expect(room['ordinary'], ordinary);
    expect(room['queryEmail'], queryEmail);
    expect(room['fragmentEmail'], fragmentEmail);
    expect(jsonEncode(records), isNot(contains('private-')));
    expect(jsonEncode(records), isNot(contains('private%')));
  });
}
