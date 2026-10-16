import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'models.dart';

part 'app_database.g.dart';

@DataClassName('SyncMetadataRow')
class SyncMetadata extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get userId => text()();
  IntColumn get localPts => integer().withDefault(const Constant(0))();
  TextColumn get localEpoch => text().withDefault(const Constant(''))();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('LocalRoomRow')
class LocalRooms extends Table {
  TextColumn get roomId => text()();
  TextColumn get roomType => text()();
  TextColumn get peerUserId => text().nullable()();
  TextColumn get displayTitle => text()();
  TextColumn get displayAvatarUrl => text().nullable()();
  IntColumn get pinAt => integer().nullable()();
  BoolColumn get isMuted => boolean().withDefault(const Constant(false))();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  IntColumn get clearedAt => integer().nullable()();
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get sortTimestamp => integer()();
  IntColumn get roomPts => integer()();
  IntColumn get msgPts => integer()();
  IntColumn get lastHistoryEditPts =>
      integer().withDefault(const Constant(0))();
  IntColumn get messagesSyncedPts => integer().withDefault(const Constant(0))();
  TextColumn get lastMessageJson => text().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {roomId};
}

@TableIndex(
  name: 'local_messages_room_created',
  columns: {#roomId, #createdAt, #id},
)
@DataClassName('LocalMessageRow')
class LocalMessages extends Table {
  TextColumn get id => text()();
  TextColumn get idempotencyKey => text().unique()();
  TextColumn get roomId => text()();
  TextColumn get peerUserId => text().nullable()();
  TextColumn get senderId => text()();
  TextColumn get senderName => text()();
  TextColumn get senderAvatarUrl => text().nullable()();
  TextColumn get type => text()();
  TextColumn get content => text().named('text')();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get replyToJson => text().nullable()();
  TextColumn get status => text()();
  BoolColumn get isEdited => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeletedForAll =>
      boolean().withDefault(const Constant(false))();
  IntColumn get deliveredAt => integer().nullable()();
  IntColumn get seenAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DriftDatabase(tables: [SyncMetadata, LocalRooms, LocalMessages])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(
        executor ??
            driftDatabase(
              name: 'chat_app_db',
              web: DriftWebOptions(
                sqlite3Wasm: Uri.parse('sqlite3.wasm'),
                driftWorker: Uri.parse('drift_worker.js'),
              ),
            ),
      );
  @override
  int get schemaVersion => 1;

  Future<void> clearAllTables() => transaction(() async {
    await delete(localMessages).go();
    await delete(localRooms).go();
    await delete(syncMetadata).go();
  });
  Future<void> initializeSession(String userId) async {
    final existing = await metadata();
    if (existing != null && existing.userId != userId) await clearAllTables();
    await into(syncMetadata).insert(
      SyncMetadataCompanion.insert(userId: userId),
      mode: InsertMode.insertOrIgnore,
    );
    await (update(localMessages)..where((m) => m.status.equals('sending')))
        .write(const LocalMessagesCompanion(status: Value('failed')));
  }

  Future<SyncMetadataRow?> metadata() =>
      (select(syncMetadata)..where((s) => s.id.equals(1))).getSingleOrNull();
  Future<void> setCursor(int pts, String epoch) =>
      (update(syncMetadata)..where((s) => s.id.equals(1))).write(
        SyncMetadataCompanion(localPts: Value(pts), localEpoch: Value(epoch)),
      );
  Future<LocalRoomRow?> roomRow(String id) =>
      (select(localRooms)..where((r) => r.roomId.equals(id))).getSingleOrNull();
  Future<ChatRoom?> room(String id) async {
    final row = await roomRow(id);
    return row == null ? null : roomModel(row);
  }

  ChatRoom roomModel(LocalRoomRow r) => ChatRoom(
    roomId: r.roomId,
    roomType: r.roomType,
    peerUserId: r.peerUserId,
    displayTitle: r.displayTitle,
    displayAvatarUrl: r.displayAvatarUrl,
    pinAt: parseTime(r.pinAt),
    isMuted: r.isMuted,
    unreadCount: r.unreadCount,
    clearedAt: parseTime(r.clearedAt),
    deletedAt: parseTime(r.deletedAt),
    sortTimestamp: parseTime(r.sortTimestamp)!,
    roomPts: r.roomPts,
    msgPts: r.msgPts,
    lastHistoryEditPts: r.lastHistoryEditPts,
    messagesSyncedPts: r.messagesSyncedPts,
    lastMessage: r.lastMessageJson == null
        ? null
        : ChatMessage.fromJson(jsonMap(jsonDecode(r.lastMessageJson!))),
  );
  ChatMessage messageModel(LocalMessageRow m) => ChatMessage(
    id: m.id,
    idempotencyKey: m.idempotencyKey,
    roomId: m.roomId,
    peerUserId: m.peerUserId,
    senderId: m.senderId,
    senderName: m.senderName,
    senderAvatarUrl: m.senderAvatarUrl,
    type: m.type,
    text: m.content,
    imageUrl: m.imageUrl,
    replyTo: m.replyToJson == null
        ? null
        : ReplySnapshot.fromJson(jsonMap(jsonDecode(m.replyToJson!))),
    status: m.status,
    isEdited: m.isEdited,
    isDeletedForAll: m.isDeletedForAll,
    deliveredAt: parseTime(m.deliveredAt),
    seenAt: parseTime(m.seenAt),
    createdAt: parseTime(m.createdAt)!,
  );
  Stream<List<ChatRoom>> watchRooms() =>
      customSelect(
        'SELECT * FROM local_rooms WHERE deleted_at IS NULL '
        'ORDER BY CASE WHEN pin_at IS NOT NULL THEN 1 ELSE 0 END DESC, '
        'pin_at DESC, sort_timestamp DESC, room_id DESC',
        readsFrom: {localRooms, localMessages},
      ).watch().asyncMap((rows) async {
        final pending = await (select(
          localMessages,
        )..where((m) => m.status.isIn(['sending', 'failed']))).get();
        final previews = <String, ChatMessage>{};
        for (final row in pending) {
          final message = messageModel(row);
          final previous = previews[message.roomId];
          if (previous == null ||
              message.createdAt.isAfter(previous.createdAt)) {
            previews[message.roomId] = message;
          }
        }
        return rows.map((row) {
          final room = roomModel(localRooms.map(row.data));
          final pending = previews[room.roomId];
          if (pending != null &&
              (room.lastMessage == null ||
                  !pending.createdAt.isBefore(room.lastMessage!.createdAt))) {
            return ChatRoom.fromJson({
              ...room.toJson(),
              'lastMessage': pending.toJson(),
            });
          }
          return room;
        }).toList();
      });
  Stream<List<ChatMessage>> watchMessages(String roomId, int limit) =>
      (select(localMessages)
            ..where((m) => m.roomId.equals(roomId))
            ..orderBy([
              (m) => OrderingTerm.desc(m.createdAt),
              (m) => OrderingTerm.desc(m.id),
            ])
            ..limit(limit))
          .watch()
          .map((rows) => rows.map(messageModel).toList());
  Future<List<ChatMessage>> allMessages(String roomId) async =>
      (await (select(localMessages)
                ..where((m) => m.roomId.equals(roomId))
                ..orderBy([
                  (m) => OrderingTerm.desc(m.createdAt),
                  (m) => OrderingTerm.desc(m.id),
                ]))
              .get())
          .map(messageModel)
          .toList();
  Future<ChatMessage?> message(String id) async {
    final row = await (select(
      localMessages,
    )..where((m) => m.id.equals(id))).getSingleOrNull();
    return row == null ? null : messageModel(row);
  }

  Future<ChatMessage?> messageByIdempotencyKey(String key) async {
    final row = await (select(
      localMessages,
    )..where((m) => m.idempotencyKey.equals(key))).getSingleOrNull();
    return row == null ? null : messageModel(row);
  }

  Future<void> upsertMessage(ChatMessage message) async {
    // REST and socket acknowledgement can race: replace by sender-scoped key.
    final duplicate =
        await (select(localMessages)
              ..where((m) => m.idempotencyKey.equals(message.idempotencyKey)))
            .getSingleOrNull();
    if (duplicate != null && duplicate.id != message.id) {
      await (delete(
        localMessages,
      )..where((m) => m.id.equals(duplicate.id))).go();
    }
    await into(localMessages).insertOnConflictUpdate(
      LocalMessagesCompanion.insert(
        id: message.id,
        idempotencyKey: message.idempotencyKey,
        roomId: message.roomId,
        peerUserId: Value(message.peerUserId),
        senderId: message.senderId,
        senderName: message.senderName,
        senderAvatarUrl: Value(message.senderAvatarUrl),
        type: message.type,
        content: message.text,
        imageUrl: Value(message.imageUrl),
        replyToJson: Value(
          message.replyTo == null
              ? null
              : jsonEncode(message.replyTo!.toJson()),
        ),
        status: message.status,
        isEdited: Value(message.isEdited),
        isDeletedForAll: Value(message.isDeletedForAll),
        deliveredAt: Value(message.deliveredAt?.millisecondsSinceEpoch),
        seenAt: Value(message.seenAt?.millisecondsSinceEpoch),
        createdAt: message.createdAt.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> upsertRoom(ChatRoom room, {bool resetSynced = false}) async {
    final existing = await roomRow(room.roomId);
    if (existing != null && existing.roomPts > room.roomPts) return;
    await into(localRooms).insertOnConflictUpdate(
      LocalRoomsCompanion.insert(
        roomId: room.roomId,
        roomType: room.roomType,
        peerUserId: Value(room.peerUserId),
        displayTitle: room.displayTitle,
        displayAvatarUrl: Value(room.displayAvatarUrl),
        pinAt: Value(room.pinAt?.millisecondsSinceEpoch),
        isMuted: Value(room.isMuted),
        unreadCount: Value(room.unreadCount),
        clearedAt: Value(room.clearedAt?.millisecondsSinceEpoch),
        deletedAt: Value(room.deletedAt?.millisecondsSinceEpoch),
        sortTimestamp: room.sortTimestamp.millisecondsSinceEpoch,
        roomPts: room.roomPts,
        msgPts: room.msgPts,
        lastHistoryEditPts: Value(room.lastHistoryEditPts),
        messagesSyncedPts: Value(
          resetSynced ? 0 : existing?.messagesSyncedPts ?? 0,
        ),
        lastMessageJson: Value(
          room.lastMessage == null
              ? null
              : jsonEncode(room.lastMessage!.toJson()),
        ),
      ),
    );
  }

  Future<void> removeMessage(String id) =>
      (delete(localMessages)..where((m) => m.id.equals(id))).go();
  Future<void> setMessageStatus(String id, String status) =>
      (update(localMessages)..where((m) => m.id.equals(id))).write(
        LocalMessagesCompanion(status: Value(status)),
      );
  Future<void> remapDraft(String draftId, String realId) =>
      (update(localMessages)..where((m) => m.roomId.equals(draftId))).write(
        LocalMessagesCompanion(roomId: Value(realId)),
      );
  Future<void> markMessagesSynced(String roomId, int pts) =>
      (update(localRooms)..where((r) => r.roomId.equals(roomId))).write(
        LocalRoomsCompanion(messagesSyncedPts: Value(pts)),
      );

  /// Must be invoked inside the queue's transaction or mutation reconciliation.
  Future<bool> applyRoomPayload(
    Map<String, dynamic> payload, {
    required String myUserId,
    String? openRoomId,
    bool markOpenSynced = true,
  }) async {
    final room = ChatRoom.fromJson(payload);
    final previous = await roomRow(room.roomId);
    if (previous != null && previous.roomPts > room.roomPts) return false;
    await upsertRoom(room);
    if (room.lastMessage != null) await upsertMessage(room.lastMessage!);
    final updated = payload['updatedMessage'];
    final event = payload['eventType'];
    if (updated != null) {
      final message = ChatMessage.fromJson(jsonMap(updated));
      if (event == 'message_deleted_me') {
        await removeMessage(message.id);
      } else {
        await upsertMessage(message);
        if (message.isDeletedForAll || message.isEdited) {
          final rows =
              await (select(localMessages)..where(
                    (m) =>
                        m.roomId.equals(room.roomId) &
                        m.replyToJson.isNotNull(),
                  ))
                  .get();
          for (final row in rows) {
            final reply = ReplySnapshot.fromJson(
              jsonMap(jsonDecode(row.replyToJson!)),
            );
            if (reply.messageId == message.id) {
              final sanitized = ReplySnapshot.fromMessage(message);
              await (update(
                localMessages,
              )..where((m) => m.id.equals(row.id))).write(
                LocalMessagesCompanion(
                  replyToJson: Value(jsonEncode(sanitized.toJson())),
                ),
              );
            }
          }
        }
      }
    }
    final action = parseTime(payload['actionTimestamp']);
    if (action != null &&
        (event == 'room_delivered' || event == 'room_peer_seen')) {
      final isSeen = event == 'room_peer_seen';
      final rows =
          await (select(localMessages)..where(
                (m) =>
                    m.roomId.equals(room.roomId) &
                    m.senderId.equals(myUserId) &
                    m.createdAt.isSmallerOrEqualValue(
                      action.millisecondsSinceEpoch,
                    ),
              ))
              .get();
      for (final row in rows) {
        await (update(localMessages)..where((m) => m.id.equals(row.id))).write(
          LocalMessagesCompanion(
            deliveredAt: Value(
              row.deliveredAt ?? action.millisecondsSinceEpoch,
            ),
            seenAt: Value(
              isSeen ? row.seenAt ?? action.millisecondsSinceEpoch : row.seenAt,
            ),
          ),
        );
      }
    }
    // A coalesced delta can leave an open room missing intermediate messages.
    // Later contiguous events cannot certify that incomplete cache. Only
    // advance a baseline whose previous content revision was already verified.
    if (markOpenSynced &&
        openRoomId == room.roomId &&
        previous != null &&
        previous.messagesSyncedPts == previous.msgPts) {
      await markMessagesSynced(room.roomId, room.msgPts);
    }
    return true;
  }

  Future<void> replaceFullInbox(List<Map<String, dynamic>> rooms) async {
    // Top page replaces stale room summaries, while message history remains
    // separately cached until opening a room verifies its content revision.
    final ids = rooms.map((r) => r['roomId'] as String).toList();
    await (delete(localRooms)..where((r) => r.roomId.isNotIn(ids))).go();
    for (final payload in rooms) {
      final room = ChatRoom.fromJson(payload);
      await upsertRoom(room, resetSynced: true);
      await markMessagesSynced(room.roomId, 0);
      if (room.lastMessage != null) await upsertMessage(room.lastMessage!);
    }
  }

  /// Latest batches either overlap an unchanged cache or replace the history,
  /// preventing both pagination gaps and undetected edits outside the window.
  Future<bool> reconcileLatest(
    String roomId,
    List<ChatMessage> fresh,
    int expectedMsgPts,
    int historyEditPts,
    int previousSyncedPts,
  ) => transaction(() async {
    final old = await allMessages(roomId);
    final overlap =
        fresh.isNotEmpty &&
        old.any((m) => m.id == fresh.last.id) &&
        historyEditPts <= previousSyncedPts;
    if (!overlap) {
      await (delete(localMessages)..where(
            (m) => m.roomId.equals(roomId) & m.status.equals('sending').not(),
          ))
          .go();
    } else {
      final oldest = fresh.last;
      final ids = fresh.map((m) => m.id).toList();
      await (delete(localMessages)..where(
            (m) =>
                m.roomId.equals(roomId) &
                m.status.equals('sent') &
                m.createdAt.isBiggerOrEqualValue(
                  oldest.createdAt.millisecondsSinceEpoch,
                ) &
                m.id.isNotIn(ids),
          ))
          .go();
    }
    for (final message in fresh) {
      await upsertMessage(message);
    }
    await markMessagesSynced(roomId, expectedMsgPts);
    return overlap;
  });
  Future<Map<String, int>> rowCounts() async {
    final rooms = await customSelect(
      'SELECT COUNT(*) AS total FROM local_rooms',
    ).getSingle();
    final messages = await customSelect(
      'SELECT COUNT(*) AS total FROM local_messages',
    ).getSingle();
    return {
      'storedRoomRows': rooms.read<int>('total'),
      'storedMessageRows': messages.read<int>('total'),
    };
  }

  Future<Map<String, Object?>> inspect() async => {
    'database': 'chat_app_db',
    'metadata': (await metadata())?.toJson(),
    'rowCounts': await rowCounts(),
    'rooms': (await select(localRooms).get()).map((r) => r.toJson()).toList(),
    'messages': (await (select(
      localMessages,
    )..limit(200)).get()).map((m) => m.toJson()).toList(),
  };
}
