import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Opt-in business traffic inspection. Authentication material and binary data
/// are excluded even when full JSON logging is enabled.
final class DebugTrafficLogger {
  DebugTrafficLogger({
    bool enabled = const bool.fromEnvironment('DEBUG_TRAFFIC_LOGGING_ENABLED'),
    void Function(Map<String, Object?> record)? writer,
  }) : _enabled = kDebugMode && enabled,
       _writer = writer ?? _printRecord;

  final void Function(Map<String, Object?> record) _writer;
  final _records = <Map<String, Object?>>[];
  bool _enabled;
  int _configuration = 0;
  String? _userId;

  bool get isEnabled => kDebugMode && _enabled;
  int get configurationGeneration => _configuration;
  String? get userId => _userId;
  List<Map<String, Object?>> get recentTrafficRecords =>
      List.unmodifiable(_records);

  void setUserId(String? userId) => _userId = userId;

  void setDebugTrafficLoggingEnabled(bool enabled) {
    final next = kDebugMode && enabled;
    if (next == _enabled) return;
    _enabled = next;
    _configuration++;
    if (!next) _records.clear();
  }

  DebugHttpTrafficSnapshot? captureHttpRequest({
    required String method,
    required String path,
    required Map<String, Object?> params,
    required Map<String, dynamic> query,
    required Object? body,
    Map<String, dynamic> headers = const {},
    ({String? userId})? identity,
  }) {
    if (!isEnabled || method.toUpperCase() == 'OPTIONS') return null;
    try {
      final inlineQuery = Uri.tryParse(path)?.queryParametersAll;
      return DebugHttpTrafficSnapshot._(
        _configuration,
        identity == null ? _userId : identity.userId,
        _snapshot({
              'params': params,
              'query': {
                for (final entry
                    in inlineQuery?.entries ??
                        <MapEntry<String, List<String>>>[])
                  entry.key: entry.value.length == 1
                      ? entry.value.single
                      : entry.value,
                ...query,
              },
              'requestBody': body,
              'requestHeaders': headers,
            })!
            as Map<String, Object?>,
      );
    } catch (_) {
      return null;
    }
  }

  bool recordHttpCompletion({
    required DebugHttpTrafficSnapshot? request,
    required Map<String, Object?> metadata,
    required Object? responseBody,
    Map<String, dynamic> responseHeaders = const {},
  }) {
    if (!isEnabled ||
        request == null ||
        request._configuration != _configuration) {
      return false;
    }
    _emit({
      ...metadata,
      'event': 'http_request',
      'source': 'flutter',
      'userId': request.userId,
      ...request._request,
      'responseBody': responseBody,
      'responseHeaders': responseHeaders,
    });
    return true;
  }

  /// The same detached request used by full traffic, bounded for the inspector
  /// and its local exporter. A configuration change retires in-flight payloads.
  DebugHttpTrafficDetails? inspectorHttpDetails({
    required DebugHttpTrafficSnapshot? request,
    required Object? responseBody,
    Map<String, dynamic> responseHeaders = const {},
  }) {
    if (!isEnabled ||
        request == null ||
        request._configuration != _configuration) {
      return null;
    }
    try {
      return DebugHttpTrafficDetails._(
        _boundedDetails({
          ...request._request,
          'responseHeaders': responseHeaders,
          'responseBody': responseBody,
        }),
      );
    } catch (_) {
      return null;
    }
  }

