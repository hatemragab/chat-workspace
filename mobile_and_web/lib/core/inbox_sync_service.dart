import 'dart:async';
import 'dart:convert';

import 'app_database.dart';
import 'chat_api.dart';
import 'debug_inspector.dart';
import 'inbox_sync_queue.dart';
import 'models.dart';

/// Every content mutation is delivered to historical views. Room recovery and
/// acknowledgement follow-ups run once, using the final committed batch state.
class InboxRoomEvent {
  const InboxRoomEvent({
    required this.payload,
    required this.roomState,
    required this.runRoomFollowUp,
    required this.acknowledge,
    required this.hasIncoming,
    this.legacyDeliveryTimestamp,
  });

  final Map<String, dynamic> payload;
  final LocalRoomRow? roomState;
  final bool runRoomFollowUp, acknowledge, hasIncoming;
  final DateTime? legacyDeliveryTimestamp;
  bool get needsMessageRecovery =>
      roomState != null && roomState!.msgPts != roomState!.messagesSyncedPts;
}

class InboxSyncService {
  InboxSyncService({
    required this.database,
    required this.api,
    required this.userId,
    required this.isCurrentSession,
    bool? restoredHasMoreRooms,
    this.persistHasMoreRooms,
    DebugInspector? inspector,
  }) : hasMoreRooms = restoredHasMoreRooms ?? false,
       _paginationKnown = restoredHasMoreRooms != null,
       inspector = inspector ?? database.debugInspector,
       queue = InboxSyncQueue(inspector: inspector ?? database.debugInspector);
  final AppDatabase database;
  final ChatApi api;
  final String userId;
  final bool Function() isCurrentSession;
  final DebugInspector? inspector;
  final InboxSyncQueue queue;
  final StreamController<InboxRoomEvent> _events = StreamController.broadcast();
  Stream<InboxRoomEvent> get roomEventsStream => _events.stream;
  String? openRoomId;
  bool hasMoreRooms;
  bool _paginationKnown;
  bool _retired = false;
  Future<void>? _closingEvents;
  bool get _isActive => !_retired && isCurrentSession();
  final Future<void> Function(bool)? persistHasMoreRooms;
  Future<void> _setHasMoreRooms(bool value) async {
    if (!_isActive) return;
    hasMoreRooms = value;
    _paginationKnown = true;
    await persistHasMoreRooms?.call(value);
  }

  int deltaRequests = 0;
  int fullSyncs = 0;
  int publicationBatches = 0, publicationEvents = 0;

  void refreshInspectorGauges() {
    queue.refreshInspectorGauges();
    inspector?.setGauges({
      'sync.deltaRequests': deltaRequests,
      'sync.fullSyncs': fullSyncs,
      'sync.publicationBatches': publicationBatches,
      'sync.publicationEvents': publicationEvents,
    });
  }

  Future<T> _trace<T>(
    String operation,
    Future<T> Function() work, {
    Map<String, Object?> data = const {},
  }) => !_isActive
      ? work()
      : inspector?.trace(
              'sync',
              operation,
              work,
              data: data,
              context: inspector?.captureContext().copyWithIdentity(userId),
            ) ??
            work();

  void _cursorAdvanced(int fromPts, int toPts, String mode) {
    inspector?.setGauges({'sync.localPts': toPts});
    inspector?.record(
      'sync',
      'cursor.advance',
      data: {'fromPts': fromPts, 'toPts': toPts, 'mode': mode},
    );
  }

