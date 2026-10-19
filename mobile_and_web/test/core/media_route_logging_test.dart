import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_workspace/core/chat_api.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _MediaAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('private media metadata and inspector use only the safe route template', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://private-host.example'));
    final adapter = _MediaAdapter();
    dio.httpClientAdapter = adapter;
    final inspector = DebugInspector(enabled: true);
    final records = <Map<String, Object?>>[];
    final api = ChatApi(
      dio: dio,
      debugInspector: inspector,
      httpLogWriter: records.add,
    )..setToken('private-bearer', userId: 'account');
    addTearDown(dio.close);
    addTearDown(inspector.dispose);

    expect(
      await api.imageBytes(
        '/public/uploads/private-file.png?token=private-query#private-fragment',
      ),
      [1, 2, 3],
    );
    expect(adapter.requests.single.path, '/public/uploads/private-file.png');
    expect(adapter.requests.single.queryParameters, isEmpty);
    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer private-bearer',
    );
    expect(records.single['route'], '/public/uploads/:filename');
    expect(records.single['status'], 200);
    final events = (inspector.snapshot()['events']! as List).cast<Map>();
    final http = events.where((event) => event['category'] == 'http').toList();
    expect(http, hasLength(2));
    expect(http.map((event) => event['phase']), ['begin', 'end']);
    for (final event in http) {
      expect(event['name'], 'GET:/public/uploads/:filename');
      expect((event['data']! as Map)['route'], '/public/uploads/:filename');
    }
    final logged = jsonEncode({'metadata': records, 'events': http});
    for (final secret in [
      'private-file',
      'private-query',
      'private-fragment',
      'private-bearer',
      'private-host',
    ]) {
      expect(logged, isNot(contains(secret)));
    }
  });
}
