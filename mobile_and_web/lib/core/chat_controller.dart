import 'dart:async';
import 'dart:convert';

import 'package:centrifuge/centrifuge.dart' as centrifuge;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'chat_api.dart';
import 'inbox_sync_service.dart';
import 'models.dart';

final chatControllerProvider = ChangeNotifierProvider<ChatController>(
  (ref) => ChatController(),
);

class ChatController extends ChangeNotifier with WidgetsBindingObserver {
  ChatController({
    AppDatabase? database,
    ChatApi? api,
    this.enableRealtime = true,
  }) : database = database ?? AppDatabase(),
       api = api ?? ChatApi();
  final AppDatabase database;
  final ChatApi api;
  final bool enableRealtime;
  final _uuid = const Uuid();
  UserProfile? currentUser;
  List<UserProfile> debugUsers = [], users = [];
  List<ChatRoom> rooms = [];
  List<ChatMessage> messages = [];
  ChatRoom? selectedRoom;
  UserProfile? draftPeer;
  String? error, highlightMessageId;
  bool initialized = false,
      busy = false,
      isJumpMode = false,
      hasMoreMessages = false;
  String connectionStatus = 'Disconnected';
  Set<String> onlineUserIds = {};
  int sessionGenerationId = 0;
  int _authenticationAttempt = 0;
  Future<void> _sessionTransition = Future<void>.value();
  int _windowLimit = 50;
  bool _serverHasMoreMessages = false;
  final Map<String, bool> _historyHasMore = {};
  String? _activeRoomId;
  bool _disposed = false, _opening = false;
  centrifuge.Client? _client;
  InboxSyncService? _sync;
  SharedPreferences? _preferences;
  StreamSubscription<List<ChatRoom>>? _roomsSubscription;
  StreamSubscription<List<ChatMessage>>? _messagesSubscription;
  StreamSubscription<Map<String, dynamic>>? _roomEventsSubscription;
  final List<StreamSubscription<dynamic>> _socketSubscriptions = [];
  Timer? _presenceTimer, _highlightTimer;
  final List<Map<String, Object?>> _events = [];
  Map<String, Object?> _databaseSummary = {};
  bool get hasMoreRooms => _sync?.hasMoreRooms ?? false;
  Map<String, Object?> get diagnostics => {
    'database': 'chat_app_db',
    'sessionGeneration': sessionGenerationId,
    'connection': connectionStatus,
    'userId': currentUser?.id,
    'localRoomCount': rooms.length,
    'visibleMessageCount': messages.length,
    'deltaRequests': _sync?.deltaRequests ?? 0,
    'fullSyncs': _sync?.fullSyncs ?? 0,
    'messageRequests': api.messageRequests,
    'selectedRoom': selectedRoom?.toJson()?..remove('lastMessage'),
    ..._databaseSummary,
    'recentEvents': List<Map<String, Object?>>.unmodifiable(_events),
  };
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _record(String event, [String? detail]) {
    _events.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'detail': ?detail,
    });
    if (_events.length > 80) _events.removeAt(0);
    if (kDebugMode) {
      debugPrint('[chat] $event${detail == null ? '' : ': $detail'}');
    }
  }

  void clearError() {
    error = null;
    _notify();
  }

  Future<T?> _run<T>(
    Future<T> Function() operation, {
    bool showBusy = true,
  }) async {
    if (showBusy) busy = true;
    error = null;
    _notify();
    try {
      return await operation();
    } catch (failure) {
      error = failure.toString();
      _record('operation_failed', failure.runtimeType.toString());
      return null;
    } finally {
      if (showBusy) busy = false;
      _notify();
    }
  }

  void _background(Future<void> Function() operation) {
    unawaited(_run(operation, showBusy: false));
  }

  Future<void> initialize() async {
    if (initialized) return;
    final startupAttempt = _authenticationAttempt;
    WidgetsBinding.instance.addObserver(this);
    await _run(() async {
      _preferences = await SharedPreferences.getInstance();
      try {
        debugUsers = await api.getUsers('/auth/debug-users');
      } on ChatApiException catch (failure) {
        if (failure.statusCode != 404 && failure.statusCode != 403) rethrow;
        debugUsers = [];
      }
      final saved = _preferences!.getString('chat_session');
      if (saved != null) {
        try {
          final session = jsonMap(jsonDecode(saved));
          await _transitionSession(() async {
            if (startupAttempt == _authenticationAttempt && !_disposed) {
              await _startSession(session, restoring: true);
            }
          });
        } on ChatApiException catch (failure) {
          if (failure.statusCode == 401) {
            await _transitionSession(() async {
              if (startupAttempt == _authenticationAttempt) {
                await _stopSession(clear: true);
              }
            });
          } else {
            rethrow;
          }
        }
      }
    });
    initialized = true;
    _notify();
  }

  Future<void> debugLogin(int number) =>
      _authenticate('/auth/debug-login', {'debugUserNumber': number});
  Future<void> login(String email, String password) => _authenticate(
    '/auth/login',
    {'email': email.trim(), 'password': password},
  );
  Future<void> signup(
    String username,
    String email,
    String password,
    String displayName,
  ) => _authenticate('/auth/signup', {
    'username': username.trim(),
    'email': email.trim(),
    'password': password,
    'displayName': displayName.trim(),
  });
  Future<void> _authenticate(String endpoint, Map<String, dynamic> body) async {
    final attempt = ++_authenticationAttempt;
    await _run(() async {
      Map<String, dynamic> session;
      try {
        session = await api.post(endpoint, body);
      } catch (_) {
        if (_disposed || attempt != _authenticationAttempt) return;
        rethrow;
      }
      if (_disposed || attempt != _authenticationAttempt) return;
      await _transitionSession(() async {
        if (_disposed || attempt != _authenticationAttempt) return;
        await _stopSession(clear: true);
        if (_disposed || attempt != _authenticationAttempt) return;
        await _startSession(session);
      });
    });
  }

  Future<void> _transitionSession(Future<void> Function() work) {
    final next = _sessionTransition.then((_) => work());
    _sessionTransition = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _startSession(
    Map<String, dynamic> session, {
    bool restoring = false,
  }) async {
    final generation = ++sessionGenerationId;
    _preferences ??= await SharedPreferences.getInstance();
    currentUser = UserProfile.fromJson(jsonMap(session['user']));
    api.setToken(session['accessToken'] as String);
    await database.initializeSession(currentUser!.id);
    if (generation != sessionGenerationId) return;
    final savedPagination = _preferences!.getString('chat_room_pagination');
    final pagination = savedPagination == null
        ? null
        : jsonMap(jsonDecode(savedPagination));
    _sync = InboxSyncService(
      database: database,
      api: api,
      userId: currentUser!.id,
      restoredHasMoreRooms: pagination?['userId'] == currentUser!.id
          ? (pagination?['hasMore'] as bool?)
          : null,
      persistHasMoreRooms: (value) async {
        if (generation == sessionGenerationId) {
          await _preferences!.setString(
            'chat_room_pagination',
            jsonEncode({'userId': currentUser!.id, 'hasMore': value}),
          );
        }
      },
      isCurrentSession: () => !_disposed && generation == sessionGenerationId,
    );
    _roomsSubscription = database.watchRooms().listen((value) {
      if (generation != sessionGenerationId) return;
      rooms = value;
      if (selectedRoom != null) {
        final matching = rooms.where((r) => r.roomId == selectedRoom!.roomId);
        if (matching.isNotEmpty) selectedRoom = matching.first;
      }
      _notify();
    });
    _roomEventsSubscription = _sync!.roomEventsStream.listen((payload) {
      if (generation != sessionGenerationId) return;
      _applyJumpEvent(payload);
      _background(() async {
        await _deliverRooms([ChatRoom.fromJson(payload)]);
        if (_activeRoomId == payload['roomId'] && !_opening) {
          await _loadLatestMessages();
          await _markSeen();
        }
      });
    });
    if (!restoring) {
      _preferences ??= await SharedPreferences.getInstance();
      await _preferences!.setString('chat_session', jsonEncode(session));
    }
    await _sync!.syncInboxDelta();
    if (generation != sessionGenerationId) return;
    await _refreshUsers();
    await _deliverRooms(await database.watchRooms().first);
    await _refreshPresence();
    _presenceTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _background(_refreshPresence),
    );
    if (enableRealtime) {
      await _connectRealtime(session['centrifugoToken'] as String?, generation);
    }
    _record('session_started', restoring ? 'restored' : 'authenticated');
  }

  Future<void> logout() async {
    ++_authenticationAttempt;
    await _run(() => _transitionSession(() => _stopSession(clear: true)));
  }

  Future<void> _stopSession({required bool clear}) async {
    ++sessionGenerationId;
    _presenceTimer?.cancel();
    _highlightTimer?.cancel();
    await _client?.disconnect();
    await _client?.close();
    _client = null;
    for (final subscription in _socketSubscriptions) {
      await subscription.cancel();
    }
    _socketSubscriptions.clear();
    await _sync?.dispose();
    _sync = null;
    await _roomsSubscription?.cancel();
    await _messagesSubscription?.cancel();
    await _roomEventsSubscription?.cancel();
    if (clear) await database.clearAllTables();
    if (clear) {
      await _preferences?.remove('chat_session');
      await _preferences?.remove('chat_room_pagination');
    }
    api.setToken(null);
    currentUser = null;
    rooms = [];
    messages = [];
    users = [];
    onlineUserIds = {};
    selectedRoom = null;
    draftPeer = null;
    _activeRoomId = null;
    isJumpMode = false;
    _historyHasMore.clear();
    _databaseSummary = {};
    _events.clear();
    connectionStatus = 'Disconnected';
    _notify();
  }

  Future<void> _connectRealtime(String? token, int generation) async {
    final client = centrifuge.createClient(
      const String.fromEnvironment(
        'CENTRIFUGO_URL',
        defaultValue: 'ws://localhost:8000/connection/websocket',
      ),
      centrifuge.ClientConfig(
        token: token ?? '',
        getToken: (_) async {
          final result = await api.post('/auth/centrifugo-token');
          if (generation != sessionGenerationId) {
            throw const ChatApiException('Session ended.');
          }
          return result['centrifugoToken'] as String;
        },
      ),
    );
    _client = client;
    final inbox = client.newSubscription('inbox:user#${currentUser!.id}');
    _socketSubscriptions.addAll([
      client.connecting.listen((_) {
        if (generation == sessionGenerationId) {
          connectionStatus = 'Connecting';
          _notify();
        }
      }),
      client.connected.listen((_) {
        if (generation == sessionGenerationId) {
          connectionStatus = 'Connected';
          _record('socket_connected');
          _notify();
        }
      }),
      client.disconnected.listen((_) {
        if (generation == sessionGenerationId) {
          connectionStatus = 'Disconnected';
          _record('socket_disconnected');
          _notify();
        }
      }),
      client.error.listen((_) {
        if (generation == sessionGenerationId) {
          _record('socket_error');
          _notify();
        }
      }),
      inbox.error.listen((_) {
        if (generation == sessionGenerationId) {
          _record('subscription_error');
          _notify();
        }
      }),
      inbox.subscribed.listen((_) {
        if (generation == sessionGenerationId) {
          _record('inbox_subscribed');
          _background(syncNow);
        }
      }),
      inbox.publication.listen((event) {
        if (generation != sessionGenerationId) return;
        _background(() async {
          final payload = jsonMap(jsonDecode(utf8.decode(event.data)));
          _record('publication', 'pts=${payload['pts']}');
          await _sync?.receivePublication(payload);
        });
      }),
    ]);
    await inbox.subscribe();
    await client.connect();
  }

  Future<void> refreshUsers() async {
    await _run(_refreshUsers, showBusy: false);
  }

  Future<void> _refreshUsers() async {
    final generation = sessionGenerationId;
    final value = await api.getUsers('/users');
    if (generation == sessionGenerationId) {
      users = value.where((u) => u.id != currentUser?.id).toList();
      _notify();
    }
  }

  Future<void> _refreshPresence() async {
    if (currentUser == null) return;
    final generation = sessionGenerationId;
    try {
      await api.post('/presence/heartbeat');
    } catch (_) {
      _record('presence_heartbeat_unavailable');
    }
    if (generation != sessionGenerationId) return;
    final ids = users.map((user) => user.id).toList();
    final online = <String>{};
    for (var start = 0; start < ids.length; start += 100) {
      final chunk = ids.skip(start).take(100).toList();
      try {
        final value = await api.getMap(
          '/presence/status',
          query: {'userIds': chunk.join(',')},
        );
        if (generation != sessionGenerationId) return;
        final statuses = jsonMap(value['statuses']);
        online.addAll(statuses.keys.where((id) => statuses[id] == true));
      } catch (_) {
        _record('presence_status_unavailable');
        online.addAll(chunk.where(onlineUserIds.contains));
      }
    }
    if (generation != sessionGenerationId) return;
    onlineUserIds = online;
    _notify();
  }

  Future<void> syncNow() async {
    await _run(_syncNow, showBusy: false);
  }

  Future<void> _syncNow() async {
    await _sync?.syncInboxDelta();
    if (_activeRoomId != null && !_opening) await _loadLatestMessages();
    await _refreshDiagnosticSummary();
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && currentUser != null) {
      _background(() async {
        await syncNow();
        await _refreshPresence();
      });
    }
  }

  Future<void> loadMoreRooms() async {
    await _run(() async {
      await _sync?.loadMoreRooms();
    });
  }

  Future<void> openDirect(UserProfile peer) async {
    await _run(() async {
      final generation = sessionGenerationId;
      final result = await api.getMap('/rooms/direct-peer/${peer.id}');
      if (generation != sessionGenerationId) return;
      if (result['room'] != null) {
        final room = ChatRoom.fromJson(jsonMap(result['room']));
        await _sync?.reconcileMutation({'room': result['room']});
        await database.remapDraft('draft_${peer.id}', room.roomId);
        await _openRoom(room);
      } else {
        await _resetMessageView();
        draftPeer = peer;
        selectedRoom = null;
        _activeRoomId = 'draft_${peer.id}';
        _watchMessages();
      }
    });
  }

  Future<void> openRoom(ChatRoom room) async {
    await _run(() => _openRoom(room));
  }

  Future<void> _openRoom(ChatRoom room) async {
    final generation = sessionGenerationId;
    await _resetMessageView();
    selectedRoom = room;
    _activeRoomId = room.roomId;
    _opening = true;
    _notify();
    try {
      await _sync?.syncInboxDelta();
      if (generation != sessionGenerationId || _activeRoomId != room.roomId) {
        return;
      }
      await _loadLatestMessages();
      if (generation != sessionGenerationId || _activeRoomId != room.roomId) {
        return;
      }
      _sync?.openRoomId = room.roomId;
      _watchMessages();
      await _markSeen();
    } finally {
      _opening = false;
    }
  }

  Future<void> _resetMessageView() async {
    await _messagesSubscription?.cancel();
    _messagesSubscription = null;
    _sync?.openRoomId = null;
    selectedRoom = null;
    draftPeer = null;
    _activeRoomId = null;
    messages = [];
    isJumpMode = false;
    highlightMessageId = null;
    _windowLimit = 50;
    hasMoreMessages = false;
    _serverHasMoreMessages = false;
  }

  Future<void> closeRoom() async {
    await _resetMessageView();
    _notify();
  }

  void _watchMessages() {
    unawaited(_messagesSubscription?.cancel());
    if (_activeRoomId == null || isJumpMode) return;
    final generation = sessionGenerationId;
    final roomId = _activeRoomId!;
    _messagesSubscription = database.watchMessages(roomId, _windowLimit).listen(
      (value) {
        if (generation == sessionGenerationId &&
            roomId == _activeRoomId &&
            !isJumpMode) {
          messages = value;
          _notify();
        }
      },
    );
  }

  Future<void> _loadLatestMessages() async {
    final sync = _sync;
    final roomId = _activeRoomId;
    final generation = sessionGenerationId;
    if (sync == null || roomId == null || roomId.startsWith('draft_')) return;
    await sync.queue.enqueue(() async {
      final room = await database.room(roomId);
      if (room == null || generation != sessionGenerationId) return;
      final cached = await database.allMessages(roomId);
      if (room.msgPts == room.messagesSyncedPts && cached.isNotEmpty) {
        _serverHasMoreMessages =
            _historyHasMore[roomId] ??
            cached.where((m) => m.status == 'sent').length >= 30;
        hasMoreMessages =
            cached.length > _windowLimit || _serverHasMoreMessages;
        return;
      }
      final response = await api.latestMessages(roomId);
      if (generation != sessionGenerationId) return;
      final fresh = (response['messages'] as List)
          .map((m) => ChatMessage.fromJson(jsonMap(m)))
          .toList();
      final preservedHistory = await database.reconcileLatest(
        roomId,
        fresh,
        room.msgPts,
        room.lastHistoryEditPts,
        room.messagesSyncedPts,
      );
      if (roomId == _activeRoomId) {
        selectedRoom = await database.room(roomId);
        _serverHasMoreMessages = preservedHistory
            ? _historyHasMore[roomId] ?? response['hasMore'] == true
            : response['hasMore'] == true;
        _historyHasMore[roomId] = _serverHasMoreMessages;
        final count = (await database.allMessages(roomId)).length;
        hasMoreMessages = count > _windowLimit || _serverHasMoreMessages;
      }
      _record('messages_reconciled', 'received=${fresh.length}');
    });
  }

  Future<void> loadOlderMessages() async {
    await _run(() async {
      final roomId = _activeRoomId;
      final generation = sessionGenerationId;
      if (roomId == null || roomId.startsWith('draft_') || isJumpMode) return;
      await _sync?.queue.enqueue(() async {
        final cached = await database.allMessages(roomId);
        if (generation != sessionGenerationId || roomId != _activeRoomId) {
          return;
        }
        if (cached.length > _windowLimit) {
          _windowLimit += 30;
          hasMoreMessages =
              cached.length > _windowLimit || _serverHasMoreMessages;
          _watchMessages();
          return;
        }
        if (!_serverHasMoreMessages) {
          hasMoreMessages = false;
          return;
        }
        final sent = cached
            .where((message) => message.status == 'sent')
            .toList();
        if (sent.isEmpty) return;
        final result = await api.latestMessages(roomId, before: sent.last);
        if (generation != sessionGenerationId) return;
        await database.transaction(() async {
          for (final value in result['messages'] as List) {
            await database.upsertMessage(ChatMessage.fromJson(jsonMap(value)));
          }
        });
        _historyHasMore[roomId] = result['hasMore'] == true;
        if (roomId == _activeRoomId) {
          _serverHasMoreMessages = result['hasMore'] == true;
          _windowLimit += 30;
          final count = (await database.allMessages(roomId)).length;
          hasMoreMessages = count > _windowLimit || _serverHasMoreMessages;
          _watchMessages();
        }
      });
    }, showBusy: false);
  }

  Future<void> createGroup(String title, List<String> participantIds) async {
    await _run(() async {
      final generation = sessionGenerationId;
      final result = await api.post('/rooms/group', {
        'title': title.trim(),
        'participantIds': participantIds,
      });
      if (generation != sessionGenerationId) return;
      await _sync?.reconcileMutation(result);
      await _openRoom(ChatRoom.fromJson(jsonMap(result['room'])));
    });
  }

  Future<void> sendText(String text, {ChatMessage? replyTo}) async {
    if (text.trim().isEmpty) return;
    final generation = sessionGenerationId;
    await _run(
      () => _send(
        generation: generation,
        type: 'text',
        text: text.trim(),
        replyTo: replyTo,
      ),
      showBusy: false,
    );
  }

  Future<void> sendImage(
    Uint8List bytes,
    String filename, {
    ChatMessage? replyTo,
  }) async {
    final generation = sessionGenerationId;
    final senderId = currentUser?.id;
    final targetRoomId = _activeRoomId;
    final targetPeerUserId = draftPeer?.id;
    if (senderId == null || targetRoomId == null) return;
    await _run(() async {
      if (!_isCurrentMessageSession(generation, senderId)) return;
      String url;
      try {
        url = await api.uploadImage(bytes, filename);
      } catch (_) {
        if (!_isCurrentMessageSession(generation, senderId)) return;
        rethrow;
      }
      if (!_isCurrentMessageSession(generation, senderId)) return;
      await _send(
        generation: generation,
        type: 'image',
        text: '',
        imageUrl: url,
        replyTo: replyTo,
        targetRoomId: targetRoomId,
        targetPeerUserId: targetPeerUserId,
      );
    });
  }

  Future<void> _send({
    required int generation,
    required String type,
    required String text,
    String? imageUrl,
    ChatMessage? replyTo,
    String? targetRoomId,
    String? targetPeerUserId,
  }) async {
    final user = currentUser;
    final roomId = targetRoomId ?? _activeRoomId;
    if (user == null ||
        roomId == null ||
        !_isCurrentMessageSession(generation, user.id)) {
      return;
    }
    final key = _uuid.v4();
    final message = ChatMessage(
      id: 'temp_$key',
      idempotencyKey: key,
      roomId: roomId,
      peerUserId:
          targetPeerUserId ?? (targetRoomId == null ? draftPeer?.id : null),
      senderId: user.id,
      senderName: user.displayName,
      senderAvatarUrl: user.avatarUrl,
      type: type,
      text: text,
      imageUrl: imageUrl,
      replyTo: replyTo == null ? null : ReplySnapshot.fromMessage(replyTo),
      status: 'sending',
      createdAt: DateTime.now().toUtc(),
    );
    await database.transaction(() async {
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      await database.upsertMessage(message);
    });
    if (!_isCurrentMessageSession(generation, message.senderId)) return;
    await _submitMessage(message, generation: generation);
  }

  bool _isCurrentMessageSession(int generation, String senderId) =>
      !_disposed &&
      generation == sessionGenerationId &&
      currentUser?.id == senderId;

  Future<void> _submitMessage(
    ChatMessage message, {
    required int generation,
  }) async {
    if (!_isCurrentMessageSession(generation, message.senderId)) return;
    try {
      final result = await api.post('/messages', {
        if (!message.roomId.startsWith('draft_')) 'roomId': message.roomId,
        if (message.roomId.startsWith('draft_'))
          'peerUserId': message.peerUserId,
        'idempotencyKey': message.idempotencyKey,
        'type': message.type,
        'text': message.text,
        if (message.imageUrl != null) 'imageUrl': message.imageUrl,
        if (message.replyTo != null)
          'replyToMessageId': message.replyTo!.messageId,
      });
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      final serverMessage = ChatMessage.fromJson(jsonMap(result['message']));
      await database.transaction(() async {
        if (!_isCurrentMessageSession(generation, message.senderId)) return;
        await database.remapDraft(message.roomId, serverMessage.roomId);
        await _sync?.reconcileMutation(result);
      });
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      if (_activeRoomId == message.roomId &&
          message.roomId.startsWith('draft_')) {
        _activeRoomId = serverMessage.roomId;
        draftPeer = null;
        final room = await database.room(serverMessage.roomId);
        if (!_isCurrentMessageSession(generation, message.senderId)) return;
        selectedRoom = room;
        _sync?.openRoomId = serverMessage.roomId;
        _watchMessages();
      }
      _record('message_sent');
    } catch (_) {
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      await database.transaction(() async {
        if (!_isCurrentMessageSession(generation, message.senderId)) return;
        await database.setMessageStatus(message.id, 'failed');
      });
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      rethrow;
    }
  }

  Future<void> retryMessage(ChatMessage message) async {
    final generation = sessionGenerationId;
    await _run(() async {
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      await database.transaction(() async {
        if (!_isCurrentMessageSession(generation, message.senderId)) return;
        await database.setMessageStatus(message.id, 'sending');
      });
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      await _submitMessage(message, generation: generation);
    }, showBusy: false);
  }

  Future<void> editMessage(ChatMessage message, String text) async {
    await _run(() async {
      final generation = sessionGenerationId;
      final result = jsonMap(
        await api.request(
          'PATCH',
          '/messages/${message.id}',
          data: {'text': text.trim()},
        ),
      );
      if (generation != sessionGenerationId) return;
      await _sync?.reconcileMutation(result);
      if (isJumpMode) _applyJumpMutation(result);
    });
  }

  Future<void> deleteMessage(
    ChatMessage message, {
    required bool forEveryone,
  }) async {
    await _run(() async {
      final generation = sessionGenerationId;
      final result = jsonMap(
        await api.request(
          'DELETE',
          '/messages/${message.id}/${forEveryone ? 'for-all' : 'for-me'}',
        ),
      );
      if (generation != sessionGenerationId) return;
      await _sync?.reconcileMutation(result);
      if (!forEveryone) {
        await database.removeMessage(message.id);
        messages = messages.where((m) => m.id != message.id).toList();
      } else if (isJumpMode) {
        _applyJumpMutation(result);
      }
    });
  }

  Future<void> setPreferences(ChatRoom room, {bool? pin, bool? isMuted}) async {
    await _run(() async {
      final generation = sessionGenerationId;
      final result = jsonMap(
        await api.request(
          'PATCH',
          '/rooms/${room.roomId}/preferences',
          data: {'pin': ?pin, 'isMuted': ?isMuted},
        ),
      );
      if (generation == sessionGenerationId) {
        await _sync?.reconcileMutation(result);
      }
    }, showBusy: false);
  }

  Future<void> _deliverRooms(List<ChatRoom> values) async {
    final ids = values
        .where(
          (r) =>
              r.roomType == 'direct' &&
              r.lastMessage != null &&
              r.lastMessage!.senderId != currentUser?.id &&
              r.lastMessage!.deliveredAt == null,
        )
        .map((r) => r.roomId)
        .toList();
    for (var start = 0; start < ids.length; start += 100) {
      try {
        await api.post('/rooms/delivered-batch', {
          'roomIds': ids.skip(start).take(100).toList(),
        });
      } catch (_) {
        _record('delivery_receipt_unavailable');
      }
    }
  }

  Future<void> _markSeen() async {
    final roomId = _activeRoomId;
    if (roomId == null || roomId.startsWith('draft_')) return;
    await api.post('/rooms/$roomId/seen');
  }

  Future<void> jumpToMessage(String targetId) async {
    await _run(() async {
      final roomId = _activeRoomId;
      final generation = sessionGenerationId;
      if (roomId == null) return;
      final cached = await database.message(targetId);
      if (cached != null && cached.roomId == roomId) {
        final all = await database.allMessages(roomId);
        _windowLimit = all.indexWhere((m) => m.id == targetId) + 30;
        isJumpMode = false;
        _watchMessages();
      } else {
        final result = await api.getMap(
          '/rooms/$roomId/messages/around/$targetId',
          query: {'limit': 30},
        );
        if (generation != sessionGenerationId || roomId != _activeRoomId) {
          return;
        }
        await _messagesSubscription?.cancel();
        isJumpMode = true;
        messages = (result['messages'] as List)
            .map((m) => ChatMessage.fromJson(jsonMap(m)))
            .toList();
      }
      if (generation != sessionGenerationId || roomId != _activeRoomId) return;
      highlightMessageId = targetId;
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
        highlightMessageId = null;
        _notify();
      });
    });
  }

  void _applyJumpMutation(Map<String, dynamic> result) {
    if (result['room'] != null) _applyJumpEvent(jsonMap(result['room']));
  }

  void _applyJumpEvent(Map<String, dynamic> payload) {
    if (!isJumpMode || payload['roomId'] != _activeRoomId) return;
    messages = reconcileJumpSlice(messages, payload);
    _notify();
  }

  Future<void> returnToLatest() async {
    await _run(() async {
      isJumpMode = false;
      _windowLimit = 50;
      await _loadLatestMessages();
      _watchMessages();
    }, showBusy: false);
  }

  String? imageUrl(String? path) =>
      path == null ? null : api.absoluteImageUrl(path);
  Future<Map<String, Object?>> inspectDatabase() async {
    if (!kDebugMode) return {'enabled': false};
    final value = await database.inspect();
    await _refreshDiagnosticSummary();
    return value;
  }

  Future<void> _refreshDiagnosticSummary() async {
    final meta = await database.metadata();
    _databaseSummary = {
      'localPts': meta?.localPts ?? 0,
      'localEpoch': meta?.localEpoch ?? '',
      ...await database.rowCounts(),
    };
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      _transitionSession(() => _stopSession(clear: false))
          .whenComplete(database.close),
    );
    super.dispose();
  }
}
