import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session, waitForController;
import 'sync_test.dart' show FakeApi, message, payload;

class _ManualPresenceTimer implements Timer {
  _ManualPresenceTimer(this.callback);
  final void Function(Timer) callback;
  bool _active = true;
  int _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    ++_tick;
    callback(this);
  }
}

int _completedSyncs(DebugInspector inspector) =>
    (inspector.snapshot()['events'] as List<Map<String, Object?>>)
        .where(
          (event) =>
              event['category'] == 'action' &&
              event['name'] == 'syncNow' &&
              event['phase'] == 'end',
        )
        .length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'presence checks unique direct-room peers instead of the user directory',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi()
        ..userList = List.generate(
          37,
          (i) => UserProfile(
            id: 'directory-$i',
            username: 'directory-$i',
            displayName: 'Directory $i',
          ),
        );
      final requests = <List<String>>[];
      api.handler = (path, query) async {
        if (path == '/presence/status') {
          requests.add((query!['userIds'] as String).split(','));
          return {
            'statuses': {
              'peer': true,
              'other-peer': false,
              'directory-0': true,
            },
            'lastSeenAt': {'other-peer': '2026-10-18T00:00:00Z'},
          };
        }
        return delta(1, [
          payload(),
          payload(room: 'same-peer'),
          {...payload(room: 'other-room'), 'peerUserId': 'other-peer'},
          {
            ...payload(room: 'group'),
            'roomType': 'group',
            'peerUserId': 'group-peer',
          },
          {...payload(room: 'draft_draft-peer'), 'peerUserId': 'draft-peer'},
          {
            ...payload(room: 'deleted'),
            'peerUserId': 'deleted-peer',
            'deletedAt': '2026-10-18T00:00:00Z',
          },
          {...payload(room: 'self'), 'peerUserId': 'me'},
          {...payload(room: 'unknown'), 'peerUserId': null},
          {...payload(room: 'empty'), 'peerUserId': ''},
        ]);
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        expect(requests, hasLength(1));
        expect(requests.single, unorderedEquals(['peer', 'other-peer']));
        expect(controller.onlineUserIds, {'peer'});
        expect(controller.offlineUserIds, {'other-peer'});
        expect(controller.lastSeenAtByUserId, {
          'other-peer': DateTime.utc(2026, 10, 18),
        });
        await controller.refreshUsers();
        await controller.syncNow();
        expect(requests, hasLength(2));
        expect(requests.last, unorderedEquals(['peer', 'other-peer']));
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test(
    'directory users and group rooms alone never cause presence requests',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi()
        ..userList = [
          const UserProfile(
            id: 'stranger',
            username: 'stranger',
            displayName: 'Stranger',
          ),
        ];
      var requests = 0;
      api.handler = (path, _) async {
        if (path == '/presence/status') {
          requests++;
          return {'statuses': <String, bool>{}};
        }
        return delta(1, [
          {...payload(room: 'group'), 'roomType': 'group'},
        ]);
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        await controller.syncNow();
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(requests, 0);
        expect(controller.onlineUserIds, isEmpty);
        expect(controller.offlineUserIds, isEmpty);
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test('direct-room presence keeps the 100-peer request limit', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    final requests = <List<String>>[];
    api.handler = (path, query) async {
      if (path == '/presence/status') {
        final ids = (query!['userIds'] as String).split(',');
        requests.add(ids);
        return {
          'statuses': {for (final id in ids) id: true},
        };
      }
      return delta(
        1,
        List.generate(
          101,
          (i) => {...payload(room: 'room-$i'), 'peerUserId': 'peer-$i'},
        ),
      );
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      expect(requests.map((ids) => ids.length), [100, 1]);
      expect(requests.expand((ids) => ids).toSet(), hasLength(101));
      expect(controller.onlineUserIds, hasLength(101));
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test('logout releases the outgoing presence session with its old credentials before local cleanup', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()..handler = (_, _) async => delta(0, []);
    final released = Completer<void>();
    final releaseResponse = Completer<Map<String, dynamic>>();
    Object? releaseCredentials, releaseBody;
    var heartbeats = 0;
    api.otherPostHandler = (path, body) async {
      if (path == '/presence/heartbeat') heartbeats++;
      if (path == '/presence/offline') {
        releaseCredentials = api.dio.options.headers['Authorization'];
        releaseBody = body;
        released.complete();
        return releaseResponse.future;
      }
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      await db.upsertMessage(message('owned'));
      final generation = controller.sessionGenerationId;
      final loggingOut = controller.logout();
      await released.future;
      expect(controller.sessionGenerationId, greaterThan(generation));
      expect(releaseCredentials, 'Bearer test-token');
      expect(releaseBody, isNull);
      expect(api.hasSessionToken, true);
      expect(await db.message('owned'), isNotNull);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(heartbeats, 0); // The client never renews presence leases.
      releaseResponse.complete({'ok': true});
      await loggingOut;
      expect(controller.currentUser, isNull);
      expect(api.hasSessionToken, false);
      expect(await db.metadata(), isNull);
      expect(await db.message('owned'), isNull);
      expect(
        (await SharedPreferences.getInstance()).getString('chat_session'),
        isNull,
      );
    } finally {
      await db.close();
    }
  });

  test(
    'account switching retires only the outgoing login without heartbeats',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi()..handler = (_, _) async => delta(0, []);
      api.authHandler = (body) async =>
          session(body['debugUserNumber'] == 1 ? 'me' : 'other');
      final operations = <String>[];
      api.otherPostHandler = (path, _) async {
        if (path == '/presence/offline' || path == '/presence/heartbeat') {
          operations.add('$path ${api.dio.options.headers['Authorization']}');
        }
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        await controller.debugLogin(2);
        expect(operations, ['/presence/offline Bearer me']);
        expect(controller.currentUser!.id, 'other');
        expect(api.dio.options.headers['Authorization'], 'Bearer other');
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  for (final status in [401, 503]) {
    test(
      'offline HTTP $status cannot block local logout or retain credentials',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = FakeApi()..handler = (_, _) async => delta(0, []);
        api.otherPostHandler = (path, _) async {
          if (path == '/presence/offline') {
            throw ChatApiException('unavailable', statusCode: status);
          }
          return {'ok': true};
        };
        final controller = ChatController(
          database: db,
          api: api,
          enableRealtime: false,
        );
        try {
          await controller.debugLogin(1);
          await db.upsertMessage(message('owned'));
          await controller.logout();
          expect(controller.error, isNull);
          expect(controller.currentUser, isNull);
          expect(api.hasSessionToken, false);
          expect(await db.metadata(), isNull);
          expect(await db.message('owned'), isNull);
          expect(
            (await SharedPreferences.getInstance()).getString('chat_session'),
            isNull,
          );
        } finally {
          await db.close();
        }
      },
    );
  }

  test('an unresponsive presence release is bounded and still clears local session', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()..handler = (_, _) async => delta(0, []);
    final neverResponding = Completer<Map<String, dynamic>>();
    api.otherPostHandler = (path, _) async =>
        path == '/presence/offline' ? neverResponding.future : {'ok': true};
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      await controller.logout().timeout(const Duration(seconds: 4));
      expect(controller.currentUser, isNull);
      expect(api.hasSessionToken, false);
      expect(await db.metadata(), isNull);
      neverResponding.complete({'ok': true});
    } finally {
      await db.close();
    }
  });

  test('a pending startup delta cannot extend the three-second offline-release bound', () async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    final deltaStarted = Completer<void>();
    final pendingDelta = Completer<Map<String, dynamic>>();
    final pendingRelease = Completer<Map<String, dynamic>>();
    var offlineCalls = 0, heartbeats = 0;
    api.handler = (_, _) async {
      deltaStarted.complete();
      return pendingDelta.future;
    };
    api.otherPostHandler = (path, _) async {
      if (path == '/presence/offline') {
        offlineCalls++;
        return pendingRelease.future;
      }
      if (path == '/presence/heartbeat') heartbeats++;
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    final initializing = controller.initialize();
    try {
      await deltaStarted.future;
      await controller.logout().timeout(const Duration(seconds: 4));
      expect(offlineCalls, 1);
      expect(heartbeats, 0);
      expect(pendingDelta.isCompleted, false);
      expect(controller.currentUser, isNull);
      expect(api.hasSessionToken, false);
      expect(await db.metadata(), isNull);
      expect(
        (await SharedPreferences.getInstance()).getString('chat_session'),
        isNull,
      );
      pendingDelta.complete(delta(999, []));
      pendingRelease.complete({'ok': true});
      await initializing;
      expect(controller.currentUser, isNull);
      expect(heartbeats, 0);
      expect(await db.metadata(), isNull);
    } finally {
      if (!pendingDelta.isCompleted) pendingDelta.complete(delta(0, []));
      if (!pendingRelease.isCompleted) pendingRelease.complete({'ok': true});
      await initializing;
      await controller.logout();
      await db.close();
    }
  });

  test(
    'peer status completing after logout cannot affect the retired session',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi()
        ..userList = [
          const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
        ];
      var delayStatus = false, statuses = 0, heartbeats = 0;
      final started = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      api.handler = (path, _) async {
        if (path == '/presence/status') {
          statuses++;
          if (delayStatus) {
            started.complete();
            return response.future;
          }
          return {
            'statuses': {'peer': true},
          };
        }
        return delta(1, [payload()]);
      };
      api.otherPostHandler = (path, _) async {
        if (path == '/presence/heartbeat') heartbeats++;
        return {'ok': true};
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
      );
      try {
        await controller.debugLogin(1);
        expect(controller.onlineUserIds, {'peer'});
        delayStatus = true;
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await started.future;
        await controller.logout();
        response.complete({
          'statuses': {'peer': false},
          'lastSeenAt': {'peer': '2026-10-18T00:00:00Z'},
        });
        await Future<void>.delayed(Duration.zero);
        expect(controller.currentUser, isNull);
        expect(controller.onlineUserIds, isEmpty);
        expect(controller.offlineUserIds, isEmpty);
        expect(controller.lastSeenAtByUserId, isEmpty);
        expect(statuses, 2);
        expect(heartbeats, 0);
        expect(api.hasSessionToken, false);
      } finally {
        if (!response.isCompleted) response.complete({'statuses': {}});
        await db.close();
      }
    },
  );

  test('recovery actions during delayed logout cannot restore or heartbeat the outgoing partial startup session', () async {
    SharedPreferences.setMockInitialValues({
      'chat_session': jsonEncode(session('me')),
    });
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    var unavailable = true, deltaRequests = 0, heartbeats = 0;
    var directRequests = 0, submissions = 0, uploads = 0;
    final releaseStarted = Completer<void>();
    final releaseResponse = Completer<Map<String, dynamic>>();
    api.authHandler = (_) async => session('other');
    api.handler = (path, _) async {
      if (path.startsWith('/rooms/direct-peer/')) {
        directRequests++;
        return {'room': null};
      }
      deltaRequests++;
      if (unavailable) {
        throw const ChatApiException('startup unavailable', statusCode: 503);
      }
      return delta(0, []);
    };
    api.postHandler = (_, _) async {
      submissions++;
      throw StateError('A stopping session must not submit messages');
    };
    api.uploadHandler = (_, _) async {
      uploads++;
      throw StateError('A stopping session must not upload images');
    };
    api.otherPostHandler = (path, _) async {
      if (path == '/presence/offline') {
        if (!releaseStarted.isCompleted) releaseStarted.complete();
        return releaseResponse.future;
      }
      if (path == '/presence/heartbeat') heartbeats++;
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.initialize();
      await waitForController(() => controller.connectionStatus == 'Offline');
      expect(controller.initialized, true);
      expect(controller.diagnostics['remoteStartupComplete'], false);
      expect(controller.currentUser!.id, 'me');
      await controller.openDirect(
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      );
      await waitForController(() => directRequests == 1);
      final oldContext = controller.captureSendContext()!;
      await db.upsertMessage(
        message('owned-draft', room: 'draft_peer', status: 'failed'),
      );
      unavailable = false;
      final loggingOut = controller.logout();
      await releaseStarted.future;
      final recovering = Future.wait([
        controller.initialize(),
        controller.syncNow(),
        controller.openDirect(
          const UserProfile(
            id: 'another-peer',
            username: 'another',
            displayName: 'Another',
          ),
        ),
        controller.sendText('must not send'),
        controller.sendText('old context must not send', context: oldContext),
        controller.sendImage(
          Uint8List.fromList([1]),
          'image.png',
          context: oldContext,
        ),
      ]);
      expect(controller.captureSendContext(), isNull);
      expect(controller.isSendContextCurrent(oldContext), false);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      releaseResponse.complete({'ok': true});
      await Future.wait([loggingOut, recovering]);
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentUser, isNull);
      expect(api.hasSessionToken, false);
      expect(await db.metadata(), isNull);
      expect(
        (await SharedPreferences.getInstance()).getString('chat_session'),
        isNull,
      );
      expect(deltaRequests, 1);
      expect(heartbeats, 0);
      expect(directRequests, 1);
      expect(submissions, 0);
      expect(uploads, 0);
      expect(await db.allMessages('draft_peer'), isEmpty);
      // The stop fence belongs to the outgoing session, not future logins.
      await controller.debugLogin(2);
      expect(controller.currentUser!.id, 'other');
      expect(heartbeats, 0); // The client never renews presence leases.
      await controller.logout();
    } finally {
      await db.close();
    }
  });

  test('concurrent resumes share one refresh and hidden results cannot replace resumed state', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()
      ..userList = [
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      ];
    var heartbeats = 0, statusRequests = 0, deltaRequests = 0;
    var delayStatus = false;
    final statusStarted = Completer<void>();
    final delayedStatus = Completer<Map<String, dynamic>>();
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        statusRequests++;
        if (delayStatus) {
          if (!statusStarted.isCompleted) statusStarted.complete();
          return delayedStatus.future;
        }
        return {
          'statuses': {'peer': false},
        };
      }
      deltaRequests++;
      return delta(1, [payload()]);
    };
    api.otherPostHandler = (path, _) async {
      if (path == '/presence/heartbeat') heartbeats++;
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      expect(heartbeats, 0); // The client never renews presence leases.
      delayStatus = true;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await statusStarted.future;
      for (var i = 0; i < 8; i++) {
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(heartbeats, 0); // The client never renews presence leases.
      expect(statusRequests, 2);
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      delayStatus = false;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitForController(() => statusRequests >= 3);
      delayedStatus.complete({
        'statuses': {'peer': true},
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(heartbeats, 0); // The client never renews presence leases.
      expect(controller.onlineUserIds, isEmpty);
      expect(controller.connectionStatus, 'Connected');
      expect(deltaRequests, greaterThan(1)); // Resume still reconciles inbox.
    } finally {
      if (!delayedStatus.isCompleted) delayedStatus.complete({'statuses': {}});
      await controller.logout();
      await db.close();
    }
  });

  test('resume reuses its completed presence snapshot after blocked inbox recovery and later actions stay fresh', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    final inspector = DebugInspector(enabled: true);
    final deltaStarted = Completer<void>();
    final pendingDelta = Completer<Map<String, dynamic>>();
    var statusRequests = 0, deltaRequests = 0;
    var peerOnline = true;
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        statusRequests++;
        return {
          'statuses': {'peer': peerOnline},
        };
      }
      deltaRequests++;
      if (deltaRequests == 2) {
        deltaStarted.complete();
        return pendingDelta.future;
      }
      return delta(1, deltaRequests == 1 ? [payload()] : []);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
      debugInspector: inspector,
    );
    try {
      await controller.debugLogin(1);
      expect(statusRequests, 1);
      expect(controller.onlineUserIds, {'peer'});

      peerOnline = false;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await deltaStarted.future;
      await waitForController(() => controller.offlineUserIds.contains('peer'));
      expect(pendingDelta.isCompleted, false);
      expect(statusRequests, 2);
      // The early status response has already finished before inbox recovery.
      // Reusing only in-flight requests would issue a duplicate after this.
      pendingDelta.complete(delta(1, []));
      await waitForController(() => _completedSyncs(inspector) == 1);
      expect(statusRequests, 2);
      expect(controller.selectedRoom, isNull);

      peerOnline = true;
      await controller.syncNow();
      expect(statusRequests, 3);
      expect(controller.onlineUserIds, {'peer'});

      peerOnline = false;
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitForController(() => _completedSyncs(inspector) == 3);
      expect(statusRequests, 4);
      expect(deltaRequests, 4);
      expect(controller.offlineUserIds, {'peer'});
      expect(controller.selectedRoom, isNull);
    } finally {
      if (!pendingDelta.isCompleted) pendingDelta.complete(delta(1, []));
      await controller.logout();
      inspector.dispose();
      await db.close();
    }
  });

  test(
    'resume refreshes presence again when inbox recovery adds an eligible peer',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      final inspector = DebugInspector(enabled: true);
      final deltaStarted = Completer<void>();
      final pendingDelta = Completer<Map<String, dynamic>>();
      final statusRequests = <Set<String>>[];
      var deltaRequests = 0;
      api.handler = (path, query) async {
        if (path == '/presence/status') {
          final ids = (query!['userIds'] as String).split(',').toSet();
          statusRequests.add(ids);
          return {
            'statuses': {for (final id in ids) id: true},
          };
        }
        deltaRequests++;
        if (deltaRequests == 2) {
          deltaStarted.complete();
          return pendingDelta.future;
        }
        return delta(1, [payload()]);
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        debugInspector: inspector,
      );
      try {
        await controller.debugLogin(1);
        expect(statusRequests, [
          <String>{'peer'},
        ]);
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await deltaStarted.future;
        await waitForController(() => statusRequests.length == 2);
        expect(statusRequests.last, {'peer'});
        pendingDelta.complete(
          delta(2, [
            {...payload(room: 'new-room', pts: 2), 'peerUserId': 'new-peer'},
          ]),
        );
        await waitForController(() => _completedSyncs(inspector) == 1);
        expect(statusRequests, hasLength(3));
        expect(statusRequests.last, {'peer', 'new-peer'});
        expect(controller.onlineUserIds, {'peer', 'new-peer'});
        expect(controller.rooms, hasLength(2));
        expect(controller.selectedRoom, isNull);
      } finally {
        if (!pendingDelta.isCompleted) pendingDelta.complete(delta(1, []));
        await controller.logout();
        inspector.dispose();
        await db.close();
      }
    },
  );

  test('peer snapshot timer is bounded, pauses when hidden and never sends heartbeats', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()
      ..userList = [
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      ];
    var delayStatus = false, statuses = 0, heartbeats = 0;
    final started = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        statuses++;
        if (delayStatus) {
          if (!started.isCompleted) started.complete();
          return response.future;
        }
        return {
          'statuses': {'peer': false},
        };
      }
      return delta(1, [payload()]);
    };
    api.otherPostHandler = (path, _) async {
      if (path == '/presence/heartbeat') heartbeats++;
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    late _ManualPresenceTimer timer;
    Duration? interval;
    try {
      await controller.debugLogin(1);
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      delayStatus = true;
      runZoned(
        () => controller.didChangeAppLifecycleState(AppLifecycleState.resumed),
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (_, _, _, duration, callback) {
            interval = duration;
            return timer = _ManualPresenceTimer(callback);
          },
        ),
      );
      await started.future;
      expect(
        interval,
        Duration(
          seconds: const int.fromEnvironment(
            'PRESENCE_REFRESH_SECONDS',
            defaultValue: 30,
          ).clamp(1, 3600),
        ),
      );
      for (var i = 0; i < 8; i++) {
        timer.fire();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(statuses, 2);
      expect(heartbeats, 0);
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(timer.isActive, false);
      timer.fire();
      response.complete({
        'statuses': {'peer': true},
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        controller.onlineUserIds,
        isEmpty,
      ); // Hidden epoch fences late results.
      delayStatus = false;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitForController(() => statuses == 3);
      expect(heartbeats, 0);
    } finally {
      if (!response.isCompleted) response.complete({'statuses': {}});
      await controller.logout();
      await db.close();
    }
  });

  test('presence query failure exposes degradation without changing healthy transport or last online set', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()
      ..userList = [
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      ];
    var failPresence = false, peerOnline = true;
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        if (failPresence) {
          throw const ChatApiException('presence unavailable', statusCode: 503);
        }
        return {
          'statuses': {'peer': peerOnline},
        };
      }
      return delta(1, [payload()]);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    late _ManualPresenceTimer timer;
    try {
      await runZoned(
        () => controller.debugLogin(1),
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (_, _, _, _, callback) =>
              timer = _ManualPresenceTimer(callback),
        ),
      );
      expect(controller.connectionStatus, 'Connected');
      expect(controller.onlineUserIds, {'peer'});
      expect(controller.presenceDegraded, false);

      failPresence = true;
      timer.fire();
      await waitForController(() => controller.presenceDegraded);
      expect(controller.connectionStatus, 'Connected');
      expect(controller.onlineUserIds, {'peer'});
      expect(controller.currentUser?.id, 'me');
      expect(controller.requiresReauthentication, false);

      failPresence = false;
      peerOnline = false;
      timer.fire();
      await waitForController(() => !controller.presenceDegraded);
      expect(controller.connectionStatus, 'Connected');
      expect(controller.onlineUserIds, isEmpty);
    } finally {
      await controller.logout();
      await db.close();
    }
  });

  test('identical presence snapshots skip notifications while changed online sets notify once', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()
      ..userList = [
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
      ];
    var peerOnline = true, requests = 0;
    var lastSeenAt = '2026-10-18T00:00:00Z';
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        requests++;
        return {
          'statuses': {'peer': peerOnline},
          'lastSeenAt': {'peer': lastSeenAt},
        };
      }
      return delta(1, [payload()]);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    late _ManualPresenceTimer timer;
    var notifications = 0;
    void countNotification() => notifications++;
    try {
      await runZoned(
        () => controller.debugLogin(1),
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (_, _, _, _, callback) =>
              timer = _ManualPresenceTimer(callback),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, 1);
      expect(controller.onlineUserIds, {'peer'});
      expect(controller.lastSeenAtByUserId, isEmpty);
      controller.addListener(countNotification);

      timer.fire();
      await waitForController(() => requests == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(notifications, 0);

      peerOnline = false;
      timer.fire();
      await waitForController(() => controller.onlineUserIds.isEmpty);
      expect(notifications, 1);
      expect(controller.lastSeenAtByUserId['peer'], DateTime.parse(lastSeenAt));

      timer.fire();
      await waitForController(() => requests == 4);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(notifications, 1);
      expect(controller.connectionStatus, 'Connected');

      lastSeenAt = '2026-10-18T01:00:00Z';
      timer.fire();
      await waitForController(
        () =>
            controller.lastSeenAtByUserId['peer'] == DateTime.parse(lastSeenAt),
      );
      expect(notifications, 2);
      peerOnline = true;
      timer.fire();
      await waitForController(() => controller.onlineUserIds.contains('peer'));
      expect(controller.lastSeenAtByUserId, isEmpty);
    } finally {
      controller.removeListener(countNotification);
      await controller.logout();
      await db.close();
    }
  });

  test('a new session refresh is independent of the retired session status request', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    api.authHandler = (body) async =>
        session(body['debugUserNumber'] == 1 ? 'me' : 'other');
    api.userList = [
      const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
    ];
    var delayStatus = false, statusRequests = 0;
    final statusStarted = Completer<void>();
    final oldStatus = Completer<Map<String, dynamic>>();
    api.handler = (path, _) async {
      if (path == '/presence/status') {
        statusRequests++;
        if (delayStatus) {
          statusStarted.complete();
          return oldStatus.future;
        }
        return {
          'statuses': {'peer': false},
        };
      }
      return delta(1, [payload()]);
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      delayStatus = true;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await statusStarted.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('resume status never began'),
      );
      delayStatus = false;
      await controller
          .debugLogin(2)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError('next login blocked'),
          );
      expect(controller.currentUser!.id, 'other');
      expect(statusRequests, 3);
      oldStatus.complete({
        'statuses': {'peer': true},
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.currentUser!.id, 'other');
      expect(controller.onlineUserIds, isEmpty);
    } finally {
      if (!oldStatus.isCompleted) oldStatus.complete({'statuses': {}});
      await controller.logout();
      await db.close();
    }
  });

  test('offline timestamps ignore malformed and unauthorized data and survive a failed snapshot', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi()
      ..userList = [
        const UserProfile(id: 'peer', username: 'peer', displayName: 'Peer'),
        const UserProfile(
          id: 'invalid',
          username: 'invalid',
          displayName: 'Invalid',
        ),
      ];
    var fail = false;
    api.handler = (path, _) async {
      if (path != '/presence/status') {
        return delta(1, [
          payload(),
          {...payload(room: 'invalid-room'), 'peerUserId': 'invalid'},
        ]);
      }
      if (fail) throw const ChatApiException('Unavailable', statusCode: 503);
      return {
        'statuses': {'peer': false, 'invalid': false},
        'lastSeenAt': {
          'peer': '2026-10-18T02:30:00+03:00',
          'invalid': 'bad-date',
          'stranger': '2026-10-18T00:00:00Z',
        },
      };
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.debugLogin(1);
      expect(controller.userOnlineStatus('peer'), false);
      expect(controller.userOnlineStatus('stranger'), isNull);
      expect(controller.lastSeenAtByUserId, {
        'peer': DateTime.utc(2026, 10, 17, 23, 30),
      });
      fail = true;
      await controller.syncNow();
      expect(controller.presenceDegraded, true);
      expect(controller.offlineUserIds, {'peer', 'invalid'});
      expect(controller.lastSeenAtByUserId, {
        'peer': DateTime.utc(2026, 10, 17, 23, 30),
      });
      await controller.logout();
      expect(controller.lastSeenAtByUserId, isEmpty);
      expect(controller.offlineUserIds, isEmpty);
    } finally {
      await db.close();
    }
  });

  test('anonymous logout never sends a presence release request', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeApi();
    var offlineCalls = 0;
    api.otherPostHandler = (path, _) async {
      if (path == '/presence/offline') offlineCalls++;
      return {'ok': true};
    };
    final controller = ChatController(
      database: db,
      api: api,
      enableRealtime: false,
    );
    try {
      await controller.logout();
      expect(offlineCalls, 0);
      expect(api.hasSessionToken, false);
    } finally {
      await db.close();
    }
  });
}
