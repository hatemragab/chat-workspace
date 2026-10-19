import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'local_log_transport_native.dart'
    if (dart.library.js_interop) 'local_log_transport_web.dart';

/// Bounded delivery of metadata and opt-in HTTP/realtime/SQLite details.
///
/// This client is separate from ChatApi: exporting an inspector HTTP event must
/// never create another inspector event. A stable batch ID makes temporary
/// failures retryable against the collector's bounded dedupe acknowledgement.
/// No backlog survives this object or an explicit capture/privacy retirement.
final class LocalLogExporter extends ChangeNotifier {
  LocalLogExporter({
    Dio? client,
    String endpoint = const String.fromEnvironment(
      'LOCAL_LOGS_URL',
      defaultValue: 'http://127.0.0.1:8083/events',
    ),
    String? instanceId,
    this.flushInterval = const Duration(milliseconds: 100),
  }) : instanceId = instanceId ?? const Uuid().v4(),
       _endpoint = parseEndpoint(endpoint),
       _client = client ?? createLocalLogClient() {
    _client.options = BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      sendTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
      contentType: Headers.jsonContentType,
      responseType: ResponseType.plain,
      followRedirects: false,
      maxRedirects: 0,
      receiveDataWhenStatusError: false,
      validateStatus: (status) => status != null,
      extra: const {'withCredentials': false},
    );
  }

  static const queueLimit = 500;
  static const queueByteLimit = 1024 * 1024;
  static const batchLimit = 50;
  static const batchByteLimit = 256 * 1024;
  static const criticalRecordReserve = 50;
  static const criticalByteReserve = 256 * 1024;
  static const noiseRecordLimit = queueLimit ~/ 2;

  final String instanceId;
  final Uri? _endpoint;
  final Dio _client;
  final Duration flushInterval;
  final _queue = Queue<({String json, int bytes, int priority})>();
  bool _enabled = false;
  bool _recording = false;
  bool _disposed = false;
  int _generation = 0;
  int _queuedBytes = 0;
  int _queuedNoiseEvents = 0;
  int _sentEvents = 0;
  int _droppedEvents = 0;
  int _retiredEvents = 0;
  int _uncertainEvents = 0;
  int _failedBatches = 0;
  int _sampledEvents = 0;
  int _sampleSequence = 0;
  int _evictedNoiseEvents = 0;
  int _droppedImportantEvents = 0;
  int _droppedCriticalEvents = 0;
  int _retriedBatches = 0;
  int _retriedEvents = 0;
  int _retryAttempt = 0;
  _LocalLogBatch? _pendingBatch;
  DateTime? _lastSuccessAt;
  DateTime? _lastFailureAt;
  String? _lastFailure;
  Timer? _timer;
  CancelToken? _cancelToken;
  int _inFlight = 0;
  bool _sending = false;

  bool get enabled => kDebugMode && _enabled && !_disposed;
  bool get available => kDebugMode && _endpoint != null && !_disposed;
  bool get _active => enabled && _recording && _endpoint != null;

  /// Only repeatable widget/watch observations are dispensable. Failures and
  /// warnings have a separate reserved budget; operation pairs/cursor/session
  /// records may evict noise rather than losing their causal timeline.
  static int priorityForRecord(Map<String, Object?> record) {
    final data = record['data'];
    final metadata = data is Map ? data : const <String, Object?>{};
    final level = record['level'] ?? metadata['level'];
    final status = metadata['status'] ?? metadata['statusCode'];
    if ((record['category'] == 'outbox' &&
            const {
              'rejected',
              'waiting_for_server',
              'needs_attention',
              'paused',
            }.contains(record['name'])) ||
        (record['category'] == 'health' && record['name'] == 'unavailable')) {
      return 2;
    }
    if (metadata['errorType'] != null ||
        level == 'error' ||
        level == 'warn' ||
        level == 'warning' ||
        (status is num && status >= 400) ||
        metadata['outcome'] == 'failed') {
      return 2;
    }
    return record['phase'] == 'instant' &&
            (record['category'] == 'widget' || record['name'] == 'watch.emit')
        ? 0
        : 1;
  }

  /// Do not allow configuration to turn a local debugging feature into upload.
  /// Redirects are also disabled on the HTTP client.
  static Uri? parseEndpoint(String value) {
    try {
      final uri = Uri.parse(value);
      if (uri.scheme != 'http' ||
          !uri.hasAuthority ||
          uri.userInfo.isNotEmpty ||
          value.contains('@') ||
          uri.hasQuery ||
          uri.hasFragment ||
          !const {
            '127.0.0.1',
            'localhost',
            '::1',
            '[::1]',
          }.contains(uri.host) ||
          uri.port < 1 ||
          uri.port > 65535) {
        return null;
      }
      return uri;
    } catch (_) {
      return null;
    }
  }

  void setEnabled(bool value) {
    if (_disposed) return;
    final next = kDebugMode && value;
    if (next == _enabled) return;
    _enabled = next;
    if (!next) retire();
    _notifySafely();
  }

  /// Capture pause/off retires pending records without clearing this opt-in.
  /// Resume sends only new events; retained timeline rows are never replayed.
  void setRecording(bool value) {
    if (_disposed || value == _recording) return;
    _recording = value;
    if (!value) retire();
  }

  void addInspectorRecord(Map<String, Object?> record) {
    if (!_active) return;
    try {
      // Preserve actions, failures, cursor transitions and span pairs. Under
      // pressure, sample only high-volume instant widget/watch observations.
      final priority = priorityForRecord(record);
      final sampleable = priority == 0;
      if (sampleable &&
          (_queuedNoiseEvents >= noiseRecordLimit ||
              (_queue.length >= queueLimit ~/ 2 &&
                  ++_sampleSequence % 4 != 0))) {
        _sampledEvents++;
        return;
      }
      final data = record['data'];
      final metadata = data is Map ? data : const <String, Object?>{};
      final metricName = record['name'];
      final metricValue = metadata['count'];
      final metricGroup = metadata['source'];
      final isMetric =
          record['category'] == 'inspector' &&
          metricName is String &&
          RegExp(r'^metric\.[a-zA-Z0-9_./:#<>-]+$').hasMatch(metricName) &&
          metricName.length <= 120 &&
          metricValue is num &&
          metricValue.isFinite &&
          metricGroup is String &&
          const {
            'gauges',
            'builds',
            'resources',
            'frames',
            'aggregate_errors',
            'delivery',
          }.contains(metricGroup);
      final json = jsonEncode({
        ...record,
        'source': 'flutter',
        'event': 'flutter_inspector',
        'level':
            metadata['errorType'] != null ||
                record['level'] == 'error' ||
                metadata['level'] == 'error'
            ? 'error'
            : priority == 2
            ? 'warn'
            : 'info',
        'requestId': metadata['requestId'],
        if (isMetric) ...{
          'metricName': metricName,
          'metricValue': metricValue,
          'metricGroup': metricGroup,
        },
      });
      final bytes = utf8.encode(json).length;
      final countLimit = priority == 2
          ? queueLimit
          : queueLimit - criticalRecordReserve;
      final byteLimit = priority == 2
          ? queueByteLimit
          : queueByteLimit - criticalByteReserve;
      if (bytes + _batchEnvelopeBytes > batchByteLimit) {
        _dropRecord(priority, 'record_too_large');
        return;
      }
      while (_queue.length >= countLimit || _queuedBytes + bytes > byteLimit) {
        ({String json, int bytes, int priority})? evicted;
        for (var lower = 0; lower < priority && evicted == null; lower++) {
          evicted = _queue
              .cast<({String json, int bytes, int priority})?>()
              .firstWhere(
                (event) => event!.priority == lower,
                orElse: () => null,
              );
        }
        if (evicted == null) {
          if (sampleable) {
            _sampledEvents++;
          } else {
            _dropRecord(priority, 'important_queue_overflow');
          }
          return;
        }
        _queue.remove(evicted);
        _queuedBytes -= evicted.bytes;
        if (evicted.priority == 0) {
          _queuedNoiseEvents--;
          _sampledEvents++;
          _evictedNoiseEvents++;
        } else {
          _droppedEvents++;
          _droppedImportantEvents++;
          _lastFailure = 'important_queue_evicted';
          _lastFailureAt = DateTime.now().toUtc();
        }
      }
      // JSON is encoded now, so later mutation cannot change a queued record.
      _queue.add((json: json, bytes: bytes, priority: priority));
      if (priority == 0) _queuedNoiseEvents++;
      _queuedBytes += bytes;
      _schedule(drain: priority == 2 || _queue.length >= batchLimit);
    } catch (_) {
      _dropRecord(priorityForRecord(record), 'serialization_failed');
    }
  }

  void _dropRecord(int priority, String failure) {
    _droppedEvents++;
    if (priority > 0) _droppedImportantEvents++;
    if (priority == 2) _droppedCriticalEvents++;
    _lastFailure = failure;
    _lastFailureAt = DateTime.now().toUtc();
    _notifySafely();
  }

  int get _batchEnvelopeBytes => utf8
      .encode(
        '{"instanceId":${jsonEncode(instanceId)},'
        '"batchId":"00000000-0000-4000-8000-000000000000","events":[]}',
      )
      .length;

  void _schedule({bool drain = false}) {
    if (!_active ||
        _sending ||
        (_queue.isEmpty && _pendingBatch == null) ||
        (_pendingBatch != null && _retryAttempt > 0 && _timer != null)) {
      return;
    }
    if (drain) {
      _timer?.cancel();
      _timer = null;
    }
    if (_timer != null) return;
    final delay = _pendingBatch != null && _retryAttempt > 0
        ? _retryDelay
        : drain
        ? Duration.zero
        : flushInterval;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Duration get _retryDelay => switch (_retryAttempt) {
    <= 1 => const Duration(milliseconds: 100),
    2 => const Duration(milliseconds: 500),
    3 => const Duration(seconds: 1),
    _ => const Duration(seconds: 2),
  };

  /// Exposed for a manual flush and deterministic tests; normal delivery uses
  /// the bounded timer. Only one request can be active, including after retire.
  Future<void> flush() async {
    if (!_active || _sending || (_queue.isEmpty && _pendingBatch == null)) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (_pendingBatch == null) {
      final entries = <({String json, int bytes, int priority})>[];
      var bytes = _batchEnvelopeBytes;
      while (_queue.isNotEmpty && entries.length < batchLimit) {
        final next = _queue.first;
        final separator = entries.isEmpty ? 0 : 1;
        if (bytes + separator + next.bytes > batchByteLimit) break;
        _queue.removeFirst();
        if (next.priority == 0) _queuedNoiseEvents--;
        _queuedBytes -= next.bytes;
        bytes += separator + next.bytes;
        entries.add(next);
      }
      if (entries.isEmpty) return;
      final id = const Uuid().v4();
      _pendingBatch = _LocalLogBatch(
        entries,
        '{"instanceId":${jsonEncode(instanceId)},"batchId":${jsonEncode(id)},'
        '"events":[${entries.map((entry) => entry.json).join(',')}]}',
      );
    }
    final batch = _pendingBatch!;
    if (_retryAttempt > 0) {
      _retriedBatches++;
      _retriedEvents += batch.entries.length;
    }
    final generation = _generation;
    final token = CancelToken();
    _cancelToken = token;
    _inFlight = batch.entries.length;
    _sending = true;
    try {
      final response = await _client.postUri<String>(
        _endpoint!,
        data: batch.body,
        cancelToken: token,
      );
      if (!_disposed && generation == _generation) {
        if (response.statusCode == 200 || response.statusCode == 202) {
          _sentEvents += batch.entries.length;
          _pendingBatch = null;
          _retryAttempt = 0;
          _lastSuccessAt = DateTime.now().toUtc();
          _lastFailure = null;
        } else {
          final status = response.statusCode ?? 0;
          _failBatch(
            batch,
            'http_$status',
            retry:
                status == 408 || status == 429 || status >= 500 || status == 0,
          );
        }
      }
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _failBatch(
          batch,
          error is DioException ? error.type.name : 'transport_failed',
          retry: true,
        );
      }
    } finally {
      // A retired request must settle before any later request starts, but its
      // late result cannot change the new generation's delivery counters.
      _sending = false;
      _inFlight = 0;
      _cancelToken = null;
      if (!_disposed) {
        _schedule(drain: true);
        _notifySafely();
      }
    }
  }

  void _failBatch(_LocalLogBatch batch, String failure, {required bool retry}) {
    _failedBatches++;
    _lastFailureAt = DateTime.now().toUtc();
    _lastFailure = failure;
    if (retry) {
      _retryAttempt++;
    } else {
      for (final entry in batch.entries) {
        _droppedEvents++;
        if (entry.priority > 0) _droppedImportantEvents++;
        if (entry.priority == 2) _droppedCriticalEvents++;
      }
      _pendingBatch = null;
      _retryAttempt = 0;
    }
  }

  /// Discard unsent rows, cancel best effort and invalidate pending accounting.
  /// Already accepted records cannot be retracted from the local collector.
  void retire({bool resetCounters = false}) {
    if (_disposed) return;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _retiredEvents +=
        _queue.length + (_sending ? 0 : _pendingBatch?.entries.length ?? 0);
    _uncertainEvents += _inFlight;
    _queue.clear();
    _queuedNoiseEvents = 0;
    _pendingBatch = null;
    _retryAttempt = 0;
    _queuedBytes = 0;
    _cancelToken?.cancel('inspector_capture_retired');
    _inFlight = 0;
    if (resetCounters) {
      _sentEvents = 0;
      _droppedEvents = 0;
      _retiredEvents = 0;
      _uncertainEvents = 0;
      _failedBatches = 0;
      _sampledEvents = 0;
      _sampleSequence = 0;
      _evictedNoiseEvents = 0;
      _droppedImportantEvents = 0;
      _droppedCriticalEvents = 0;
      _retriedBatches = 0;
      _retriedEvents = 0;
      _lastSuccessAt = null;
      _lastFailureAt = null;
      _lastFailure = null;
    }
  }

  Map<String, Object?> snapshot() => Map<String, Object?>.unmodifiable({
    'enabled': enabled,
    'available': available,
    'active': _active,
    'endpoint': _endpoint?.toString(),
    'instanceId': instanceId,
    'queuedEvents': _queue.length,
    'queuedBytes': _queuedBytes,
    'inFlightEvents': _inFlight,
    'sentEvents': _sentEvents,
    'droppedEvents': _droppedEvents,
    'retiredEvents': _retiredEvents,
    'uncertainEvents': _uncertainEvents,
    'failedBatches': _failedBatches,
    'sampledEvents': _sampledEvents,
    'evictedNoiseEvents': _evictedNoiseEvents,
    'droppedImportantEvents': _droppedImportantEvents,
    'droppedCriticalEvents': _droppedCriticalEvents,
    'retriedBatches': _retriedBatches,
    'retriedEvents': _retriedEvents,
    'pendingRetryEvents': _retryAttempt > 0
        ? _pendingBatch?.entries.length ?? 0
        : 0,
    'retryAttempt': _retryAttempt,
    'pendingImportantEvents':
        _queue.where((event) => event.priority > 0).length +
        (_pendingBatch?.entries.where((event) => event.priority > 0).length ??
            0),
    'lastSuccessAt': _lastSuccessAt?.toIso8601String(),
    'lastFailureAt': _lastFailureAt?.toIso8601String(),
    'lastFailure': _endpoint == null ? 'invalid_local_endpoint' : _lastFailure,
    'queueLimit': queueLimit,
    'queueByteLimit': queueByteLimit,
    'batchLimit': batchLimit,
    'batchByteLimit': batchByteLimit,
    'criticalRecordReserve': criticalRecordReserve,
    'criticalByteReserve': criticalByteReserve,
    'noiseRecordLimit': noiseRecordLimit,
  });

  void _notifySafely() {
    if (_disposed) return;
    try {
      notifyListeners();
    } catch (_) {
      // This notifier has no bearing on captured application operations.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    retire();
    _disposed = true;
    _client.close(force: true);
    super.dispose();
  }
}

final class _LocalLogBatch {
  const _LocalLogBatch(this.entries, this.body);
  final List<({String json, int bytes, int priority})> entries;
  final String body;
}
