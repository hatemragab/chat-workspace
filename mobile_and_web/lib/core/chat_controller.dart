import 'dart:async';
import 'dart:convert';

import 'package:centrifuge/centrifuge.dart' as centrifuge;
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'chat_api.dart';
import 'debug_inspector.dart';
import 'inbox_sync_service.dart';
import 'models.dart';
import 'network_config.dart';
import 'outbox_send_queue.dart';
import 'realtime_transport_logging.dart';
import 'server_health_monitor.dart';

final chatControllerProvider = ChangeNotifierProvider<ChatController>(
  (ref) => ChatController(enableDebugLogging: kDebugMode),
);

/// Captured before UI awaits so a send remains bound to its initiating account
/// and conversation, including a batch whose first image creates a direct room.
class MessageSendContext {
  const MessageSendContext({
    required this.generation,
    required this.senderId,
    required this.targetRoomId,
    this.targetPeerUserId,
    this.targetPeer,
  });
  final int generation;
  final String senderId, targetRoomId;
  final String? targetPeerUserId;
  final UserProfile? targetPeer;
}

typedef _PresenceSnapshot = ({
  Future<void> completion,
  Set<String> peers,
  int epoch,
});

class ChatController extends ChangeNotifier with WidgetsBindingObserver {
  ChatController({
    AppDatabase? database,
    ChatApi? api,
    this.enableRealtime = true,
    this.realtimeUrl = centrifugoUrl,
    this.healthMonitorFactory,
    DebugInspector? debugInspector,
    bool enableDebugLogging = false,
  }) : database = database ?? AppDatabase(),
       api = api ?? ChatApi(),
       debugInspector = debugInspector ?? DebugInspector(),
       _ownsDebugInspector = debugInspector == null {
    this.database.attachDebugInspector(this.debugInspector);
    this.debugInspector.setSqliteDetailsEnabled(
      this.api.debugTrafficLoggingEnabled,
    );
    this.api.debugInspector = this.debugInspector;
    this.api.onUnauthorized = () {
      unawaited(_requireReauthentication(sessionGenerationId));
    };
    if (kDebugMode && enableDebugLogging) {
      // Configure before initialize() so startup operations reach Logdy too.
      this.debugInspector.setEnabled(true);
      this.debugInspector.setShareWithLocalLogs(true);
      setDebugTrafficLoggingEnabled(
        const bool.fromEnvironment(
          'DEBUG_TRAFFIC_LOGGING_ENABLED',
          defaultValue: true,
        ),
      );
    }
  }
  final DebugInspector debugInspector;
  final bool _ownsDebugInspector;
  DebugTraceContext? lastStateContext;
  Map<String, Object?> _lastObservedState = const {};
  int _notificationId = 0;
  int get lastStateNotificationId => _notificationId;

  void refreshInspectorGauges() {
    debugInspector.updateContext(
      userId: currentUser?.id,
      sessionGeneration: sessionGenerationId,
      roomId: _activeRoomId,
    );
    if (!debugInspector.enabled) return;
    database.refreshInspectorGauges();
    _sync?.refreshInspectorGauges();
    debugInspector.setGauges({
      'rooms': rooms.length,
      'visibleMessages': messages.length,
      'onlineUsers': onlineUserIds.length,
      'socketSubscriptions': _socketSubscriptions.length,
      'roomsSubscription': _roomsSubscription == null ? 0 : 1,
      'messagesSubscription': _messagesSubscription == null ? 0 : 1,
      'roomEventsSubscription': _roomEventsSubscription == null ? 0 : 1,
      'presenceTimer': _presenceTimer?.isActive == true ? 1 : 0,
      'highlightTimer': _highlightTimer?.isActive == true ? 1 : 0,
      'lifecycleObserver': _observingLifecycle && !_disposed ? 1 : 0,
      'roomRecoveries': _roomRecoveries.length,
      'draftAdoptions': _draftAdoptions.length,
      'directLookups': _directLookups.length,
      'inboxRecovery': _inboxRecovery == null ? 0 : 1,
      'sessionStartup': _sessionStartup == null ? 0 : 1,
    });
  }

  final AppDatabase database;
  final ChatApi api;
  final bool enableRealtime;
  final String realtimeUrl;
  final ServerHealthMonitor Function()? healthMonitorFactory;
  ServerHealthMonitor? _serverHealth;
  OutboxSendQueue? _outbox;

  /// Waits for the current drain, without waiting for a future recovery timer.
  Future<void> get outboxIdle => _outbox?.idle ?? Future<void>.value();
  final _uuid = const Uuid();
  UserProfile? currentUser;
  List<UserProfile> debugUsers = [], users = [];
  String? _directoryCursor;
  bool hasMoreUsers = false;
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
  bool presenceDegraded = false, requiresReauthentication = false;
  bool _refreshPresenceFailed = false;
  Set<String> onlineUserIds = {};
  Set<String> offlineUserIds = {};
  Map<String, DateTime> lastSeenAtByUserId = {};
  bool? userOnlineStatus(String userId) => onlineUserIds.contains(userId)
      ? true
      : offlineUserIds.contains(userId)
      ? false
      : null;
  int sessionGenerationId = 0;
  int _authenticationAttempt = 0;
  Future<void>? _initialization;
  Future<void>? _sessionStartup;
  Future<void>? _inboxRecovery;
  _PresenceSnapshot? _presenceRefresh;
  int _presenceEpoch = 0;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  final Map<String, Future<void>> _roomRecoveries = {};
  final Map<String, Future<void>> _draftAdoptions = {};
  Future<void> _uploadTail = Future<void>.value();
  final Map<String, Future<Map<String, dynamic>>> _directLookups = {};
  Map<String, dynamic>? _sessionInfo;
  bool _remoteStartupComplete = false, _recoveryNeeded = false;
  int? _startupGeneration;
  Future<void>? _debugDiscovery;
  bool _observingLifecycle = false, _debugDirectoryLoaded = false;
  int _navigationRequest = 0, _jumpRequest = 0, _jumpHistoryEditPts = 0;
  String? _jumpTargetId;
  Future<void> _sessionTransition = Future<void>.value();
  int _windowLimit = 50;
  bool _serverHasMoreMessages = false;
  final Map<String, bool> _historyHasMore = {};
  String? _activeRoomId;
  bool _disposed = false, _opening = false, _sessionStopping = false;
  centrifuge.Client? _client;
  InboxSyncService? _sync;
  SharedPreferences? _preferences;
  StreamSubscription<List<ChatRoom>>? _roomsSubscription;
  StreamSubscription<List<ChatMessage>>? _messagesSubscription;
  Completer<List<ChatMessage>?>? _initialMessageWindow;
  bool _hasMoreCachedMessages = false;
  StreamSubscription<InboxRoomEvent>? _roomEventsSubscription;
  final List<StreamSubscription<dynamic>> _socketSubscriptions = [];
  Timer? _presenceTimer, _presenceRefreshTimer, _highlightTimer;
  Timer? _receiptTimer;
  Future<void>? _receiptFlush;
  bool _receiptFlushRequested = false;
  int _receiptRetryAttempt = 0;
  final List<Map<String, Object?>> _events = [];
  Map<String, Object?> _databaseSummary = {};
  bool get hasMoreRooms => _sync?.hasMoreRooms ?? false;
  bool get debugTrafficLoggingEnabled => api.debugTrafficLoggingEnabled;
  bool get demoEnabled =>
      kDebugMode && _debugDirectoryLoaded && debugUsers.isNotEmpty;

  void setDebugTrafficLoggingEnabled(bool enabled) {
    api.setDebugTrafficLoggingEnabled(enabled);
    debugInspector.setSqliteDetailsEnabled(api.debugTrafficLoggingEnabled);
    _notify();
  }

  Map<String, Object?> get _recentTrafficCounts {
    final records = api.recentTrafficRecords;
    final byUser = <String, Map<String, int>>{};
    var http = 0, realtime = 0;
    for (final record in records) {
      final event = record['event'];
      final key = event == 'http_request'
          ? 'httpRequests'
          : 'realtimePublications';
      if (event == 'http_request') {
        http++;
      } else if (event == 'realtime_publication') {
        realtime++;
      } else {
        continue;
      }
      final userId = record['userId'] as String? ?? 'anonymous';
      final counts = byUser.putIfAbsent(
        userId,
        () => {'httpRequests': 0, 'realtimePublications': 0},
      );
      counts[key] = counts[key]! + 1;
    }
    return {
      'retainedRecords': records.length,
      'httpRequests': http,
      'realtimePublications': realtime,
      'byUser': byUser,
    };
  }

  bool get _hasActiveSession =>
      !_disposed && !_sessionStopping && currentUser != null;
  Map<String, Object?> get diagnostics => {
    'database': 'chat_app_db',
    'sessionGeneration': sessionGenerationId,
    'connection': connectionStatus,
    'outbox': {
      'running': _outbox?.isRunning ?? false,
      'paused': _outbox?.isPaused ?? false,
      'queued': _outbox?.queuedCount ?? 0,
      'failed': _outbox?.failedCount ?? 0,
      'needsAttention': _outbox?.pausedCount ?? 0,
      'physicalAttempts': _outbox?.physicalAttemptCount ?? 0,
      'serverHealth': _serverHealth?.status.name ?? 'unknown',
      'nextRetryAt': _outbox?.nextRetryAt?.toUtc().toIso8601String(),
      'reason': _outbox?.lastReason,
    },
    'remoteStartupComplete': _remoteStartupComplete,
    'userId': currentUser?.id,
    'localRoomCount': rooms.length,
    'visibleMessageCount': messages.length,
    'deltaRequests': _sync?.deltaRequests ?? 0,
    'fullSyncs': _sync?.fullSyncs ?? 0,
    'messageRequests': api.messageRequests,
    'recentApiRequests': api.recentApiRequests,
    'debugTrafficLoggingEnabled': debugTrafficLoggingEnabled,
    'recentTrafficCounts': _recentTrafficCounts,
    'recentTrafficRecords': api.recentTrafficRecords,
    'selectedRoom': selectedRoom?.toJson()?..remove('lastMessage'),
    ..._databaseSummary,
    'recentEvents': List<Map<String, Object?>>.unmodifiable(_events),
  };
  void _notify() {
    if (_disposed) return;
    refreshInspectorGauges();
    if (debugInspector.enabled && !debugInspector.paused) {
      final state = <String, Object?>{
        'userId': currentUser?.id,
        'roomId': _activeRoomId,
        'roomCount': rooms.length,
        'messageCount': messages.length,
        'connectionState': connectionStatus,
        'busy': busy,
        'initialized': initialized,
        'isJumpMode': isJumpMode,
        'hasMoreMessages': hasMoreMessages,
        'errorType': error == null ? null : 'present',
        'sessionGeneration': sessionGenerationId,
      };
      final changed = state.keys
          .where((key) => state[key] != _lastObservedState[key])
          .toList();
      _lastObservedState = state;
      final context = debugInspector.captureContext();
      // An authentication action began anonymously. A state notification after
      // session installation must describe the now-installed account.
      lastStateContext =
          context.userId == currentUser?.id &&
              context.sessionGeneration == sessionGenerationId
          ? context
          : debugInspector.captureContext(detached: true);
      debugInspector.record(
        'state',
        'notifyListeners',
        context: lastStateContext,
        data: {
          'notificationId': ++_notificationId,
          'changedFields': changed,
          'roomCount': rooms.length,
          'messageCount': messages.length,
          'busy': busy,
          'connectionState': connectionStatus,
        },
      );
    }
    notifyListeners();
  }

