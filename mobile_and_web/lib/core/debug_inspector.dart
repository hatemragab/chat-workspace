import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'local_log_exporter.dart';
import 'debug_traffic_logger.dart';
import 'sqlite_query_details.dart';

/// A controller-local, opt-in debug timeline. HTTP/SQLite payloads additionally
/// require full debug capture; credentials and binary bytes remain excluded.
///
/// Its notifier is independent of application state. Only timeline and control
/// changes notify; build, frame and gauge sampling cannot cause a rebuild loop.
final class DebugInspector extends ChangeNotifier {
  DebugInspector({bool enabled = false, LocalLogExporter? localLogExporter})
    : _enabled = kDebugMode && enabled,
      _localLogExporter = localLogExporter ?? LocalLogExporter() {
    _localLogExporter.setRecording(_recording);
    _localLogExporter.addListener(_scheduleRefresh);
    if (_enabled) _attachFrames();
  }

  static const eventLimit = 500;
  static const activeSpanLimit = 64;
  static const _aggregateLimit = 100;
  static const _metricLimit = 64;
  static const _frameLimit = 120;
  static const _frameBudgetMicros = 16667;
  static const _refreshInterval = Duration(milliseconds: 250);
  static final _zoneKey = Object();
  final _contextOwner = Object();
  final LocalLogExporter _localLogExporter;

  bool _enabled;
  bool _paused = false;
  bool _disposed = false;
  bool _sqliteDetailsEnabled = false;
  int _sqliteEpoch = 0;
  bool _httpDetailsEnabled = false;
  int _httpEpoch = 0;
  bool _realtimeDetailsEnabled = false;
  bool _framesAttached = false;
  int _epoch = 0;
  int _sequence = 0;
  int _identity = 0;
  int _droppedEvents = 0;
  int _droppedSpans = 0;
  int _overflowSpans = 0;
  int _activeSpanCount = 0;
  int _aggregateOverflow = 0;
  int _buildOverflow = 0;
  int _gaugeOverflow = 0;
  int _frameCount = 0;
  int _overBudgetFrames = 0;
  Timer? _refreshTimer;
  DebugTraceContext _context = const DebugTraceContext();
  final _events = Queue<Map<String, Object?>>();
  final _active = <String, DebugSpan>{};
  final _aggregates = <String, _DebugAggregate>{};
  final _gauges = <String, int>{};
  final _builds = <String, int>{};
  final _frames = Queue<({int build, int raster, int total})>();

  bool get enabled => kDebugMode && _enabled && !_disposed;
  bool get paused => _paused;
  int get captureGeneration => _epoch;
  bool get _recording => enabled && !_paused;
  bool get sqliteDetailsEnabled =>
      kDebugMode && _sqliteDetailsEnabled && !_disposed;
  bool get httpDetailsEnabled =>
      kDebugMode && _httpDetailsEnabled && !_disposed;
  bool get realtimeDetailsEnabled =>
      kDebugMode && _realtimeDetailsEnabled && !_disposed;

  void setRealtimeDetailsEnabled(bool value) {
    if (_disposed) return;
    final next = kDebugMode && value;
    if (next == _realtimeDetailsEnabled) return;
    _realtimeDetailsEnabled = next;
    if (!next) _retireDetails('realtime');
    _notifySafely();
  }

  void setHttpDetailsEnabled(bool value) {
    if (_disposed) return;
    final next = kDebugMode && value;
    if (next == _httpDetailsEnabled) return;
    _httpDetailsEnabled = next;
    _httpEpoch++;
    if (!next) _retireDetails('http');
    _notifySafely();
  }

  void _retireDetails(String key) {
    _localLogExporter.retire();
    final metadataOnly = _events.map((event) {
      final data = event['data']! as Map<String, Object?>;
      return Map<String, Object?>.unmodifiable({
        ...event,
        'data': Map<String, Object?>.unmodifiable({...data}..remove(key)),
      });
    }).toList();
    _events
      ..clear()
      ..addAll(metadataOnly);
  }

