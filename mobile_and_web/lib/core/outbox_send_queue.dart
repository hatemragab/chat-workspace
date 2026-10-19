import 'dart:async';
import 'dart:math' as math;

import 'package:queue/queue.dart';

import 'app_database.dart';
import 'chat_api.dart';
import 'debug_inspector.dart';
import 'models.dart';
import 'server_health_monitor.dart';

/// A single execution lane over durable Drift rows, independent of inbox sync.
/// The oldest unresolved send owns the lane until confirmed or rejected.
class OutboxSendQueue {
  OutboxSendQueue({
    required this.database,
    required this.api,
    required this.senderId,
    required this.send,
    required this.healthMonitor,
    required this.isCurrentSession,
    required this.onAuthenticationRequired,
    this.inspector,
    this.onStateChanged,
    this.retryDelay = const Duration(seconds: 2),
    this.maxAttempts = 3,
    DateTime Function()? now,
    double Function()? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? math.Random().nextDouble {
    healthMonitor.addListener(_healthChanged);
    unawaited(_watchHead());
  }

  Future<void> _watchHead() {
    if (_disposed) return Future.value();
    if (_headSubscription != null) return _headReady!.future;
    // Observe external acknowledgments while parked. The drain already rereads
    // the head after every attempt, so watching its own writes just duplicates
    // those reads. Reattaching always performs an initial query, covering work
    // committed between the final head read and this subscription.
    final ready = _headReady = Completer<void>();
    _headSubscription = database
        .watchOutboundSnapshot(senderId)
        .listen(
          (snapshot) {
            if (_disposed || !isCurrentSession()) return;
            final first = !ready.isCompleted;
            final countsChanged =
                queuedCount != snapshot.queued ||
                failedCount != snapshot.failed ||
                pausedCount != snapshot.paused;
            _pendingSnapshot = snapshot;
            _applyCounts(snapshot);
            if (first) ready.complete();
            final key = snapshot.head?.idempotencyKey;
            final headChanged = !_hasObservedHead || key != _observedHeadKey;
            _hasObservedHead = true;
            _observedHeadKey = key;
            if (_scheduled) {
              if (!first && headChanged) _wakeRequested = true;
            } else if (headChanged) {
              _scheduleDrain();
            } else if (countsChanged) {
              _record('queue_changed');
            }
          },
          onError: (Object _) {
            if (!ready.isCompleted) ready.complete();
            if (!_active) return;
            _lastReason = 'local_storage_or_protocol';
            pause();
            _record('paused', {'reason': _lastReason});
          },
        );
    return ready.future;
  }

  Future<void> _stopWatchingHead() async {
    final subscription = _headSubscription;
    _headSubscription = null;
    _headReady = null;
    await subscription?.cancel();
  }

  final AppDatabase database;
  final ChatApi api;
  final String senderId;
  final Future<void> Function(ChatMessage) send;
  final ServerHealthMonitor healthMonitor;
  final bool Function() isCurrentSession;
  final void Function() onAuthenticationRequired;
  final DebugInspector? inspector;
  final void Function()? onStateChanged;
  final Duration retryDelay;
  final int maxAttempts;
  final DateTime Function() _now;
  final double Function() _random;
  final Queue _lane = Queue(parallel: 1);
  bool _disposed = false, _paused = false, _scheduled = false;
  bool _wakeRequested = false, _running = false;
  bool _freshReadRequested = false;
  bool _hasObservedHead = false, _countsDirty = true;
  String? _observedHeadKey;
  Object? _lastNotifiedState;
  Timer? _timer;
  StreamSubscription<OutboundSnapshot>? _headSubscription;
  Completer<void>? _headReady;
  OutboundSnapshot? _pendingSnapshot;
  Future<void> _idle = Future.value();
  String? _lastReason;
  String? _operationId, _roomId;
  int? _enqueueOrder, _attempt;
  DateTime? _nextRetryAt;
  int physicalAttemptCount = 0;
  int _throttleAttempt = 0;
  int queuedCount = 0, failedCount = 0, pausedCount = 0;
  bool get isRunning => _running;
  bool get isPaused => _paused;
  String? get lastReason => _lastReason;
  DateTime? get nextRetryAt => _nextRetryAt;
  Future<void> get idle => _idle;
  bool get _active => !_disposed && !_paused && isCurrentSession();

  void _healthChanged() {
    if (healthMonitor.isReady && !_scheduled) wake();
  }

  void wake() {
    _scheduleDrain(refresh: true, refreshActive: true);
  }

  /// The enqueuer has already committed a durable row. Prefer its observer
  /// result when delivered; otherwise obtain a fresh observed snapshot.
  void wakeAfterEnqueue() {
    _scheduleDrain(refresh: _pendingSnapshot?.head == null);
  }

  void _scheduleDrain({bool refresh = false, bool refreshActive = false}) {
    if (!_active) return;
    _wakeRequested = true;
    if (_scheduled) {
      if (refreshActive) _freshReadRequested = true;
      return;
    }
    _scheduled = true;
    _idle = _lane
        .add<void>(() async {
          if (refresh) {
            _pendingSnapshot = null;
            await _stopWatchingHead();
          }
          await _watchHead();
          do {
            _wakeRequested = false;
            await _drain();
          } while ((_wakeRequested || _freshReadRequested) && _active);
        })
        .catchError((Object failure) {
          if (!_active) return;
          // Local storage/logic failures must never become unbounded HTTP retries.
          _paused = true;
          _lastReason = 'local_storage_or_protocol';
          healthMonitor.stopRecovery();
          _record('paused', {'reason': _lastReason});
        })
        .whenComplete(() {
          _scheduled = false;
          unawaited(_watchHead());
          if ((_wakeRequested || _freshReadRequested) && _active) {
            _scheduleDrain();
          }
        });
  }

  Future<void> _drain() async {
    while (_active) {
      // Any wake received during the previous attempt is covered by this read.
      // A wake after the read remains pending for the lane's completion loop.
      _wakeRequested = false;
      if (_freshReadRequested) {
        // Retry/resume may commit after a watched snapshot's SQL read but
        // before delivery. Retain that control wake's freshness requirement;
        // ordinary enqueues are already covered by the active drain/observer.
        _freshReadRequested = false;
        _pendingSnapshot = null;
        await _stopWatchingHead();
      }
      var snapshot = _pendingSnapshot;
      _pendingSnapshot = null;
      snapshot ??= await database.outboundSnapshot(senderId);
      if (!_active) return;
      if (_freshReadRequested) continue;
      _applyCounts(snapshot);
      final head = snapshot.head;
      _hasObservedHead = true;
      _observedHeadKey = head?.idempotencyKey;
      if (head == null) {
        if (_headSubscription == null) {
          await _watchHead();
          continue;
        }
        _timer?.cancel();
        _timer = null;
        _operationId = null;
        _roomId = null;
        _enqueueOrder = null;
        _attempt = null;
        _nextRetryAt = null;
        _lastReason = null;
        healthMonitor.stopRecovery();
        _record('empty');
        return;
      }
      await _stopWatchingHead();
      if (!_active) return;
      if (_freshReadRequested) continue;
      _operationId = head.idempotencyKey;
      _roomId = head.roomId;
      _enqueueOrder = head.enqueueOrder;
      _attempt = head.retryCount;
      if (head.outboxPaused) {
        _timer?.cancel();
        _timer = null;
        _nextRetryAt = null;
        _lastReason = head.lastErrorCode ?? 'needs_attention';
        healthMonitor.stopRecovery();
        _record('head_paused', {'reason': _lastReason});
        return;
      }
      final due = head.nextAttemptAt;
      if (due != null && due.isAfter(_now())) {
        _schedule(due);
        return;
      }
      if (healthMonitor.status == ServerHealthStatus.unavailable &&
          !await healthMonitor.check()) {
        if (!_active) return;
        _lastReason = 'server_unavailable';
        _record('waiting_for_server', {'reason': _lastReason});
        return;
      }
      if (!_active) return;
      // Reread after the readiness await: an inbound acknowledgment may have won.
      final fresh = await database.messageByIdempotencyKey(
        senderId,
        head.idempotencyKey,
      );
      if (!_active) return;
      if (fresh == null || fresh.status == 'sent' || fresh.status == 'failed') {
        _countsDirty = true;
        await _refreshCounts();
        continue;
      }
      if (fresh.retryCount >= maxAttempts) {
        await _update(
          fresh.idempotencyKey,
          status: 'queued',
          paused: true,
          outcomeUnknown: true,
          errorCode: fresh.lastErrorCode ?? 'retry_budget_exhausted',
          errorMessage: fresh.lastErrorText ?? 'Sending paused after repeated failures. Retry to resume this message.',
          clearRetryAt: true,
        );
        if (_active) {
          _lastReason = 'retry_budget_exhausted';
          healthMonitor.stopRecovery();
          _record('needs_attention', {
            'reason': _lastReason,
            'attempt': fresh.retryCount,
          });
        }
        return;
      }
      var attempts = fresh.retryCount + 1;
      var burstRequests = 0;
      _timer?.cancel();
      _timer = null;
      await _update(
        fresh.idempotencyKey,
        status: 'sending',
        retryCount: attempts,
        clearRetryAt: true,
      );
      if (!_active) return;
      _running = true;
      _nextRetryAt = null;
      _record('attempt', {'attempt': attempts});
      try {
        Future<void> submit() => api.runOutboundAttempt(
          isCurrentSession: () => _active,
          canRetry: () => attempts < maxAttempts,
          onPhysicalAttempt: () async {
            final current = await database.messageByIdempotencyKey(
              senderId,
              fresh.idempotencyKey,
            );
            if (!_active || current == null || current.status == 'sent') {
              throw const ChatApiException(
                'The outgoing operation ended.',
                kind: ChatFailureKind.cancelled,
                code: 'outbound_retired',
              );
            }
            ++physicalAttemptCount;
            if (++burstRequests > 1) {
              ++attempts;
              await _update(fresh.idempotencyKey, retryCount: attempts);
            }
            _record('http_attempt', {
              'attempt': attempts,
              'physicalAttempts': physicalAttemptCount,
            });
          },
          operation: () => send(fresh),
        );
        final debug = inspector;
        if (debug == null) {
          await submit();
        } else {
          await debug.trace(
            'outbox',
            'send',
            submit,
            data: {'operationId': fresh.idempotencyKey, 'attempt': attempts},
            context: debug
                .captureContext()
                .copyWithIdentity(senderId)
                .copyWithRoom(fresh.roomId),
          );
        }
        if (!_active) return;
        _countsDirty = true;
        final acknowledged = await database.messageByIdempotencyKey(
          senderId,
          fresh.idempotencyKey,
        );
        if (!_active) return;
        if (acknowledged?.status != 'sent') {
          throw const ChatApiException(
            'The server acknowledgment could not be saved.',
            kind: ChatFailureKind.protocol,
            code: 'unconfirmed_acknowledgment',
          );
        }
        healthMonitor.markReady();
        _throttleAttempt = 0;
        _lastReason = null;
        await _refreshCounts(observe: true);
        _record('acknowledged');
      } catch (error) {
        if (!_active) return;
        _countsDirty = true;
        final existing = await database.messageByIdempotencyKey(
          senderId,
          fresh.idempotencyKey,
        );
        if (!_active) return;
        if (existing?.status == 'sent') continue;
        final failure = error is ChatApiException
            ? error
            : const ChatApiException(
                'Sending paused. Retry after checking this message.',
                kind: ChatFailureKind.protocol,
                code: 'local_or_protocol_failure',
              );
        if (await _handleFailure(fresh, failure, attempts)) return;
      } finally {
        _running = false;
        if (_active) await _refreshCounts();
        _record('attempt_finished');
      }
    }
  }

  Future<bool> _handleFailure(
    ChatMessage message,
    ChatApiException failure,
    int attempts,
  ) async {
    if (!_active) return true;
    final code = failure.code ?? failure.kind.name;
    final wasUncertain = message.outcomeUnknown || failure.outcomeUnknown;
    _lastReason = code;
    if (failure.statusCode == 401 ||
        failure.kind == ChatFailureKind.authentication) {
      await _update(
        message.idempotencyKey,
        status: 'queued',
        errorCode: code,
        errorMessage: failure.message,
        retryCount: message.retryCount,
        outcomeUnknown: wasUncertain,
      );
      if (_active) onAuthenticationRequired();
      pause();
      return true;
    }
    if (failure.isDefinitiveRejection) {
      await _update(
        message.idempotencyKey,
        status: wasUncertain ? 'queued' : 'failed',
        errorCode: code,
        errorMessage: failure.message,
        outcomeUnknown: wasUncertain,
        paused: wasUncertain,
        clearRetryAt: true,
      );
      _record(wasUncertain ? 'needs_attention' : 'rejected', {
        'reason': code,
        'status': failure.statusCode,
        'outcomeUnknown': wasUncertain,
      });
      return wasUncertain;
    }
    final throttled =
        failure.statusCode == 429 ||
        failure.kind == ChatFailureKind.rateLimited;
    if (throttled) {
      _throttleAttempt = (_throttleAttempt + 1).clamp(1, 5);
      final minimumDelay = _jitteredDelay(_throttleAttempt);
      final directive = failure.retryAfter;
      final deadline = _now().add(
        directive == null || directive < minimumDelay
            ? minimumDelay
            : directive,
      );
      await _update(
        message.idempotencyKey,
        status: 'queued',
        retryCount: message.retryCount,
        nextAttemptAt: deadline,
        errorCode: code,
        errorMessage: failure.message,
        outcomeUnknown: wasUncertain,
      );
      if (_active) _schedule(deadline);
      return true;
    }
    if (failure.kind == ChatFailureKind.cancelled) {
      await _update(
        message.idempotencyKey,
        status: 'queued',
        retryCount: message.retryCount,
        errorCode: code,
        errorMessage: failure.message,
        outcomeUnknown: true,
      );
      pause();
      return true;
    }
    if (failure.isTransient) {
      final ready = await healthMonitor.check(force: true);
      if (!_active) return true;
      if (!ready) {
        final directive = failure.retryAfter;
        final deadline = directive == null
            ? null
            : _now().add(directive < retryDelay ? retryDelay : directive);
        await _update(
          message.idempotencyKey,
          status: 'queued',
          retryCount: message.retryCount,
          errorCode: code,
          errorMessage: failure.message,
          outcomeUnknown: true,
          nextAttemptAt: deadline,
          clearRetryAt: deadline == null,
        );
        if (_active && deadline != null) _schedule(deadline);
        _record('waiting_for_server', {'reason': code});
        return true;
      }
      if (attempts < maxAttempts) {
        final minimum = _jitteredDelay(attempts);
        final directive = failure.retryAfter;
        final deadline = _now().add(
          directive == null || directive < minimum ? minimum : directive,
        );
        await _update(
          message.idempotencyKey,
          status: 'queued',
          nextAttemptAt: deadline,
          retryCount: attempts,
          errorCode: code,
          errorMessage: failure.message,
          outcomeUnknown: true,
        );
        if (_active) _schedule(deadline);
        return true;
      }
    }
    await _update(
      message.idempotencyKey,
      status: 'queued',
      paused: true,
      errorCode: code,
      errorMessage: failure.message,
      outcomeUnknown: true,
      clearRetryAt: true,
    );
    if (_active) {
      healthMonitor.stopRecovery();
      _record('needs_attention', {'reason': code, 'attempt': attempts});
    }
    return true;
  }

  Future<void> _update(
    String key, {
    String? status,
    int? retryCount,
    DateTime? nextAttemptAt,
    String? errorCode,
    String? errorMessage,
    bool? outcomeUnknown,
    bool? paused,
    bool clearError = false,
    bool clearRetryAt = false,
  }) => database.transaction(() async {
    // Recheck after obtaining SQLite's write lane, including same-account
    // reauthentication that preserves the original pending rows.
    if (!_active) return;
    await database.updateOutboundState(
      senderId,
      key,
      status: status,
      retryCount: retryCount,
      nextAttemptAt: nextAttemptAt,
      errorCode: errorCode,
      errorMessage: errorMessage,
      outcomeUnknown: outcomeUnknown,
      paused: paused,
      clearError: clearError,
      clearRetryAt: clearRetryAt,
    );
    if (_active && key == _operationId && retryCount != null) {
      _attempt = retryCount;
    }
    if (status == 'failed' || paused != null) _countsDirty = true;
    await _refreshCounts();
  });

  Future<void> _refreshCounts({bool observe = false}) async {
    if (!_countsDirty) return;
    OutboundSnapshot? snapshot;
    if (observe) {
      await _watchHead();
      snapshot = _pendingSnapshot;
    } else {
      snapshot = await database.outboundSnapshot(senderId);
      _pendingSnapshot = snapshot;
    }
    if (!_active) return;
    if (snapshot == null) {
      throw StateError('The outbound snapshot could not be read.');
    }
    _applyCounts(snapshot);
  }

  void _applyCounts(OutboundSnapshot snapshot) {
    _countsDirty = false;
    queuedCount = snapshot.queued;
    failedCount = snapshot.failed;
    pausedCount = snapshot.paused;
  }

  Duration _jitteredDelay(int attempts) {
    final factor = 1 << (attempts - 1).clamp(0, 4);
    return Duration(
      milliseconds:
          (retryDelay.inMilliseconds * factor * (0.5 + _random() * 0.5)).ceil(),
    );
  }

  void _schedule(DateTime deadline) {
    if (!_active) return;
    _timer?.cancel();
    _nextRetryAt = deadline;
    final delay = deadline.difference(_now());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timer = null;
      wake();
    });
    _record('waiting', {'nextRetryAt': deadline.toUtc().toIso8601String()});
  }

