import 'dart:async';

import 'app_database.dart';
import 'chat_api.dart';
import 'inbox_sync_queue.dart';
import 'models.dart';

class InboxSyncService {
  InboxSyncService({
    required this.database,
    required this.api,
    required this.userId,
    required this.isCurrentSession,
    bool? restoredHasMoreRooms,
    this.persistHasMoreRooms,
  }) : hasMoreRooms = restoredHasMoreRooms ?? false,
       _paginationKnown = restoredHasMoreRooms != null;
  final AppDatabase database;
  final ChatApi api;
  final String userId;
  final bool Function() isCurrentSession;
  final InboxSyncQueue queue = InboxSyncQueue();
  final StreamController<Map<String, dynamic>> _events =
      StreamController.broadcast();
  Stream<Map<String, dynamic>> get roomEventsStream => _events.stream;
  String? openRoomId;
  bool hasMoreRooms;
  bool _paginationKnown;
  final Future<void> Function(bool)? persistHasMoreRooms;
  Future<void> _setHasMoreRooms(bool value) async {
    hasMoreRooms = value;
    _paginationKnown = true;
    await persistHasMoreRooms?.call(value);
  }

  int deltaRequests = 0;
  int fullSyncs = 0;
  Future<void> syncInboxDelta() async {
    await queue.enqueue(_syncDelta);
  }

  Future<void> _syncDelta() async {
    if (!isCurrentSession()) return;
    final metadata = await database.metadata();
    if (metadata == null) return;
    deltaRequests++;
    final delta = await api.getMap(
      '/rooms/delta',
      query: {'sincePts': metadata.localPts, 'epoch': metadata.localEpoch},
    );
    if (!isCurrentSession()) return;
    if (delta['requiresFullSync'] == true) {
      final full = await api.getMap('/rooms', query: {'limit': 25});
      if (!isCurrentSession()) return;
      final rooms = (full['rooms'] as List).map(jsonMap).toList();
      await database.transaction(() async {
        if (!isCurrentSession()) return;
        await database.replaceFullInbox(rooms);
        await database.setCursor(
          intValue(full['pts']),
          full['epoch'] as String,
        );
      });
      await _setHasMoreRooms(full['nextCursor'] != null);
      fullSyncs++;
      for (final room in rooms) {
        if (!_events.isClosed) _events.add(room);
      }
    } else {
      final rooms = (delta['rooms'] as List? ?? []).map(jsonMap).toList();
      await database.transaction(() async {
        if (!isCurrentSession()) return;
        if (!_paginationKnown) {
          final cached = await database.watchRooms().first;
          await _setHasMoreRooms(
            cached.where((room) => room.pinAt == null).length >= 25,
          );
        }
        for (final room in rooms) {
          // Delta contains only the latest state for a room. It cannot prove
          // that older cached messages contain every intervening mutation.
          await database.applyRoomPayload(
            room,
            myUserId: userId,
            openRoomId: openRoomId,
            markOpenSynced: false,
          );
        }
        await database.setCursor(
          intValue(delta['pts']),
          delta['epoch'] as String,
        );
      });
      for (final room in rooms) {
        if (!_events.isClosed) _events.add(room);
      }
    }
  }

  Future<void> receivePublication(Map<String, dynamic> event) async {
    await queue.enqueue(() async {
      if (!isCurrentSession()) return;
      var metadata = await database.metadata();
      if (metadata == null) return;
      final pts = intValue(event['pts']);
      final epoch = event['epoch'] as String;
      if (metadata.localEpoch.isEmpty ||
          epoch != metadata.localEpoch ||
          pts > metadata.localPts + 1) {
        await _syncDelta();
        if (!isCurrentSession()) return;
        metadata = await database.metadata();
        if (metadata == null) return;
      }
      if (pts <= metadata.localPts || epoch != metadata.localEpoch) return;
      if (pts != metadata.localPts + 1) return;
      final payload = jsonMap(event['room']);
      await database.transaction(() async {
        if (!isCurrentSession()) return;
        await database.applyRoomPayload(
          payload,
          myUserId: userId,
          openRoomId: openRoomId,
        );
        await database.setCursor(pts, epoch);
      });
      if (!_events.isClosed) _events.add(payload);
    });
  }

  /// Mutation resources reconcile optimistics but never alter the inbox cursor.
  Future<void> reconcileMutation(Map<String, dynamic> response) async {
    if (!isCurrentSession()) return;
    await database.transaction(() async {
      if (!isCurrentSession()) return;
      var acceptsResource = true;
      if (response['room'] != null) {
        acceptsResource = await database.applyRoomPayload(
          jsonMap(response['room']),
          myUserId: userId,
          markOpenSynced: false,
        );
      }
      if (response['message'] != null) {
        final message = ChatMessage.fromJson(jsonMap(response['message']));
        final existing = await database.message(message.id);
        final optimistic = await database.messageByIdempotencyKey(
          message.idempotencyKey,
        );
        // A newer room revision may cover a different message. Still acknowledge
        // the outstanding send, while preserving any newer live message body.
        if (acceptsResource ||
            (existing == null &&
                optimistic != null &&
                optimistic.status != 'sent')) {
          await database.upsertMessage(message);
        }
      }
    });
  }

  Future<void> loadMoreRooms() async {
    await queue.enqueue(() async {
      final rooms = await database.watchRooms().first;
      final unpinned = rooms.where((r) => r.pinAt == null).toList();
      if (unpinned.isEmpty || !isCurrentSession()) return;
      final oldest = unpinned.last;
      final page = await api.getMap(
        '/rooms',
        query: {
          'limit': 25,
          'beforeSortTimestamp': oldest.sortTimestamp.toIso8601String(),
          'beforeRoomId': oldest.roomId,
        },
      );
      if (!isCurrentSession()) return;
      await database.transaction(() async {
        for (final room in (page['rooms'] as List).map(jsonMap)) {
          await database.applyRoomPayload(
            room,
            myUserId: userId,
            markOpenSynced: false,
          );
        }
      });
      await _setHasMoreRooms(page['nextCursor'] != null);
    });
  }

  Future<void> dispose() async {
    await queue.clear();
    await _events.close();
  }
}
