import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:flutter/foundation.dart';
import 'package:http_parser/http_parser.dart';

import 'debug_traffic_logger.dart';
import 'debug_inspector.dart';
import 'models.dart';
import 'network_config.dart';

class ChatApi {
  ChatApi({
    Dio? dio,
    String? baseUrl,
    bool enableHttpLogging = true,
    void Function(Map<String, Object?> record)? httpLogWriter,
    DebugTrafficLogger? trafficLogger,
    this.outboundAttemptTimeout = const Duration(seconds: 75),
    List<Duration> outboundRetryDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
    ],
    DebugInspector? debugInspector,
  }) : dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl ?? apiBaseUrl,
               connectTimeout: const Duration(seconds: 12),
               receiveTimeout: const Duration(seconds: 20),
             ),
           ),
       trafficLogger = trafficLogger ?? DebugTrafficLogger(),
       _customHttpWriter = httpLogWriter != null,
       _httpLogWriter = kDebugMode && enableHttpLogging
           ? httpLogWriter ?? _printHttpLog
           : null {
    this.debugInspector = debugInspector;
    // Independent of console/full-payload logging. RequestOptions captures the
    // span synchronously alongside the bearer and originating account.
    this.dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          _finishInspector(response.requestOptions, response: response);
          handler.next(response);
        },
        onError: (error, handler) {
          _finishInspector(
            error.requestOptions,
            response: error.response,
            error: error,
          );
          handler.next(error);
        },
      ),
    );
    if (_httpLogWriter != null) {
      this.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method.toUpperCase() != 'OPTIONS') {
              final identity = options.extra[_requestIdentityKey];
              final userId = identity is _HttpRequestIdentity
                  ? identity.userId
                  : this.trafficLogger.userId;
              _httpTraces[options] = _HttpRequestTrace(
                userId,
                this.trafficLogger.captureHttpRequest(
                  method: options.method,
                  path: options.path,
                  params: _routeParameters(options.path),
                  query: options.queryParameters,
                  body: options.data,
                  headers: options.headers,
                  identity: (userId: userId),
                ),
              );
            }
            handler.next(options);
          },
          onResponse: (response, handler) {
            _recordHttpCompletion(
              response.requestOptions,
              _httpTraces[response.requestOptions],
              response: response,
            );
            handler.next(response);
          },
          onError: (error, handler) {
            _recordHttpCompletion(
              error.requestOptions,
              _httpTraces[error.requestOptions],
              response: error.response,
              errorType: error.type,
            );
            handler.next(error);
          },
        ),
      );
    }
    this.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final outbound = options.extra[_outboundKey];
          if (outbound is _OutboundAttempt) {
            if (!outbound.isCurrent() || outbound.cancelToken.isCancelled) {
              handler.reject(
                DioException.requestCancelled(
                  requestOptions: options,
                  reason: 'outbound_session_retired',
                ),
              );
              return;
            }
            try {
              if (options.method == 'POST' && options.path == '/messages') {
                await outbound.onPhysicalAttempt?.call();
              }
            } catch (error) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: error,
                  message: 'Could not save the outgoing attempt.',
                ),
              );
              return;
            }
            if (!outbound.isCurrent() || outbound.cancelToken.isCancelled) {
              handler.reject(
                DioException.requestCancelled(
                  requestOptions: options,
                  reason: 'outbound_session_retired',
                ),
              );
              return;
            }
          }
          handler.next(options);
        },
        onError: (error, handler) {
          final outbound = error.requestOptions.extra[_outboundKey];
          if (outbound is _OutboundAttempt &&
              error.requestOptions.method == 'POST' &&
              error.requestOptions.path == '/messages') {
            outbound.outcomeUnknown =
                outbound.outcomeUnknown ||
                ChatApiException.fromDio(error).outcomeUnknown;
          }
          handler.next(error);
        },
      ),
    );
    this.dio.interceptors.add(
      RetryInterceptor(
        dio: this.dio,
        retries: 2,
        retryDelays: outboundRetryDelays,
        retryEvaluator: (error, attempt) {
          final outbound = error.requestOptions.extra[_outboundKey];
          if (outbound is! _OutboundAttempt ||
              error.requestOptions.method != 'POST' ||
              error.requestOptions.path != '/messages' ||
              !outbound.isCurrent() ||
              outbound.cancelToken.isCancelled ||
              outbound.canRetry?.call() == false) {
            return false;
          }
          final failure = ChatApiException.fromDio(error);
          return failure.retryAfter == null &&
              failure.kind != ChatFailureKind.rateLimited &&
              failure.isTransient;
        },
      ),
    );
  }
  final Dio dio;
  final Duration outboundAttemptTimeout;
  VoidCallback? onUnauthorized;
  int _sessionEpoch = 0;
  final _images = <String, Uint8List>{};
  final _imageRequests = <String, Future<Uint8List>>{};
  int _imageBytes = 0;
  static const _requestIdentityKey = 'chat.requestIdentity';
  static const _inspectorSpanKey = 'chat.inspectorSpan';
  final _httpTraces = Expando<_HttpRequestTrace>();
  DebugInspector? _debugInspector;
  DebugInspector? get debugInspector => _debugInspector;
  set debugInspector(DebugInspector? value) {
    _debugInspector = value;
    value?.setHttpDetailsEnabled(trafficLogger.isEnabled);
    value?.setRealtimeDetailsEnabled(trafficLogger.isEnabled);
  }

  final _presenceRequests = <CancelToken>{};
  static final Object _outboundZone = Object();
  static const _outboundKey = 'chat.outboundAttempt';
  final _outboundRequests = <CancelToken>{};

  /// One durable outbox burst. Captures its session before Dio schedules work.
  Future<T> runOutboundAttempt<T>({
    required bool Function() isCurrentSession,
    required Future<T> Function() operation,
    Future<void> Function()? onPhysicalAttempt,
    bool Function()? canRetry,
  }) async {
    final attempt = _OutboundAttempt(
      isCurrentSession,
      CancelToken(),
      onPhysicalAttempt,
      canRetry,
    );
    _outboundRequests.add(attempt.cancelToken);
    final deadline = Timer(outboundAttemptTimeout, () {
      attempt.cancelToken.cancel('outbound_deadline_exceeded');
    });
    try {
      return await runZoned(operation, zoneValues: {_outboundZone: attempt});
    } finally {
      deadline.cancel();
      _outboundRequests.remove(attempt.cancelToken);
    }
  }

  void cancelOutboundRequests() {
    for (final token in _outboundRequests.toList(growable: false)) {
      token.cancel('outbound_session_retired');
    }
    _outboundRequests.clear();
  }

  /// Retire only ephemeral polls; inbox recovery and mutations remain intact.
  void cancelPresenceRequests() {
    final requests = _presenceRequests.toList(growable: false);
    _presenceRequests.clear();
    for (final request in requests) {
      request.cancel('presence_retired');
    }
  }

  void _finishInspector(
    RequestOptions options, {
    Response<Object?>? response,
    DioException? error,
  }) {
    final span = options.extra.remove(_inspectorSpanKey);
    if (span is DebugSpan) {
      span.finish(
        data: {
          'status': response?.statusCode,
          'requestId': _responseRequestId(response),
          'outcome': error?.type.name ?? 'response',
        },
        error: error?.type == DioExceptionType.cancel ? null : error,
        httpDetails: trafficLogger.inspectorHttpDetails(
          request: _httpTraces[options]?.traffic,
          responseBody: response?.data,
          responseHeaders: response?.headers.map ?? const {},
        ),
      );
    }
  }

  final DebugTrafficLogger trafficLogger;
  final bool _customHttpWriter;
  final void Function(Map<String, Object?> record)? _httpLogWriter;
  final _recentApiRequests = <Map<String, Object?>>[];

  List<Map<String, Object?>> get recentApiRequests => List.unmodifiable(
    _recentApiRequests.map(
      (record) => Map<String, Object?>.unmodifiable(record),
    ),
  );
  bool get debugTrafficLoggingEnabled => trafficLogger.isEnabled;
  List<Map<String, Object?>> get recentTrafficRecords =>
      trafficLogger.recentTrafficRecords;
  void setDebugTrafficLoggingEnabled(bool enabled) {
    trafficLogger.setDebugTrafficLoggingEnabled(enabled);
    debugInspector?.setHttpDetailsEnabled(trafficLogger.isEnabled);
    debugInspector?.setRealtimeDetailsEnabled(trafficLogger.isEnabled);
  }

  static void _printHttpLog(Map<String, Object?> record) =>
      debugPrint('[api] ${jsonEncode(record)}');

  void _recordHttpCompletion(
    RequestOptions options,
    _HttpRequestTrace? trace, {
    Response<Object?>? response,
    DioExceptionType? errorType,
  }) {
    if (trace == null || trace.completed) return;
    trace.completed = true;
    trace.stopwatch.stop();
    // Metadata stays content-free; full opt-in uses credential-redacted copies.
    try {
      final record = Map<String, Object?>.unmodifiable({
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'event': 'http_request',
        'source': 'flutter',
        'userId': trace.userId,
        'method': _safeMethod(options.method),
        'route': _safeRoute(options.path),
        'status': response?.statusCode,
        'durationMs': trace.stopwatch.elapsedMilliseconds,
        'requestId': _responseRequestId(response),
        'outcome': errorType?.name ?? 'response',
      });
      _recentApiRequests.add(record);
      if (_recentApiRequests.length > 60) _recentApiRequests.removeAt(0);
      final fullRecord = trafficLogger.recordHttpCompletion(
        request: trace.traffic,
        metadata: record,
        responseBody: response?.data,
        responseHeaders: response?.headers.map ?? const {},
      );
      if (_customHttpWriter || !fullRecord) _httpLogWriter?.call(record);
    } catch (_) {
      // A failed diagnostic writer must not fail or retry a successful request.
    }
  }

  static String _safeMethod(String method) =>
      const {
        'GET',
        'POST',
        'PUT',
        'PATCH',
        'DELETE',
        'HEAD',
        'OPTIONS',
        'CONNECT',
        'TRACE',
      }.contains(method.toUpperCase())
      ? method.toUpperCase()
      : 'OTHER';

  static String _safeRoute(String path) {
    final route = Uri.tryParse(path)?.path;
    if (const {
      '/health',
      '/auth/debug-users',
      '/auth/debug-login',
      '/auth/signup',
      '/auth/login',
      '/auth/centrifugo-token',
      '/users',
      '/rooms',
      '/rooms/delta',
      '/rooms/group',
      '/rooms/delivered-batch',
      '/messages',
      '/uploads/image',
      '/presence/heartbeat',
      '/presence/offline',
      '/presence/status',
    }.contains(route)) {
      return route!;
    }
    if (route != null) {
      for (final template in const [
        '/public/uploads/:filename',
        '/rooms/direct-peer/:peerUserId',
        '/rooms/:roomId/preferences',
        '/rooms/:roomId/messages',
        '/rooms/:roomId/messages/around/:targetMessageId',
        '/rooms/:roomId/delivered',
        '/rooms/:roomId/seen',
        '/messages/:messageId',
        '/messages/:messageId/for-all',
        '/messages/:messageId/for-me',
      ]) {
        final pattern = template.replaceAll(RegExp(r':\w+'), '[^/]+');
        if (RegExp('^$pattern\$').hasMatch(route)) return template;
      }
    }
    return '[unmatched]';
  }

  static String? _responseRequestId(Response<Object?>? response) {
    final values = response?.headers['x-request-id'];
    if (values == null || values.length != 1) return null;
    final value = values.single;
    return !value.contains(RegExp(r'[\r\n]')) &&
            RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$').hasMatch(value)
        ? value
        : null;
  }

  static Map<String, Object?> _routeParameters(String path) {
    final template = _safeRoute(path).split('/');
    final segments = Uri.tryParse(path)?.path.split('/');
    if (segments == null || segments.length != template.length) return {};
    return {
      for (var index = 0; index < template.length; index++)
        if (template[index].startsWith(':'))
          template[index].substring(1): segments[index],
    };
  }

  int messageRequests = 0;
  bool get hasSessionToken => dio.options.headers['Authorization'] is String;
  void setToken(String? token, {String? userId}) {
    cancelOutboundRequests();
    _sessionEpoch++;
    _images.clear();
    _imageRequests.clear();
    _imageBytes = 0;
    trafficLogger.setUserId(token == null ? null : userId);
    if (token == null) {
      dio.options.headers.remove('Authorization');
    } else {
      dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  Options _requestOptions(String method, String path) => Options(
    method: method,
    sendTimeout:
        Zone.current[_outboundZone] is _OutboundAttempt ||
            path == '/uploads/image'
        ? const Duration(seconds: 30)
        : null,
    // Dio schedules interceptors after copying the bearer. Keep its matching
    // identity from this synchronous API entry, including anonymous requests.
    extra: {
      if (Zone.current[_outboundZone] case final _OutboundAttempt outbound)
        _outboundKey: outbound,
      'sessionEpoch': _sessionEpoch,
      _requestIdentityKey: _HttpRequestIdentity(trafficLogger.userId),
      if (method.toUpperCase() != 'OPTIONS')
        _inspectorSpanKey: debugInspector?.begin(
          'http',
          '${_safeMethod(method)}:${_safeRoute(path)}',
          data: {'method': _safeMethod(method), 'route': _safeRoute(path)},
          context: debugInspector?.captureContext().copyWithIdentity(
            trafficLogger.userId,
          ),
        ),
    },
  );

  Future<Object?> request(
    String method,
    String path, {
    Map<String, dynamic>? data,
    Map<String, dynamic>? query,
  }) async {
    final options = _requestOptions(method, path);
    final outbound = options.extra?[_outboundKey] as _OutboundAttempt?;
    final span = options.extra?[_inspectorSpanKey] as DebugSpan?;
    final cancel =
        const {'/presence/heartbeat', '/presence/status'}.contains(path)
        ? CancelToken()
        : outbound?.cancelToken;
    if (cancel != null && outbound == null) _presenceRequests.add(cancel);
    Object? failure;
    try {
      return (await dio.request<Object?>(
        path,
        data: data,
        queryParameters: query,
        options: options,
        cancelToken: cancel,
      )).data;
    } on DioException catch (error) {
      failure = error.type == DioExceptionType.cancel ? null : error;
      if (error.response?.statusCode == 401 &&
          options.extra?['sessionEpoch'] == _sessionEpoch &&
          hasSessionToken &&
          !path.startsWith('/auth/login') &&
          !path.startsWith('/auth/signup')) {
        onUnauthorized?.call();
      }
      throw ChatApiException.fromDio(
        error,
        outcomeUnknown: outbound?.outcomeUnknown ?? false,
      );
    } catch (error) {
      failure = error;
      rethrow;
    } finally {
      if (cancel != null) _presenceRequests.remove(cancel);
      // Dio normally completes through its interceptor. Setup failures can
      // happen before that boundary; finishing twice is deliberately harmless.
      span?.finish(error: failure);
    }
  }

  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async => jsonMap(await request('GET', path, query: query));
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async => jsonMap(await request('POST', path, data: body));
  Future<List<UserProfile>> getUsers(String path) async =>
      ((await request('GET', path)) as List)
          .map((u) => UserProfile.fromJson(jsonMap(u)))
          .toList();
  Future<({List<UserProfile> users, String? nextCursor})> directoryPage({
    String? cursor,
  }) async {
    final page = await getMap(
      '/users',
      query: {'limit': 100, 'afterUserId': ?cursor},
    );
    return (
      users: (page['users'] as List)
          .map((value) => UserProfile.fromJson(jsonMap(value)))
          .toList(),
      nextCursor: page['nextCursor'] as String?,
    );
  }

  Future<Map<String, dynamic>> latestMessages(
    String roomId, {
    ChatMessage? before,
  }) {
    messageRequests++;
    return getMap(
      '/rooms/$roomId/messages',
      query: {
        'limit': 30,
        if (before != null)
          'beforeCreatedAt': before.createdAt.toIso8601String(),
        if (before != null) 'beforeId': before.id,
      },
    );
  }

  /// Each room has its own immutable message sequence; a batch cannot share
  /// one boundary across rooms.
  Future<void> deliverThrough(
    List<({String roomId, int upToSeq})> targets,
  ) async {
    if (targets.isEmpty) return;
    await post('/rooms/delivered-batch', {
      'targets': [
        for (final target in targets)
          {'roomId': target.roomId, 'upToSeq': target.upToSeq},
      ],
    });
  }

  Future<void> seenThrough(String roomId, int upToSeq) async {
    await post('/rooms/$roomId/seen', {'upToSeq': upToSeq});
  }

  Future<String> uploadImage(Uint8List bytes, String filename) async {
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const ChatApiException(
        'Choose an image smaller than 5 MB.',
        kind: ChatFailureKind.validation,
        code: 'invalid_image_size',
      );
    }
    final extension = filename.split('.').last.toLowerCase();
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => null,
    };
    if (mime == null) {
      throw const ChatApiException(
        'Choose a JPEG, PNG, WebP, or GIF image.',
        kind: ChatFailureKind.validation,
        code: 'invalid_image_type',
      );
    }
    final options = _requestOptions('POST', '/uploads/image');
    final span = options.extra?[_inspectorSpanKey] as DebugSpan?;
    Object? failure;
    try {
      final response = await dio.post<Object?>(
        '/uploads/image',
        options: options,
        cancelToken:
            (options.extra?[_outboundKey] as _OutboundAttempt?)?.cancelToken,
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(
            bytes,
            filename: filename,
            contentType: MediaType.parse(mime),
          ),
        }),
      );
      final body = jsonMap(response.data);
      return (body['imageUrl'] ?? body['url']) as String;
    } on DioException catch (error) {
      failure = error;
      if (error.response?.statusCode == 401 &&
          options.extra?['sessionEpoch'] == _sessionEpoch) {
        onUnauthorized?.call();
      }
      throw ChatApiException.fromDio(error);
    } catch (error) {
      failure = error;
      rethrow;
    } finally {
      span?.finish(error: failure);
    }
  }

  String absoluteImageUrl(String path) =>
      Uri.parse(dio.options.baseUrl).resolve(path).toString();

  Future<Uint8List> imageBytes(String path) async {
    final uri = Uri.parse(absoluteImageUrl(path));
    final base = Uri.parse(dio.options.baseUrl);
    if (uri.origin != base.origin || !uri.path.startsWith('/public/uploads/')) {
      throw const ChatApiException('This image source is not supported.');
    }
    final cached = _images.remove(uri.path);
    if (cached != null) {
      _images[uri.path] = cached;
      return cached;
    }
    final epoch = _sessionEpoch;
    final existing = _imageRequests[uri.path];
    if (existing != null) return existing;
    late final Future<Uint8List> pending;
    pending = _fetchImage(uri, epoch).whenComplete(() {
      if (identical(_imageRequests[uri.path], pending)) {
        _imageRequests.remove(uri.path);
      }
    });
    _imageRequests[uri.path] = pending;
    return pending;
  }

  Future<Uint8List> _fetchImage(Uri uri, int epoch) async {
    final options = _requestOptions('GET', uri.path)
      ..responseType = ResponseType.bytes
      ..followRedirects = false
      ..maxRedirects = 0;
    try {
      final response = await dio.get<List<int>>(uri.path, options: options);
      if (epoch != _sessionEpoch) {
        throw const ChatApiException('Session ended.');
      }
      final bytes = Uint8List.fromList(response.data!);
      if (bytes.length > 5 * 1024 * 1024) {
        throw const ChatApiException('Image exceeds the display budget.');
      }
      while (_images.isNotEmpty &&
          (_images.length >= 64 ||
              _imageBytes + bytes.length > 20 * 1024 * 1024)) {
        _imageBytes -= _images.remove(_images.keys.first)!.length;
      }
      _images[uri.path] = bytes;
      _imageBytes += bytes.length;
      return bytes;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 && epoch == _sessionEpoch) {
        onUnauthorized?.call();
      }
      throw ChatApiException(
        'Image unavailable.',
        statusCode: error.response?.statusCode,
      );
    }
  }
}