  void _record(String event, [String? detail]) {
    refreshInspectorGauges();
    // Existing free-form details may contain business data; the inspector only
    // retains the fixed operational event name and causal context.
    debugInspector.record('controller', event);
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
    String name,
    Future<T> Function() operation, {
    bool showBusy = true,
    bool Function()? isCurrent,
    DebugTraceContext? traceContext,
  }) async {
    refreshInspectorGauges();
    try {
      return await debugInspector.trace<T?>('action', name, () async {
        final generation = sessionGenerationId;
        bool current() =>
            isCurrent?.call() ?? generation == sessionGenerationId;
        if (!current()) return null;
        if (showBusy) busy = true;
        error = null;
        _notify();
        try {
          return await operation();
        } catch (failure) {
          if (current()) {
            if (failure is ChatApiException &&
                failure.statusCode == 401 &&
                currentUser != null) {
              await _requireReauthentication(generation);
            }
            error = failure.toString();
            debugInspector.record(
              'action',
              'failed',
              data: {
                'operation': name,
                'errorType': failure.runtimeType.toString(),
              },
            );
            _record('operation_failed', failure.runtimeType.toString());
          }
          rethrow;
        } finally {
          if (current()) {
            if (showBusy) busy = false;
            _notify();
          }
        }
      }, context: traceContext);
    } catch (_) {
      // Preserve the controller contract while the span retains the failure.
      return null;
    }
  }

  void Function(T) _observe<T>(void Function(T) callback) => (value) {
    refreshInspectorGauges();
    debugInspector.runIndependent(() => callback(value));
  };

  void _background(Future<void> Function() operation) {
    unawaited(
      _run(
        'background',
        operation,
        showBusy: false,
        traceContext: debugInspector.captureContext(detached: true),
      ),
    );
  }

  Future<void> initialize() {
    if (_sessionStopping || _disposed) return Future<void>.value();
    _discoverDebugUsers();
    if (initialized) return Future<void>.value();
    if (_initialization != null) return _initialization!;
    late final Future<void> initialization;
    initialization = _initialize().whenComplete(() {
      if (identical(_initialization, initialization)) _initialization = null;
    });
    return _initialization = initialization;
  }

  Future<void> _initialize() async {
    final startupAttempt = _authenticationAttempt;
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }
    var startupComplete = initialized;
    bool ownsAttempt() =>
        startupAttempt == _authenticationAttempt && !_disposed;
    bool current() => ownsAttempt() && !_sessionStopping;
    await _run('initialize', () async {
      _preferences = await SharedPreferences.getInstance();
      if (startupComplete ||
          _sessionStopping ||
          _disposed ||
          startupAttempt != _authenticationAttempt) {
        return;
      }
      final saved = _preferences!.getString('chat_session');
      if (saved != null) {
        try {
          final session = jsonMap(jsonDecode(saved));
          int? generation;
          await _transitionSession(() async {
            if (current()) {
              if (currentUser != null && _sync != null) {
                // Required startup may have failed transiently after installing
                // the session. Retry recovery without duplicating observers.
                generation = sessionGenerationId;
              } else {
                generation = await _startSession(session, restoring: true);
              }
            }
          });
          if (generation != null && current()) {
            // SQLite restoration is sufficient for a usable local session.
            // Network recovery must never hold cached navigation behind HTTP.
            unawaited(_recoverSession(session, generation!, restoring: true));
          }
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
      if (ownsAttempt()) startupComplete = true;
    }, isCurrent: ownsAttempt);
    if (ownsAttempt()) {
      initialized = startupComplete;
      _notify();
    }
  }

  void _discoverDebugUsers() {
    if (_debugDirectoryLoaded || _debugDiscovery != null) return;
    // This optional request has its own execution lifetime. In particular it
    // must not keep a failed mandatory initialization deduplicated until its
    // network timeout, preventing the visible recovery action from retrying.
    _debugDiscovery = _loadDebugUsers().whenComplete(() {
      _debugDiscovery = null;
    });
    unawaited(_debugDiscovery);
  }

  Future<void> _loadDebugUsers() async {
    try {
      final value = await api.getUsers('/auth/debug-users');
      if (_disposed) return;
      debugUsers = value;
      _debugDirectoryLoaded = true;
    } catch (failure) {
      if (_disposed) return;
      _debugDirectoryLoaded =
          failure is ChatApiException &&
          (failure.statusCode == 404 || failure.statusCode == 403);
      debugUsers = [];
      if (!_debugDirectoryLoaded) _record('debug_directory_unavailable');
    }
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
    bool current() => !_disposed && attempt == _authenticationAttempt;
    await _run('authenticate', () async {
      Map<String, dynamic> session;
      try {
        session = await api.post(endpoint, body);
      } catch (_) {
        if (_disposed || attempt != _authenticationAttempt) return;
        rethrow;
      }
      if (_disposed || attempt != _authenticationAttempt) return;
      _invalidateSession();
      int? generation;
      await _transitionSession(() async {
        if (_disposed || attempt != _authenticationAttempt) return;
        final sameAccount =
            currentUser?.id ==
            UserProfile.fromJson(jsonMap(session['user'])).id;
        await _stopSession(
          clear: !sameAccount,
          release: !requiresReauthentication,
        );
        if (_disposed || attempt != _authenticationAttempt) return;
        generation = await _startSession(session);
      });
      if (generation != null && current() && !_sessionStopping) {
        await _finishSessionStartup(session, generation!, restoring: false);
      }
    }, isCurrent: current);
  }

  Future<void> _transitionSession(Future<void> Function() work) {
    final next = _sessionTransition.then((_) => work());
    _sessionTransition = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<int?> _startSession(
    Map<String, dynamic> session, {
    bool restoring = false,
  }) async {
    final generation = ++sessionGenerationId;
    _sessionStopping = false;
    requiresReauthentication = false;
    initialized = false;
    _preferences ??= await SharedPreferences.getInstance();
    if (!_isCurrentSession(generation)) return null;
    final sessionUser = UserProfile.fromJson(jsonMap(session['user']));
    currentUser = sessionUser;
    _sessionInfo = session;
    _remoteStartupComplete = false;
    api.setToken(session['accessToken'] as String, userId: currentUser!.id);
    refreshInspectorGauges();
    return debugInspector.runIndependent(() async {
      debugInspector.record('session', 'installed');
      await database.initializeSession(currentUser!.id);
      if (!_isCurrentSession(generation)) return null;
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
          if (_isCurrentSession(generation)) {
            await _preferences!.setString(
              'chat_room_pagination',
              jsonEncode({'userId': currentUser!.id, 'hasMore': value}),
            );
          }
        },
        isCurrentSession: () => _isCurrentSession(generation),
      );
      _roomsSubscription = database
          .watchRooms(userId: sessionUser.id)
          .listen(
            _observe((value) {
              if (generation != sessionGenerationId) return;
              final knownRooms = rooms.map((room) => room.roomId).toSet();
              if (enableRealtime &&
                  _client?.state == centrifuge.State.connected &&
                  value.any(
                    (room) =>
                        !room.roomId.startsWith('draft_') &&
                        !knownRooms.contains(room.roomId),
                  )) {
                _schedulePresenceSnapshot(generation);
              }
              rooms = value;
              _mergeCachedPeers(value);
              if (selectedRoom != null) {
                final matching = rooms.where(
                  (r) => r.roomId == selectedRoom!.roomId,
                );
                if (matching.isNotEmpty) selectedRoom = matching.first;
              }
              final peer = draftPeer;
              if (peer != null && _activeRoomId == 'draft_${peer.id}') {
                final knownReal = value.where(
                  (room) =>
                      room.roomType == 'direct' &&
                      room.peerUserId == peer.id &&
                      !room.roomId.startsWith('draft_'),
                );
                if (knownReal.isNotEmpty) {
                  unawaited(
                    _adoptKnownDraftRoom(
                      knownReal.first,
                      generation,
                      _navigationRequest,
                    ),
                  );
                }
              }
              _notify();
            }),
          );
      _roomEventsSubscription = _sync!.roomEventsStream.listen(
        _observe((event) {
          if (generation != sessionGenerationId) return;
          final payload = event.payload;
          _applyJumpEvent(payload);
          if (!event.runRoomFollowUp || event.roomState == null) return;
          final room = database.roomModel(event.roomState!);
          final navigation = _navigationRequest;
          final selected = _activeRoomId == room.roomId && !_opening;
          final foreground =
              selected && _lifecycleState == AppLifecycleState.resumed;
          // Capture before any follow-up await: later queued publications must
          // not enlarge the boundary this foreground event made visible.
          final seenBoundary =
              event.acknowledge &&
                  foreground &&
                  (event.hasIncoming || room.unreadCount > 0)
              ? (
                  sequence: room.lastMessage?.messageSeq,
                  timestamp: room.lastMessage?.createdAt ?? room.sortTimestamp,
                )
              : null;
          _background(() async {
            if (event.acknowledge) {
              await _queueRoomEventReceipts(
                event,
                generation,
                navigation,
                markSeen: seenBoundary != null,
              );
            }
            if (_isCurrentView(generation, navigation) &&
                selected &&
                _activeRoomId == room.roomId &&
                !_opening) {
              if (event.needsMessageRecovery) {
                await _recoverRoom(
                  room.roomId,
                  generation,
                  syncInbox: false,
                  acknowledge: false,
                );
              } else if (isJumpMode &&
                  room.lastHistoryEditPts > _jumpHistoryEditPts) {
                await _refreshHistoricalJump();
              }
              if (event.needsMessageRecovery &&
                  seenBoundary != null &&
                  _isCurrentView(generation, navigation) &&
                  _activeRoomId == room.roomId &&
                  _lifecycleState == AppLifecycleState.resumed) {
                unawaited(
                  _markSeen(
                    maximumSequence: seenBoundary.sequence,
                    maximumTimestamp: seenBoundary.timestamp,
                    expectedNavigation: navigation,
                  ),
                );
              }
            }
          });
        }),
      );
      if (!restoring) {
        _preferences ??= await SharedPreferences.getInstance();
        await _preferences!.setString('chat_session', jsonEncode(session));
      }
      if (!_isCurrentSession(generation)) return null;
      rooms = await database.watchRooms(userId: sessionUser.id).first;
      if (!_isCurrentSession(generation)) return null;
      _mergeCachedPeers(rooms);
      initialized = true;
      busy = false;
      _installOutbox(generation);
      _startPresenceTimer();
      _notify();
      return _isCurrentSession(generation) ? generation : null;
    });
  }

  void _mergeCachedPeers(List<ChatRoom> cachedRooms) {
    final known = {for (final user in users) user.id: user};
    for (final room in cachedRooms) {
      final peerId = room.peerUserId;
      if (room.roomType == 'direct' &&
          peerId != null &&
          peerId != currentUser?.id) {
        known.putIfAbsent(
          peerId,
          () => UserProfile(
            id: peerId,
            username: peerId,
            displayName: room.displayTitle,
            avatarUrl: room.displayAvatarUrl,
          ),
        );
      }
    }
    users = known.values.toList();
  }

  void _installOutbox(int generation) {
    final senderId = currentUser!.id;
    final health = _serverHealth =
        healthMonitorFactory?.call() ??
        ServerHealthMonitor(
          healthUri: Uri.parse(
            api.dio.options.baseUrl.isEmpty
                ? apiBaseUrl
                : api.dio.options.baseUrl,
          ).resolve('/health'),
          inspector: debugInspector,
        );
    var wasReady = false;
    var hadOutage = false;
    health.addListener(() {
      if (!_isCurrentMessageSession(generation, senderId)) return;
      final ready = health.status.name == 'ready';
      if (health.status == ServerHealthStatus.unavailable) hadOutage = true;
      final recovered = ready && !wasReady;
      wasReady = ready;
      if (recovered && !requiresReauthentication) {
        // The first successful send is also the health monitor's first proof
        // of readiness. A completed healthy startup already reconciled inbox;
        // only an outage or unfinished startup needs another recovery.
        if (hadOutage || _recoveryNeeded || !_remoteStartupComplete) {
          _background(syncNow);
        }
        hadOutage = false;
      }
      _notify();
    });
    _outbox = OutboxSendQueue(
      database: database,
      api: api,
      senderId: senderId,
      send: (message) => _submitMessage(message, generation: generation),
      healthMonitor: health,
      isCurrentSession: () =>
          _isCurrentMessageSession(generation, senderId) &&
          !requiresReauthentication,
      onAuthenticationRequired: () {
        unawaited(_requireReauthentication(generation));
      },
      inspector: debugInspector,
      onStateChanged: () {
        if (_isCurrentMessageSession(generation, senderId)) _notify();
      },
    );
    if (_presenceActive) {
      _outbox!.wake();
    } else {
      _outbox!.pause();
    }
  }

