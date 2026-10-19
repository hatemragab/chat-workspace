import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Exercise the SDK's actual protobuf wire format rather than mock callbacks.
// ignore: implementation_imports
import 'package:centrifuge/src/proto/client.pb.dart' as protocol;
import 'package:centrifuge/centrifuge.dart' as centrifuge;
import 'package:chat_workspace/core/chat_api.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/debug_traffic_logger.dart';
import 'package:chat_workspace/core/local_log_exporter.dart';
import 'package:chat_workspace/core/realtime_transport_logging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

final class _ExportAdapter implements HttpClientAdapter {
  _ExportAdapter(this.events);
  final List<Map<String, dynamic>> events;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = jsonDecode(options.data as String) as Map;
    events.addAll((body['events'] as List).cast<Map<String, dynamic>>());
    return ResponseBody.fromString('', 202);
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError('Expected realtime observation was not delivered.');
}

final class _Harness {
  _Harness(this.server, {required bool full}) {
    logger = DebugTrafficLogger(enabled: full, writer: (_) {});
    exporter = LocalLogExporter(
      client: Dio()..httpClientAdapter = _ExportAdapter(exported),
      endpoint: 'http://127.0.0.1:${server.port}/events',
      flushInterval: const Duration(days: 1),
    );
    inspector = DebugInspector(enabled: true, localLogExporter: exporter)
      ..updateContext(userId: 'socket-user', sessionGeneration: 7)
      ..setShareWithLocalLogs(true);
    api = ChatApi(trafficLogger: logger, debugInspector: inspector);
    client = createLoggedRealtimeClient(
      'ws://127.0.0.1:${server.port}/socket',
      centrifuge.ClientConfig(
        getData: () async => utf8.encode(
          '{"token":"private-connect-token","label":"connection input"}',
        ),
        headers: {'Authorization': 'Bearer private-header-token'},
      ),
      inspector: inspector,
      trafficLogger: logger,
      isCurrentSession: () => current,
      context: () => inspector.captureContext(detached: true),
    );
    server.listen((request) async {
      socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (_) => 'centrifuge-protobuf',
      );
      socket.listen((dynamic frame) async {
        final bytes = frame as List<int>;
        var offset = 0;
        while (offset < bytes.length) {
          var length = 0, shift = 0, next = 0;
          do {
            next = bytes[offset++];
            length |= (next & 127) << shift;
            shift += 7;
          } while (next >= 128);
          final command = protocol.Command.fromBuffer(
            bytes.sublist(offset, offset + length),
          );
          offset += length;
          commands.add(command);
          if (command.hasConnect()) {
            send(
              protocol.Reply(
                id: command.id,
                connect: protocol.ConnectResult(
                  client: 'wire-client',
                  version: '6.9',
                  ping: 30,
                  pong: true,
                  data: utf8.encode(
                    '{"greeting":"connection reply","token":"private-reply-token"}',
                  ),
                  subs: [
                    MapEntry(
                      'inbox:user#socket-user',
                      protocol.SubscribeResult(),
                    ),
                  ],
                ),
              ),
            );
          } else if (command.hasRpc()) {
            rpcStarted = true;
            await rpcRelease?.future;
            send(
              rejectRpc
                  ? protocol.Reply(
                      id: command.id,
                      error: protocol.Error(code: 403, message: 'Rejected'),
                    )
                  : protocol.Reply(
                      id: command.id,
                      rpc: protocol.RPCResult(data: command.rpc.data),
                    ),
            );
          }
        }
      });
    });
  }

  static Future<_Harness> start({bool full = true}) async {
    final h = _Harness(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      full: full,
    );
    addTearDown(h.close);
    await h.client.connect();
    await h.client.ready();
    return h;
  }

  final HttpServer server;
  late final centrifuge.Client client;
  late final ChatApi api;
  late final DebugInspector inspector;
  late final DebugTrafficLogger logger;
  late final LocalLogExporter exporter;
  late WebSocket socket;
  final commands = <protocol.Command>[];
  final exported = <Map<String, dynamic>>[];
  bool current = true, rpcStarted = false, rejectRpc = false;
  Completer<void>? rpcRelease;

  List<Map<String, Object?>> get events =>
      (inspector.snapshot()['events'] as List).cast<Map<String, Object?>>();
  Map lastData(String name) =>
      events.lastWhere((e) => e['name'] == name)['data'] as Map;

  void send(protocol.Reply reply) {
    final bytes = reply.writeToBuffer(), prefix = <int>[];
    var length = bytes.length;
    while (length >= 128) {
      prefix.add((length & 127) | 128);
      length >>= 7;
    }
    prefix.add(length);
    socket.add([...prefix, ...bytes]);
  }

  Future<void> publish(List<int> bytes) async {
    final received = client.publication.first;
    send(
      protocol.Reply(
        push: protocol.Push(
          channel: 'inbox:user#socket-user',
          pub: protocol.Publication(data: bytes),
        ),
      ),
    );
    expect(
      (await received).data,
      bytes,
      reason: 'Inspection must not mutate application bytes.',
    );
  }

  Future<void> close() async {
    current = false;
    if (rpcRelease case final release? when !release.isCompleted) {
      release.complete();
    }
    await client.close();
    inspector.dispose();
    api.dio.close(force: true);
    await server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real connect commands and replies preserve wire data and export redacted decoded JSON', () async {
    final h = await _Harness.start();
    final command = h.commands.single;
    expect(jsonDecode(utf8.decode(command.connect.data)), {
      'token': 'private-connect-token',
      'label': 'connection input',
    });
    final sent = h.lastData('socket.send.connect');
    final received = h.lastData('socket.receive.connect');
    expect(sent['direction'], 'send');
    expect(sent['stage'], 'encoded_for_send');
    expect(sent['protocolId'], received['protocolId']);
    expect(sent['connectionId'], received['connectionId']);
    expect((sent['packetBytes'] as int), greaterThan(0));
    final connect =
        (((sent['realtime'] as Map)['payload'] as Map)['connect'] as Map);
    expect(connect['data'], {
      'token': '[REDACTED]',
      'label': 'connection input',
    });
    expect(
      ((((received['realtime'] as Map)['payload'] as Map)['connect']
              as Map)['data']
          as Map)['greeting'],
      'connection reply',
    );
    expect(
      h.events.every(
        (e) => e['userId'] == 'socket-user' && e['sessionGeneration'] == 7,
      ),
      isTrue,
    );
    await h.exporter.flush();
    expect(
      h.exported.where((e) => e['name'] == 'socket.send.connect'),
      hasLength(1),
    );
    expect(
      h.exported.where((e) => e['name'] == 'socket.receive.connect'),
      hasLength(1),
    );
    expect(jsonEncode(h.exported), isNot(contains('private-')));
    expect(
      jsonEncode(h.exported),
      isNot(contains(base64Encode(command.connect.data))),
    );
  });

  test('hydrated, compact receipt and unread publications export the actual received JSON', () async {
    final h = await _Harness.start();
    for (final envelope in [
      {
        'pts': 8,
        'epoch': 'epoch',
        'room': {
          'roomId': 'room',
          'eventType': 'message_new',
          'lastMessage': {
            'text': 'Visible incoming text',
            'token': 'private-publication-token',
          },
        },
      },
      {
        'pts': 9,
        'epoch': 'epoch',
        'receipt': {
          'roomId': 'room',
          'eventType': 'room_peer_seen',
          'peerSeenSeq': 3,
        },
      },
      {
        'pts': 10,
        'epoch': 'epoch',
        'unread': {
          'roomId': 'room',
          'eventType': 'room_unread_cleared',
          'unreadCount': 1,
        },
      },
    ]) {
      await h.publish(utf8.encode(jsonEncode(envelope)));
      final data = h.lastData('socket.receive.publication');
      expect(data['channel'], 'inbox:user#socket-user');
      final publication =
          (((data['realtime'] as Map)['payload'] as Map)['push'] as Map)['pub']
              as Map;
      final payload = publication['data'] as Map;
      expect(payload['pts'], envelope['pts']);
      expect(payload['epoch'], 'epoch');
      expect(jsonEncode(data), isNot(contains('private-publication-token')));
    }
    await h.exporter.flush();
    expect(
      h.exported.where((e) => e['name'] == 'socket.receive.publication'),
      hasLength(3),
    );
    expect(jsonEncode(h.exported), contains('Visible incoming text'));
  });

  test('ping/pong, binary and oversized payloads and protocol errors stay observable without changing results', () async {
    final h = await _Harness.start();
    h.send(protocol.Reply());
    await _until(() => h.commands.any((c) => c.writeToBuffer().isEmpty));
    expect(h.lastData('socket.receive.ping')['direction'], 'receive');
    expect(
      (h.lastData('socket.send.pong')['realtime'] as Map)['payload'],
      isEmpty,
    );
    await h.publish([255, 0, 254]);
    var payload =
        (h.lastData('socket.receive.publication')['realtime'] as Map)['payload']
            as Map;
    expect(((payload['push'] as Map)['pub'] as Map)['data'], {
      'type': 'binary',
      'length': 3,
    });
    await h.publish(utf8.encode(jsonEncode({'text': 'x' * 40000})));
    payload =
        (h.lastData('socket.receive.publication')['realtime'] as Map)['payload']
            as Map;
    expect(
      (((payload['push'] as Map)['pub'] as Map)['data']
          as Map)['payloadOmitted'],
      isTrue,
    );
    expect(
      utf8
          .encode(
            jsonEncode(h.lastData('socket.receive.publication')['realtime']),
          )
          .length,
      lessThanOrEqualTo(DebugHttpTrafficDetails.maxBytes),
    );
    h.rejectRpc = true;
    await expectLater(
      h.client.rpc(
        'inspect',
        utf8.encode(
          '{"text":"outgoing RPC","password":"private-rpc-password"}',
        ),
      ),
      throwsA(anything),
    );
    expect(h.lastData('socket.receive.error')['level'], 'error');
    expect(
      (h.lastData('socket.receive.error')['realtime'] as Map)['payload'],
      contains('error'),
    );
    expect(jsonEncode(h.events), isNot(contains('private-rpc-password')));
  });

  test(
    'metadata-only traffic and retired socket callbacks omit payloads',
    () async {
      final h = await _Harness.start(full: false);
      await h.publish(utf8.encode('{"text":"not captured"}'));
      expect(
        h.events.every((e) => !(e['data'] as Map).containsKey('realtime')),
        isTrue,
      );
      expect(jsonEncode(h.events), isNot(contains('not captured')));
      final count = h.events.length;
      h.current = false;
      await h.publish(utf8.encode('{"text":"retired callback"}'));
      expect(h.events, hasLength(count));
    },
  );

  for (final clear in [false, true]) {
    test(
      '${clear ? 'clear' : 'full-debug opt-out'} fences a pending reply and clears retained or queued payloads',
      () async {
        final h = await _Harness.start();
        h.rpcRelease = Completer<void>();
        final reply = h.client.rpc(
          'inspect',
          utf8.encode('{"text":"pending private RPC"}'),
        );
        await _until(() => h.rpcStarted);
        if (clear) {
          h.inspector.clear();
        } else {
          h.api.setDebugTrafficLoggingEnabled(false);
          h.api.setDebugTrafficLoggingEnabled(true);
        }
        expect(jsonEncode(h.events), isNot(contains('pending private RPC')));
        h.rpcRelease!.complete();
        h.rpcRelease = null;
        expect(jsonDecode(utf8.decode((await reply).data)), {
          'text': 'pending private RPC',
        });
        final data = h.lastData('socket.receive.rpc');
        expect(data.containsKey('realtime'), isFalse);
        expect(data['reason'], 'request_configuration_changed_or_untracked');
        await h.publish(utf8.encode('{"text":"new incoming payload"}'));
        await h.exporter.flush();
        expect(jsonEncode(h.exported), isNot(contains('pending private RPC')));
        expect(jsonEncode(h.exported), contains('new incoming payload'));
      },
    );
  }

  test('disabled full-debug never evaluates the realtime payload builder', () {
    final logger = DebugTrafficLogger(enabled: false);
    expect(
      logger.inspectorRealtimeDetails(
        direction: 'send',
        operation: 'connect',
        payload: () => throw StateError('Must not inspect'),
      ),
      isNull,
    );
    logger.setDebugTrafficLoggingEnabled(true);
    expect(
      logger.inspectorRealtimeDetails(
        direction: 'receive',
        operation: 'publication',
        payload: () => throw StateError('Inspection failure'),
      ),
      isNull,
    );
  });
}
