import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_workspace/core/exports.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test.dart' show FakeApi, payload;
import 'review_regressions_test.dart' show delta, session;

import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  final response = Completer<ResponseBody>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

List<Map<String, Object?>> _events(DebugInspector inspector) =>
    (inspector.snapshot()['events']! as List).cast<Map<String, Object?>>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'HTTP spans follow initiating action and work with console logging off',
    () async {
      final inspector = DebugInspector()..setEnabled(true);
      inspector.updateContext(
        userId: 'user-a',
        sessionGeneration: 4,
        roomId: 'room-a',
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://synthetic.example'));
      final adapter = _Adapter();
      dio.httpClientAdapter = adapter;
      final api = ChatApi(
        dio: dio,
        enableHttpLogging: false,
        debugInspector: inspector,
      );
      api.setToken('secret-bearer', userId: 'user-a');
      final work = inspector.trace(
        'action',
        'sendText',
        () => api.request(
          'POST',
          '/messages',
          data: {'text': 'private-message', 'password': 'private-password'},
        ),
      );
      inspector.updateContext(
        userId: 'user-b',
        sessionGeneration: 5,
        roomId: 'room-b',
      );
      api.setToken('other-secret', userId: 'user-b');
      adapter.response.complete(
        ResponseBody.fromString(
          '{"ok":true}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
            'x-request-id': ['request-123'],
          },
        ),
      );
      expect(await work, {'ok': true});
      final events = _events(inspector);
      final http = events.where((e) => e['category'] == 'http').toList();
      expect(http, hasLength(2));
      expect(http.every((e) => e['userId'] == 'user-a'), true);
      expect(http.every((e) => e['sessionGeneration'] == 4), true);
      expect(http.every((e) => e['roomId'] == 'room-a'), true);
      final action = events.firstWhere((e) => e['category'] == 'action');
      expect(http.first['traceId'], action['traceId']);
      expect(http.first['parentSpanId'], action['spanId']);
      final output = jsonEncode(inspector.snapshot());
      for (final private in [
        'private-message',
        'private-password',
        'secret-bearer',
        'other-secret',
      ]) {
        expect(output, isNot(contains(private)));
      }
      dio.close();
      inspector.dispose();
    },
  );

  test(
    'controller records state changes and resources without observer feedback',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final inspector = DebugInspector()..setEnabled(true);
      final controller = ChatController(
        database: db,
        enableRealtime: false,
        debugInspector: inspector,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.error = 'private-error-content';
      controller.clearError();
      final state = _events(inspector)
          .where((e) => e['category'] == 'state')
          .toList();
      expect(state, hasLength(1));
      inspector.recordBuild('ChatShell', context: controller.lastStateContext);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(notifications, 1);
      expect(
        jsonEncode(inspector.snapshot()),
        isNot(contains('private-error-content')),
      );
      expect((inspector.snapshot()['gauges']! as Map)['roomsSubscription'], 0);
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      inspector.dispose();
    },
  );
  test('caught controller errors remain failures in the action span', () async {
    final inspector = DebugInspector()..setEnabled(true);
    final api = FakeApi()
      ..usersHandler = (_) async => throw StateError('private failure');
    final controller = ChatController(
      database: AppDatabase(NativeDatabase.memory()),
      api: api,
      enableRealtime: false,
      debugInspector: inspector,
    );
    controller.currentUser = const UserProfile(
      id: 'actor',
      username: 'actor',
      displayName: 'Actor',
    );
    await controller.refreshUsers();
    expect(controller.error, contains('private failure'));
    final completion = _events(inspector).singleWhere(
      (event) =>
          event['category'] == 'action' &&
          event['name'] == 'refreshUsers' &&
          event['phase'] == 'end',
    );
    expect((completion['data']! as Map)['errorType'], 'StateError');
    expect(
      jsonEncode(inspector.snapshot()),
      isNot(contains('private failure')),
    );
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    inspector.dispose();
  });
  test('installed session and persistent Drift callbacks stay traceable after clear and reenable', () async {
    SharedPreferences.setMockInitialValues({});
    final inspector = DebugInspector()..setEnabled(true);
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()..authHandler = (_) async => session('me');
    api.handler = (path, _) async =>
        path == '/rooms/delta' ? delta(0, []) : {'statuses': <String, bool>{}};
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      debugInspector: inspector,
    );
    try {
      await controller.debugLogin(1);
      final installed = _events(inspector)
          .where((e) => e['category'] == 'session');
      expect(installed, isNotEmpty);
      expect(
        installed.every(
          (e) =>
              e['userId'] == 'me' &&
              e['sessionGeneration'] == controller.sessionGenerationId,
        ),
        true,
      );
      for (final cycle in [1, 2]) {
        if (cycle == 1) {
          inspector.clear();
        } else {
          inspector.setEnabled(false);
          inspector.setEnabled(true);
        }
        await db.upsertRoom(
          ChatRoom.fromJson(payload(room: 'traced-room', pts: cycle)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final states = _events(inspector)
            .where((e) => e['category'] == 'state')
            .toList();
        expect(states, isNotEmpty);
        expect(
          states.every(
            (e) =>
                e['userId'] == 'me' &&
                e['sessionGeneration'] == controller.sessionGenerationId,
          ),
          true,
        );
      }
      await controller.logout();
      expect((inspector.snapshot()['gauges']! as Map)['roomsSubscription'], 0);
      expect(
        (inspector.snapshot()['gauges']! as Map)['drift.subscriptions'],
        0,
      );
    } finally {
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      inspector.dispose();
    }
  });
  test(
    'HTTP setup failures retire spans without needing a response interceptor',
    () async {
      final inspector = DebugInspector(enabled: true);
      final dio = Dio();
      final api = ChatApi(
        dio: dio,
        enableHttpLogging: false,
        debugInspector: inspector,
      );
      await expectLater(api.request('GET', 'http://['), throwsA(anything));
      expect((inspector.snapshot()['resources']! as Map)['activeSpans'], 0);
      expect(
        _events(inspector)
            .where((e) => e['category'] == 'http' && e['phase'] == 'end'),
        hasLength(1),
      );
      dio.close();
      inspector.dispose();
    },
  );

  test('room preference actions identify their target instead of the selected room', () async {
    final inspector = DebugInspector(enabled: true);
    final dio = Dio(BaseOptions(baseUrl: 'https://synthetic.example'));
    final adapter = _Adapter();
    dio.httpClientAdapter = adapter;
    final api = ChatApi(dio: dio, enableHttpLogging: false);
    final controller = ChatController(
      database: AppDatabase(NativeDatabase.memory()),
      api: api,
      enableRealtime: false,
      debugInspector: inspector,
    );
    controller.currentUser = const UserProfile(
      id: 'actor',
      username: 'actor',
      displayName: 'Actor',
    );
    controller.selectedRoom = ChatRoom.fromJson(payload(room: 'selected'));
    final work = controller.setPreferences(
      ChatRoom.fromJson(payload(room: 'target')),
      pin: true,
    );
    adapter.response.complete(
      ResponseBody.fromString(
        '{}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    await work;
    final action = _events(inspector)
        .firstWhere((e) => e['category'] == 'action' && e['phase'] == 'begin');
    final http = _events(inspector).firstWhere((e) => e['category'] == 'http');
    expect(action['roomId'], 'target');
    expect(http['roomId'], 'target');
    expect(http['name'], 'PATCH:/rooms/:roomId/preferences');
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    inspector.dispose();
    dio.close();
  });
}