  Future<void> _synchronizeInbox(int generation) {
    if (!_isCurrentSession(generation)) return Future<void>.value();
    if (_inboxRecovery != null) return _inboxRecovery!;
    final sync = _sync;
    if (sync == null) return Future<void>.value();
    late final Future<void> recovery;
    recovery = sync.syncInboxDelta().whenComplete(() {
      if (identical(_inboxRecovery, recovery)) _inboxRecovery = null;
    });
    return _inboxRecovery = recovery;
  }

  Future<void> _requireReauthentication(int generation) async {
    if (!_isCurrentSession(generation) || requiresReauthentication) return;
    requiresReauthentication = true;
    _outbox?.pause();
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _cancelPresenceRefresh();
    await _client?.disconnect();
    if (!_isCurrentSession(generation) || !requiresReauthentication) return;
    connectionStatus = 'Sign in required';
    _notify();
  }

  Future<void> _recoverSession(
    Map<String, dynamic> session,
    int generation, {
    required bool restoring,
  }) async {
    if (!_isCurrentSession(generation) ||
        _sessionStartup != null ||
        requiresReauthentication) {
      return;
    }
    try {
      await _finishSessionStartup(session, generation, restoring: restoring);
      if (!_isCurrentSession(generation)) return;
      final roomId = _activeRoomId;
      if (roomId != null && !roomId.startsWith('draft_')) {
        await _recoverRoom(roomId, generation, syncInbox: false);
      } else if (draftPeer != null) {
        await _recoverDirect(draftPeer!, generation, _navigationRequest);
      }
    } catch (failure) {
      if (!_isCurrentSession(generation)) return;
      if (failure is ChatApiException && failure.statusCode == 401) {
        await _requireReauthentication(generation);
        return;
      }
      _recoveryNeeded = true;
      connectionStatus = 'Offline';
      _record('session_recovery_unavailable');
      _notify();
    }
  }

  Future<void> _finishSessionStartup(
    Map<String, dynamic> session,
    int generation, {
    required bool restoring,
  }) {
    if (!_isCurrentSession(generation)) return Future<void>.value();
    if (_startupGeneration == generation && _sessionStartup != null) {
      return _sessionStartup!;
    }
    _startupGeneration = generation;
    late final Future<void> startup;
    startup = debugInspector
        .runIndependent(
          () => _completeSessionStartup(
            session,
            generation,
            restoring: restoring,
          ),
        )
        .catchError((Object failure) async {
          if (_isCurrentSession(generation)) {
            if (failure is ChatApiException && failure.statusCode == 401) {
              await _requireReauthentication(generation);
            } else {
              _recoveryNeeded = true;
              connectionStatus = 'Offline';
              _notify();
            }
          }
          throw failure;
        })
        .whenComplete(() {
          if (identical(_sessionStartup, startup)) _sessionStartup = null;
        });
    return _sessionStartup = startup;
  }

  Future<void> _completeSessionStartup(
    Map<String, dynamic> session,
    int generation, {
    required bool restoring,
  }) async {
    final sync = _sync;
    if (sync == null ||
        !_isCurrentSession(generation) ||
        requiresReauthentication) {
      return;
    }
    _recoveryNeeded = false;
    await _synchronizeInbox(generation);
    if (!_isCurrentSession(generation) || requiresReauthentication) return;
    await _refreshUsers();
    if (!_isCurrentSession(generation) || requiresReauthentication) return;
    final cachedRooms = await database.watchRooms(userId: sync.userId).first;
    if (!_isCurrentSession(generation) || requiresReauthentication) return;
    await _deliverRooms(cachedRooms);
    if (!_isCurrentSession(generation) || requiresReauthentication) return;
    final presence = _startPresenceSnapshot();
    await presence.completion;
    if (!_isCurrentSession(generation) || requiresReauthentication) return;
    if (enableRealtime && _client == null) {
      await _connectRealtime(generation, initialPresence: presence);
    }
    if (!_isCurrentSession(generation) || requiresReauthentication) return;
    _remoteStartupComplete = true;
    if (!_recoveryNeeded) {
      connectionStatus =
          !enableRealtime || _client?.state == centrifuge.State.connected
          ? 'Connected'
          : _client?.state == centrifuge.State.connecting
          ? 'Connecting'
          : 'Disconnected';
    }
    _record('session_started', restoring ? 'restored' : 'authenticated');
  }

  Future<void> logout() {
    final attempt = ++_authenticationAttempt;
    _invalidateSession();
    return _run(
      'logout',
      () => _transitionSession(() => _stopSession(clear: true)),
      isCurrent: () => !_disposed && attempt == _authenticationAttempt,
    );
  }

  bool _isCurrentSession(int generation) =>
      !_disposed && !_sessionStopping && generation == sessionGenerationId;

  bool get _presenceActive =>
      _lifecycleState != AppLifecycleState.hidden &&
      _lifecycleState != AppLifecycleState.paused &&
      _lifecycleState != AppLifecycleState.detached;

  void _startPresenceTimer() {
    if (!_hasActiveSession || !_presenceActive || _presenceTimer != null) {
      return;
    }
    final generation = sessionGenerationId;
    _presenceTimer = Timer.periodic(
      // Refresh authorized peer snapshots; Centrifugo owns our online status.
      Duration(
        seconds: const int.fromEnvironment(
          'PRESENCE_REFRESH_SECONDS',
          defaultValue: 30,
        ).clamp(1, 3600),
      ),
      _observe((_) {
        if (!_isCurrentSession(generation) || !_presenceActive) return;
        final session = _sessionInfo;
        if ((!_remoteStartupComplete || _recoveryNeeded) && session != null) {
          unawaited(_recoverSession(session, generation, restoring: true));
        } else if (_presenceRefresh == null) {
          _refreshPresenceInBackground();
        }
      }),
    );
  }

  void _cancelPresenceRefresh() {
    ++_presenceEpoch;
    _presenceRefresh = null;
    api.cancelPresenceRequests();
  }

  void _invalidateSession() {
    if (_sessionStopping) return;
    _sessionStopping = true;
    _outbox?.dispose();
    _outbox = null;
    _serverHealth = null;
    ++sessionGenerationId;
    ++_navigationRequest;
    final window = _initialMessageWindow;
    if (window != null && !window.isCompleted) window.complete(null);
    ++_jumpRequest;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _cancelPresenceRefresh();
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = null;
    _receiptTimer?.cancel();
    _receiptTimer = null;
    _receiptFlush = null;
    _receiptFlushRequested = false;
    _receiptRetryAttempt = 0;
    _highlightTimer?.cancel();
    _initialization = null;
    _sessionStartup = null;
    _inboxRecovery = null;
    _roomRecoveries.clear();
    _draftAdoptions.clear();
    _directLookups.clear();
    _uploadTail = Future<void>.value();
    _remoteStartupComplete = false;
    _recoveryNeeded = false;
    _sessionInfo = null;
    _startupGeneration = null;
    _sync?.queue.invalidate();
  }

  Future<void> _stopSession({required bool clear, bool release = true}) async {
    _invalidateSession();
    if (release && currentUser != null && api.hasSessionToken) {
      // Release only the outgoing authentication session before replacing its
      // credentials. A server outage must not trap the user in this session.
      try {
        await api.post('/presence/offline').timeout(const Duration(seconds: 3));
      } catch (_) {
        _record('presence_offline_unavailable');
      }
    }
    await _client?.disconnect();
    await _client?.close();
    _client = null;
    for (final subscription in _socketSubscriptions) {
      await subscription.cancel();
    }
    _socketSubscriptions.clear();
    await _roomEventsSubscription?.cancel();
    _roomEventsSubscription = null;
    await _sync?.retire();
    _sync = null;
    await _roomsSubscription?.cancel();
    _roomsSubscription = null;
    await _cancelMessageWatch();
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
    _directoryCursor = null;
    hasMoreUsers = false;
    presenceDegraded = false;
    onlineUserIds = {};
    offlineUserIds = {};
    lastSeenAtByUserId = {};
    selectedRoom = null;
    draftPeer = null;
    _activeRoomId = null;
    isJumpMode = false;
    _jumpTargetId = null;
    _historyHasMore.clear();
    _databaseSummary = {};
    _events.clear();
    connectionStatus = 'Disconnected';
    _notify();
  }

  Future<void> _connectRealtime(
    int generation, {
    _PresenceSnapshot? initialPresence,
  }) async {
    final client = createLoggedRealtimeClient(
      realtimeUrl,
      centrifuge.ClientConfig(
        // JWTs travel as connection data so the OSS connect proxy can enforce
        // revocation on every reconnect. Centrifugo uses the login's expiry;
        // NestJS disconnects retired sessions with persistent retries.
        getData: () async {
          if (!_isCurrentSession(generation) || requiresReauthentication) {
            throw const ChatApiException('Session ended.');
          }
          final result = await api.post('/auth/centrifugo-token');
          if (!_isCurrentSession(generation) || requiresReauthentication) {
            throw const ChatApiException('Session ended.');
          }
          return utf8.encode(jsonEncode({'token': result['centrifugoToken']}));
        },
      ),
      inspector: debugInspector,
      trafficLogger: api.trafficLogger,
      isCurrentSession: () =>
          _isCurrentSession(generation) && !requiresReauthentication,
      context: () => debugInspector.captureContext(detached: true),
    );
    _client = client;
    final inboxChannel = 'inbox:user#${currentUser!.id}';
    _socketSubscriptions.addAll([
      client.connecting.listen(
        _observe((_) {
          if (generation == sessionGenerationId) {
            connectionStatus = 'Connecting';
            _notify();
          }
        }),
      ),
      client.connected.listen(
        _observe((_) {
          if (generation == sessionGenerationId) {
            connectionStatus = 'Connected';
            _record('socket_connected');
            _notify();
          }
        }),
      ),
      client.disconnected.listen(
        _observe((_) {
          if (generation == sessionGenerationId) {
            connectionStatus = 'Disconnected';
            _record('socket_disconnected');
            _notify();
          }
        }),
      ),
      client.error.listen(
        _observe((_) {
          if (generation == sessionGenerationId) {
            _record('socket_error');
            _notify();
          }
        }),
      ),
      client.subscribed.listen(
        _observe((event) {
          if (generation == sessionGenerationId &&
              event.channel == inboxChannel) {
            _record('inbox_subscribed');
            // Only the first subscription can reuse this startup's snapshot.
            // A reconnect always refreshes presence after reconciling inbox.
            final presence = initialPresence;
            initialPresence = null;
            _background(() => _runSyncNow(presence: presence));
          }
        }),
      ),
      client.publication.listen(
        _observe((event) {
          if (generation != sessionGenerationId ||
              event.channel != inboxChannel) {
            return;
          }
          final receivingUserId = currentUser?.id;
          if (receivingUserId == null) return;
          _background(() async {
            final payload = jsonMap(jsonDecode(utf8.decode(event.data)));
            api.trafficLogger.recordRealtimePublication(
              payload,
              channel: 'inbox:user#$receivingUserId',
              userId: receivingUserId,
            );
            if (payload['type'] == 'presence_changed') {
              // Notifications invalidate a snapshot. Reordered or duplicate
              // hints cannot overwrite newer user-level presence.
              _schedulePresenceSnapshot(generation);
              return;
            }
            final room = jsonMap(
              payload['receipt'] ?? payload['unread'] ?? payload['room'],
            );
            final context = debugInspector.captureContext().copyWithRoom(
              room['roomId'] as String?,
            );
            await debugInspector.trace(
              'realtime',
              'inbox.publication',
              () async {
                _record('publication', 'pts=${payload['pts']}');
                await _sync?.receivePublication(payload);
              },
              data: {'eventType': room['eventType'], 'pts': payload['pts']},
              context: context,
            );
          });
        }),
      ),
    ]);
    if (!_isCurrentSession(generation)) return;
    try {
      await client.connect();
    } finally {
      // A failed first attempt can schedule a later reconnect without emitting
      // subscribed. That reconnect must not reuse the earlier startup status.
      initialPresence = null;
    }
  }

