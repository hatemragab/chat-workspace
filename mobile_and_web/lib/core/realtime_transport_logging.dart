// The locked centrifuge 0.20.1 SDK has no public protocol observer. Keep its
// internal transport seam isolated here, use its unchanged socket/codec logic,
// and cover upgrades with real protobuf WebSocket tests. Release uses its factory.
// ignore_for_file: implementation_imports

import 'dart:convert';

import 'package:centrifuge/centrifuge.dart' as centrifuge;
import 'package:centrifuge/src/client.dart' show ClientImpl;
import 'package:centrifuge/src/codec.dart';
import 'package:centrifuge/src/proto/client.pb.dart' as protocol;
import 'package:centrifuge/src/transport.dart';
import 'package:centrifuge/src/channel.dart'
    if (dart.library.js_interop) 'package:centrifuge/src/channel_html.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'debug_inspector.dart';
import 'debug_traffic_logger.dart';

centrifuge.Client createLoggedRealtimeClient(
  String url,
  centrifuge.ClientConfig config, {
  required DebugInspector inspector,
  required DebugTrafficLogger trafficLogger,
  required bool Function() isCurrentSession,
  required DebugTraceContext Function() context,
}) {
  if (!kDebugMode) return centrifuge.createClient(url, config);
  return ClientImpl(url, config, ({required url, required config}) {
    final observer = _ProtocolObserver(
      inspector,
      trafficLogger,
      isCurrentSession,
      context,
    );
    return Transport(
      () async {
        final channel = connect(
          Uri.parse(url),
          protocols: ['centrifuge-protobuf'],
          headers: config.headers,
          tlsSkipVerify: config.tlsSkipVerify,
        );
        await channel.ready;
        return channel;
      },
      config,
      _CommandEncoder(observer),
      _ReplyDecoder(observer),
    );
  });
}

final class _ProtocolObserver {
  _ProtocolObserver(
    this.inspector,
    this.trafficLogger,
    this.isCurrentSession,
    this.context,
  );
  final DebugInspector inspector;
  final DebugTrafficLogger trafficLogger;
  final bool Function() isCurrentSession;
  final DebugTraceContext Function() context;
  final connectionId = const Uuid().v4();
  final _requestConfigurations = <int, ({int traffic, int inspector})>{};

  void record(
    String direction,
    String operation,
    int protocolId,
    int bytes,
    Object? Function() payload, {
    String? channel,
  }) {
    try {
      if (!isCurrentSession() || !inspector.enabled || inspector.paused) return;
      var capturePayload = true;
      if (protocolId > 0) {
        if (direction == 'send') {
          if (_requestConfigurations.length >= DebugInspector.activeSpanLimit) {
            _requestConfigurations.remove(_requestConfigurations.keys.first);
          }
          _requestConfigurations[protocolId] = (
            traffic: trafficLogger.configurationGeneration,
            inspector: inspector.captureGeneration,
          );
        } else {
          capturePayload =
              _requestConfigurations.remove(protocolId) ==
              (
                traffic: trafficLogger.configurationGeneration,
                inspector: inspector.captureGeneration,
              );
        }
      }
      inspector.record(
        'realtime',
        'socket.$direction.$operation',
        context: context(),
        data: {
          'direction': direction,
          'operation': operation,
          'protocolId': protocolId,
          'connectionId': connectionId,
          'packetBytes': bytes,
          'channel': channel,
          'stage': direction == 'send' ? 'encoded_for_send' : 'decoded_receive',
          if (operation == 'error') 'level': 'error',
          if (!capturePayload)
            'reason': 'request_configuration_changed_or_untracked',
        },
        realtimeDetails: inspector.realtimeDetailsEnabled && capturePayload
            ? trafficLogger.inspectorRealtimeDetails(
                direction: direction,
                operation: operation,
                payload: () => _protocolJson(payload()),
              )
            : null,
      );
    } catch (_) {
      // Never replace a frame, protocol result, error, or application callback.
    }
  }
}

