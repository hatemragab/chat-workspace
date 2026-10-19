import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_workspace/core/exports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_regressions_test.dart' show delta, session, waitForController;
import 'sync_test.dart'
    show FakeApi, instant, message, payload, testServerHealth;

const _peer = UserProfile(id: 'peer', username: 'peer', displayName: 'Peer');
const _anotherPeer = UserProfile(
  id: 'another-peer',
  username: 'another',
  displayName: 'Another',
);

class _DeferredTransactionDatabase extends AppDatabase {
  _DeferredTransactionDatabase() : super(NativeDatabase.memory());
  int? transactionsBeforePause;
  final paused = Completer<void>(), resume = Completer<void>();

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    final remaining = transactionsBeforePause;
    if (remaining != null) {
      transactionsBeforePause = remaining == 0 ? null : remaining - 1;
      if (remaining == 0) {
        paused.complete();
        await resume.future;
      }
    }
    return super.transaction(action, requireNew: requireNew);
  }
}

class _DeleteApi extends FakeApi {
  @override
  Future<Object?> request(
    String method,
    String path, {
    Map<String, dynamic>? data,
    Map<String, dynamic>? query,
  }) async {
    if (method == 'DELETE') return {'room': payload(pts: 2)};
    throw StateError('Unexpected $method $path');
  }
}

class _DeferredMetadataDatabase extends AppDatabase {
  _DeferredMetadataDatabase() : super(NativeDatabase.memory());
  bool pauseMetadata = false;
  final paused = Completer<void>(), resume = Completer<void>();

  @override
  Future<SyncMetadataRow?> metadata() async {
    final value = await super.metadata();
    if (pauseMetadata) {
      pauseMetadata = false;
      paused.complete();
      await resume.future;
    }
    return value;
  }
}