class _HttpRequestTrace {
  _HttpRequestTrace(this.userId, this.traffic);
  final String? userId;
  final DebugHttpTrafficSnapshot? traffic;
  final stopwatch = Stopwatch()..start();
  bool completed = false;
}

class _HttpRequestIdentity {
  const _HttpRequestIdentity(this.userId);
  final String? userId;
}

enum ChatFailureKind {
  validation,
  authentication,
  authorization,
  notFound,
  conflict,
  rateLimited,
  transport,
  timeout,
  unavailable,
  cancelled,
  protocol,
  unknown,
}

class ChatApiException implements Exception {
  const ChatApiException(
    this.message, {
    this.statusCode,
    this.kind = ChatFailureKind.unknown,
    this.code,
    this.retryAfter,
    this.requestId,
    this.retryable,
    this.outcomeUnknown = false,
  });

  factory ChatApiException.fromDio(
    DioException error, {
    bool outcomeUnknown = false,
  }) {
    final status = error.response?.statusCode;
    final body = error.response?.data;
    final detail = body is Map ? body['detail'] ?? body['message'] : null;
    final code = body is Map ? body['code'] : null;
    final deadlineExceeded =
        error.type == DioExceptionType.cancel &&
        error.error == 'outbound_deadline_exceeded';
    final retryAfterValues = error.response?.headers['retry-after'];
    final kind = deadlineExceeded
        ? ChatFailureKind.timeout
        : switch (status) {
            400 || 413 || 415 || 422 => ChatFailureKind.validation,
            401 => ChatFailureKind.authentication,
            403 => ChatFailureKind.authorization,
            404 || 410 => ChatFailureKind.notFound,
            409 || 412 => ChatFailureKind.conflict,
            429 => ChatFailureKind.rateLimited,
            408 => ChatFailureKind.timeout,
            500 || 502 || 503 || 504 => ChatFailureKind.unavailable,
            _ => switch (error.type) {
              DioExceptionType.cancel => ChatFailureKind.cancelled,
              DioExceptionType.connectionError => ChatFailureKind.transport,
              DioExceptionType.connectionTimeout ||
              DioExceptionType.sendTimeout ||
              DioExceptionType.receiveTimeout => ChatFailureKind.timeout,
              DioExceptionType.badCertificate => ChatFailureKind.protocol,
              _ => ChatFailureKind.unknown,
            },
          };
    return ChatApiException(
      detail is List
          ? detail.join(', ')
          : detail?.toString() ??
                (kind == ChatFailureKind.transport
                    ? 'Cannot reach the chat server. Please try again.'
                    : error.message ?? 'Request failed.'),
      statusCode: status,
      kind: kind,
      outcomeUnknown:
          outcomeUnknown ||
          const {
            ChatFailureKind.transport,
            ChatFailureKind.timeout,
            ChatFailureKind.unavailable,
          }.contains(kind),
      code: deadlineExceeded
          ? 'outbound_deadline_exceeded'
          : code is String && RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(code)
          ? code
          : null,
      retryAfter: _retryAfter(
        retryAfterValues?.length == 1 ? retryAfterValues!.single : null,
        body is Map ? body['retryAfterSeconds'] : null,
      ),
      requestId: ChatApi._responseRequestId(error.response),
      retryable: body is Map && body['retryable'] is bool
          ? body['retryable'] as bool
          : null,
    );
  }