final class _CommandEncoder extends ProtobufCommandEncoder {
  _CommandEncoder(this.observer);
  final _ProtocolObserver observer;
  @override
  List<int> convert(protocol.Command input) {
    final bytes = super.convert(input);
    observer.record(
      'send',
      _commandOperation(input),
      input.id,
      bytes.length,
      input.toProto3Json,
    );
    return bytes;
  }
}

final class _ReplyDecoder extends ProtobufReplyDecoder {
  _ReplyDecoder(this.observer);
  final _ProtocolObserver observer;
  @override
  List<protocol.Reply> convert(List<int> input) {
    final replies = super.convert(input);
    for (final reply in replies) {
      observer.record(
        'receive',
        _replyOperation(reply),
        reply.id,
        input.length,
        reply.toProto3Json,
        channel: reply.hasPush() ? reply.push.channel : null,
      );
    }
    return replies;
  }
}

String _commandOperation(protocol.Command command) {
  if (command.hasConnect()) return 'connect';
  if (command.hasSubscribe()) return 'subscribe';
  if (command.hasUnsubscribe()) return 'unsubscribe';
  if (command.hasPublish()) return 'publish';
  if (command.hasPresence()) return 'presence';
  if (command.hasPresenceStats()) return 'presence_stats';
  if (command.hasHistory()) return 'history';
  if (command.hasRpc()) return 'rpc';
  if (command.hasRefresh()) return 'refresh';
  if (command.hasSubRefresh()) return 'sub_refresh';
  if (command.hasSend()) return 'send';
  if (command.hasPing()) return 'ping';
  return 'pong';
}

String _replyOperation(protocol.Reply reply) {
  if (reply.hasPush()) {
    final push = reply.push;
    if (push.hasPub()) return 'publication';
    if (push.hasSubscribe()) return 'subscribe';
    if (push.hasUnsubscribe()) return 'unsubscribe';
    if (push.hasJoin()) return 'join';
    if (push.hasLeave()) return 'leave';
    if (push.hasDisconnect()) return 'disconnect';
    if (push.hasMessage()) return 'message';
    if (push.hasConnect()) return 'connect';
    if (push.hasRefresh()) return 'refresh';
    return 'push';
  }
  if (reply.hasError()) return 'error';
  if (reply.hasConnect()) return 'connect';
  if (reply.hasSubscribe()) return 'subscribe';
  if (reply.hasUnsubscribe()) return 'unsubscribe';
  if (reply.hasPublish()) return 'publish';
  if (reply.hasPresence()) return 'presence';
  if (reply.hasPresenceStats()) return 'presence_stats';
  if (reply.hasHistory()) return 'history';
  if (reply.hasRpc()) return 'rpc';
  if (reply.hasRefresh()) return 'refresh';
  if (reply.hasSubRefresh()) return 'sub_refresh';
  if (reply.hasPing()) return 'ping';
  return reply.id == 0 ? 'ping' : 'reply';
}

// Protobuf JSON encodes bytes as base64. Decode only protocol byte fields;
// application JSON is returned intact and credential-redacted by the logger.
Object? _protocolJson(Object? value, [int depth = 0]) {
  if (depth > 16) {
    return const {
      'payloadOmitted': true,
      'omissionReason': 'protocol_depth_limit',
    };
  }
  if (value is List) {
    return value.map((item) => _protocolJson(item, depth + 1)).toList();
  }
  if (value is! Map) return value;
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String)
        entry.key as String:
            const {'data', 'connInfo', 'chanInfo'}.contains(entry.key) &&
                entry.value is String
            ? _applicationData(entry.value as String)
            : _protocolJson(entry.value, depth + 1),
  };
}

Object? _applicationData(String encoded) {
  if (encoded.length > DebugHttpTrafficDetails.maxBytes * 4 ~/ 3) {
    return const {
      'payloadOmitted': true,
      'omissionReason': 'application_data_byte_limit',
    };
  }
  try {
    final bytes = base64Decode(encoded);
    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return {'type': 'binary', 'length': bytes.length};
    }
  } on FormatException {
    return const {
      'payloadOmitted': true,
      'omissionReason': 'invalid_protocol_bytes',
    };
  }
}