Map<String, dynamic> _acknowledgement(Map<String, dynamic> body, int index) {
  final sent = {
    ...body,
    'id': 'server-$index',
    'roomId': 'real-room',
    'senderId': 'me',
    'senderName': 'Me',
    'createdAt': instant.add(Duration(seconds: index)).toIso8601String(),
  };
  return {
    'message': sent,
    'room': {...payload(room: 'real-room', pts: index), 'lastMessage': sent},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final pendingWrite in ['reconciliation', 'local deletion']) {
    test(
      'delete-for-me paused in $pendingWrite cannot remove the next account shared row or view',
      () async {
        final db = _DeferredTransactionDatabase();
        final api = _DeleteApi();
        api.authHandler = (body) async =>
            session(body['debugUserNumber'] == 1 ? 'me' : 'other');
        api.handler = (_, _) async => delta(0, []);
        final controller = ChatController(
          database: db,
          api: api,
          enableRealtime: false,
          healthMonitorFactory: testServerHealth,
        );
        try {
          await controller.debugLogin(1);
          await db.upsertMessage(message('shared-message'));
          db.transactionsBeforePause = pendingWrite == 'reconciliation' ? 0 : 1;
          final deleting = controller.deleteMessage(
            message('shared-message'),
            forEveryone: false,
          );
          await db.paused.future;
          await controller.debugLogin(2);
          final shared = message('shared-message');
          await db.upsertMessage(shared);
          controller.messages = [shared];
          db.resume.complete();
          await deleting;
          expect(controller.currentUser!.id, 'other');
          expect(await db.message(shared.id), isNotNull);
          expect(controller.messages.map((m) => m.id), [shared.id]);
        } finally {
          if (!db.resume.isCompleted) db.resume.complete();
          await controller.logout();
          await db.close();
        }
      },
    );
  }

  for (final stage in ['delta', 'users', 'presence']) {
    for (final fails in [false, true]) {
      test(
        'logout retires pending startup $stage and its late ${fails ? 'failure' : 'response'} cannot affect the next login',
        () async {
          SharedPreferences.setMockInitialValues({
            'chat_session': jsonEncode(session('me')),
          });
          final db = AppDatabase(NativeDatabase.memory());
          final api = FakeApi();
          final started = Completer<void>();
          final response = Completer<Map<String, dynamic>>();
          final userResponse = Completer<List<UserProfile>>();
          final requests = <String>[];
          api.authHandler = (_) async => session('other');
          bool oldSession() =>
              api.dio.options.headers['Authorization'] == 'Bearer me';
          api.handler = (path, _) async {
            requests.add(
              'GET $path ${api.dio.options.headers['Authorization']}',
            );
            if (path == '/rooms/delta') {
              if (oldSession() && stage == 'delta') {
                started.complete();
                return response.future;
              }
              return delta(
                oldSession() ? 1 : 5,
                stage == 'presence' ? [payload()] : [],
              );
            }
            if (path == '/presence/status') {
              if (oldSession() && stage == 'presence') {
                started.complete();
                return response.future;
              }
              return {'statuses': <String, bool>{}};
            }
            if (path.startsWith('/rooms/direct-peer/')) return {'room': null};
            throw StateError('Unexpected request: $path');
          };
          api.usersHandler = (path) async {
            if (path != '/users') return [];
            requests.add(
              'GET $path ${api.dio.options.headers['Authorization']}',
            );
            if (oldSession() && stage == 'users') {
              started.complete();
              return userResponse.future;
            }
            return [_peer];
          };
          api.otherPostHandler = (path, _) async {
            requests.add(
              'POST $path ${api.dio.options.headers['Authorization']}',
            );
            return {'ok': true};
          };
          final controller = ChatController(
            database: db,
            api: api,
            enableRealtime: false,
            healthMonitorFactory: testServerHealth,
          );
          final initializing = controller.initialize();
          try {
            await started.future;
            final oldGeneration = controller.sessionGenerationId;
            final loggingOut = controller.logout();
            expect(controller.sessionGenerationId, greaterThan(oldGeneration));
            expect(controller.captureSendContext(), isNull);
            await controller.openDirect(_anotherPeer);
            await loggingOut.timeout(const Duration(seconds: 1));
            expect(controller.currentUser, isNull);
            expect(await db.metadata(), isNull);
            expect(api.hasSessionToken, false);
            expect(
              (await SharedPreferences.getInstance()).getString('chat_session'),
              isNull,
            );
            expect(
              requests.where((r) => r.contains('/rooms/direct-peer/')),
              isEmpty,
            );
            expect(
              requests.where((r) => r == 'POST /presence/offline Bearer me'),
              hasLength(1),
            );

            await controller.debugLogin(2);
            final currentGeneration = controller.sessionGenerationId;
            final completedRequests = requests.length;
            controller.error = 'A newer operation failed';
            if (fails) {
              if (stage == 'users') {
                userResponse.completeError(
                  const ChatApiException('old request failed', statusCode: 503),
                );
              } else {
                response.completeError(
                  const ChatApiException('old request failed', statusCode: 503),
                );
              }
            } else if (stage == 'users') {
              userResponse.complete([_anotherPeer]);
            } else {
              response.complete({
                'requiresFullSync': true,
                'pts': 999,
                'epoch': 'retired',
              });
            }
            await initializing;
            await Future<void>.delayed(Duration.zero);
            expect(controller.currentUser!.id, 'other');
            expect(controller.sessionGenerationId, currentGeneration);
            expect(controller.initialized, true);
            expect(controller.error, 'A newer operation failed');
            expect(controller.users.map((user) => user.id), [_peer.id]);
            expect(api.dio.options.headers['Authorization'], 'Bearer other');
            expect((await db.metadata())!.localPts, 5);
            expect(requests, hasLength(completedRequests));
            expect(
              (controller.diagnostics['recentEvents'] as List).where(
                (event) => event['event'] == 'session_started',
              ),
              hasLength(1),
            );
          } finally {
            if (!response.isCompleted) response.complete(delta(0, []));
            if (!userResponse.isCompleted) userResponse.complete([]);
            await initializing;
            await controller.logout();
            await db.close();
          }
        },
      );
    }
  }

  test(
    'expired saved credentials finish initialization and leave login usable',
    () async {
      SharedPreferences.setMockInitialValues({
        'chat_session': jsonEncode(session('me')),
      });
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      api.authHandler = (_) async => session('other');
      api.handler = (_, _) async {
        if (api.dio.options.headers['Authorization'] == 'Bearer me') {
          throw const ChatApiException('expired', statusCode: 401);
        }
        return delta(0, []);
      };
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      try {
        await controller.initialize();
        await waitForController(() => controller.requiresReauthentication);
        expect(controller.currentUser!.id, 'me');
        expect(controller.initialized, true);
        expect(controller.busy, false);
        expect(controller.error, isNull);
        expect(api.hasSessionToken, true);
        await controller.debugLogin(2);
        expect(controller.currentUser!.id, 'other');
        expect(controller.initialized, true);
        expect(controller.busy, false);
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );

  test(
    'retiring a sync paused in metadata prevents its next HTTP request',
    () async {
      final db = _DeferredMetadataDatabase();
      await db.initializeSession('me');
      final api = FakeApi();
      var requests = 0;
      api.handler = (_, _) async {
        requests++;
        return delta(99, []);
      };
      final sync = InboxSyncService(
        database: db,
        api: api,
        userId: 'me',
        isCurrentSession: () => true,
      );
      db.pauseMetadata = true;
      final pending = sync.syncInboxDelta();
      try {
        await db.paused.future;
        await sync.retire().timeout(const Duration(seconds: 1));
        await db.clearAllTables();
        db.resume.complete();
        await pending;
        expect(requests, 0);
        expect(await db.metadata(), isNull);
      } finally {
        if (!db.resume.isCompleted) db.resume.complete();
        await sync.dispose();
        await db.close();
      }
    },
  );

  test(
    'retiring sync does not wait for a paused room-event listener',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final sync = InboxSyncService(
        database: db,
        api: FakeApi(),
        userId: 'me',
        isCurrentSession: () => true,
      );
      final subscription = sync.roomEventsStream.listen((_) {});
      subscription.pause();
      try {
        await sync.retire().timeout(const Duration(seconds: 1));
      } finally {
        await subscription.cancel();
        await sync.dispose();
        await db.close();
      }
    },
  );

  for (final navigate in [false, true]) {
    test(
      'lazy batch second image stays ${navigate ? 'in its original room after navigation' : 'visible while pending and failed'} and retries with its key',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = FakeApi();
        api.handler = (path, _) async => path.startsWith('/rooms/direct-peer/')
            ? {'room': null}
            : delta(0, []);
        api.uploadHandler = (_, filename) async => '/public/uploads/$filename';
        final submitted = <Map<String, dynamic>>[];
        final secondStarted = Completer<void>();
        final secondResponse = Completer<Map<String, dynamic>>();
        api.postHandler = (_, body) async {
          submitted.add(Map<String, dynamic>.from(body!));
          if (submitted.length == 2) {
            secondStarted.complete();
            return secondResponse.future;
          }
          return _acknowledgement(body, submitted.length);
        };
        final controller = ChatController(
          database: db,
          api: api,
          enableRealtime: false,
          healthMonitorFactory: testServerHealth,
        );
        try {
          await controller.debugLogin(1);
          await controller.openDirect(_peer);
          final context = controller.captureSendContext()!;
          await controller.sendImage(
            Uint8List.fromList([1]),
            'first.png',
            context: context,
          );
          await controller.outboxIdle;
          expect(controller.selectedRoom!.roomId, 'real-room');
          if (navigate) await controller.openDirect(_anotherPeer);
          final sending = controller.sendImage(
            Uint8List.fromList([2]),
            'second.png',
            context: context,
          );
          await secondStarted.future;
          await Future<void>.delayed(Duration.zero);
          final optimistic = (await db.allMessages('real-room'))
              .singleWhere((m) => m.imageUrl!.endsWith('second.png'));
          expect(optimistic.status, 'sending');
          expect(optimistic.peerUserId, _peer.id);
          expect(await db.allMessages('draft_peer'), isEmpty);
          expect(submitted[1]['roomId'], 'real-room');
          expect(submitted[1].containsKey('peerUserId'), false);
          if (!navigate) {
            expect(controller.messages.any((m) => m.id == optimistic.id), true);
          }
          secondResponse.completeError(
            const ChatApiException(
              'Invalid message',
              statusCode: 400,
              kind: ChatFailureKind.validation,
            ),
          );
          await sending;
          await controller.outboxIdle;
          final failed = (await db.message(optimistic.id))!;
          expect(failed.status, 'failed');
          expect(failed.roomId, 'real-room');
          if (navigate) {
            expect(controller.draftPeer!.id, _anotherPeer.id);
            expect(await db.allMessages('draft_another-peer'), isEmpty);
          } else {
            await Future<void>.delayed(Duration.zero);
            expect(
              controller.messages.any(
                (m) => m.id == failed.id && m.status == 'failed',
              ),
              true,
            );
          }
          await controller.retryMessage(failed);
          await controller.outboxIdle;
          expect(
            submitted[2]['idempotencyKey'],
            submitted[1]['idempotencyKey'],
          );
          expect(submitted[2]['roomId'], 'real-room');
          expect(await db.message(failed.id), isNull);
          expect(
            (await db.messageByIdempotencyKey(
              'me',
              failed.idempotencyKey,
            ))!.status,
            'sent',
          );
          expect(await db.allMessages('draft_peer'), isEmpty);
          if (navigate) expect(controller.draftPeer!.id, _anotherPeer.id);
        } finally {
          if (!secondResponse.isCompleted) {
            secondResponse.complete({});
          }
          await controller.logout();
          await db.close();
        }
      },
    );
  }

  test(
    'a remapped lazy context cannot create an image under a later account',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeApi();
      api.authHandler = (body) async =>
          session(body['debugUserNumber'] == 1 ? 'me' : 'other');
      api.handler = (path, _) async => path.startsWith('/rooms/direct-peer/')
          ? {'room': null}
          : delta(0, []);
      var uploads = 0, submissions = 0;
      api.uploadHandler = (_, filename) async {
        uploads++;
        return '/public/uploads/$filename';
      };
      api.postHandler = (_, body) async =>
          _acknowledgement(body!, ++submissions);
      final controller = ChatController(
        database: db,
        api: api,
        enableRealtime: false,
        healthMonitorFactory: testServerHealth,
      );
      try {
        await controller.debugLogin(1);
        await controller.openDirect(_peer);
        final context = controller.captureSendContext()!;
        await controller.sendImage(
          Uint8List.fromList([1]),
          'first.png',
          context: context,
        );
        await controller.outboxIdle;
        await controller.debugLogin(2);
        await controller.openDirect(_peer);
        await controller.sendImage(
          Uint8List.fromList([2]),
          'second.png',
          context: context,
        );
        expect(uploads, 1);
        expect(submissions, 1);
        expect(await db.allMessages('real-room'), isEmpty);
        expect(await db.allMessages('draft_peer'), isEmpty);
        expect(controller.currentUser!.id, 'other');
      } finally {
        await controller.logout();
        await db.close();
      }
    },
  );
}