  void setSqliteDetailsEnabled(bool value) {
    if (_disposed) return;
    final next = kDebugMode && value;
    if (next == _sqliteDetailsEnabled) return;
    _sqliteDetailsEnabled = next;
    _sqliteEpoch++;
    if (!next) {
      for (final span in _active.values) {
        span._sqliteDetails = null;
      }
      _retireDetails('sqlite');
    }
    _notifySafely();
  }

  /// Independent debug opt-in. Pausing/disabling capture preserves this choice
  /// but retires pending delivery. Only newly captured events can be shared.
  void setShareWithLocalLogs(bool value) {
    if (_disposed) return;
    _localLogExporter.setEnabled(value);
    _notifySafely();
  }

  void setEnabled(bool value) {
    if (_disposed) return;
    final next = kDebugMode && value;
    if (next == _enabled) return;
    _enabled = next;
    _paused = false;
    _localLogExporter.setRecording(_recording);
    _invalidate();
    _resetData();
    if (next) {
      _attachFrames();
    } else {
      _detachFrames();
    }
    _notifySafely();
  }

  void setPaused(bool value) {
    if (_disposed || value == _paused) return;
    _paused = value;
    _localLogExporter.setRecording(_recording);
    _invalidate();
    if (value) {
      _detachFrames();
    } else if (enabled) {
      _attachFrames();
    }
    _notifySafely();
  }

  void clear() {
    if (_disposed) return;
    _localLogExporter.retire(resetCounters: true);
    _invalidate();
    _resetData();
    _notifySafely();
  }

  /// The identity is copied at each operation's start, including across awaits.
  /// Passing null clears a field (for example, after logout or room close).
  void updateContext({String? userId, int? sessionGeneration, String? roomId}) {
    if (_disposed) return;
    _context = DebugTraceContext(
      userId: _safeIdentifier(userId),
      sessionGeneration: sessionGeneration,
      roomId: _safeIdentifier(roomId),
    );
  }

  DebugTraceContext captureContext({bool detached = false}) {
    final zone = Zone.current[_zoneKey];
    if (!detached && zone is _DebugZone && identical(zone.owner, this)) {
      // Keep an invalidated operation's original epoch. Falling back to current
      // context here would let its later children reappear after clear/restart.
      return zone.context;
    }
    return DebugTraceContext._(
      userId: _context.userId,
      sessionGeneration: _context.sessionGeneration,
      roomId: _context.roomId,
      owner: _contextOwner,
      epoch: _epoch,
    );
  }

  /// A timer, subscription or lifecycle callback is a new operation rather than
  /// a continuation of the trace that originally registered the callback.
  /// Re-enter here on each invocation to capture the current epoch and identity.
  T runIndependent<T>(T Function() action) {
    if (!_recording) return action();
    return runZoned<T>(
      action,
      zoneValues: {
        _zoneKey: _DebugZone(this, _epoch, captureContext(detached: true)),
      },
    );
  }

  void record(
    String category,
    String name, {
    Map<String, Object?> data = const {},
    int? durationMicros,
    DebugTraceContext? context,
    DebugRealtimeTrafficDetails? realtimeDetails,
  }) {
    if (!_recording) return;
    try {
      final captured = context ?? captureContext();
      if (!_validContext(captured)) return;
      _append(
        category,
        name,
        'instant',
        captured,
        Map.unmodifiable({
          ..._safeData(data),
          if (category == 'realtime' &&
              realtimeDetailsEnabled &&
              realtimeDetails?.isCurrent == true)
            'realtime': realtimeDetails!.values,
        }),
        durationMicros: durationMicros,
      );
    } catch (_) {
      // A diagnostic must never interrupt the operation it observes.
    }
  }