  Future<void> refreshUsers() async {
    if (!_hasActiveSession) return;
    await _run('refreshUsers', _refreshUsers, showBusy: false);
  }

  Future<void> _refreshUsers() async {
    if (requiresReauthentication) return;
    final generation = sessionGenerationId;
    final page = await api.directoryPage();
    if (generation == sessionGenerationId) {
      _directoryCursor = page.nextCursor;
      hasMoreUsers = page.nextCursor != null;
      users = page.users.where((u) => u.id != currentUser?.id).toList();
      _mergeCachedPeers(rooms);
      _notify();
    }
  }

  Future<void> loadMoreUsers() => _run('loadMoreUsers', () async {
    final generation = sessionGenerationId;
    if (!hasMoreUsers) return;
    final page = await api.directoryPage(cursor: _directoryCursor);
    if (!_isCurrentSession(generation)) return;
    final merged = {for (final user in users) user.id: user};
    for (final user in page.users) {
      if (user.id != currentUser?.id) merged[user.id] = user;
    }
    users = merged.values.toList();
    _directoryCursor = page.nextCursor;
    hasMoreUsers = page.nextCursor != null;
    _notify();
  }, showBusy: false);

  void _schedulePresenceSnapshot(int generation) {
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = Timer(const Duration(milliseconds: 200), () {
      if (_isCurrentSession(generation)) {
        _refreshPresenceInBackground();
      }
    });
  }

  void _refreshPresenceInBackground() {
    // Poll completion only notifies when the snapshot or degradation changes.
    // The general action wrapper announces start/end even without a state change.
    unawaited(
      debugInspector
          .trace<void>(
            'action',
            'presenceSnapshot',
            _refreshPresence,
            context: debugInspector.captureContext(detached: true),
          )
          .catchError((Object failure, StackTrace _) {
            _record('presence_refresh_failed', failure.runtimeType.toString());
          }),
    );
  }

  Set<String> _presencePeers() => rooms
      .where(
        (room) =>
            room.roomType == 'direct' &&
            room.deletedAt == null &&
            !room.roomId.startsWith('draft_'),
      )
      .map((room) => room.peerUserId)
      .whereType<String>()
      .where((id) => id.isNotEmpty && id != currentUser?.id)
      .toSet();

  _PresenceSnapshot _startPresenceSnapshot() {
    final completion = _refreshPresence();
    return _presenceRefresh ??
        (
          peers: _presencePeers(),
          epoch: _presenceEpoch,
          completion: completion,
        );
  }

  Future<void> _refreshPresenceAfter(_PresenceSnapshot? snapshot) async {
    if (snapshot != null) {
      await snapshot.completion;
      // A hide/account change retires this operation; its successor owns the
      // next snapshot. New peers discovered by inbox sync still need a refresh.
      if (snapshot.epoch != _presenceEpoch ||
          setEquals(snapshot.peers, _presencePeers())) {
        return;
      }
    }
    await _refreshPresence();
  }

  Future<void> _refreshPresence() {
    if (!_hasActiveSession || !_presenceActive || requiresReauthentication) {
      return Future<void>.value();
    }
    final existing = _presenceRefresh;
    if (existing != null) return existing.completion;
    final generation = sessionGenerationId;
    final epoch = _presenceEpoch;
    final peers = _presencePeers();
    late final Future<void> refresh;
    refresh = _completePresenceRefresh(generation, epoch, peers).whenComplete(
      () {
        if (identical(_presenceRefresh?.completion, refresh)) {
          _presenceRefresh = null;
        }
      },
    );
    _presenceRefresh = (peers: peers, epoch: epoch, completion: refresh);
    return refresh;
  }

  bool _isCurrentPresence(int generation, int epoch) =>
      _isCurrentSession(generation) &&
      epoch == _presenceEpoch &&
      _presenceActive;

  Future<void> _completePresenceRefresh(
    int generation,
    int epoch,
    Set<String> peers,
  ) async {
    if (!_isCurrentPresence(generation, epoch)) return;
    final ids = peers.toList();
    final online = <String>{};
    final offline = <String>{};
    final lastSeen = <String, DateTime>{};
    _refreshPresenceFailed = false;
    for (var start = 0; start < ids.length; start += 100) {
      final chunk = ids.skip(start).take(100).toList();
      try {
        final value = await api.getMap(
          '/presence/status',
          query: {'userIds': chunk.join(',')},
        );
        if (!_isCurrentPresence(generation, epoch)) return;
        final statuses = jsonMap(value['statuses']);
        final timestamps = value['lastSeenAt'];
        for (final id in chunk) {
          if (statuses[id] == true) {
            online.add(id);
          } else if (statuses[id] == false) {
            offline.add(id);
            final timestamp = timestamps is Map ? timestamps[id] : null;
            final parsed = timestamp is String
                ? DateTime.tryParse(timestamp)
                : null;
            if (parsed != null) lastSeen[id] = parsed.toUtc();
          }
        }
      } catch (_) {
        if (!_isCurrentPresence(generation, epoch)) return;
        _refreshPresenceFailed = true;
        _record('presence_status_unavailable');
        online.addAll(chunk.where(onlineUserIds.contains));
        offline.addAll(chunk.where(offlineUserIds.contains));
        for (final id in chunk) {
          final previous = lastSeenAtByUserId[id];
          if (previous != null) lastSeen[id] = previous;
        }
      }
    }
    if (!_isCurrentPresence(generation, epoch)) return;
    final changed =
        !setEquals(onlineUserIds, online) ||
        !setEquals(offlineUserIds, offline) ||
        !mapEquals(lastSeenAtByUserId, lastSeen) ||
        presenceDegraded != _refreshPresenceFailed;
    onlineUserIds = online;
    offlineUserIds = offline;
    lastSeenAtByUserId = lastSeen;
    presenceDegraded = _refreshPresenceFailed;
    if (changed) _notify();
  }

  Future<void> syncNow() => _runSyncNow();

  Future<void> _runSyncNow({
    _PresenceSnapshot? presence,
    bool wakeOutbox = true,
  }) async {
    if (_sessionStopping || _disposed) return;
    if (wakeOutbox && !requiresReauthentication) _outbox?.wake();
    if (!initialized) {
      // This is also the visible recovery action after a transient cold-start
      // failure. Finish users/presence/realtime setup, not just the inbox delta.
      await initialize();
      if (!initialized || _sessionStopping || _disposed) return;
    }
    await _run('syncNow', () => _syncNow(presence: presence), showBusy: false);
  }

  Future<void> _syncNow({_PresenceSnapshot? presence}) async {
    if (requiresReauthentication) return;
    final generation = sessionGenerationId;
    final session = _sessionInfo;
    if ((!_remoteStartupComplete || _recoveryNeeded) && session != null) {
      await _finishSessionStartup(session, generation, restoring: true);
      if (!_isCurrentSession(generation)) return;
    }
    await _synchronizeInbox(generation);
    if (!_isCurrentSession(generation)) return;
    _scheduleReceiptFlush(generation);
    final roomId = _activeRoomId;
    if (roomId != null && !roomId.startsWith('draft_')) {
      await _recoverRoom(roomId, generation, syncInbox: false);
    } else if (draftPeer != null) {
      await _recoverDirect(draftPeer!, generation, _navigationRequest);
    }
    if (!_isCurrentSession(generation)) return;
    await _refreshPresenceAfter(presence);
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    debugInspector.record('lifecycle', state.name);
    if (!_presenceActive) {
      _outbox?.pause();
      _presenceTimer?.cancel();
      _presenceTimer = null;
      _cancelPresenceRefresh();
    } else if (state == AppLifecycleState.resumed && _hasActiveSession) {
      if (!requiresReauthentication) _outbox?.resume();
      _startPresenceTimer();
      _background(() async {
        // Refresh peers without waiting behind inbox network recovery.
        final presence = _startPresenceSnapshot();
        // resume() above already requested a fresh outbox read.
        await _runSyncNow(presence: presence, wakeOutbox: false);
      });
    }
  }

  Future<void> loadMoreRooms() async {
    if (!_hasActiveSession) return;
    await _run('loadMoreRooms', () async {
      await _sync?.loadMoreRooms();
    });
  }

  Future<void> openDirect(UserProfile peer) async {
    if (!_hasActiveSession) return;
    final generation = sessionGenerationId;
    final navigation = ++_navigationRequest;
    await _run(
      'openDirect',
      () async {
        final cached =
            await (database.select(database.localRooms)..where(
                  (room) =>
                      room.roomType.equals('direct') &
                      room.peerUserId.equals(peer.id),
                ))
                .get();
        if (!_isCurrentView(generation, navigation)) return;
        final real = cached.where((room) => !room.roomId.startsWith('draft_'));
        if (real.isNotEmpty) {
          await database.transaction(() async {
            if (!_isCurrentView(generation, navigation)) return;
            await database.remapDraft('draft_${peer.id}', real.first.roomId);
          });
          if (!_isCurrentView(generation, navigation)) return;
          await _openRoom(
            database.roomModel(real.first),
            generation: generation,
            navigation: navigation,
          );
          return;
        }
        if (!await _resetMessageView(generation, navigation)) return;
        draftPeer = peer;
        _activeRoomId = 'draft_${peer.id}';
        await _showCachedMessages(generation, navigation);
        if (!_isCurrentView(generation, navigation)) return;
        // A remote lookup can discover old server history, but opening a known
        // peer's local draft (including failed sends) never waits for that lookup.
        unawaited(_recoverDirect(peer, generation, navigation));
      },
      traceContext: debugInspector.captureContext().copyWithRoom(
        'draft_${peer.id}',
      ),
    );
  }

  Future<void> _recoverDirect(
    UserProfile peer,
    int generation,
    int navigation,
  ) async {
    final sync = _sync;
    try {
      if (!_isCurrentView(generation, navigation)) return;
      final cached =
          await (database.select(database.localRooms)..where(
                (room) =>
                    room.roomType.equals('direct') &
                    room.peerUserId.equals(peer.id),
              ))
              .get();
      if (!_isCurrentView(generation, navigation)) return;
      final knownReal = cached.where(
        (room) => !room.roomId.startsWith('draft_'),
      );
      if (knownReal.isNotEmpty) {
        final room = database.roomModel(knownReal.first);
        await database.transaction(() async {
          if (!_isCurrentView(generation, navigation)) return;
          await database.remapDraft('draft_${peer.id}', room.roomId);
        });
        if (!_isCurrentView(generation, navigation)) return;
        if (_activeRoomId == 'draft_${peer.id}') {
          await _openRoom(room, generation: generation, navigation: navigation);
        }
        return;
      }
      if (requiresReauthentication) return;
      var lookup = _directLookups[peer.id];
      if (lookup == null) {
        late final Future<Map<String, dynamic>> pending;
        pending = api.getMap('/rooms/direct-peer/${peer.id}').whenComplete(() {
          if (identical(_directLookups[peer.id], pending)) {
            _directLookups.remove(peer.id);
          }
        });
        _directLookups[peer.id] = lookup = pending;
      }
      final result = await lookup;
      if (!_isCurrentView(generation, navigation) || result['room'] == null) {
        return;
      }
      final room = ChatRoom.fromJson(jsonMap(result['room']));
      await database.transaction(() async {
        if (!_isCurrentView(generation, navigation)) return;
        await sync?.reconcileMutation({'room': result['room']});
        if (!_isCurrentView(generation, navigation)) return;
        await database.remapDraft('draft_${peer.id}', room.roomId);
      });
      if (!_isCurrentView(generation, navigation)) return;
      if (_activeRoomId == 'draft_${peer.id}') {
        await _openRoom(room, generation: generation, navigation: navigation);
      }
    } catch (_) {
      if (!_isCurrentView(generation, navigation)) return;
      _recoveryNeeded = true;
      connectionStatus = 'Offline';
      _record('direct_lookup_unavailable');
      _notify();
    }
  }

