import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// XHR cannot disable redirects. Fetch can reject them before forwarding this
/// local-only metadata to another origin, and explicitly omits all credentials.
Dio createLocalLogClient() => Dio()..httpClientAdapter = _LocalFetchAdapter();

final class _LocalFetchAdapter implements HttpClientAdapter {
  final _controllers = <_AbortController>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Local log transport is closed.');
    final controller = _AbortController();
    _controllers.add(controller);
    var finished = false;
    var timedOut = false;
    final timer = Timer(const Duration(seconds: 2), () {
      timedOut = true;
      controller.abort();
    });
    unawaited(
      cancelFuture?.then((_) {
        if (!finished) controller.abort();
      }),
    );
    try {
      final bytes = await requestStream?.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final response = await _fetch(
        options.uri.toString(),
        _FetchOptions(
          method: 'POST',
          headers:
              const {'Content-Type': 'application/json'}.jsify()! as JSObject,
          body: utf8.decode(bytes?.takeBytes() ?? Uint8List(0)),
          mode: 'cors',
          credentials: 'omit',
          redirect: 'error',
          signal: controller.signal,
        ),
      ).toDart;
      // Delivery only needs the HTTP status; do not retain arbitrary response
      // bodies from the collector or an accidentally configured local server.
      await response.body?.cancel().toDart;
      return ResponseBody.fromString('', response.status);
    } catch (_) {
      if (timedOut) {
        throw DioException.receiveTimeout(
          timeout: const Duration(seconds: 2),
          requestOptions: options,
        );
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'local_log_delivery_failed',
      );
    } finally {
      finished = true;
      timer.cancel();
      _controllers.remove(controller);
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final controller in _controllers) {
      controller.abort();
    }
    _controllers.clear();
  }
}

@JS('fetch')
external JSPromise<_FetchResponse> _fetch(String url, _FetchOptions options);

@JS('AbortController')
extension type _AbortController._(JSObject _) implements JSObject {
  external factory _AbortController();
  external JSObject get signal;
  external void abort();
}

extension type _FetchOptions._(JSObject _) implements JSObject {
  external factory _FetchOptions({
    required String method,
    required JSObject headers,
    required String body,
    required String mode,
    required String credentials,
    required String redirect,
    required JSObject signal,
  });
}

extension type _FetchResponse._(JSObject _) implements JSObject {
  external int get status;
  external _ResponseStream? get body;
}

extension type _ResponseStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> cancel();
}