  Future<Map<String, dynamic>?> _getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!_isActive) return null;
    try {
      final response = await api.getMap(path, query: query);
      return _isActive ? response : null;
    } catch (_) {
      if (!_isActive) return null;
      rethrow;
    }
  }

  Future<void> syncInboxDelta() async {
    await queue.enqueue(_syncDelta, operation: 'inbox.delta');
  }

  Future<void> _syncDelta() => _trace('inbox.delta', _syncDeltaWork);

  Future<void> _syncDeltaWork() async {
    if (!_isActive) return;
    final metadata = await database.metadata();
    if (!_isActive || metadata == null) return;
    inspector?.record(
      'sync',
      'delta.request',
      data: {'fromPts': metadata.localPts},
    );
    deltaRequests++;
    inspector?.setGauges({'sync.deltaRequests': deltaRequests});
    final delta = await _getMap(
      '/rooms/delta',
      query: {'sincePts': metadata.localPts, 'epoch': metadata.localEpoch},
    );
    if (delta == null) return;
    if (delta['requiresFullSync'] == true) {
      inspector?.record(
        'sync',
        'full.required',
        data: {'fromPts': metadata.localPts},
      );
      final full = await _getMap(
        '/rooms',
        query: {'limit': 25, 'pinnedLimit': 100},
      );
      if (full == null) return;
      final rooms = (full['rooms'] as List).map(jsonMap).toList();
      var pinnedCursor = full['pinnedNextCursor'];
      while (pinnedCursor != null) {
        final page = await _getMap(
          '/rooms',
          query: {
            'limit': 25,
            'pinnedLimit': 100,
            'pinnedOnly': true,
            ...jsonMap(pinnedCursor),
          },
        );
        if (page == null) return;
        rooms.addAll((page['rooms'] as List).map(jsonMap));
        pinnedCursor = page['pinnedNextCursor'];
      }
      final targetPts = intValue(full['pts']);
      await _trace(
        'inbox.apply.full',
        () => database.transaction(() async {
          if (!_isActive) return;
          await database.replaceFullInbox(rooms);
          if (!_isActive) return;
          await database.setCursor(targetPts, full['epoch'] as String);
          await database.saveRoomPage(
            full['epoch'] as String,
            full['nextCursor'] == null ? null : jsonMap(full['nextCursor']),
          );
        }),
        data: {
          'roomCount': rooms.length,
          'fromPts': metadata.localPts,
          'targetPts': targetPts,
        },
      );
      if (!_isActive) return;
      _cursorAdvanced(metadata.localPts, targetPts, 'full');
      await _setHasMoreRooms(full['nextCursor'] != null);
      if (!_isActive) return;
      fullSyncs++;
      inspector?.setGauges({'sync.fullSyncs': fullSyncs});
      await _emitRoomEvents(rooms);
    } else {
      final rooms = (delta['rooms'] as List? ?? []).map(jsonMap).toList();
      final targetPts = intValue(delta['pts']);
      await _trace(
        'inbox.apply.delta',
        () => database.transaction(() async {
          if (!_isActive) return;
          if (!_paginationKnown) {
            final cached = await database.watchRooms(userId: userId).first;
            if (!_isActive) return;
            await _setHasMoreRooms(
              cached
                      .where(
                        (room) =>
                            room.pinAt == null &&
                            !room.roomId.startsWith('draft_'),
                      )
                      .length >=
                  25,
            );
          }
          for (final room in rooms) {
            if (!_isActive) return;
            // Delta contains only the latest state for a room. It cannot prove
            // that older cached messages contain every intervening mutation.
            await database.applyRoomPayload(
              room,
              myUserId: userId,
              openRoomId: openRoomId,
              markOpenSynced: false,
            );
          }
          if (!_isActive) return;
          if (targetPts != metadata.localPts ||
              delta['epoch'] != metadata.localEpoch) {
            await database.setCursor(targetPts, delta['epoch'] as String);
          }
        }),
        data: {
          'roomCount': rooms.length,
          'fromPts': metadata.localPts,
          'targetPts': targetPts,
        },
      );
      if (!_isActive) return;
      _cursorAdvanced(metadata.localPts, targetPts, 'delta');
      await _emitRoomEvents(rooms);
    }
  }

  final List<_PendingPublication> _publications = [];
  bool _publicationDrainScheduled = false;

  void _publicationDiagnostic(Map<String, dynamic> event, String stage) {
    if (!_isActive) return;
    final payload = _publicationPayload(event);
    final epoch = event['epoch'];
    final pts = event['pts'];
    inspector?.record(
      'realtime',
      'publication.$stage',
      data: {
        'stage': stage == 'received'
            ? 'client_received'
            : stage == 'applied'
            ? 'inbox_applied'
            : 'already_covered',
        'epoch': epoch,
        'pts': pts,
        'roomId': payload['roomId'],
        'eventType': payload['eventType'],
        'channel': 'inbox:user#$userId',
        'correlationKey': 'inbox:$userId:$epoch:$pts',
      },
      context: inspector?.captureContext().copyWithIdentity(userId),
    );
  }

  Future<void> receivePublication(Map<String, dynamic> event) {
    if (!_isActive) return Future<void>.value();
    _publicationDiagnostic(event, 'received');
    final pending = _PendingPublication(event);
    _publications.add(pending);
    _schedulePublicationDrain();
    return pending.done.future;
  }

  void _schedulePublicationDrain() {
    if (_publicationDrainScheduled || !_isActive || _publications.isEmpty) {
      return;
    }
    _publicationDrainScheduled = true;
    unawaited(
      queue
          .enqueue(() async {
            final batch = _publications.take(64).toList();
            _publications.removeRange(0, batch.length);
            try {
              if (_isActive) {
                await _applyPublicationBatch(
                  batch.map((p) => p.event).toList(),
                );
              }
              for (final pending in batch) {
                pending.done.complete();
              }
            } catch (error, stack) {
              for (final pending in batch) {
                pending.done.completeError(error, stack);
              }
            } finally {
              _publicationDrainScheduled = false;
              _schedulePublicationDrain();
            }
          }, operation: 'inbox.publication')
          .then((_) {
            // Retirement discards queued work; all waiters must still terminate.
            if (!_isActive) _finishPendingPublications();
          }),
    );
  }

  void _finishPendingPublications() {
    for (final pending in _publications) {
      pending.done.complete();
    }
    _publications.clear();
  }

  Future<void> _applyPublicationBatch(List<Map<String, dynamic>> events) async {
    final metadata = await database.metadata();
    if (!_isActive || metadata == null) return;
    var expected = metadata.localPts;
    var contiguous = metadata.localEpoch.isNotEmpty;
    final fresh = <Map<String, dynamic>>[];
    for (final event in events) {
      final pts = intValue(event['pts']);
      if (event['epoch'] != metadata.localEpoch) {
        contiguous = false;
        break;
      }
      if (pts <= expected) {
        _publicationDiagnostic(event, 'covered');
        inspector?.record(
          'sync',
          'publication.skip',
          data: {'pts': pts, 'localPts': expected, 'reason': 'coveredOrEpoch'},
        );
        continue;
      }
      if (pts != expected + 1) {
        contiguous = false;
        break;
      }
      fresh.add(event);
      expected = pts;
    }
    if (!contiguous) {
      for (final event in events) {
        await _receivePublicationWork(event);
      }
      return;
    }
    if (fresh.isEmpty) return;
    try {
      await database.transaction(() async {
        for (final event in fresh) {
          if (!_isActive) return;
          await _applyPublicationPayload(event);
        }
        if (!_isActive) return;
        await database.setCursor(expected, metadata.localEpoch);
      });
    } on _MissingPublicationRoom {
      // The failed compact application has rolled back the whole batch. Recover
      // outside that transaction, then replay against the authoritative cursor.
      // Existing rooms need no separate existence query before their mutation.
      await _syncDelta();
      for (final event in events) {
        await _receivePublicationWork(event);
      }
      return;
    }
    if (!_isActive) return;
    publicationBatches++;
    publicationEvents += fresh.length;
    inspector?.record(
      'sync',
      'publication.batch',
      data: {'count': fresh.length},
    );
    refreshInspectorGauges();
    _cursorAdvanced(metadata.localPts, expected, 'publication');
    // Emit each mutation for historical context correctness; one database commit
    // coalesces watch notifications without dropping message content or quotes.
    for (final event in fresh) {
      _publicationDiagnostic(event, 'applied');
    }
    await _emitRoomEvents(fresh.map(_publicationPayload).toList());
  }

  Future<void> _receivePublicationWork(Map<String, dynamic> event) async {
    if (!_isActive) return;
    var metadata = await database.metadata();
    if (!_isActive || metadata == null) return;
    final pts = intValue(event['pts']);
    final epoch = event['epoch'] as String;
    inspector?.record(
      'sync',
      'publication.receive',
      data: {
        'pts': pts,
        'localPts': metadata.localPts,
        'epochMatches': epoch == metadata.localEpoch,
      },
    );
    if (metadata.localEpoch.isEmpty ||
        epoch != metadata.localEpoch ||
        pts > metadata.localPts + 1) {
      inspector?.record(
        'sync',
        'publication.gap',
        data: {'pts': pts, 'localPts': metadata.localPts},
      );
      await _syncDelta();
      if (!_isActive) return;
      metadata = await database.metadata();
      if (!_isActive || metadata == null) return;
    }
    if (pts <= metadata.localPts || epoch != metadata.localEpoch) {
      if (epoch == metadata.localEpoch) {
        _publicationDiagnostic(event, 'covered');
      }
      inspector?.record(
        'sync',
        'publication.skip',
        data: {
          'pts': pts,
          'localPts': metadata.localPts,
          'reason': 'coveredOrEpoch',
        },
      );
      return;
    }
    if (pts != metadata.localPts + 1) {
      inspector?.record(
        'sync',
        'publication.skip',
        data: {
          'pts': pts,
          'localPts': metadata.localPts,
          'reason': 'noncontiguous',
        },
      );
      return;
    }
    final payload = _publicationPayload(event);
    final previousPts = metadata.localPts;
    final applied = await _trace(
      'inbox.apply.publication',
      () async {
        try {
          await database.transaction(() async {
            if (!_isActive) return;
            await _applyPublicationPayload(event);
            if (!_isActive) return;
            await database.setCursor(pts, epoch);
          });
          return true;
        } on _MissingPublicationRoom {
          return false;
        }
      },
      data: {
        'pts': pts,
        'roomId': payload['roomId'],
        'eventType': payload['eventType'],
      },
    );
    if (!applied) {
      await _syncDelta();
      return;
    }
    if (!_isActive) return;
    _cursorAdvanced(previousPts, pts, 'publication');
    _publicationDiagnostic(event, 'applied');
    await _emitRoomEvents([payload]);
  }

  Future<void> _emitRoomEvents(List<Map<String, dynamic>> payloads) async {
    if (!_isActive || _events.isClosed || !_events.hasListener) return;
    final lastIndexes = <String, int>{};
    final acknowledgements = <String>{};
    final incomingRooms = <String>{};
    final legacyDeliveries = <String, DateTime>{};
    for (var index = 0; index < payloads.length; index++) {
      final payload = payloads[index];
      final roomId = payload['roomId'] as String;
      lastIndexes[roomId] = index;
      if (const [
        'room_delivered',
        'room_peer_seen',
        'room_unread_cleared',
      ].contains(payload['eventType'])) {
        continue;
      }
      acknowledgements.add(roomId);
      final last = payload['lastMessage'] == null
          ? null
          : ChatMessage.fromJson(jsonMap(payload['lastMessage']));
      if (intValue(payload['unreadCount']) > 0 ||
          (last != null && last.senderId != userId)) {
        incomingRooms.add(roomId);
      }
      if (last != null &&
          last.senderId != userId &&
          !last.isDelivered &&
          (payload['receiptProtocol'] != 'sequence' ||
              last.messageSeq == null)) {
        final previous = legacyDeliveries[roomId];
        if (previous == null || last.createdAt.isAfter(previous)) {
          legacyDeliveries[roomId] = last.createdAt;
        }
      }
    }
    final states = <String, LocalRoomRow?>{};
    for (final roomId in lastIndexes.keys) {
      // Coverage and certification may have advanced after the payload's room
      // upsert. Read the final state once, after the entire transaction commits.
      states[roomId] = await database.roomRow(roomId);
      if (!_isActive || _events.isClosed) return;
    }
    for (var index = 0; index < payloads.length; index++) {
      final payload = payloads[index];
      final roomId = payload['roomId'] as String;
      final room = states[roomId];
      _events.add(
        InboxRoomEvent(
          payload: {
            ...payload,
            'needsMessageRecovery':
                room != null && room.msgPts != room.messagesSyncedPts,
          },
          roomState: room,
          runRoomFollowUp: index == lastIndexes[roomId],
          acknowledge: acknowledgements.contains(roomId),
          hasIncoming: incomingRooms.contains(roomId),
          legacyDeliveryTimestamp: legacyDeliveries[roomId],
        ),
      );
    }
  }

  Map<String, dynamic> _publicationPayload(Map<String, dynamic> event) =>
      event['unread'] != null
      ? {
          ...jsonMap(event['unread']),
          'compactUnread': true,
          'roomPts': intValue(event['pts']),
        }
      : event['receipt'] == null
      ? jsonMap(event['room'])
      : {
          ...jsonMap(event['receipt']),
          'compactReceipt': true,
          'roomPts': intValue(event['pts']),
          'msgPts': intValue(event['pts']),
        };

  Future<void> _applyPublicationPayload(Map<String, dynamic> event) async {
    if (event['unread'] != null) {
      if (!await database.applyUnreadPayload(
        jsonMap(event['unread']),
        pts: intValue(event['pts']),
      )) {
        throw const _MissingPublicationRoom();
      }
    } else if (event['receipt'] != null) {
      if (!await database.applyReceiptPayload(
        jsonMap(event['receipt']),
        pts: intValue(event['pts']),
        myUserId: userId,
      )) {
        throw const _MissingPublicationRoom();
      }
    } else {
      await database.applyRoomPayload(
        jsonMap(event['room']),
        myUserId: userId,
        openRoomId: openRoomId,
      );
    }
  }

  /// Mutation resources reconcile optimistics but never alter the inbox cursor.
  Future<void> reconcileMutation(Map<String, dynamic> response) => _trace(
    'mutation.reconcile',
    () => _reconcileMutation(response),
    data: {
      'hasRoom': response['room'] != null,
      'hasMessage': response['message'] != null,
    },
  );

  Future<void> _reconcileMutation(Map<String, dynamic> response) async {
    if (!_isActive) return;
    await database.transaction(() async {
      if (!_isActive) return;
      var acceptsResource = true;
      if (response['room'] != null) {
        acceptsResource = await database.applyRoomPayload(
          jsonMap(response['room']),
          myUserId: userId,
          markOpenSynced: false,
        );
      }
      if (!_isActive) return;
      if (response['message'] != null) {
        final message = ChatMessage.fromJson(jsonMap(response['message']));
        if (acceptsResource) {
          // Hydrated mutation responses commonly contain this same message in
          // the room and at the top level. applyRoomPayload already reconciled
          // it, including an optimistic send or a delete-for-me removal.
          if (response['room'] == null ||
              !_messageHandledByRoom(jsonMap(response['room']), message)) {
            await database.upsertMessage(message);
          }
          return;
        }
        final optimistic = await database.messageByIdempotencyKey(
          message.senderId,
          message.idempotencyKey,
        );
        if (!_isActive) return;
        if (optimistic == null || optimistic.status == 'sent') return;
        final existing = await database.message(message.id);
        if (!_isActive) return;
        // A newer room revision may cover a different message. Still acknowledge
        // the outstanding send, while preserving any newer live message body.
        if (existing == null) await database.upsertMessage(message);
      }
    });
  }

  bool _messageHandledByRoom(Map<String, dynamic> room, ChatMessage message) {
    final encoded = jsonEncode(message.toJson());
    for (final field in ['updatedMessage', 'lastMessage']) {
      final value = room[field];
      if (value == null) continue;
      final embedded = ChatMessage.fromJson(jsonMap(value));
      if (room['eventType'] == 'message_deleted_me' &&
          field == 'updatedMessage' &&
          embedded.id == message.id &&
          embedded.senderId == message.senderId &&
          embedded.idempotencyKey == message.idempotencyKey) {
        return true;
      }
      if (jsonEncode(embedded.toJson()) == encoded) return true;
    }
    return false;
  }

  Future<void> loadMoreRooms() async {
    await queue.enqueue(() async {
      if (!_isActive || !hasMoreRooms) return;
      final metadata = await database.metadata();
      if (!_isActive || metadata == null) return;
      final known =
          metadata.roomPageKnown &&
          metadata.roomPageEpoch == metadata.localEpoch;
      if (known && metadata.roomPageCursorJson == null) {
        await _setHasMoreRooms(false);
        return;
      }
      final cursor = known
          ? jsonMap(jsonDecode(metadata.roomPageCursorJson!))
          : <String, dynamic>{};
      final page = await _getMap('/rooms', query: {'limit': 25, ...cursor});
      if (page == null) return;
      await database.transaction(() async {
        if (!_isActive) return;
        for (final room in (page['rooms'] as List).map(jsonMap)) {
          if (!_isActive) return;
          await database.applyRoomPayload(
            room,
            myUserId: userId,
            markOpenSynced: false,
          );
        }
        if (!_isActive) return;
        await database.saveRoomPage(
          metadata.localEpoch,
          page['nextCursor'] == null ? null : jsonMap(page['nextCursor']),
        );
      });
      await _setHasMoreRooms(page['nextCursor'] != null);
    }, operation: 'inbox.rooms.page');
  }

  /// Stop accepting work immediately. A pending HTTP response cannot hold up
  /// account cleanup and will be discarded by the retired session's fences.
  Future<void> retire() async {
    if (_retired) return;
    _retired = true;
    _finishPendingPublications();
    inspector?.record(
      'sync',
      'session.retire',
      data: {'generation': queue.generation},
    );
    queue.retire();
    // Stream completion can wait for a paused consumer. Retirement itself must
    // not let either that consumer or pending HTTP block local account cleanup.
    _closingEvents = _events.close();
    unawaited(_closingEvents);
  }

  Future<void> dispose() async {
    await retire();
    await queue.idle;
    await _closingEvents;
  }
}

class _PendingPublication {
  _PendingPublication(this.event);
  final Map<String, dynamic> event;
  final Completer<void> done = Completer<void>();
}

/// Signals a normal recovery path, distinct from malformed payloads or SQL
/// failures. The inbox cursor must remain with the rolled-back local state.
class _MissingPublicationRoom implements Exception {
  const _MissingPublicationRoom();
}