  Future<void> openRoom(ChatRoom room) async {
    if (!_hasActiveSession) return;
    final generation = sessionGenerationId;
    final navigation = ++_navigationRequest;
    await _run(
      'openRoom',
      () => _openRoom(room, generation: generation, navigation: navigation),
      traceContext: debugInspector.captureContext().copyWithRoom(room.roomId),
    );
  }

  bool _isCurrentView(int generation, int navigation) =>
      !_disposed &&
      !_sessionStopping &&
      currentUser != null &&
      generation == sessionGenerationId &&
      navigation == _navigationRequest;

  Future<void> _openRoom(
    ChatRoom room, {
    required int generation,
    required int navigation,
  }) async {
    if (!_isCurrentView(generation, navigation)) return;
    if (!await _resetMessageView(generation, navigation)) return;
    _activeRoomId = room.roomId;
    if (room.roomId.startsWith('draft_')) {
      final peerId = room.peerUserId ?? room.roomId.substring(6);
      draftPeer = UserProfile(
        id: peerId,
        username: peerId,
        displayName: room.displayTitle,
        avatarUrl: room.displayAvatarUrl,
      );
    } else {
      selectedRoom = await database.room(room.roomId) ?? room;
      if (!_isCurrentView(generation, navigation)) return;
      _sync?.openRoomId = room.roomId;
    }
    await _showCachedMessages(generation, navigation);
    if (!_isCurrentView(generation, navigation)) return;
    if (room.roomId.startsWith('draft_')) {
      unawaited(_recoverDirect(draftPeer!, generation, navigation));
    } else {
      unawaited(_recoverRoom(room.roomId, generation));
    }
  }

  Future<void> _showCachedMessages(int generation, int navigation) async {
    if (!_isCurrentView(generation, navigation) || _activeRoomId == null) {
      return;
    }
    // Keep the subscription which supplies the initial cache snapshot, so there
    // is no second SELECT or gap between displaying rows and observing writes.
    await _watchMessages();
  }

  Future<void> _adoptKnownDraftRoom(
    ChatRoom room,
    int generation,
    int navigation,
  ) {
    final draftId = 'draft_${room.peerUserId}';
    final key = '$generation:$navigation:$draftId';
    if (!_isCurrentView(generation, navigation) || _activeRoomId != draftId) {
      return Future<void>.value();
    }
    if (_draftAdoptions[key] != null) return _draftAdoptions[key]!;
    late final Future<void> adoption;
    adoption =
        (() async {
          try {
            await database.transaction(() async {
              if (!_isCurrentView(generation, navigation) ||
                  _activeRoomId != draftId) {
                return;
              }
              await database.remapDraft(draftId, room.roomId);
            });
            if (!_isCurrentView(generation, navigation) ||
                _activeRoomId != draftId) {
              return;
            }
            selectedRoom = room;
            draftPeer = null;
            _activeRoomId = room.roomId;
            _sync?.openRoomId = room.roomId;
            await _showCachedMessages(generation, navigation);
          } catch (failure) {
            if (!_isCurrentView(generation, navigation)) return;
            error = failure.toString();
            _record('local_draft_remap_failed');
            _notify();
          }
        })().whenComplete(() {
          if (identical(_draftAdoptions[key], adoption)) {
            _draftAdoptions.remove(key);
          }
        });
    return _draftAdoptions[key] = adoption;
  }

  Future<void> _recoverRoom(
    String roomId,
    int generation, {
    bool syncInbox = true,
    bool acknowledge = true,
  }) {
    if (!_isCurrentSession(generation) ||
        requiresReauthentication ||
        roomId.startsWith('draft_')) {
      return Future<void>.value();
    }
    final existing = _roomRecoveries[roomId];
    if (existing != null) return existing;
    late final Future<void> recovery;
    recovery =
        (() async {
          try {
            if (syncInbox) await _synchronizeInbox(generation);
            if (!_isCurrentSession(generation) || _activeRoomId != roomId) {
              return;
            }
            await _loadLatestMessages();
            if (!_isCurrentSession(generation) || _activeRoomId != roomId) {
              return;
            }
            await _refreshHistoricalJump();
            if (!_isCurrentSession(generation) || _activeRoomId != roomId) {
              return;
            }
            if (acknowledge) unawaited(_markSeen());
          } catch (failure) {
            if (failure is ChatApiException && failure.statusCode == 401) {
              await _requireReauthentication(generation);
              return;
            }
            if (!_isCurrentSession(generation) || _activeRoomId != roomId) {
              return;
            }
            _recoveryNeeded = true;
            connectionStatus = 'Offline';
            _record('room_recovery_unavailable');
            _notify();
          }
        })().whenComplete(() {
          if (identical(_roomRecoveries[roomId], recovery)) {
            _roomRecoveries.remove(roomId);
          }
        });
    return _roomRecoveries[roomId] = recovery;
  }

  Future<bool> _resetMessageView(int generation, int navigation) async {
    await _cancelMessageWatch();
    if (!_isCurrentView(generation, navigation)) return false;
    _sync?.openRoomId = null;
    selectedRoom = null;
    draftPeer = null;
    _activeRoomId = null;
    messages = [];
    isJumpMode = false;
    _jumpTargetId = null;
    ++_jumpRequest;
    _jumpHistoryEditPts = 0;
    highlightMessageId = null;
    _windowLimit = 50;
    hasMoreMessages = false;
    _serverHasMoreMessages = false;
    _hasMoreCachedMessages = false;
    _opening = false;
    return true;
  }

  Future<void> closeRoom() async {
    await _resetMessageView(sessionGenerationId, ++_navigationRequest);
    _notify();
  }

  Future<void> _cancelMessageWatch() async {
    final subscription = _messagesSubscription;
    _messagesSubscription = null;
    final first = _initialMessageWindow;
    _initialMessageWindow = null;
    if (first != null && !first.isCompleted) first.complete(null);
    await subscription?.cancel();
  }

  Future<List<ChatMessage>?> _watchMessages() {
    unawaited(_cancelMessageWatch());
    if (_activeRoomId == null || isJumpMode) return Future.value(null);
    final generation = sessionGenerationId;
    final navigation = _navigationRequest;
    final roomId = _activeRoomId!;
    final first = Completer<List<ChatMessage>?>();
    _initialMessageWindow = first;
    _hasMoreCachedMessages = false;
    bool current() =>
        _isCurrentView(generation, navigation) &&
        roomId == _activeRoomId &&
        !isJumpMode &&
        identical(_initialMessageWindow, first);
    _messagesSubscription = database
        .watchMessages(roomId, _windowLimit + 1)
        .listen(
          _observe((value) {
            if (current()) {
              if (!first.isCompleted) {
                _serverHasMoreMessages =
                    !roomId.startsWith('draft_') &&
                    (_historyHasMore[roomId] ??
                        value.where((m) => m.status == 'sent').length >= 30);
                first.complete(value);
              }
              _hasMoreCachedMessages = value.length > _windowLimit;
              messages = value.take(_windowLimit).toList();
              hasMoreMessages =
                  _hasMoreCachedMessages || _serverHasMoreMessages;
              _notify();
            }
          }),
          onError: (Object failure, StackTrace stack) {
            if (!current()) return;
            if (!first.isCompleted) first.complete(null);
            _recoveryNeeded = true;
            connectionStatus = 'Offline';
            _record('message_watch_unavailable');
            _notify();
          },
          onDone: () {
            if (!first.isCompleted) first.complete(null);
          },
        );
    return first.future;
  }

  Future<void> _loadLatestMessages() async {
    if (!_hasActiveSession) return;
    final sync = _sync;
    final roomId = _activeRoomId;
    final generation = sessionGenerationId;
    if (sync == null || roomId == null || roomId.startsWith('draft_')) return;
    await sync.queue.enqueue(() async {
      final room = await database.room(roomId);
      if (room == null || generation != sessionGenerationId) return;
      if (generation != sessionGenerationId) return;
      if (room.msgPts == room.messagesSyncedPts) {
        final cached = await database.messageWindow(roomId, _windowLimit + 1);
        if (!_isCurrentSession(generation)) return;
        if (cached.isNotEmpty) {
          final hasMore =
              _historyHasMore[roomId] ??
              await database.messageCount(roomId, sentOnly: true) >= 30;
          if (!_isCurrentSession(generation)) return;
          if (_activeRoomId == roomId) {
            _serverHasMoreMessages = hasMore;
            hasMoreMessages = cached.length > _windowLimit || hasMore;
          }
          return;
        }
      }
      final response = await api.latestMessages(roomId);
      if (generation != sessionGenerationId) return;
      final fresh = (response['messages'] as List)
          .map((m) => ChatMessage.fromJson(jsonMap(m)))
          .toList();
      final preservedHistory = await database.transaction(() async {
        if (!_isCurrentSession(generation)) return false;
        return database.reconcileLatest(
          roomId,
          fresh,
          room.msgPts,
          room.lastHistoryEditPts,
          room.messagesSyncedPts,
          receipts: response['receipts'] == null
              ? null
              : ReceiptWatermarks.fromJson(jsonMap(response['receipts'])),
          myUserId: currentUser?.id,
          requireReceiptSummary: room.roomType == 'direct',
          coverage: response['coverage'] == null
              ? null
              : jsonMap(response['coverage']),
          receiptState: response['receiptState'] == null
              ? null
              : jsonMap(response['receiptState']),
        );
      });
      if (generation != sessionGenerationId) return;
      if (roomId == _activeRoomId) {
        final currentRoom = await database.room(roomId);
        if (generation != sessionGenerationId || roomId != _activeRoomId) {
          return;
        }
        selectedRoom = currentRoom;
        _serverHasMoreMessages = preservedHistory
            ? _historyHasMore[roomId] ?? response['hasMore'] == true
            : response['hasMore'] == true;
        _historyHasMore[roomId] = _serverHasMoreMessages;
        // The retained watch observes the committed bounded window, including
        // its extra row. Its next emission also handles delayed invalidations.
        hasMoreMessages = _hasMoreCachedMessages || _serverHasMoreMessages;
      }
      _record('messages_reconciled', 'received=${fresh.length}');
    });
  }