  DebugSpan? begin(
    String category,
    String name, {
    Map<String, Object?> data = const {},
    DebugTraceContext? context,
    SqliteQueryDetails Function()? sqlite,
  }) {
    if (!_recording) return null;
    try {
      final parent = context ?? captureContext();
      if (!_validContext(parent)) return null;
      // Only the optional DevTools registry is capped. The caller already owns
      // this in-flight operation, so its lightweight handle can still finish a
      // causal begin/end pair without an unbounded inspector-owned registry.
      final registered = _active.length < activeSpanLimit;
      if (!registered) _overflowSpans++;
      final safeCategory = _safeLabel(category);
      final safeName = _safeLabel(name);
      final spanContext = DebugTraceContext._(
        userId: parent.userId,
        sessionGeneration: parent.sessionGeneration,
        roomId: parent.roomId,
        traceId: _safeIdentifier(parent.traceId) ?? 't${++_identity}',
        spanId: 's${++_identity}',
        parentSpanId: _safeIdentifier(parent.spanId),
        owner: _contextOwner,
        epoch: _epoch,
      );
      final span = DebugSpan._(
        this,
        _epoch,
        safeCategory,
        safeName,
        spanContext,
        _safeData(data),
        registered,
      );
      if (httpDetailsEnabled && safeCategory == 'http') {
        span._httpEpoch = _httpEpoch;
      }
      if (sqliteDetailsEnabled &&
          sqlite != null &&
          safeCategory == 'drift' &&
          safeName.startsWith('query.')) {
        span._sqliteEpoch = _sqliteEpoch;
        if (registered) {
          try {
            span._sqliteDetails = sqlite();
          } catch (_) {
            /* Metadata still completes. */
          }
        }
      }
      _activeSpanCount++;
      if (registered) {
        _active[spanContext.spanId!] = span;
        _startTimelineTask(span, _active[parent.spanId]);
      }
      _append(
        safeCategory,
        safeName,
        'begin',
        spanContext,
        Map.unmodifiable({...span._data, ..._sqliteData(span)}),
      );
      return span;
    } catch (_) {
      return null;
    }
  }

  Future<T> trace<T>(
    String category,
    String name,
    Future<T> Function() action, {
    Map<String, Object?> data = const {},
    DebugTraceContext? context,
  }) {
    final span = begin(category, name, data: data, context: context);
    if (span == null) return action();
    return runZoned<Future<T>>(() async {
      try {
        final result = await action();
        span.finish();
        return result;
      } catch (error) {
        span.finish(error: error);
        rethrow;
      }
    }, zoneValues: {_zoneKey: _DebugZone(this, _epoch, span._context)});
  }

  /// Named gauges merge across samplers; callers explicitly report zero when a
  /// resource closes. The number of names is bounded and sampling never notifies.
  void setGauges(Map<String, int> values) {
    if (!_recording) return;
    try {
      var count = 0;
      for (final entry in values.entries) {
        if (count++ >= _metricLimit * 2) {
          _gaugeOverflow++;
          break;
        }
        final key = _safeLabel(entry.key);
        if (!_gauges.containsKey(key) && _gauges.length >= _metricLimit) {
          _gaugeOverflow++;
          continue;
        }
        _gauges[key] = entry.value;
      }
    } catch (_) {
      // Sampling is best effort and must not affect controller state.
    }
  }

  void recordBuild(
    String widgetName, {
    DebugTraceContext? context,
    int? notificationId,
  }) {
    if (!_recording) return;
    try {
      final name = _safeLabel(widgetName);
      if (!_builds.containsKey(name) && _builds.length >= _metricLimit) {
        _buildOverflow++;
        return;
      }
      _builds[name] = (_builds[name] ?? 0) + 1;
      final captured = context ?? captureContext();
      if (!_validContext(captured)) return;
      _append(
        'widget',
        'build:$name',
        'instant',
        captured,
        Map<String, Object?>.unmodifiable({'notificationId': ?notificationId}),
        notify: false,
      );
    } catch (_) {
      // Widget instrumentation must never break a build.
    }
  }

