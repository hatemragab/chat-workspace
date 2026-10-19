import 'dart:async';
import 'dart:typed_data';

import 'package:chat_workspace/core/chat_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class MediaAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  FutureOr<ResponseBody> Function(RequestOptions) respond = (_) =>
      ResponseBody.fromBytes(
        [1, 2, 3],
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Dio dio;
  late MediaAdapter adapter;
  late ChatApi api;
  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
    adapter = MediaAdapter();
    dio.httpClientAdapter = adapter;
    api = ChatApi(dio: dio, enableHttpLogging: false)
      ..setToken('account-one', userId: 'one');
  });
  tearDown(() => dio.close());

  test('private image uses bearer bytes, no query credentials, scoped cache and blocks external origins', () async {
    expect(await api.imageBytes('/public/uploads/image.png'), [1, 2, 3]);
    expect(await api.imageBytes('/public/uploads/image.png'), [1, 2, 3]);
    expect(adapter.requests, hasLength(1));
    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer account-one',
    );
    expect(adapter.requests.single.uri.query, isEmpty);
    expect(adapter.requests.single.followRedirects, false);
    api.setToken('account-two', userId: 'two');
    await api.imageBytes('/public/uploads/image.png');
    expect(adapter.requests, hasLength(2));
    expect(
      adapter.requests.last.headers['Authorization'],
      'Bearer account-two',
    );
    await expectLater(
      api.imageBytes('https://external.example/public/uploads/image.png'),
      throwsA(isA<ChatApiException>()),
    );
    expect(adapter.requests, hasLength(2));
  });

  test('current session media401 requests reauthentication but stale response cannot retire new session', () async {
    var expired = 0;
    api.onUnauthorized = () => expired++;
    adapter.respond = (_) => ResponseBody.fromBytes([], 401);
    await expectLater(
      api.imageBytes('/public/uploads/current.png'),
      throwsA(isA<ChatApiException>()),
    );
    expect(expired, 1);
    final response = Completer<ResponseBody>();
    adapter.respond = (_) => response.future;
    final pending = api.imageBytes('/public/uploads/stale.png');
    final assertion = expectLater(pending, throwsA(isA<ChatApiException>()));
    await Future<void>.delayed(Duration.zero);
    api.setToken('replacement', userId: 'one');
    response.complete(ResponseBody.fromBytes([], 401));
    await assertion;
    expect(expired, 1);
  });

  test('directory pages use bounded cursor contract', () async {
    adapter.respond = (_) => ResponseBody.fromString(
      '{"users":[{"id":"peer","username":"peer","displayName":"Peer"}],"nextCursor":"peer"}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
    final page = await api.directoryPage(cursor: 'previous');
    expect(page.users.single.id, 'peer');
    expect(page.nextCursor, 'peer');
    expect(adapter.requests.single.queryParameters, {
      'limit': 100,
      'afterUserId': 'previous',
    });
  });

  test('concurrent image consumers share one authenticated request', () async {
    final response = Completer<ResponseBody>();
    final started = Completer<void>();
    adapter.respond = (_) {
      started.complete();
      return response.future;
    };
    final first = api.imageBytes('/public/uploads/shared.png');
    final second = api.imageBytes('/public/uploads/shared.png');
    await started.future;
    expect(adapter.requests, hasLength(1));
    response.complete(ResponseBody.fromBytes([1], 200));
    expect(await first, [1]);
    expect(await second, [1]);
  });
}