  Future<void> loadOlderMessages() async {
    if (!_hasActiveSession) return;
    await _run('loadOlderMessages', () async {
      final roomId = _activeRoomId;
      final userId = currentUser?.id;
      final generation = sessionGenerationId;
      final navigation = _navigationRequest;
      if (roomId == null || userId == null || isJumpMode) return;
      if (_hasMoreCachedMessages) {
        _windowLimit += 30;
        // The widened watch supplies the cache snapshot and observes future
        // writes, without reading the same window once before subscribing.
        await _showCachedMessages(generation, navigation);
        return;
      }
      if (roomId.startsWith('draft_') || !_serverHasMoreMessages) {
        hasMoreMessages = false;
        return;
      }
      await _sync?.queue.enqueue(() async {
        if (!_isCurrentView(generation, navigation) ||
            roomId != _activeRoomId) {
          return;
        }
        final previousLimit = _windowLimit;
        _windowLimit += 30;
        // Read the widened window once through its retained watch. Do this in
        // the inbox lane so an earlier recovery cannot replace the cache after
        // choosing the compound pagination cursor. The same watch observes the
        // page commit; no obsolete narrow-window refresh or resubscribe follows.
        final cached = await _watchMessages();
        if (!_isCurrentView(generation, navigation) ||
            roomId != _activeRoomId ||
            cached == null) {
          return;
        }
        if (cached.length > previousLimit) return;
        // This snapshot contains the entire cache (including pending sends),
        // so its oldest sent row supplies the cursor without another SELECT.
        final sent = cached.where((message) => message.status == 'sent');
        if (sent.isEmpty) return;
        final oldest = sent.last;
        try {
          final result = await api.latestMessages(roomId, before: oldest);
          if (!_isCurrentView(generation, navigation)) return;
          await database.transaction(() async {
            if (!_isCurrentView(generation, navigation)) return;
            await database.storeOlderMessagePage(
              roomId,
              [
                for (final value in result['messages'] as List)
                  ChatMessage.fromJson(jsonMap(value)),
              ],
              userId: userId,
              coverage: result['coverage'] == null
                  ? null
                  : jsonMap(result['coverage']),
              receiptState: result['receiptState'] == null
                  ? null
                  : jsonMap(result['receiptState']),
            );
          });
          if (!_isCurrentView(generation, navigation)) return;
          _historyHasMore[roomId] = result['hasMore'] == true;
          if (roomId == _activeRoomId) {
            _serverHasMoreMessages = result['hasMore'] == true;
            hasMoreMessages = _hasMoreCachedMessages || _serverHasMoreMessages;
          }
        } catch (_) {
          if (_isCurrentView(generation, navigation) &&
              roomId == _activeRoomId &&
              !isJumpMode &&
              _windowLimit == previousLimit + 30) {
            // Failed retries must not grow the watched window indefinitely.
            // Restore its previous bound and keep observing live writes.
            _windowLimit = previousLimit;
            await _watchMessages();
          }
          rethrow;
        }
      });
    }, showBusy: false);
  }

  Future<void> createGroup(String title, List<String> participantIds) async {
    if (!_hasActiveSession) return;
    final generation = sessionGenerationId;
    final navigation = ++_navigationRequest;
    await _run('createGroup', () async {
      final result = await api.post('/rooms/group', {
        'title': title.trim(),
        'participantIds': participantIds,
      });
      if (!_isCurrentView(generation, navigation)) return;
      await _sync?.reconcileMutation(result);
      if (!_isCurrentView(generation, navigation)) return;
      await _openRoom(
        ChatRoom.fromJson(jsonMap(result['room'])),
        generation: generation,
        navigation: navigation,
      );
    });
  }

  MessageSendContext? captureSendContext() {
    if (!_hasActiveSession) return null;
    final senderId = currentUser?.id;
    final roomId = _activeRoomId;
    if (senderId == null || roomId == null) return null;
    return MessageSendContext(
      generation: sessionGenerationId,
      senderId: senderId,
      targetRoomId: roomId,
      targetPeerUserId: draftPeer?.id,
      targetPeer: draftPeer,
    );
  }

  bool isSendContextCurrent(MessageSendContext context) =>
      _isCurrentMessageSession(context.generation, context.senderId);

  Future<bool> sendText(
    String text, {
    ChatMessage? replyTo,
    MessageSendContext? context,
  }) async {
    if (text.trim().isEmpty) return false;
    final captured = context ?? captureSendContext();
    if (captured == null || !isSendContextCurrent(captured)) return false;
    final saved = await _run(
      'sendText',
      () => _send(
        context: captured,
        type: 'text',
        text: text.trim(),
        replyTo: replyTo,
      ),
      showBusy: false,
      traceContext: debugInspector.captureContext().copyWithRoom(
        captured.targetRoomId,
      ),
    );
    return saved != null;
  }

  Future<void> sendImage(
    Uint8List bytes,
    String filename, {
    ChatMessage? replyTo,
    MessageSendContext? context,
  }) async {
    final captured = context ?? captureSendContext();
    if (captured == null || !isSendContextCurrent(captured)) return;
    await _run(
      'sendImage',
      () => _send(
        context: captured,
        type: 'image',
        text: '',
        replyTo: replyTo,
        uploadBytes: bytes,
        uploadFilename: filename,
      ),
      traceContext: debugInspector.captureContext().copyWithRoom(
        captured.targetRoomId,
      ),
    );
  }

  Future<void> sendImageBatch(
    List<({Uint8List bytes, String filename})> images, {
    ChatMessage? replyTo,
    required MessageSendContext context,
  }) async {
    await _run('sendImages', () async {
      final pending = <ChatMessage>[];
      // Persist every selected item before the first network await.
      await database.transaction(() async {
        for (final image in images) {
          if (!isSendContextCurrent(context)) return;
          final message = await _send(
            context: context,
            type: 'image',
            text: '',
            replyTo: replyTo,
            uploadBytes: image.bytes,
            uploadFilename: image.filename,
            deferSubmit: true,
          );
          if (message != null) pending.add(message);
        }
      });
      if (pending.isNotEmpty && isSendContextCurrent(context)) {
        _outbox?.wakeAfterEnqueue();
      }
    });
  }

  Future<ChatMessage?> _send({
    required MessageSendContext context,
    required String type,
    required String text,
    String? imageUrl,
    ChatMessage? replyTo,
    Uint8List? uploadBytes,
    String? uploadFilename,
    bool deferSubmit = false,
  }) async {
    final generation = context.generation;
    final user = currentUser;
    if (user == null || !isSendContextCurrent(context)) {
      return null;
    }
    final key = _uuid.v4();
    ChatMessage? optimistic;
    ChatRoom? resolvedRoom;
    await database.transaction(() async {
      if (!isSendContextCurrent(context)) return;
      var roomId = context.targetRoomId;
      if (roomId.startsWith('draft_') && context.targetPeerUserId != null) {
        // An earlier item in the same batch may have created this direct room.
        // Resolve its original peer inside the local write transaction rather
        // than binding a later optimistic row to the now-retired draft ID.
        final candidateRooms =
            await (database.select(database.localRooms)..where(
                  (room) =>
                      room.roomType.equals('direct') &
                      room.peerUserId.equals(context.targetPeerUserId!),
                ))
                .get();
        if (!isSendContextCurrent(context)) return;
        final realRooms = candidateRooms.where(
          (room) => !room.roomId.startsWith('draft_'),
        );
        if (realRooms.isNotEmpty) {
          resolvedRoom = database.roomModel(realRooms.first);
          roomId = realRooms.first.roomId;
          await database.remapDraft(context.targetRoomId, roomId);
          if (!isSendContextCurrent(context)) return;
        }
      }
      if (uploadBytes != null) {
        await database.checkUploadQuota(uploadBytes.length);
        if (!isSendContextCurrent(context)) return;
      }
      final message = optimistic = ChatMessage(
        id: 'temp_$key',
        idempotencyKey: key,
        roomId: roomId,
        peerUserId: context.targetPeerUserId,
        senderId: user.id,
        senderName: user.displayName,
        senderAvatarUrl: user.avatarUrl,
        type: type,
        text: text,
        imageUrl: imageUrl,
        uploadBytes: uploadBytes,
        uploadFilename: uploadFilename,
        replyTo: replyTo == null ? null : ReplySnapshot.fromMessage(replyTo),
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
      );
      if (roomId.startsWith('draft_') && context.targetPeerUserId != null) {
        final peerId = context.targetPeerUserId!;
        final knownPeer = users.where((peer) => peer.id == peerId);
        await database.upsertDraftRoom(
          context.targetPeer ??
              (knownPeer.isNotEmpty
                  ? knownPeer.first
                  : UserProfile(
                      id: peerId,
                      username: peerId,
                      displayName: peerId,
                    )),
          message,
        );
        if (!isSendContextCurrent(context)) return;
      }
      await database.enqueueOutboundMessage(message);
    });
    final message = optimistic;
    if (message == null || !isSendContextCurrent(context)) return null;
    debugInspector.record(
      'outbox',
      'enqueued',
      context: debugInspector.captureContext().copyWithRoom(message.roomId),
      data: {'operationId': message.idempotencyKey, 'status': 'queued'},
    );
    if (!deferSubmit &&
        resolvedRoom != null &&
        _activeRoomId == context.targetRoomId) {
      _activeRoomId = resolvedRoom!.roomId;
      selectedRoom = resolvedRoom;
      draftPeer = null;
      _sync?.openRoomId = resolvedRoom!.roomId;
      await _showCachedMessages(generation, _navigationRequest);
      if (!isSendContextCurrent(context)) return null;
    }
    if (!deferSubmit) _outbox?.wakeAfterEnqueue();
    return message;
  }

  bool _isCurrentMessageSession(int generation, String senderId) =>
      !_disposed &&
      !_sessionStopping &&
      generation == sessionGenerationId &&
      currentUser?.id == senderId;

  Future<void> _submitMessage(
    ChatMessage message, {
    required int generation,
  }) async {
    if (!_isCurrentMessageSession(generation, message.senderId)) return;
    if (requiresReauthentication) {
      throw const ChatApiException(
        'Sign in again to send saved work.',
        statusCode: 401,
      );
    }
    if (message.uploadBytes != null) {
      final upload = _uploadTail.then((_) {
        if (!_isCurrentMessageSession(generation, message.senderId) ||
            requiresReauthentication) {
          throw const ChatApiException(
            'Sign in again to send saved work.',
            statusCode: 401,
          );
        }
        return api.uploadImage(
          message.uploadBytes!,
          message.uploadFilename ?? 'image.png',
        );
      });
      _uploadTail = upload.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      final url = await upload;
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      await database.transaction(() async {
        if (!_isCurrentMessageSession(generation, message.senderId)) return;
        final current = await database.messageByIdempotencyKey(
          message.senderId,
          message.idempotencyKey,
        );
        if (!_isCurrentMessageSession(generation, message.senderId)) return;
        if (current?.status == 'sent') {
          message = current!;
          return;
        }
        // Preserve the worker's current claim/retry metadata and any draft
        // remapping while checkpointing the uploaded resource.
        message = (current ?? message).copyWith(
          imageUrl: url,
          clearUpload: true,
        );
        await database.upsertMessage(message);
      });
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      if (message.status == 'sent') return;
    }
    final result = await api.post('/messages', {
      if (!message.roomId.startsWith('draft_')) 'roomId': message.roomId,
      if (message.roomId.startsWith('draft_')) 'peerUserId': message.peerUserId,
      'idempotencyKey': message.idempotencyKey,
      'type': message.type,
      'text': message.text,
      if (message.imageUrl != null) 'imageUrl': message.imageUrl,
      if (message.replyTo != null)
        'replyToMessageId': message.replyTo!.messageId,
    });
    if (!_isCurrentMessageSession(generation, message.senderId)) return;
    final serverMessage = ChatMessage.fromJson(jsonMap(result['message']));
    final roomPayload = jsonMap(result['room']);
    if (serverMessage.senderId != message.senderId ||
        serverMessage.idempotencyKey != message.idempotencyKey ||
        roomPayload['roomId'] != serverMessage.roomId ||
        (!message.roomId.startsWith('draft_') &&
            serverMessage.roomId != message.roomId) ||
        (message.roomId.startsWith('draft_') &&
            (roomPayload['roomType'] != 'direct' ||
                roomPayload['peerUserId'] != message.peerUserId))) {
      throw const ChatApiException(
        'Sending paused because the server acknowledgment did not match.',
        kind: ChatFailureKind.protocol,
        code: 'acknowledgment_identity_mismatch',
      );
    }
    await database.transaction(() async {
      if (!_isCurrentMessageSession(generation, message.senderId)) return;
      await database.remapDraft(message.roomId, serverMessage.roomId);
      await _sync?.reconcileMutation(result);
    });
    if (!_isCurrentMessageSession(generation, message.senderId)) return;
    if (_activeRoomId == message.roomId &&
        message.roomId.startsWith('draft_')) {
      final room = await database.room(serverMessage.roomId);
      if (!_isCurrentMessageSession(generation, message.senderId) ||
          _activeRoomId != message.roomId ||
          room == null) {
        return;
      }
      // Keep one valid conversation identity throughout the draft transition.
      // Watch-room notifications can run during the lookup above.
      _activeRoomId = serverMessage.roomId;
      draftPeer = null;
      selectedRoom = room;
      _sync?.openRoomId = serverMessage.roomId;
      _watchMessages();
    }
    _record('message_sent');
  }