  /// Explicit local-log counter export; the UI calls this only for its Refresh
  /// button. No polling, build instrumentation or automatic snapshot reads can
  /// generate these records. The records do not update duration aggregates.
  void exportMetricsSnapshot() {
    if (!_recording || !_localLogExporter.enabled) return;
    try {
      final context = captureContext(detached: true);
      final gauges = Map<String, int>.of(_gauges);
      final builds = Map<String, int>.of(_builds);
      final aggregates = _aggregates.values
          .map((item) => item.snapshot())
          .toList();
      final frames = _frames.toList(growable: false);
      final resources = <String, int>{
        'eventCount': _events.length,
        'activeSpans': _activeSpanCount,
        'trackedSpans': _active.length,
        'overflowSpans': _overflowSpans,
        'droppedEvents': _droppedEvents,
        'droppedSpans': _droppedSpans,
        'aggregateOverflow': _aggregateOverflow,
        'buildOverflow': _buildOverflow,
        'gaugeOverflow': _gaugeOverflow,
      };
      void metric(String source, String operation, int count) => _append(
        'inspector',
        'metric.$source.$operation',
        'instant',
        context,
        _safeData({'source': source, 'operation': operation, 'count': count}),
        notify: false,
        aggregate: false,
      );

      final delivery = _localLogExporter.snapshot();
      for (final key in [
        'sentEvents',
        'queuedEvents',
        'droppedEvents',
        'sampledEvents',
        'evictedNoiseEvents',
        'droppedImportantEvents',
        'droppedCriticalEvents',
        'retriedBatches',
        'retriedEvents',
        'pendingRetryEvents',
        'pendingImportantEvents',
        'failedBatches',
        'retiredEvents',
        'uncertainEvents',
      ]) {
        final value = delivery[key];
        if (value is int) metric('delivery', key, value);
      }
      for (final entry in gauges.entries) {
        metric('gauges', entry.key, entry.value);
      }
      for (final entry in builds.entries) {
        metric('builds', entry.key, entry.value);
      }
      for (final entry in resources.entries) {
        metric('resources', entry.key, entry.value);
      }
      metric(
        'frames',
        kIsWeb ? 'web_unavailable' : 'native_frame_timing',
        _frameCount,
      );
      metric('frames', 'overBudgetCount', _overBudgetFrames);
      for (final entry in {
        'p95BuildMicros': _p95(frames.map((frame) => frame.build)),
        'p95RasterMicros': _p95(frames.map((frame) => frame.raster)),
        'p95TotalMicros': _p95(frames.map((frame) => frame.total)),
      }.entries) {
        if (entry.value != null) metric('frames', entry.key, entry.value!);
      }
      for (final item in aggregates) {
        final operation = '${item['category']}/${item['name']}';
        _append(
          'inspector',
          'aggregate.$operation',
          'instant',
          context,
          _safeData({
            'source': 'aggregates',
            'operation': operation,
            'count': item['count'],
            'microseconds': item['totalMicros'],
            'durationMs': (item['maxMicros'] as int? ?? 0) / 1000,
          }),
          notify: false,
          aggregate: false,
        );
        metric('aggregate_errors', operation, item['errorCount'] as int);
      }
    } catch (_) {
      // A manual diagnostic export cannot alter application operations.
    }
  }

  Map<String, Object?> snapshot() {
    final samples = _frames.toList(growable: false);
    return Map<String, Object?>.unmodifiable({
      'enabled': enabled,
      'paused': paused,
      'sqliteDetailsEnabled': sqliteDetailsEnabled,
      'httpDetailsEnabled': httpDetailsEnabled,
      'realtimeDetailsEnabled': realtimeDetailsEnabled,
      'localLogs': _localLogExporter.snapshot(),
      'context': Map<String, Object?>.unmodifiable({
        'userId': _context.userId,
        'sessionGeneration': _context.sessionGeneration,
        'roomId': _context.roomId,
      }),
      'events': List<Map<String, Object?>>.unmodifiable(_events),
      'aggregates': List<Map<String, Object?>>.unmodifiable(
        _aggregates.values.map((value) => value.snapshot()),
      ),
      'gauges': Map<String, int>.unmodifiable(_gauges),
      'builds': Map<String, int>.unmodifiable(_builds),
      'frames': Map<String, Object?>.unmodifiable({
        'supported': !kIsWeb,
        'reason': kIsWeb ? 'web_unavailable' : 'native_frame_timing',
        'callbackAttached': _framesAttached,
        'count': _frameCount,
        'sampleLimit': _frameLimit,
        'frameBudgetMicros': _frameBudgetMicros,
        'budgetKind': 'heuristic_60hz',
        'overBudgetCount': _overBudgetFrames,
        'p95BuildMicros': _p95(samples.map((frame) => frame.build)),
        'p95RasterMicros': _p95(samples.map((frame) => frame.raster)),
        'p95TotalMicros': _p95(samples.map((frame) => frame.total)),
        'recent': List<Map<String, Object?>>.unmodifiable(
          samples.map(
            (frame) => Map<String, Object?>.unmodifiable({
              'buildMicros': frame.build,
              'rasterMicros': frame.raster,
              'totalMicros': frame.total,
            }),
          ),
        ),
      }),
      'resources': Map<String, Object?>.unmodifiable({
        'eventLimit': eventLimit,
        'activeSpanLimit': activeSpanLimit,
        'activeSpans': _activeSpanCount,
        'trackedSpans': _active.length,
        'overflowSpans': _overflowSpans,
        'eventCount': _events.length,
        'droppedEvents': _droppedEvents,
        'droppedSpans': _droppedSpans,
        'aggregateCount': _aggregates.length,
        'aggregateOverflow': _aggregateOverflow,
        'buildOverflow': _buildOverflow,
        'gaugeOverflow': _gaugeOverflow,
      }),
    });
  }