  DebugRealtimeTrafficDetails? inspectorRealtimeDetails({
    required String direction,
    required String operation,
    required Object? Function() payload,
  }) {
    if (!isEnabled) return null;
    try {
      return DebugRealtimeTrafficDetails._(
        this,
        _configuration,
        _boundedDetails({
          'direction': direction,
          'operation': operation,
          'payload': payload(),
        }),
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?> _boundedDetails(Map<String, Object?> values) {
    final details = <String, Object?>{'policy': 'full_debug'};
    for (final entry in values.entries) {
      final safe = _snapshot(entry.value);
      final bytes = utf8
          .encode(jsonEncode({...details, entry.key: safe}))
          .length;
      details[entry.key] = bytes <= DebugHttpTrafficDetails.maxBytes - 1024
          ? safe
          : Map<String, Object?>.unmodifiable({
              'payloadOmitted': true,
              'omissionReason': 'detail_byte_limit',
              'limitBytes': DebugHttpTrafficDetails.maxBytes,
            });
    }
    return Map.unmodifiable(details);
  }

  void recordRealtimePublication(
    Object? data, {
    String? channel,
    String? userId,
  }) {
    if (!isEnabled) return;
    try {
      final recipient = userId ?? _userId;
      final publication = data is Map
          ? data['receipt'] ?? data['unread'] ?? data['room']
          : null;
      _emit({
        'event': 'realtime_publication',
        'source': 'flutter',
        'direction': 'receive',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'userId': recipient,
        'recipientUserId': recipient,
        // The message sender is not necessarily the actor of an edit or receipt.
        'actorUserId': null,
        'requestId': null,
        'channel': channel,
        'pts': data is Map ? data['pts'] : null,
        'eventType': publication is Map ? publication['eventType'] : null,
        'data': data,
      });
    } catch (_) {
      // Malformed debug data cannot interrupt processing of a publication.
    }
  }

  void _emit(Map<String, Object?> values) {
    if (!isEnabled) return;
    try {
      final record = _snapshot(values)! as Map<String, Object?>;
      _records.add(record);
      if (_records.length > 60) _records.removeAt(0);
      _writer(record);
    } catch (_) {
      // Inspection must never interrupt HTTP, realtime delivery or account work.
    }
  }

  static void _printRecord(Map<String, Object?> record) =>
      debugPrint(jsonEncode(record), wrapWidth: null);

  /// Shared by explicitly enabled local SQLite inspection. Does not log or
  /// retain the supplied value and never changes the application value.
  static Object? snapshotValue(Object? value) => _snapshot(value);
  static bool credentialField(String key) => _isSecret(key);

  static bool _isSecret(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return const {
          'auth',
          'authentication',
          'bearer',
          'jwt',
          'pass',
          'csrf',
        }.contains(normalized) ||
        const [
          'password',
          'passwd',
          'pwd',
          'token',
          'authorization',
          'cookie',
          'apikey',
          'accesskey',
          'signingkey',
          'clientkey',
          'secret',
          'credential',
          'signature',
          'privatekey',
          'sessionid',
          'appcheck',
          'authenticate',
        ].any(normalized.contains);
  }

  static String _safeText(String value) => value
      .replaceAllMapped(
        RegExp(r'(\b[a-z][a-z0-9+.-]*://)[^/\s?#]+@', caseSensitive: false),
        (match) => '${match[1]}[REDACTED]@',
      )
      .replaceAll(
        RegExp(r'\b(?:Bearer|Basic)\s+[a-z0-9._~+/=-]+', caseSensitive: false),
        '[REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'\beyJ[a-z0-9_-]+\.eyJ[a-z0-9_-]+\.[a-z0-9_-]+\b',
          caseSensitive: false,
        ),
        '[REDACTED]',
      )
      .replaceAllMapped(RegExp(r'([?&])([^=&#]+)=([^&#]*)'), (match) {
        try {
          return _isSecret(Uri.decodeComponent(match[2]!))
              ? '${match[1]}${match[2]}=[REDACTED]'
              : match[0]!;
        } on FormatException {
          return match[0]!;
        }
      });

  static Object? _snapshot(Object? value, [Set<Object>? ancestors]) {
    if (value == null || value is bool || value is num) return value;
    if (value is String) {
      // JSON sent with a text content type still needs recursive redaction.
      if (value.trimLeft().startsWith('{') ||
          value.trimLeft().startsWith('[') ||
          value.trimLeft().startsWith('"')) {
        try {
          final parsed = jsonDecode(value);
          final sanitized = jsonEncode(_snapshot(parsed, ancestors));
          if (sanitized != jsonEncode(parsed)) return sanitized;
        } on FormatException {
          // An ordinary message that starts with a bracket remains text.
        }
      }
      return _safeText(value);
    }
    if (value is TypedData) {
      return Map<String, Object?>.unmodifiable({
        'type': 'binary',
        'length': value.lengthInBytes,
      });
    }
    if (value is ByteBuffer) {
      return Map<String, Object?>.unmodifiable({
        'type': 'binary',
        'length': value.lengthInBytes,
      });
    }
    if (value is MultipartFile) {
      return _snapshot({
        'type': 'file',
        'filename': value.filename,
        'contentType': value.contentType?.toString(),
        'length': value.length,
      }, ancestors);
    }
    if (value is FormData) {
      final fields = <String, Object?>{};
      for (final entry in value.fields) {
        final previous = fields[entry.key];
        fields[entry.key] = previous == null
            ? entry.value
            : [if (previous is List) ...previous else previous, entry.value];
      }
      return _snapshot({
        'type': 'multipart/form-data',
        'fields': fields,
        'files': [
          for (final entry in value.files)
            {
              'field': entry.key,
              'file': _isSecret(entry.key) ? '[REDACTED]' : entry.value,
            },
        ],
      }, ancestors);
    }
    final seen = ancestors ?? Set<Object>.identity();
    if (value is Map || value is Iterable) {
      if (!seen.add(value)) return '[Circular]';
      try {
        if (value is Map) {
          return Map<String, Object?>.unmodifiable({
            for (final entry in value.entries)
              if (entry.key is String)
                entry.key as String: _isSecret(entry.key as String)
                    ? '[REDACTED]'
                    : _snapshot(entry.value, seen),
          });
        }
        return List<Object?>.unmodifiable(
          (value as Iterable).map((item) => _snapshot(item, seen)),
        );
      } finally {
        seen.remove(value);
      }
    }
    return '[Non-JSON data]';
  }
}

final class DebugHttpTrafficSnapshot {
  const DebugHttpTrafficSnapshot._(
    this._configuration,
    this.userId,
    this._request,
  );
  final int _configuration;
  final String? userId;
  final Map<String, Object?> _request;
}

/// Only the credential-redacting traffic logger can construct this envelope.
final class DebugHttpTrafficDetails {
  const DebugHttpTrafficDetails._(this.values);
  static const maxBytes = 32 * 1024;
  final Map<String, Object?> values;
}

final class DebugRealtimeTrafficDetails {
  const DebugRealtimeTrafficDetails._(
    this._logger,
    this._configuration,
    this.values,
  );
  final DebugTrafficLogger _logger;
  final int _configuration;
  final Map<String, Object?> values;
  bool get isCurrent =>
      _logger.isEnabled && _logger._configuration == _configuration;
}