  Future<void> retryMessage(ChatMessage message) async {
    final generation = sessionGenerationId;
    await _run(
      'retryMessage',
      () async {
        if (!_isCurrentMessageSession(generation, message.senderId)) return;
        await _outbox?.retry(message);
      },
      showBusy: false,
      traceContext: debugInspector.captureContext().copyWithRoom(
        message.roomId,
      ),
    );
  }

  Future<void> editMessage(ChatMessage message, String text) async {
    if (!_hasActiveSession) return;
    await _run(
      'editMessage',
      () async {
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
        if (!_isCurrentSession(generation)) return;
        if (isJumpMode) _applyJumpMutation(result);
      },
      traceContext: debugInspector.captureContext().copyWithRoom(
        message.roomId,
      ),
    );
  }

  Future<void> deleteMessage(
    ChatMessage message, {
    required bool forEveryone,
  }) async {
    if (!_hasActiveSession) return;
    await _run(
      'deleteMessage',
      () async {
        final generation = sessionGenerationId;
        final result = jsonMap(
          await api.request(
            'DELETE',
            '/messages/${message.id}/${forEveryone ? 'for-all' : 'for-me'}',
          ),
        );
        if (generation != sessionGenerationId) return;
        await _sync?.reconcileMutation(result);
        if (!_isCurrentSession(generation)) return;
        if (!forEveryone) {
          await database.transaction(() async {
            if (!_isCurrentSession(generation)) return;
            await database.removeMessage(message.id);
          });
          if (!_isCurrentSession(generation)) return;
          messages = messages.where((m) => m.id != message.id).toList();
        } else if (isJumpMode) {
          _applyJumpMutation(result);
        }
      },
      traceContext: debugInspector.captureContext().copyWithRoom(
        message.roomId,
      ),
    );
  }

  Future<void> setPreferences(ChatRoom room, {bool? pin, bool? isMuted}) async {
    if (!_hasActiveSession) return;
    await _run(
      'setPreferences',
      () async {
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
      },
      showBusy: false,
      traceContext: debugInspector.captureContext().copyWithRoom(room.roomId),
    );
  }

  Future<void> _deliverRooms(
    List<ChatRoom> values, {
    bool retryPending = true,
  }) async {
    if (requiresReauthentication || !_hasActiveSession) return;
    final generation = sessionGenerationId;
    final senderId = currentUser?.id;
    if (senderId == null) return;
    final sync = _sync;
    if (sync == null) return;
    final candidates = values.where((room) {
      if (room.roomType != 'direct' || room.roomId.startsWith('draft_')) {
        return false;
      }
      final last = room.lastMessage;
      return room.receiptProtocol == 'sequence' ||
          (last != null && last.senderId != senderId && !last.isDelivered);
    }).toList();
    if (candidates.isEmpty) {
      // Startup still retries durable acknowledgements, even when a newer
      // outgoing preview has replaced their original incoming message.
      if (retryPending) _scheduleReceiptFlush(generation);
      return;
    }
    var queued = false;
    await sync.queue.enqueue(
      () => database.transaction(() async {
        for (final room in candidates) {
          if (!_isCurrentMessageSession(generation, senderId)) return;
          final target = room.receiptProtocol == 'sequence'
              ? await database.receiptTarget(room.roomId)
              : null;
          if (!_isCurrentMessageSession(generation, senderId)) return;
          if (target != null) {
            await database.queueReceipt(
              room.roomId,
              deliveredThroughSeq: target,
            );
            queued = true;
          }
          final last = room.lastMessage;
          if (last != null &&
              (room.receiptProtocol != 'sequence' || last.messageSeq == null) &&
              last.senderId != senderId &&
              !last.isDelivered) {
            await database.queueReceipt(
              room.roomId,
              deliveredThroughTimestamp: last.createdAt,
            );
            queued = true;
          }
        }
      }),
      operation: 'receipts.delivery.queue',
    );
    if ((queued || retryPending) &&
        _isCurrentMessageSession(generation, senderId)) {
      _scheduleReceiptFlush(generation);
    }
  }

  Future<void> _queueRoomEventReceipts(
    InboxRoomEvent event,
    int generation,
    int navigation, {
    required bool markSeen,
  }) async {
    final state = event.roomState;
    final sync = _sync;
    if (state == null ||
        sync == null ||
        requiresReauthentication ||
        !_isCurrentSession(generation)) {
      return;
    }
    final room = database.roomModel(state);
    if (room.roomId.startsWith('draft_')) return;
    final sequenceEnabled = room.receiptProtocol == 'sequence';
    final delivered = room.roomType == 'direct' && sequenceEnabled
        ? database.receiptTargetFromRoom(state)
        : null;
    final seen = markSeen && sequenceEnabled
        ? database.receiptTargetFromRoom(state, seen: true)
        : null;
    final deliveryTarget =
        delivered != null && delivered > state.ownDeliveredSeq
        ? delivered
        : null;
    final seenTarget = seen != null && seen > state.ownSeenSeq ? seen : null;
    final deliveryTimestamp = room.roomType == 'direct'
        ? event.legacyDeliveryTimestamp
        : null;
    final last = room.lastMessage;
    final seenTimestamp =
        markSeen && (!sequenceEnabled || last?.messageSeq == null)
        ? last?.createdAt ?? (room.unreadCount > 0 ? room.sortTimestamp : null)
        : null;
    if (deliveryTarget == null &&
        seenTarget == null &&
        deliveryTimestamp == null &&
        seenTimestamp == null) {
      return;
    }
    var queued = false;
    await sync.queue.enqueue(
      () => database.transaction(() async {
        if (!_isCurrentSession(generation) || requiresReauthentication) return;
        final canSee =
            markSeen &&
            _isCurrentView(generation, navigation) &&
            _activeRoomId == room.roomId &&
            _lifecycleState == AppLifecycleState.resumed &&
            !_opening;
        if (deliveryTarget == null &&
            deliveryTimestamp == null &&
            (!canSee || (seenTarget == null && seenTimestamp == null))) {
          return;
        }
        // queueReceipt merges with durable tasks and confirmed cursors. Delivery
        // and foreground Seen share that one read, with the captured boundaries.
        await database.queueReceipt(
          room.roomId,
          deliveredThroughSeq: deliveryTarget,
          seenThroughSeq: canSee ? seenTarget : null,
          deliveredThroughTimestamp: deliveryTimestamp,
          seenThroughTimestamp: canSee ? seenTimestamp : null,
        );
        queued = true;
      }),
      operation: 'receipts.room.queue',
    );
    if (queued && _isCurrentSession(generation)) {
      _scheduleReceiptFlush(generation);
    }
  }