  bool _validContext(DebugTraceContext context) =>
      context._owner == null ||
      (identical(context._owner, _contextOwner) && context._epoch == _epoch);

  Map<String, Object?> _sqliteData(
    DebugSpan span, {
    Object? result,
    bool completed = false,
    bool failed = false,
    bool cancelled = false,
  }) {
    if (!sqliteDetailsEnabled || span._sqliteEpoch != _sqliteEpoch) {
      return const {};
    }
    try {
      return {
        'sqlite':
            span._sqliteDetails?.snapshot(
              result: result,
              completed: completed,
              failed: failed,
              cancelled: cancelled,
            ) ??
            const {
              'policy': 'full_debug',
              'database': 'chat_app_db',
              'payloadOmitted': true,
              'omissionReason': 'span_capacity_or_inspection_failure',
            },
      };
    } catch (_) {
      return const {};
    }
  }

  void _finish(
    DebugSpan span,
    Map<String, Object?> data,
    Object? error,
    Object? sqliteResult,
    DebugHttpTrafficDetails? httpDetails,
  ) {
    if (!_recording ||
        span._epoch != _epoch ||
        (span._registered &&
            !identical(_active.remove(span._context.spanId), span))) {
      span._cancel();
      return;
    }
    _activeSpanCount--;
    try {
      final safe = Map<String, Object?>.unmodifiable({
        ...span._data,
        ..._safeData(data),
        if (httpDetailsEnabled &&
            span._category == 'http' &&
            span._httpEpoch == _httpEpoch &&
            httpDetails != null)
          'http': httpDetails.values,
        ..._sqliteData(
          span,
          result: sqliteResult,
          completed: true,
          failed: error != null,
          cancelled: data['outcome'] == 'cancelled',
        ),
        if (error != null)
          'errorType': _safeLabel(error.runtimeType.toString()),
      });
      _append(
        span._category,
        span._name,
        'end',
        span._context,
        safe,
        durationMicros: span._clock.elapsedMicroseconds,
      );
    } catch (_) {
      // Completion tracing cannot replace the actual result or exception.
    } finally {
      span._cancel();
    }
  }