  Future<void> retry(ChatMessage message) async {
    if (_disposed || !isCurrentSession() || message.senderId != senderId) {
      return;
    }
    await database.transaction(() async {
      if (_disposed || !isCurrentSession()) return;
      await database.retryOutboundMessage(senderId, message.idempotencyKey);
    });
    if (!_disposed && isCurrentSession()) {
      _paused = false;
      healthMonitor.setActive(true);
      wake();
    }
  }

  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
    healthMonitor.setActive(false);
  }

  void resume() {
    if (_disposed) return;
    _paused = false;
    healthMonitor.setActive(true);
    wake();
  }

  void _record(String event, [Map<String, Object?> data = const {}]) {
    if (_disposed || !isCurrentSession()) return;
    inspector?.record(
      'outbox',
      event,
      data: {
        if (_operationId != null) 'operationId': _operationId,
        if (_enqueueOrder != null) 'enqueueOrder': _enqueueOrder,
        if (_attempt != null) 'attempt': _attempt,
        if (_attempt != null) 'retryCount': _attempt,
        if (_lastReason != null) 'reason': _lastReason,
        if (_nextRetryAt != null)
          'nextRetryAt': _nextRetryAt!.toUtc().toIso8601String(),
        'queuedCount': queuedCount,
        'failedCount': failedCount,
        'pausedCount': pausedCount,
        'sessionPhysicalAttempts': physicalAttemptCount,
        'running': _running,
        'queuePaused': _paused,
        'healthStatus': healthMonitor.status.name,
        ...data,
      },
      context: inspector
          ?.captureContext()
          .copyWithIdentity(senderId)
          .copyWithRoom(_roomId),
    );
    inspector?.setGauges({
      'outbox.running': _running ? 1 : 0,
      'outbox.physicalAttempts': physicalAttemptCount,
      'outbox.queued': queuedCount,
      'outbox.failed': failedCount,
      'outbox.paused': pausedCount,
    });
    final state = (
      running: _running,
      paused: _paused,
      queued: queuedCount,
      failed: failedCount,
      needsAttention: pausedCount,
      physicalAttempts: physicalAttemptCount,
      health: healthMonitor.status,
      retryAt: _nextRetryAt,
      reason: _lastReason,
    );
    if (state != _lastNotifiedState) {
      _lastNotifiedState = state;
      onStateChanged?.call();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    final ready = _headReady;
    if (ready != null && !ready.isCompleted) ready.complete();
    unawaited(_headSubscription?.cancel());
    _headSubscription = null;
    api.cancelOutboundRequests();
    healthMonitor.removeListener(_healthChanged);
    healthMonitor.dispose();
    _lane.dispose();
  }
}