  Future<void> _markSeen({
    int? maximumSequence,
    DateTime? maximumTimestamp,
    int? expectedNavigation,
  }) async {
    if (requiresReauthentication) return;
    if (!_hasActiveSession || _lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final roomId = _activeRoomId;
    if (roomId == null ||
        roomId.startsWith('draft_') ||
        (expectedNavigation != null &&
            expectedNavigation != _navigationRequest)) {
      return;
    }
    final generation = sessionGenerationId;
    final sync = _sync;
    if (sync == null) return;
    await sync.queue.enqueue(
      () => database.transaction(() async {
        if (!_isCurrentSession(generation) ||
            _activeRoomId != roomId ||
            (expectedNavigation != null &&
                expectedNavigation != _navigationRequest) ||
            _lifecycleState != AppLifecycleState.resumed) {
          return;
        }
        final state = await database.roomRow(roomId);
        final room = state == null ? null : database.roomModel(state);
        if (!_isCurrentSession(generation) ||
            _activeRoomId != roomId ||
            _lifecycleState != AppLifecycleState.resumed ||
            room == null) {
          return;
        }
        var target = room.receiptProtocol == 'sequence' && state != null
            ? database.receiptTargetFromRoom(state, seen: true)
            : null;
        if (maximumTimestamp != null && maximumSequence == null) {
          target = null;
        } else if (target != null &&
            maximumSequence != null &&
            target > maximumSequence) {
          target = maximumSequence;
        }
        if (!_isCurrentSession(generation) ||
            _activeRoomId != roomId ||
            (expectedNavigation != null &&
                expectedNavigation != _navigationRequest) ||
            _lifecycleState != AppLifecycleState.resumed) {
          return;
        }
        if (target != null) {
          await database.queueReceipt(roomId, seenThroughSeq: target);
        }
        var last = room.lastMessage;
        if (last == null) {
          final cached = await database.messageWindow(roomId, 1);
          if (!_isCurrentSession(generation) ||
              _activeRoomId != roomId ||
              _lifecycleState != AppLifecycleState.resumed) {
            return;
          }
          if (cached.isNotEmpty && cached.first.status == 'sent') {
            last = cached.first;
          }
        }
        // Legacy rows retain timestamp acknowledgements. Capture the visible
        // room boundary; a retry must never expand to the server's current time.
        if (last != null &&
            (room.receiptProtocol != 'sequence' || last.messageSeq == null)) {
          final timestamp =
              maximumTimestamp != null &&
                  last.createdAt.isAfter(maximumTimestamp)
              ? maximumTimestamp
              : last.createdAt;
          await database.queueReceipt(roomId, seenThroughTimestamp: timestamp);
        } else if (room.roomType == 'group' &&
            target == null &&
            room.unreadCount > 0) {
          await database.queueReceipt(
            roomId,
            seenThroughTimestamp:
                maximumTimestamp != null &&
                    room.sortTimestamp.isAfter(maximumTimestamp)
                ? maximumTimestamp
                : room.sortTimestamp,
          );
        }
      }),
      operation: 'receipts.seen.queue',
    );
    if (_isCurrentSession(generation)) _scheduleReceiptFlush(generation);
  }

  void _scheduleReceiptFlush(int generation, {bool retry = false}) {
    if (!_isCurrentSession(generation) || requiresReauthentication) return;
    // Preserve a wake arriving after an in-flight read took its SQL snapshot.
    if (_receiptFlush != null) {
      _receiptFlushRequested = true;
      return;
    }
    if (_receiptTimer?.isActive == true) return;
    final delay = retry
        ? Duration(seconds: 1 << _receiptRetryAttempt.clamp(0, 4))
        : const Duration(milliseconds: 120);
    _receiptTimer = Timer(delay, () {
      _receiptTimer = null;
      if (!_isCurrentSession(generation) || requiresReauthentication) return;
      unawaited(_flushReceipts(generation));
    });
  }

  Future<void> _confirmReceipt(
    int generation,
    String roomId, {
    int? deliveredThroughSeq,
    int? seenThroughSeq,
    DateTime? deliveredThroughTimestamp,
    DateTime? seenThroughTimestamp,
  }) async {
    if (!_isCurrentSession(generation)) return;
    await _sync?.queue.enqueue(
      () => database.transaction(() async {
        if (!_isCurrentSession(generation)) return;
        await database.confirmReceipt(
          roomId,
          deliveredThroughSeq: deliveredThroughSeq,
          seenThroughSeq: seenThroughSeq,
          deliveredThroughTimestamp: deliveredThroughTimestamp,
          seenThroughTimestamp: seenThroughTimestamp,
        );
      }),
      operation: 'receipts.confirm',
    );
  }

  Future<void> _flushReceipts(int generation) {
    final running = _receiptFlush;
    if (running != null) return running;
    late final Future<void> flushing;
    var failed = false;
    var initialReadWasEmpty = false;
    _receiptFlushRequested = false;
    flushing =
        (() async {
              if (!_isCurrentSession(generation) || requiresReauthentication) {
                return;
              }
              final targets = await database.pendingReceiptTargets();
              initialReadWasEmpty = targets.isEmpty;
              if (!_isCurrentSession(generation) || requiresReauthentication) {
                return;
              }
              final deliveries = <({String roomId, int upToSeq})>[];
              final legacyDeliveries = <int, List<String>>{};
              var protocolDeferred = false;
              for (final target in targets) {
                if (!_isCurrentSession(generation) ||
                    requiresReauthentication) {
                  return;
                }
                final room = await database.room(target.roomId);
                if (!_isCurrentSession(generation)) return;
                final sequenceEnabled =
                    (room?.receiptProtocol ?? target.receiptProtocol) ==
                    'sequence';
                final legacySeen = target.seenThroughTimestamp;
                if (legacySeen != null) {
                  await api.post('/rooms/${target.roomId}/seen', {
                    'upToTimestamp': legacySeen.toUtc().toIso8601String(),
                  });
                  if (!_isCurrentSession(generation)) return;
                  await _confirmReceipt(
                    generation,
                    target.roomId,
                    seenThroughTimestamp: legacySeen,
                    deliveredThroughTimestamp: legacySeen,
                  );
                }
                final legacyDelivered = target.deliveredThroughTimestamp;
                if (legacyDelivered != null &&
                    (legacySeen == null ||
                        legacyDelivered.isAfter(legacySeen))) {
                  legacyDeliveries
                      .putIfAbsent(
                        legacyDelivered.millisecondsSinceEpoch,
                        () => [],
                      )
                      .add(target.roomId);
                }
                final seen = target.seenThroughSeq;
                if (seen != null && sequenceEnabled) {
                  // The target records what this account read while foreground. Retry
                  // that captured target even after navigation; never substitute now.
                  await api.seenThrough(target.roomId, seen);
                  if (!_isCurrentSession(generation)) return;
                  await _confirmReceipt(
                    generation,
                    target.roomId,
                    seenThroughSeq: seen,
                    deliveredThroughSeq: seen,
                  );
                }
                final delivered = target.deliveredThroughSeq;
                if (!sequenceEnabled && (seen != null || delivered != null)) {
                  // A server can roll back its publication mode while this
                  // device has durable work. Retain the original sequence
                  // target until that protocol is available again.
                  protocolDeferred = true;
                } else if (delivered != null &&
                    (seen == null || delivered > seen)) {
                  deliveries.add((roomId: target.roomId, upToSeq: delivered));
                }
              }
              for (final entry in legacyDeliveries.entries) {
                final boundary = DateTime.fromMillisecondsSinceEpoch(
                  entry.key,
                  isUtc: true,
                );
                for (var start = 0; start < entry.value.length; start += 100) {
                  if (!_isCurrentSession(generation) ||
                      requiresReauthentication) {
                    return;
                  }
                  final ids = entry.value.skip(start).take(100).toList();
                  await api.post('/rooms/delivered-batch', {
                    'roomIds': ids,
                    'upToTimestamp': boundary.toIso8601String(),
                  });
                  if (!_isCurrentSession(generation)) return;
                  for (final roomId in ids) {
                    await _confirmReceipt(
                      generation,
                      roomId,
                      deliveredThroughTimestamp: boundary,
                    );
                    if (!_isCurrentSession(generation)) return;
                  }
                }
              }
              for (var start = 0; start < deliveries.length; start += 100) {
                if (!_isCurrentSession(generation) ||
                    requiresReauthentication) {
                  return;
                }
                final batch = deliveries.skip(start).take(100).toList();
                await api.deliverThrough(batch);
                if (!_isCurrentSession(generation)) return;
                for (final target in batch) {
                  await _confirmReceipt(
                    generation,
                    target.roomId,
                    deliveredThroughSeq: target.upToSeq,
                  );
                  if (!_isCurrentSession(generation)) return;
                }
              }
              failed = protocolDeferred;
              _receiptRetryAttempt = protocolDeferred
                  ? (_receiptRetryAttempt + 1).clamp(0, 4)
                  : 0;
            })()
            .catchError((Object failure) async {
              if (!_isCurrentSession(generation)) return;
              failed = true;
              _receiptRetryAttempt = (_receiptRetryAttempt + 1).clamp(0, 4);
              _record('receipt_unavailable');
              if (failure is ChatApiException && failure.statusCode == 401) {
                await _requireReauthentication(generation);
              }
            })
            .whenComplete(() async {
              if (!identical(_receiptFlush, flushing)) return;
              _receiptFlush = null;
              if (!_isCurrentSession(generation) || requiresReauthentication) {
                return;
              }
              final requested = _receiptFlushRequested;
              _receiptFlushRequested = false;
              if (initialReadWasEmpty) {
                if (requested) _scheduleReceiptFlush(generation);
                return;
              }
              final pending = await database.pendingReceiptTargets();
              if (!_isCurrentSession(generation) || pending.isEmpty) return;
              _scheduleReceiptFlush(generation, retry: failed);
            });
    return _receiptFlush = flushing;
  }

  Future<void> jumpToMessage(String targetId) async {
    if (!_hasActiveSession) return;
    final roomId = _activeRoomId;
    final generation = sessionGenerationId;
    final navigation = _navigationRequest;
    final request = ++_jumpRequest;
    bool current() =>
        _isCurrentView(generation, navigation) &&
        roomId == _activeRoomId &&
        request == _jumpRequest;
    await _run('jumpToMessage', () async {
      if (roomId == null) return;
      final cached = await database.message(targetId);
      if (!current()) return;
      if (cached != null && cached.roomId == roomId) {
        final context = await database.localContext(cached);
        if (!current()) return;
        await _cancelMessageWatch();
        if (!current()) return;
        isJumpMode = true;
        _jumpTargetId = targetId;
        _jumpHistoryEditPts =
            (await database.room(roomId))?.lastHistoryEditPts ?? 0;
        if (!current()) return;
        messages = context;
      } else {
        if (roomId.startsWith('draft_')) {
          throw const ChatApiException(
            'This message is not cached on this device.',
          );
        }
        await _cancelMessageWatch();
        if (!current()) return;
        isJumpMode = true;
        _jumpTargetId = targetId;
        _jumpHistoryEditPts = -1;
        await _refreshHistoricalJump();
      }
      if (!current() || (isJumpMode && _jumpTargetId != targetId)) return;
      highlightMessageId = targetId;
      _highlightTimer?.cancel();
      _highlightTimer = Timer(
        const Duration(milliseconds: 1500),
        () => debugInspector.runIndependent(() {
          highlightMessageId = null;
          _notify();
        }),
      );
    });
  }

  void _applyJumpMutation(Map<String, dynamic> result) {
    if (result['room'] != null) _applyJumpEvent(jsonMap(result['room']));
  }

  void _applyJumpEvent(Map<String, dynamic> payload) {
    if (!isJumpMode || payload['roomId'] != _activeRoomId) return;
    if (payload['updatedMessage'] == null &&
        payload['quoteUpdate'] == null &&
        payload['peerDeliveredSeq'] == null &&
        payload['peerSeenSeq'] == null) {
      return;
    }
    messages = reconcileJumpSlice(messages, payload, myUserId: currentUser?.id);
    _notify();
  }

  /// Redis delta/full-sync can coalesce an edit/delete into a later new-message
  /// payload. The history revision invalidates remote context independently of
  /// the latest message window, while tail messages leave its viewport alone.
  Future<void> _refreshHistoricalJump() async {
    final sync = _sync;
    final targetId = _jumpTargetId;
    final roomId = _activeRoomId;
    final generation = sessionGenerationId;
    final navigation = _navigationRequest;
    final request = _jumpRequest;
    if (sync == null || !isJumpMode || targetId == null || roomId == null) {
      return;
    }
    bool current() =>
        _isCurrentView(generation, navigation) &&
        isJumpMode &&
        roomId == _activeRoomId &&
        targetId == _jumpTargetId &&
        request == _jumpRequest;
    await sync.queue.enqueue(() async {
      if (!current()) return;
      var room = await database.room(roomId);
      if (!current()) return;
      if (room == null) {
        _leaveHistoricalJump();
        return;
      }
      if (room.lastHistoryEditPts <= _jumpHistoryEditPts) {
        return;
      }
      // Do not leave stale or globally deleted content on screen if recovery
      // fails. The next sync can retry because its revision is not certified.
      if (_jumpHistoryEditPts >= 0) {
        messages = [];
        _notify();
      }
      while (current() && room != null) {
        final historyRevision = room.lastHistoryEditPts;
        Map<String, dynamic> result;
        try {
          result = await api.getMap(
            '/rooms/$roomId/messages/around/$targetId',
            query: {'limit': 30},
          );
        } on ChatApiException catch (failure) {
          if (!current()) return;
          if (failure.statusCode == 404 || failure.statusCode == 403) {
            _leaveHistoricalJump();
            return;
          }
          rethrow;
        }
        if (!current()) return;
        room = await database.room(roomId);
        if (!current()) return;
        if (room == null) {
          _leaveHistoricalJump();
          return;
        }
        // A REST mutation can reconcile outside the inbox lane while this
        // request waits. Fetch again rather than accepting its stale context.
        if (room.lastHistoryEditPts > historyRevision) continue;
        final fresh = (result['messages'] as List)
            .map((m) => ChatMessage.fromJson(jsonMap(m)))
            .toList();
        if (!fresh.any((message) => message.id == targetId)) {
          _leaveHistoricalJump();
          return;
        }
        messages = fresh;
        _jumpHistoryEditPts = historyRevision;
        _notify();
        return;
      }
    });
  }

  void _leaveHistoricalJump() {
    ++_jumpRequest;
    isJumpMode = false;
    _jumpTargetId = null;
    _jumpHistoryEditPts = 0;
    highlightMessageId = null;
    _windowLimit = 50;
    messages = [];
    _watchMessages();
    _notify();
  }

  Future<void> returnToLatest() async {
    if (!_hasActiveSession) return;
    final generation = sessionGenerationId;
    final navigation = _navigationRequest;
    await _run('returnToLatest', () async {
      _leaveHistoricalJump();
      await _showCachedMessages(generation, navigation);
      if (!_isCurrentView(generation, navigation)) return;
      final roomId = _activeRoomId;
      if (roomId != null && !roomId.startsWith('draft_')) {
        unawaited(_recoverRoom(roomId, generation));
      }
    }, showBusy: false);
  }

  String? imageUrl(String? path) =>
      path == null ? null : api.absoluteImageUrl(path);
  Future<Map<String, Object?>> inspectDatabase() async {
    if (!kDebugMode) return {'enabled': false};
    final generation = sessionGenerationId;
    final value = await database.inspect();
    if (!_isCurrentSession(generation)) return {};
    final meta = jsonMap(value['metadata']);
    _databaseSummary = {
      'localPts': meta['localPts'] ?? 0,
      'localEpoch': meta['localEpoch'] ?? '',
      ...jsonMap(value['rowCounts']),
    };
    return value;
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidateSession();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      _transitionSession(() => _stopSession(clear: false, release: false))
          .whenComplete(database.close),
    );
    api.debugInspector = null;
    if (_ownsDebugInspector) debugInspector.dispose();
    super.dispose();
  }
}