  void _append(
    String category,
    String name,
    String phase,
    DebugTraceContext context,
    Map<String, Object?> data, {
    int? durationMicros,
    bool notify = true,
    bool aggregate = true,
  }) {
    final safeCategory = _safeLabel(category);
    final safeName = _safeLabel(name);
    final duration = durationMicros == null
        ? null
        : (durationMicros < 0 ? 0 : durationMicros);
    final event = Map<String, Object?>.unmodifiable({
      'seq': ++_sequence,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'category': safeCategory,
      'name': safeName,
      'phase': phase,
      'traceId': _safeIdentifier(context.traceId),
      'spanId': _safeIdentifier(context.spanId),
      'parentSpanId': _safeIdentifier(context.parentSpanId),
      'userId': _safeIdentifier(context.userId),
      'sessionGeneration': context.sessionGeneration,
      'roomId': _safeIdentifier(context.roomId),
      'durationMicros': duration,
      'data': data,
    });
    try {
      // Stream the immutable sanitized record at append time. Export does not
      // poll retained rows, so ring eviction or reopening the UI cannot replay.
      _localLogExporter.addInspectorRecord(event);
    } catch (_) {
      // Diagnostic delivery cannot interrupt capture or application execution.
    }
    if (_events.length >= eventLimit) {
      final priority = LocalLogExporter.priorityForRecord(event);
      Map<String, Object?>? evicted;
      for (var lower = 0; lower <= priority && evicted == null; lower++) {
        evicted = _events.cast<Map<String, Object?>?>().firstWhere(
          (value) => LocalLogExporter.priorityForRecord(value!) == lower,
          orElse: () => null,
        );
      }
      if (evicted != null) _events.remove(evicted);
      _droppedEvents++;
      if (evicted != null) _events.add(event);
    } else {
      _events.add(event);
    }
    if (aggregate && phase != 'begin') {
      final key = '$safeCategory/$safeName';
      final isError = data['errorType'] != null || data['level'] == 'error';
      final aggregate = _aggregates[key];
      if (aggregate != null) {
        aggregate.add(duration, isError);
      } else if (_aggregates.length < _aggregateLimit) {
        _aggregates[key] = _DebugAggregate(safeCategory, safeName)
          ..add(duration, isError);
      } else {
        _aggregateOverflow++;
      }
    }
    if (notify) _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (_refreshTimer != null || !_recording) return;
    _refreshTimer = Timer(_refreshInterval, () {
      _refreshTimer = null;
      if (_recording) _notifySafely();
    });
  }

  void _notifySafely() {
    if (_disposed) return;
    try {
      notifyListeners();
    } catch (_) {
      // The inspector is never part of the application's correctness path.
    }
  }

  void _invalidate() {
    _epoch++;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    for (final span in _active.values) {
      span._cancel();
    }
    _active.clear();
    _activeSpanCount = 0;
  }

  void _resetData() {
    _events.clear();
    _aggregates.clear();
    _gauges.clear();
    _builds.clear();
    _frames.clear();
    _droppedEvents = 0;
    _droppedSpans = 0;
    _overflowSpans = 0;
    _aggregateOverflow = 0;
    _buildOverflow = 0;
    _gaugeOverflow = 0;
    _frameCount = 0;
    _overBudgetFrames = 0;
  }

  void _attachFrames() {
    if (!kDebugMode || kIsWeb || _framesAttached || !_recording) return;
    try {
      WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
      _framesAttached = true;
    } catch (_) {
      // A headless controller may be constructed before a binding exists.
    }
  }