  static Duration? _retryAfter(String? value, Object? seconds) {
    final numeric = value == null ? null : int.tryParse(value.trim());
    if (numeric != null && numeric >= 0) return Duration(seconds: numeric);
    if (value != null) {
      try {
        final delay = parseHttpDate(value).difference(DateTime.now().toUtc());
        return delay.isNegative ? Duration.zero : delay;
      } on FormatException {
        /* malformed header is not a retry directive */
      }
    }
    return seconds is num && seconds.isFinite && seconds >= 0
        ? Duration(milliseconds: (seconds * 1000).ceil())
        : null;
  }

  final String message;
  final int? statusCode;
  final ChatFailureKind kind;
  final String? code, requestId;
  final Duration? retryAfter;
  final bool? retryable;
  final bool outcomeUnknown;
  bool get isTransient =>
      retryable != false &&
      (kind == ChatFailureKind.transport ||
          kind == ChatFailureKind.timeout ||
          kind == ChatFailureKind.unavailable ||
          const [408, 500, 502, 503, 504].contains(statusCode));
  bool get isDefinitiveRejection =>
      kind == ChatFailureKind.validation ||
      kind == ChatFailureKind.authorization ||
      kind == ChatFailureKind.notFound ||
      kind == ChatFailureKind.conflict ||
      (statusCode != null &&
          statusCode! >= 400 &&
          statusCode! < 500 &&
          !const [401, 408, 429].contains(statusCode));
  @override
  String toString() => message;
}

class _OutboundAttempt {
  _OutboundAttempt(
    this.isCurrent,
    this.cancelToken,
    this.onPhysicalAttempt,
    this.canRetry,
  );
  final bool Function() isCurrent;
  final CancelToken cancelToken;
  final Future<void> Function()? onPhysicalAttempt;
  final bool Function()? canRetry;
  bool outcomeUnknown = false;
}