  void _detachFrames() {
    if (!_framesAttached) return;
    try {
      WidgetsBinding.instance.removeTimingsCallback(_onFrameTimings);
    } catch (_) {
      // A binding can be torn down independently in a test or shutdown.
    }
    _framesAttached = false;
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!_recording || kIsWeb) return;
    for (final timing in timings) {
      final frame = (
        build: timing.buildDuration.inMicroseconds,
        raster: timing.rasterDuration.inMicroseconds,
        total: timing.totalSpan.inMicroseconds,
      );
      _frameCount++;
      if (frame.total > _frameBudgetMicros) _overBudgetFrames++;
      _frames.add(frame);
      if (_frames.length > _frameLimit) _frames.removeFirst();
    }
  }

  static int? _p95(Iterable<int> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) return null;
    return sorted[((sorted.length * .95).ceil() - 1).clamp(
      0,
      sorted.length - 1,
    )];
  }

  static void _startTimelineTask(DebugSpan span, DebugSpan? parent) {
    if (!kDebugMode || kIsWeb) return;
    try {
      span._task = developer.TimelineTask(parent: parent?._task)
        ..start('${span._category}.${span._name}', arguments: span._data);
    } catch (_) {
      span._task = null;
    }
  }

  // Explicit metadata keys keep a mislabeled business object out of diagnostics.
  // Strings must also be bounded technical identifiers; free-form content is not
  // accepted even under an otherwise approved key.
  static const _metadataKeys = {
    'direction',
    'protocolId',
    'connectionId',
    'packetBytes',
    'method',
    'path',
    'route',
    'status',
    'statusCode',
    'errorType',
    'level',
    'reason',
    'source',
    'eventType',
    'stage',
    'correlationKey',
    'channel',
    'requestId',
    'pts',
    'roomPts',
    'msgPts',
    'localPts',
    'messagesSyncedPts',
    'lastHistoryEditPts',
    'sincePts',
    'targetPts',
    'epoch',
    'count',
    'rows',
    'roomCount',
    'messageCount',
    'cached',
    'cacheHit',
    'operation',
    'table',
    'transactionId',
    'connectionState',
    'attempt',
    'operationId',
    'enqueueOrder',
    'retryCount',
    'nextRetryAt',
    'physicalAttempts',
    'sessionPhysicalAttempts',
    'queuedCount',
    'failedCount',
    'pausedCount',
    'running',
    'queuePaused',
    'healthStatus',
    'previousStatus',
    'outcomeUnknown',
    'queueDepth',
    'pendingCount',
    'historyEdited',
    'recovered',
    'fullSync',
    'widget',
    'bytes',
    'microseconds',
    'durationMs',
    'outcome',
    'busy',
    'initialized',
    'isJumpMode',
    'hasMoreMessages',
    'selectedRoomId',
    'userChanged',
    'changed',
    'notificationId',
    'changedFields',
    'socketSubscriptions',
    'roomsSubscription',
    'messagesSubscription',
    'roomEventsSubscription',
    'presenceTimer',
    'highlightTimer',
    'lifecycleObserver',
    'roomRecoveries',
    'draftAdoptions',
    'directLookups',
    'sessionStopping',
    'roomId',
    'userId',
    'sessionGeneration',
    'argumentCount',
    'rowCount',
    'affectedRows',
    'statementCount',
    'executionCount',
    'watch',
    'limit',
    'generation',
    'pending',
    'invalidated',
    'fromPts',
    'toPts',
    'mode',
    'epochMatches',
    'hasRoom',
    'hasMessage',
  };
  static final _identifier = RegExp(r'^[a-zA-Z0-9_./:#<>-]+$');

  static String _safeLabel(String value) {
    if (value.isEmpty || !_identifier.hasMatch(value)) return '[invalid]';
    if (RegExp(r'\beyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\b')
        .hasMatch(value)) {
      return '[redacted]';
    }
    return value.length > 120 ? '${value.substring(0, 117)}...' : value;
  }

  static String? _safeIdentifier(String? value) =>
      value == null ? null : _safeLabel(value);

  static Map<String, Object?> _safeData(
    Map<String, Object?> values, [
    int depth = 0,
    _DebugDataBudget? budget,
  ]) {
    if (depth >= 3) return const {};
    final remaining = budget ?? _DebugDataBudget();
    final safe = <String, Object?>{};
    for (final entry in values.entries) {
      if (remaining.entries-- <= 0) break;
      if (!_metadataKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (value == null || value is bool || value is int) {
        safe[entry.key] = value;
      } else if (value is double && value.isFinite) {
        safe[entry.key] = value;
      } else if (value is String) {
        safe[entry.key] = entry.key == 'path' || entry.key == 'route'
            ? _safeRoute(value)
            : _safeLabel(value);
      } else if (value is Map<String, Object?>) {
        safe[entry.key] = _safeData(value, depth + 1, remaining);
      } else if (value is Iterable &&
          (entry.key == 'changed' || entry.key == 'changedFields')) {
        safe[entry.key] = List<String>.unmodifiable(
          value.take(16).whereType<String>().map(_safeLabel),
        );
      }
    }
    return Map<String, Object?>.unmodifiable(safe);
  }

  static String _safeRoute(String value) {
    try {
      final path = Uri.parse(value).path;
      return _safeLabel(path.isEmpty ? '/' : path);
    } catch (_) {
      return '[invalid]';
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _localLogExporter.removeListener(_scheduleRefresh);
    _localLogExporter.dispose();
    _invalidate();
    _detachFrames();
    _resetData();
    _context = const DebugTraceContext();
    _enabled = false;
    _disposed = true;
    super.dispose();
  }
}

/// An immutable causal and session snapshot. Public construction is useful when
/// a caller already owns an operation identity; captured contexts additionally
/// carry the inspector epoch so cleared/disabled operations cannot reappear.
final class DebugTraceContext {
  const DebugTraceContext({
    this.userId,
    this.sessionGeneration,
    this.roomId,
    this.traceId,
    this.spanId,
    this.parentSpanId,
  }) : _owner = null,
       _epoch = null;

  const DebugTraceContext._({
    this.userId,
    this.sessionGeneration,
    this.roomId,
    this.traceId,
    this.spanId,
    this.parentSpanId,
    required this._owner,
    required this._epoch,
  });

  final String? userId;
  final int? sessionGeneration;
  final String? roomId;
  final String? traceId;
  final String? spanId;
  final String? parentSpanId;
  final Object? _owner;
  final int? _epoch;

  DebugTraceContext copyWithIdentity(String? userId) => DebugTraceContext._(
    userId: DebugInspector._safeIdentifier(userId),
    sessionGeneration: sessionGeneration,
    roomId: roomId,
    traceId: traceId,
    spanId: spanId,
    parentSpanId: parentSpanId,
    owner: _owner,
    epoch: _epoch,
  );

  DebugTraceContext copyWithRoom(String? roomId) => DebugTraceContext._(
    userId: userId,
    sessionGeneration: sessionGeneration,
    roomId: DebugInspector._safeIdentifier(roomId),
    traceId: traceId,
    spanId: spanId,
    parentSpanId: parentSpanId,
    owner: _owner,
    epoch: _epoch,
  );
}

final class DebugSpan {
  DebugSpan._(
    this._owner,
    this._epoch,
    this._category,
    this._name,
    this._context,
    this._data,
    this._registered,
  );

  DebugInspector? _owner;
  final int _epoch;
  final String _category;
  final String _name;
  final DebugTraceContext _context;
  final Map<String, Object?> _data;
  final bool _registered;
  SqliteQueryDetails? _sqliteDetails;
  int _sqliteEpoch = -1;
  int _httpEpoch = -1;
  final _clock = Stopwatch()..start();
  developer.TimelineTask? _task;

  void finish({
    Map<String, Object?> data = const {},
    Object? error,
    Object? sqliteResult,
    DebugHttpTrafficDetails? httpDetails,
  }) {
    final owner = _owner;
    if (owner == null) return;
    owner._finish(this, data, error, sqliteResult, httpDetails);
  }

  void _cancel() {
    _owner = null;
    _sqliteDetails = null;
    _clock.stop();
    try {
      _task?.finish();
    } catch (_) {
      // DevTools timeline support varies by runtime.
    }
    _task = null;
  }
}

final class _DebugZone {
  const _DebugZone(this.owner, this.epoch, this.context);
  final DebugInspector owner;
  final int epoch;
  final DebugTraceContext context;
}

final class _DebugDataBudget {
  int entries = 32;
}

final class _DebugAggregate {
  _DebugAggregate(this.category, this.name);
  final String category;
  final String name;
  int count = 0;
  int totalMicros = 0;
  int? minMicros;
  int? maxMicros;
  int errorCount = 0;

  void add(int? duration, bool error) {
    count++;
    if (error) errorCount++;
    if (duration == null) return;
    totalMicros += duration;
    if (minMicros == null || duration < minMicros!) minMicros = duration;
    if (maxMicros == null || duration > maxMicros!) maxMicros = duration;
  }

  Map<String, Object?> snapshot() => Map<String, Object?>.unmodifiable({
    'category': category,
    'name': name,
    'count': count,
    'totalMicros': totalMicros,
    'minMicros': minMicros,
    'maxMicros': maxMicros,
    'errorCount': errorCount,
  });
}
