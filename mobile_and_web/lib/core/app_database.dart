import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'debug_inspector.dart';
import 'models.dart';
import 'sqlite_query_details.dart';

part 'app_database.g.dart';

typedef OutboundSnapshot = ({
  ChatMessage? head,
  int queued,
  int failed,
  int paused,
});

/// A notification dependency, never a SQL/schema object. Delegating the row
/// mapping keeps this compatible with Drift's customSelect readsFrom API;
/// only entityName is used when registering the watched query's updates.
class _WatchDependency<T, Row> extends ResultSetImplementation<T, Row> {
  _WatchDependency(this.attachedDatabase, this.entityName, this.source);

  @override
  final DatabaseConnectionUser attachedDatabase;
  @override
  final String entityName;
  final ResultSetImplementation<T, Row> source;

  @override
  T get asDslTable => source.asDslTable;
  @override
  List<GeneratedColumn> get $columns => source.$columns;
  @override
  Map<String, GeneratedColumn> get columnsByName => source.columnsByName;
  @override
  FutureOr<Row> map(Map<String, dynamic> data, {String? tablePrefix}) =>
      source.map(data, tablePrefix: tablePrefix);
}

@DataClassName('SyncMetadataRow')
class SyncMetadata extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get userId => text()();
  IntColumn get localPts => integer().withDefault(const Constant(0))();
  TextColumn get localEpoch => text().withDefault(const Constant(''))();
  TextColumn get roomPageCursorJson => text().nullable()();
  TextColumn get roomPageEpoch => text().nullable()();
  BoolColumn get roomPageKnown =>
      boolean().withDefault(const Constant(false))();
  IntColumn get lastOutboundOrder => integer().withDefault(const Constant(0))();
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
  IntColumn get contentPts => integer().nullable()();
  TextColumn get receiptProtocol =>
      text().withDefault(const Constant('legacy'))();
  IntColumn get peerDeliveredSeq => integer().withDefault(const Constant(0))();
  IntColumn get peerSeenSeq => integer().withDefault(const Constant(0))();
  IntColumn get ownDeliveredSeq => integer().withDefault(const Constant(0))();
  IntColumn get ownSeenSeq => integer().withDefault(const Constant(0))();
  IntColumn get receivedThroughSeq =>
      integer().withDefault(const Constant(0))();
  IntColumn get verifiedHeadSeq => integer().withDefault(const Constant(0))();
  TextColumn get receivedRangesJson =>
      text().withDefault(const Constant('[]'))();
  @override
  Set<Column<Object>> get primaryKey => {roomId};
}

@TableIndex(
  name: 'local_messages_room_created',
  columns: {#roomId, #createdAt, #id},
)
@TableIndex(
  name: 'local_messages_reply_target',
  columns: {#roomId, #replyTargetId},
)
@TableIndex(
  name: 'local_messages_outbox',
  columns: {#senderId, #status, #enqueueOrder},
)
@DataClassName('LocalMessageRow')
class LocalMessages extends Table {
  TextColumn get id => text()();
  TextColumn get idempotencyKey => text()();
  TextColumn get roomId => text()();
  TextColumn get peerUserId => text().nullable()();
  TextColumn get senderId => text()();
  TextColumn get senderName => text()();
  TextColumn get senderAvatarUrl => text().nullable()();
  TextColumn get type => text()();
  TextColumn get content => text().named('text')();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get replyToJson => text().nullable()();
  TextColumn get replyTargetId => text().nullable()();
  BlobColumn get uploadBytes => blob().nullable()();
  TextColumn get uploadFilename => text().nullable()();
  TextColumn get status => text()();
  BoolColumn get isEdited => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeletedForAll =>
      boolean().withDefault(const Constant(false))();
  IntColumn get deliveredAt => integer().nullable()();
  IntColumn get seenAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get messageSeq => integer().nullable()();
  BoolColumn get deliveredByCursor =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get seenByCursor => boolean().withDefault(const Constant(false))();
  IntColumn get enqueueOrder => integer().nullable()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  IntColumn get nextAttemptAt => integer().nullable()();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get lastErrorText => text().nullable()();
  BoolColumn get outcomeUnknown =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get outboxPaused => boolean().withDefault(const Constant(false))();
  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {senderId, idempotencyKey},
  ];
}

@DataClassName('ReceiptTaskRow')
class ReceiptTasks extends Table {
  TextColumn get roomId => text()();
  TextColumn get receiptProtocol =>
      text().withDefault(const Constant('legacy'))();
  IntColumn get deliveredTargetSeq =>
      integer().withDefault(const Constant(0))();
  IntColumn get seenTargetSeq => integer().withDefault(const Constant(0))();
  IntColumn get deliveredConfirmedSeq =>
      integer().withDefault(const Constant(0))();
  IntColumn get seenConfirmedSeq => integer().withDefault(const Constant(0))();
  IntColumn get deliveredTargetTimestamp => integer().nullable()();
  IntColumn get seenTargetTimestamp => integer().nullable()();
  IntColumn get deliveredConfirmedTimestamp => integer().nullable()();
  IntColumn get seenConfirmedTimestamp => integer().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {roomId};
}

@DriftDatabase(tables: [SyncMetadata, LocalRooms, LocalMessages, ReceiptTasks])
class AppDatabase extends _$AppDatabase {
  static const _inboxUpdates = '__inbox_projection';
  static const _outboxUpdates = '__outbound_projection';
  late final _inboxDependency = _WatchDependency(
    this,
    _inboxUpdates,
    localMessages,
  );
  late final _outboxDependency = _WatchDependency(
    this,
    _outboxUpdates,
    localMessages,
  );

  /// Ordinary writes keep the broad notification contract. History-only writes
  /// explicitly notify the real tables through super, leaving these projection
  /// dependencies untouched. Drift buffers both kinds in the same transaction.
  @override
  void notifyUpdates(Set<TableUpdate> updates) {
    super.notifyUpdates({
      ...updates,
      if (updates.any(
        (u) =>
            u.table == localMessages.actualTableName ||
            u.table == localRooms.actualTableName,
      ))
        const TableUpdate(_inboxUpdates),
      if (updates.any((u) => u.table == localMessages.actualTableName))
        const TableUpdate(_outboxUpdates),
    });
  }

  AppDatabase([QueryExecutor? executor, DebugInspector? inspector])
    : this._(
        executor ??
            driftDatabase(
              name: 'chat_app_db',
              web: DriftWebOptions(
                sqlite3Wasm: Uri.parse('sqlite3.wasm'),
                driftWorker: Uri.parse('drift_worker.js'),
              ),
            ),
        _DatabaseInspector(inspector),
      );

  AppDatabase._(QueryExecutor executor, this._debug)
    : super(executor.interceptWith(_debug));

  final _DatabaseInspector _debug;
  DebugInspector? get debugInspector => _debug.inspector;

  /// Allows the app's one inspector to observe an injected database as well.
  void attachDebugInspector(DebugInspector? inspector) {
    _debug.inspector = inspector;
    _debug.updateWatchGauges();
  }

  void refreshInspectorGauges() => _debug.updateWatchGauges();

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (migrator, from, to) => transaction(() async {
      if (from < 2) {
        // Rebuild only this table to replace the v1 UUID-only constraint.
        // Drift copies all columns and recreates its indexes atomically.
        await migrator.alterTable(
          TableMigration(
            localMessages,
            newColumns: [
              localMessages.replyTargetId,
              localMessages.uploadBytes,
              localMessages.uploadFilename,
              localMessages.messageSeq,
              localMessages.deliveredByCursor,
              localMessages.seenByCursor,
              localMessages.enqueueOrder,
              localMessages.retryCount,
              localMessages.nextAttemptAt,
              localMessages.lastErrorCode,
              localMessages.lastErrorText,
              localMessages.outcomeUnknown,
              localMessages.outboxPaused,
            ],
          ),
        );
      }
      if (from < 3) {
        // Older versions could certify stale retained content or receipts.
        // Keep their rows and inbox cursor, but require one fresh verification.
        await update(localRooms)
            .write(const LocalRoomsCompanion(messagesSyncedPts: Value(0)));
      }
      if (from < 4) {
        await migrator.addColumn(syncMetadata, syncMetadata.roomPageCursorJson);
        await migrator.addColumn(syncMetadata, syncMetadata.roomPageEpoch);
        await migrator.addColumn(syncMetadata, syncMetadata.roomPageKnown);
        // v1's table rebuild already copies the current message columns.
        if (from >= 2) {
          await migrator.addColumn(localMessages, localMessages.replyTargetId);
          await migrator.addColumn(localMessages, localMessages.uploadBytes);
          await migrator.addColumn(localMessages, localMessages.uploadFilename);
        }
        await customStatement(
          'UPDATE local_messages SET reply_target_id = '
          "json_extract(reply_to_json, '\$.messageId') WHERE reply_to_json IS NOT NULL",
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS local_messages_reply_target '
          'ON local_messages (room_id, reply_target_id)',
        );
      }
      if (from < 5) {
        await migrator.createTable(receiptTasks);
        for (final column in [
          localRooms.contentPts,
          localRooms.receiptProtocol,
          localRooms.peerDeliveredSeq,
          localRooms.peerSeenSeq,
          localRooms.ownDeliveredSeq,
          localRooms.ownSeenSeq,
          localRooms.receivedThroughSeq,
          localRooms.verifiedHeadSeq,
          localRooms.receivedRangesJson,
        ]) {
          await migrator.addColumn(localRooms, column);
        }
        if (from >= 2) {
          await migrator.addColumn(localMessages, localMessages.messageSeq);
          await migrator.addColumn(
            localMessages,
            localMessages.deliveredByCursor,
          );
          await migrator.addColumn(localMessages, localMessages.seenByCursor);
        }
      }
      if (from < 6) {
        await migrator.addColumn(syncMetadata, syncMetadata.lastOutboundOrder);
        // The v1 rebuild above already includes all current message columns.
        if (from >= 2) {
          for (final column in [
            localMessages.enqueueOrder,
            localMessages.retryCount,
            localMessages.nextAttemptAt,
            localMessages.lastErrorCode,
            localMessages.lastErrorText,
            localMessages.outcomeUnknown,
            localMessages.outboxPaused,
          ]) {
            await migrator.addColumn(localMessages, column);
          }
        }
        // Preserve historical failures for explicit Retry: their original
        // failure classification is unknown. Interrupted sends retain FIFO.
        final interrupted =
            await (select(localMessages)
                  ..where((m) => m.status.isIn(['queued', 'sending']))
                  ..orderBy([
                    (m) => OrderingTerm.asc(m.createdAt),
                    (m) => OrderingTerm.asc(m.id),
                  ]))
                .get();
        var order = 0;
        for (final row in interrupted) {
          await (update(localMessages)..where((m) => m.id.equals(row.id)))
              .write(LocalMessagesCompanion(enqueueOrder: Value(++order)));
        }
        await (update(syncMetadata)..where((m) => m.id.equals(1))).write(
          SyncMetadataCompanion(lastOutboundOrder: Value(order)),
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS local_messages_outbox '
          'ON local_messages (sender_id, status, enqueue_order)',
        );
      }
    }),
  );

  Future<void> clearAllTables() => transaction(() async {
    await delete(localMessages).go();
    await delete(localRooms).go();
    await delete(syncMetadata).go();
    await delete(receiptTasks).go();
  });
  static final Object _transactionOwner = Object();
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) => super.transaction(
    () => runZoned(action, zoneValues: {_transactionOwner: this}),
    requireNew: requireNew,
  );
  Future<T> _atomic<T>(Future<T> Function() work) =>
      identical(Zone.current[_transactionOwner], this)
      ? work()
      : transaction(work);
  Future<void> initializeSession(String userId) async {
    final existing = await metadata();
    if (existing != null && existing.userId != userId) await clearAllTables();
    await into(syncMetadata).insert(
      SyncMetadataCompanion.insert(userId: userId),
      mode: InsertMode.insertOrIgnore,
    );
    await recoverInterruptedSends(userId);
    await _restorePendingDraftRooms(userId);
  }

  Future<void> _restorePendingDraftRooms(String userId) async {
    final pending =
        await (select(localMessages)
              ..where(
                (m) =>
                    m.senderId.equals(userId) &
                    m.status.isIn(['queued', 'sending', 'failed']),
              )
              ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
            .get();
    final restored = <String>{};
    for (final row in pending) {
      if (!row.roomId.startsWith('draft_') || !restored.add(row.roomId)) {
        continue;
      }
      if (await roomRow(row.roomId) != null) continue;
      final peerId = row.roomId.substring('draft_'.length);
      if (peerId.isEmpty) continue;
      await upsertDraftRoom(
        UserProfile(id: peerId, username: peerId, displayName: peerId),
        messageModel(row),
      );
    }
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
    contentPts: r.contentPts,
    receiptProtocol: r.receiptProtocol,
    peerDeliveredSeq: r.peerDeliveredSeq,
    peerSeenSeq: r.peerSeenSeq,
    ownDeliveredSeq: r.ownDeliveredSeq,
    ownSeenSeq: r.ownSeenSeq,
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
    uploadBytes: m.uploadBytes,
    uploadFilename: m.uploadFilename,
    status: m.status,
    isEdited: m.isEdited,
    isDeletedForAll: m.isDeletedForAll,
    deliveredAt: parseTime(m.deliveredAt),
    seenAt: parseTime(m.seenAt),
    createdAt: parseTime(m.createdAt)!,
    messageSeq: m.messageSeq,
    deliveredByCursor: m.deliveredByCursor,
    seenByCursor: m.seenByCursor,
    enqueueOrder: m.enqueueOrder,
    retryCount: m.retryCount,
    nextAttemptAt: parseTime(m.nextAttemptAt),
    lastErrorCode: m.lastErrorCode,
    lastErrorText: m.lastErrorText,
    outcomeUnknown: m.outcomeUnknown,
    outboxPaused: m.outboxPaused,
  );

  /// Session owners pass their captured account. Older callers resolve it once
  /// per subscription, keeping cursor-only writes out of the room dependency set.
  Stream<List<ChatRoom>> watchRooms({String? userId}) => _debug.watch(
    'rooms',
    userId == null
        ? Stream.fromFuture(metadata()).asyncExpand(
            (metadata) => _watchRoomPreviews(metadata?.userId ?? ''),
          )
        : _watchRoomPreviews(userId),
  );

  Stream<List<ChatRoom>> _watchRoomPreviews(String userId) {
    // Inbox previews need display and receipt fields, not upload blobs, reply
    // snapshots or retry counters. Conversation and outbox reads retain full rows.
    final previewColumns = [
      localMessages.id,
      localMessages.idempotencyKey,
      localMessages.roomId,
      localMessages.senderId,
      localMessages.senderName,
      localMessages.type,
      localMessages.content,
      localMessages.imageUrl,
      localMessages.status,
      localMessages.isEdited,
      localMessages.isDeletedForAll,
      localMessages.deliveredAt,
      localMessages.seenAt,
      localMessages.createdAt,
      localMessages.messageSeq,
      localMessages.deliveredByCursor,
      localMessages.seenByCursor,
      localMessages.outcomeUnknown,
      localMessages.outboxPaused,
    ];
    return customSelect(
      'WITH pending_messages AS ('
      'SELECT ${previewColumns.map((column) => column.name).join(', ')}, '
      'ROW_NUMBER() OVER (PARTITION BY room_id '
      'ORDER BY created_at DESC, id DESC) AS pending_rank FROM local_messages '
      "WHERE sender_id = ? AND status IN ('queued', 'sending', 'failed')) "
      'SELECT r.*, ${previewColumns.map((column) => 'pending.${column.name} AS pending_${column.name}').join(', ')} '
      'FROM local_rooms r LEFT JOIN pending_messages pending '
      'ON pending.room_id = r.room_id AND pending.pending_rank = 1 '
      'WHERE r.deleted_at IS NULL '
      'ORDER BY CASE WHEN r.pin_at IS NOT NULL THEN 1 ELSE 0 END DESC, '
      'r.pin_at DESC, r.sort_timestamp DESC, r.room_id DESC',
      variables: [Variable(userId)],
      readsFrom: {_inboxDependency},
    ).watch().map(
      (rows) => rows.map((row) {
        final room = roomModel(localRooms.map(row.data));
        if (row.data['pending_id'] == null) return room;
        final pending = ChatMessage(
          id: row.read<String>('pending_id'),
          idempotencyKey: row.read<String>('pending_idempotency_key'),
          roomId: row.read<String>('pending_room_id'),
          senderId: row.read<String>('pending_sender_id'),
          senderName: row.read<String>('pending_sender_name'),
          type: row.read<String>('pending_type'),
          text: row.read<String>('pending_text'),
          imageUrl: row.readNullable<String>('pending_image_url'),
          status: row.read<String>('pending_status'),
          isEdited: row.read<bool>('pending_is_edited'),
          isDeletedForAll: row.read<bool>('pending_is_deleted_for_all'),
          deliveredAt: parseTime(row.readNullable<int>('pending_delivered_at')),
          seenAt: parseTime(row.readNullable<int>('pending_seen_at')),
          createdAt: parseTime(row.read<int>('pending_created_at'))!,
          messageSeq: row.readNullable<int>('pending_message_seq'),
          deliveredByCursor: row.read<bool>('pending_delivered_by_cursor'),
          seenByCursor: row.read<bool>('pending_seen_by_cursor'),
          outcomeUnknown: row.read<bool>('pending_outcome_unknown'),
          outboxPaused: row.read<bool>('pending_outbox_paused'),
        );
        if (room.lastMessage != null &&
            pending.createdAt.isBefore(room.lastMessage!.createdAt)) {
          return room;
        }
        return ChatRoom.fromJson({
          ...room.toJson(),
          'lastMessage': pending.toJson(),
        });
      }).toList(),
    );
  }

  Stream<List<ChatMessage>> watchMessages(String roomId, int limit) =>
      _debug.watch(
        'messages',
        (select(localMessages)
              ..where((m) => m.roomId.equals(roomId))
              ..orderBy([
                (m) => OrderingTerm.desc(m.createdAt),
                (m) => OrderingTerm.desc(m.id),
              ])
              ..limit(limit))
            .watch()
            .map((rows) => rows.map(messageModel).toList()),
        data: {'roomId': roomId, 'limit': limit},
      );
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
  Future<List<ChatMessage>> messageWindow(String roomId, int limit) async =>
      (await (select(localMessages)
                ..where((m) => m.roomId.equals(roomId))
                ..orderBy([
                  (m) => OrderingTerm.desc(m.createdAt),
                  (m) => OrderingTerm.desc(m.id),
                ])
                ..limit(limit))
              .get())
          .map(messageModel)
          .toList();
  Future<int> messageCount(String roomId, {bool sentOnly = false}) async {
    final result = await customSelect(
      'SELECT COUNT(*) AS total FROM local_messages '
      'WHERE room_id = ?${sentOnly ? " AND status = 'sent'" : ''}',
      variables: [Variable(roomId)],
      readsFrom: {localMessages},
    ).getSingle();
    return result.read<int>('total');
  }

  Future<int> messageOffset(ChatMessage target) async {
    final result = await customSelect(
      'SELECT COUNT(*) AS total FROM local_messages '
      'WHERE room_id = ? AND (created_at > ? OR (created_at = ? AND id > ?))',
      variables: [
        Variable(target.roomId),
        Variable(target.createdAt.millisecondsSinceEpoch),
        Variable(target.createdAt.millisecondsSinceEpoch),
        Variable(target.id),
      ],
      readsFrom: {localMessages},
    ).getSingle();
    return result.read<int>('total');
  }

  Future<List<ChatMessage>> localContext(ChatMessage target) async {
    final timestamp = target.createdAt.millisecondsSinceEpoch;
    final rows = await customSelect(
      'SELECT * FROM (SELECT * FROM local_messages '
      'WHERE room_id = ? AND (created_at < ? OR (created_at = ? AND id <= ?)) '
      'ORDER BY created_at DESC, id DESC LIMIT 16) UNION ALL SELECT * FROM '
      '(SELECT * FROM local_messages WHERE room_id = ? AND '
      '(created_at > ? OR (created_at = ? AND id > ?)) '
      'ORDER BY created_at ASC, id ASC LIMIT 15) ORDER BY created_at DESC, id DESC',
      variables: [
        Variable(target.roomId),
        Variable(timestamp),
        Variable(timestamp),
        Variable(target.id),
        Variable(target.roomId),
        Variable(timestamp),
        Variable(timestamp),
        Variable(target.id),
      ],
      readsFrom: {localMessages},
    ).get();
    return rows
        .map((row) => messageModel(localMessages.map(row.data)))
        .toList();
  }

  Future<ChatMessage?> oldestSent(String roomId) async {
    final row =
        await (select(localMessages)
              ..where((m) => m.roomId.equals(roomId) & m.status.equals('sent'))
              ..orderBy([
                (m) => OrderingTerm.asc(m.createdAt),
                (m) => OrderingTerm.asc(m.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : messageModel(row);
  }

  Future<void> saveRoomPage(String epoch, Map<String, dynamic>? cursor) =>
      (update(syncMetadata)..where((m) => m.id.equals(1))).write(
        SyncMetadataCompanion(
          roomPageEpoch: Value(epoch),
          roomPageCursorJson: Value(cursor == null ? null : jsonEncode(cursor)),
          roomPageKnown: const Value(true),
        ),
      );
  Future<void> checkUploadQuota(int bytes) async {
    final row = await customSelect(
      'SELECT COUNT(*) AS files, COALESCE(SUM(length(upload_bytes)),0) AS bytes '
      'FROM local_messages WHERE upload_bytes IS NOT NULL',
    ).getSingle();
    if (bytes > 5 * 1024 * 1024 ||
        row.read<int>('files') >= 20 ||
        row.read<int>('bytes') + bytes > 20 * 1024 * 1024) {
      throw StateError(
        'Pending images exceed the 20-file / 20 MB local upload quota. Retry existing images first.',
      );
    }
  }

  Future<ChatMessage?> message(String id) async {
    final row = await (select(
      localMessages,
    )..where((m) => m.id.equals(id))).getSingleOrNull();
    return row == null ? null : messageModel(row);
  }

  Future<ChatMessage?> messageByIdempotencyKey(
    String senderId,
    String key,
  ) async {
    final row =
        await (select(localMessages)..where(
              (m) => m.senderId.equals(senderId) & m.idempotencyKey.equals(key),
            ))
            .getSingleOrNull();
    return row == null ? null : messageModel(row);
  }

  /// Includes a paused or delayed head so newer messages cannot bypass it.
  Future<ChatMessage?> nextOutboundMessage(String senderId) async {
    final row =
        await (select(localMessages)
              ..where(
                (m) =>
                    m.senderId.equals(senderId) &
                    m.status.isIn(['queued', 'sending']),
              )
              ..orderBy([
                (m) => OrderingTerm.asc(m.enqueueOrder),
                (m) => OrderingTerm.asc(m.createdAt),
                (m) => OrderingTerm.asc(m.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : messageModel(row);
  }

  Future<({int queued, int failed, int paused})> outboundCounts(
    String senderId,
  ) async {
    final row = await customSelect(
      "SELECT COALESCE(SUM(CASE WHEN status IN ('queued', 'sending') "
      'THEN 1 ELSE 0 END), 0) AS queued, '
      "COALESCE(SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END), 0) AS failed, "
      "COALESCE(SUM(CASE WHEN status IN ('queued', 'sending') AND outbox_paused = 1 "
      'THEN 1 ELSE 0 END), 0) AS paused '
      'FROM local_messages WHERE sender_id = ? '
      "AND status IN ('queued', 'sending', 'failed')",
      variables: [Variable(senderId)],
      readsFrom: {localMessages},
    ).getSingle();
    return (
      queued: row.read<int>('queued'),
      failed: row.read<int>('failed'),
      paused: row.read<int>('paused'),
    );
  }

  Selectable<QueryRow> _outboundSnapshotQuery(String senderId) => customSelect(
    "WITH counts AS (SELECT COALESCE(SUM(CASE WHEN status IN ('queued', 'sending') "
    'THEN 1 ELSE 0 END), 0) AS queued, '
    "COALESCE(SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END), 0) AS failed, "
    "COALESCE(SUM(CASE WHEN status IN ('queued', 'sending') AND outbox_paused = 1 "
    'THEN 1 ELSE 0 END), 0) AS paused FROM local_messages '
    "WHERE sender_id = ? AND status IN ('queued', 'sending', 'failed')), "
    'head AS (SELECT * FROM local_messages WHERE sender_id = ? '
    "AND status IN ('queued', 'sending') "
    'ORDER BY enqueue_order ASC, created_at ASC, id ASC LIMIT 1) '
    'SELECT counts.*, head.* FROM counts LEFT JOIN head ON 1 = 1',
    variables: [Variable(senderId), Variable(senderId)],
    readsFrom: {_outboxDependency},
  );

  OutboundSnapshot _outboundSnapshot(QueryRow row) => (
    head: row.data['id'] == null
        ? null
        : messageModel(localMessages.map(row.data)),
    queued: row.read<int>('queued'),
    failed: row.read<int>('failed'),
    paused: row.read<int>('paused'),
  );

  Future<OutboundSnapshot> outboundSnapshot(String senderId) async =>
      _outboundSnapshot(await _outboundSnapshotQuery(senderId).getSingle());

  Stream<OutboundSnapshot> watchOutboundSnapshot(String senderId) =>
      _outboundSnapshotQuery(senderId).watchSingle().map(_outboundSnapshot);

  Future<int> _allocateOutboundOrder(String senderId) async {
    final session = await metadata();
    if (session == null || session.userId != senderId) {
      throw StateError(
        'The outgoing message does not match the local session.',
      );
    }
    final next = session.lastOutboundOrder + 1;
    await (update(syncMetadata)..where((m) => m.id.equals(1))).write(
      SyncMetadataCompanion(lastOutboundOrder: Value(next)),
    );
    return next;
  }

  Future<void> enqueueOutboundMessage(
    ChatMessage message, {
    UserProfile? peer,
  }) => _atomic(() async {
    final existing = await messageByIdempotencyKey(
      message.senderId,
      message.idempotencyKey,
    );
    if (existing != null) return;
    final order = await _allocateOutboundOrder(message.senderId);
    final queued = message.copyWith(
      status: 'queued',
      enqueueOrder: order,
      retryCount: 0,
      outcomeUnknown: false,
      outboxPaused: false,
      clearError: true,
      clearRetryAt: true,
    );
    await upsertMessage(queued);
    if (peer != null) await upsertDraftRoom(peer, queued);
  });

  Future<void> updateOutboundState(
    String senderId,
    String key, {
    String? status,
    int? retryCount,
    DateTime? nextAttemptAt,
    String? errorCode,
    String? errorMessage,
    bool? outcomeUnknown,
    bool? paused,
    bool clearError = false,
    bool clearRetryAt = false,
  }) {
    if (status != null &&
        !const ['queued', 'sending', 'failed'].contains(status)) {
      throw ArgumentError.value(status, 'status', 'Invalid outgoing state');
    }
    if (retryCount != null && retryCount < 0) {
      throw ArgumentError.value(
        retryCount,
        'retryCount',
        'Must be nonnegative',
      );
    }
    // The predicate and write are one SQLite statement: late failures cannot
    // overwrite a REST, inbox or realtime acknowledgement.
    return (update(localMessages)..where(
          (m) =>
              m.senderId.equals(senderId) &
              m.idempotencyKey.equals(key) &
              m.status.isNotIn(['sent']),
        ))
        .write(
          LocalMessagesCompanion(
            status: status == null ? const Value.absent() : Value(status),
            retryCount: retryCount == null
                ? const Value.absent()
                : Value(retryCount),
            nextAttemptAt: clearRetryAt
                ? const Value(null)
                : nextAttemptAt == null
                ? const Value.absent()
                : Value(nextAttemptAt.millisecondsSinceEpoch),
            lastErrorCode: clearError
                ? const Value(null)
                : errorCode == null
                ? const Value.absent()
                : Value(errorCode),
            lastErrorText: clearError
                ? const Value(null)
                : errorMessage == null
                ? const Value.absent()
                : Value(errorMessage),
            outcomeUnknown: outcomeUnknown == null
                ? const Value.absent()
                : Value(outcomeUnknown),
            outboxPaused: paused == null ? const Value.absent() : Value(paused),
          ),
        )
        .then((_) {});
  }

  Future<void> retryOutboundMessage(String senderId, String key) =>
      _atomic(() async {
        final message = await messageByIdempotencyKey(senderId, key);
        if (message == null || message.status == 'sent') return;
        if (message.enqueueOrder == null) {
          final order = await _allocateOutboundOrder(senderId);
          await (update(localMessages)..where(
                (m) =>
                    m.senderId.equals(senderId) &
                    m.idempotencyKey.equals(key) &
                    m.status.isNotIn(['sent']),
              ))
              .write(LocalMessagesCompanion(enqueueOrder: Value(order)));
        }
        await updateOutboundState(
          senderId,
          key,
          status: 'queued',
          retryCount: 0,
          paused: false,
          clearError: true,
          clearRetryAt: true,
        );
      });

  Future<void> recoverInterruptedSends(String senderId) => _atomic(() async {
    final missingOrder =
        await (select(localMessages)
              ..where(
                (m) =>
                    m.senderId.equals(senderId) &
                    m.status.isIn(['queued', 'sending']) &
                    m.enqueueOrder.isNull(),
              )
              ..orderBy([
                (m) => OrderingTerm.asc(m.createdAt),
                (m) => OrderingTerm.asc(m.id),
              ]))
            .get();
    for (final row in missingOrder) {
      final order = await _allocateOutboundOrder(senderId);
      await (update(localMessages)..where((m) => m.id.equals(row.id))).write(
        LocalMessagesCompanion(enqueueOrder: Value(order)),
      );
    }
    await (update(localMessages)..where(
          (m) => m.senderId.equals(senderId) & m.status.equals('sending'),
        ))
        .write(
          const LocalMessagesCompanion(
            status: Value('queued'),
            outcomeUnknown: Value(true),
            nextAttemptAt: Value(null),
          ),
        );
  });

  Future<void> upsertMessage(ChatMessage message) => upsertMessages([message]);

  /// Read shared reconciliation context once per batch. It stays inside this
  /// transaction, so account changes and concurrent acknowledgements cannot
  /// make the cached rows stale between messages.
  Future<void> upsertMessages(List<ChatMessage> messages) => _atomic(() async {
    await _upsertMessages(messages);
  });

  /// Persists a history page and its receipt/coverage proof with one shared
  /// transaction-local account and room context. Older history does not verify
  /// the current head or advance the inbox/message-sync revision.
  Future<void> storeOlderMessagePage(
    String roomId,
    List<ChatMessage> messages, {
    Map<String, dynamic>? coverage,
    Map<String, dynamic>? receiptState,
    String? userId,
  }) => _atomic(() async {
    if (messages.any((message) => message.roomId != roomId)) {
      throw ArgumentError('Every history message must belong to its room.');
    }
    final user = userId ?? (await metadata())?.userId;
    final rooms = await _upsertMessages(
      messages,
      userId: user,
      userIdResolved: true,
      historyPage: true,
    );
    var currentRoom = rooms.containsKey(roomId)
        ? rooms[roomId]
        : await roomRow(roomId);
    if (currentRoom == null) return;
    if (coverage != null && receiptState != null && user != null) {
      currentRoom = await _applySequenceSnapshot(
        roomId,
        receiptState,
        previous: currentRoom,
        userId: user,
        historyPage: true,
      );
    }
    if (coverage != null) {
      final from = intValue(coverage['fromSeq']);
      final through = intValue(coverage['throughSeq']);
      await _recordMessageRanges(roomId, [
        if (from > 0 && through >= from) [from, through],
      ], row: currentRoom);
    }
  });

  Future<Map<String, LocalRoomRow?>> _upsertMessages(
    List<ChatMessage> messages, {
    String? userId,
    bool userIdResolved = false,
    bool historyPage = false,
    Map<String, LocalRoomRow?> knownRooms = const {},
    Map<(String, String), LocalMessageRow?> knownDuplicates = const {},
  }) async {
    if (messages.isEmpty) return {...knownRooms};
    final sentRoomIds = messages
        .where((m) => m.status == 'sent')
        .map((m) => m.roomId)
        .toSet();
    String? user;
    if (sentRoomIds.isNotEmpty) {
      user = userIdResolved ? userId : userId ?? (await metadata())?.userId;
    }
    final rooms = <String, LocalRoomRow?>{...knownRooms};
    final roomIds = sentRoomIds.where((id) => !rooms.containsKey(id)).toList();
    for (var offset = 0; offset < roomIds.length; offset += 200) {
      final chunk = roomIds.sublist(
        offset,
        math.min(offset + 200, roomIds.length),
      );
      // Missing rooms are resolved context too. They cannot acquire coverage
      // in this transaction and must not trigger a second fallback SELECT.
      rooms.addEntries(chunk.map((id) => MapEntry(id, null)));
      for (final row in await (select(
        localRooms,
      )..where((r) => r.roomId.isIn(chunk))).get()) {
        rooms[row.roomId] = row;
      }
    }
    final duplicates = <(String, String), LocalMessageRow?>{...knownDuplicates};
    final unknown = messages
        .where((m) => !duplicates.containsKey((m.senderId, m.idempotencyKey)))
        .toList();
    // Bound SQL variables for recovery pages and large full-inbox responses.
    for (var offset = 0; offset < unknown.length; offset += 200) {
      final chunk = unknown.sublist(
        offset,
        math.min(offset + 200, unknown.length),
      );
      for (final row
          in await (select(localMessages)..where(
                (m) =>
                    m.senderId.isIn(chunk.map((m) => m.senderId).toSet()) &
                    m.idempotencyKey.isIn(
                      chunk.map((m) => m.idempotencyKey).toSet(),
                    ),
              ))
              .get()) {
        duplicates[(row.senderId, row.idempotencyKey)] = row;
      }
    }
    final ranges = <String, List<List<int>>>{};
    final pending = <LocalMessageRow>[];
    var affectsPending = false;
    Future<void> flush() async {
      if (pending.isEmpty) return;
      await _writeMessageRows(
        pending,
        notifyProjections: !historyPage || affectsPending,
      );
      pending.clear();
      affectsPending = false;
    }

    for (final message in messages) {
      final key = (message.senderId, message.idempotencyKey);
      final duplicate = duplicates[key];
      if (duplicate?.status == 'sent' && message.status != 'sent') continue;
      if (duplicate != null && duplicate.id != message.id) {
        // Identity adoption must observe earlier inputs before deleting their
        // optimistic identity or moving the rest of their pending draft.
        await flush();
        if (duplicate.roomId.startsWith('draft_') &&
            const ['queued', 'sending', 'failed'].contains(duplicate.status) &&
            !message.roomId.startsWith('draft_') &&
            message.status == 'sent') {
          await remapDraft(duplicate.roomId, message.roomId);
          for (final entry in duplicates.entries.toList()) {
            if (entry.value?.roomId == duplicate.roomId) {
              duplicates[entry.key] = entry.value!.copyWith(
                roomId: message.roomId,
              );
            }
          }
        }
        await (delete(
          localMessages,
        )..where((m) => m.id.equals(duplicate.id))).go();
      }
      final row = _mergeMessage(
        message,
        duplicate,
        rooms[message.roomId],
        user,
      );
      duplicates[key] = row;
      if (row != duplicate) {
        pending.add(row);
        // An older page can acknowledge an uncertain offline send. Its queue
        // head/count and optimistic inbox preview must still refresh.
        affectsPending |=
            row.status != 'sent' ||
            (duplicate != null && duplicate.status != 'sent');
      }
      if (message.status == 'sent' && message.messageSeq != null) {
        ranges.putIfAbsent(message.roomId, () => []).add([
          message.messageSeq!,
          message.messageSeq!,
        ]);
      }
    }
    await flush();
    for (final entry in ranges.entries) {
      final room = rooms[entry.key];
      if (room == null) continue;
      final row = await _recordMessageRanges(entry.key, entry.value, row: room);
      if (row != null) rooms[entry.key] = row;
    }
    return rooms;
  }

  LocalMessageRow _mergeMessage(
    ChatMessage message,
    LocalMessageRow? duplicate,
    LocalRoomRow? room,
    String? user,
  ) {
    final effective = user == null || room == null
        ? message
        : applySequenceReceipts(
            message,
            user,
            room.peerDeliveredSeq,
            room.peerSeenSeq,
          );
    final values = LocalMessagesCompanion.insert(
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
        message.replyTo == null ? null : jsonEncode(message.replyTo!.toJson()),
      ),
      replyTargetId: Value(message.replyTo?.messageId),
      uploadBytes: Value(message.uploadBytes),
      uploadFilename: Value(message.uploadFilename),
      status: message.status,
      isEdited: Value(message.isEdited),
      isDeletedForAll: Value(message.isDeletedForAll),
      deliveredAt: Value(
        message.deliveredAt?.millisecondsSinceEpoch ?? duplicate?.deliveredAt,
      ),
      seenAt: Value(
        message.seenAt?.millisecondsSinceEpoch ?? duplicate?.seenAt,
      ),
      createdAt: message.createdAt.millisecondsSinceEpoch,
      messageSeq: Value(message.messageSeq ?? duplicate?.messageSeq),
      deliveredByCursor: Value(
        effective.deliveredByCursor || duplicate?.deliveredByCursor == true,
      ),
      seenByCursor: Value(
        effective.seenByCursor || duplicate?.seenByCursor == true,
      ),
      enqueueOrder: Value(
        message.status == 'sent'
            ? null
            : duplicate?.enqueueOrder ?? message.enqueueOrder,
      ),
      retryCount: Value(
        message.status == 'sent'
            ? 0
            : duplicate?.retryCount ?? message.retryCount,
      ),
      nextAttemptAt: Value(
        message.status == 'sent'
            ? null
            : duplicate?.nextAttemptAt ??
                  message.nextAttemptAt?.millisecondsSinceEpoch,
      ),
      lastErrorCode: Value(
        message.status == 'sent'
            ? null
            : duplicate?.lastErrorCode ?? message.lastErrorCode,
      ),
      lastErrorText: Value(
        message.status == 'sent'
            ? null
            : duplicate?.lastErrorText ?? message.lastErrorText,
      ),
      outcomeUnknown: Value(
        message.status != 'sent' &&
            (duplicate?.outcomeUnknown ?? message.outcomeUnknown),
      ),
      outboxPaused: Value(
        message.status != 'sent' &&
            (duplicate?.outboxPaused ?? message.outboxPaused),
      ),
    );
    final next = duplicate?.copyWithCompanion(values);
    return next ??
        LocalMessageRow(
          id: message.id,
          idempotencyKey: message.idempotencyKey,
          roomId: message.roomId,
          peerUserId: message.peerUserId,
          senderId: message.senderId,
          senderName: message.senderName,
          senderAvatarUrl: message.senderAvatarUrl,
          type: message.type,
          content: message.text,
          imageUrl: message.imageUrl,
          replyToJson: values.replyToJson.value,
          replyTargetId: values.replyTargetId.value,
          uploadBytes: message.uploadBytes,
          uploadFilename: message.uploadFilename,
          status: message.status,
          isEdited: message.isEdited,
          isDeletedForAll: message.isDeletedForAll,
          deliveredAt: values.deliveredAt.value,
          seenAt: values.seenAt.value,
          createdAt: message.createdAt.millisecondsSinceEpoch,
          messageSeq: values.messageSeq.value,
          deliveredByCursor: values.deliveredByCursor.value,
          seenByCursor: values.seenByCursor.value,
          enqueueOrder: values.enqueueOrder.value,
          retryCount: values.retryCount.value,
          nextAttemptAt: values.nextAttemptAt.value,
          lastErrorCode: values.lastErrorCode.value,
          lastErrorText: values.lastErrorText.value,
          outcomeUnknown: values.outcomeUnknown.value,
          outboxPaused: values.outboxPaused.value,
        );
  }

  /// Generate parameterized multi-row VALUES from Drift's typed row mapping.
  /// All columns are present, including explicit nulls, so an acknowledgement
  /// clears upload/retry state exactly as the single-row companion did.
  Future<void> _writeMessageRows(
    List<LocalMessageRow> rows, {
    bool notifyProjections = true,
  }) async {
    final columns = rows.first.toColumns(false).keys.toList();
    // Stay below SQLite's conservative 999-variable limit on every platform.
    final chunkSize = 900 ~/ columns.length;
    for (var offset = 0; offset < rows.length; offset += chunkSize) {
      final chunk = rows.sublist(
        offset,
        math.min(offset + chunkSize, rows.length),
      );
      final context = GenerationContext.fromDb(this);
      final identifiers = columns.map(context.identifier).toList();
      context.buffer.write(
        'INSERT INTO ${context.identifier(localMessages.actualTableName)} '
        '(${identifiers.join(', ')}) VALUES ',
      );
      for (var index = 0; index < chunk.length; index++) {
        if (index > 0) context.buffer.write(', ');
        context.buffer.write('(');
        final values = chunk[index].toColumns(false);
        for (var column = 0; column < columns.length; column++) {
          if (column > 0) context.buffer.write(', ');
          values[columns[column]]!.writeInto(context);
        }
        context.buffer.write(')');
      }
      context.buffer
        ..write(' ON CONFLICT (${context.identifier(localMessages.id.name)}) ')
        ..write('DO UPDATE SET ')
        ..write(identifiers.map((name) => '$name = excluded.$name').join(', '));
      await customInsert(context.sql, variables: context.introducedVariables);
      final updates = {
        TableUpdate.onTable(localMessages, kind: UpdateKind.insert),
      };
      // Explicit notification also reaches our projection mapping inside a
      // Drift transaction; automatic customInsert updates use its child engine.
      if (notifyProjections) {
        notifyUpdates(updates);
      } else {
        super.notifyUpdates(updates);
      }
    }
  }

  Future<void> upsertRoom(ChatRoom room, {bool resetSynced = false}) =>
      _atomic(() async {
        await _upsertRoom(
          room,
          await roomRow(room.roomId),
          (await metadata())?.userId,
          resetSynced: resetSynced,
        );
      });

  Future<LocalRoomRow> _upsertRoom(
    ChatRoom room,
    LocalRoomRow? existing,
    String? user, {
    bool resetSynced = false,
  }) async {
    if (existing != null && existing.roomPts > room.roomPts) return existing;
    final deliveredSeq = math.max(
      existing?.peerDeliveredSeq ?? 0,
      room.peerDeliveredSeq,
    );
    final seenSeq = math.max(existing?.peerSeenSeq ?? 0, room.peerSeenSeq);
    final ownDelivered = math.max(
      existing?.ownDeliveredSeq ?? 0,
      room.ownDeliveredSeq,
    );
    final ownSeen = math.max(existing?.ownSeenSeq ?? 0, room.ownSeenSeq);
    final last = room.lastMessage == null || user == null
        ? room.lastMessage
        : applySequenceReceipts(room.lastMessage!, user, deliveredSeq, seenSeq);
    final values = LocalRoomsCompanion.insert(
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
      lastMessageJson: Value(last == null ? null : jsonEncode(last.toJson())),
      contentPts: Value(room.contentPts ?? existing?.contentPts),
      receiptProtocol: Value(room.receiptProtocol),
      peerDeliveredSeq: Value(math.max(deliveredSeq, seenSeq)),
      peerSeenSeq: Value(seenSeq),
      ownDeliveredSeq: Value(math.max(ownDelivered, ownSeen)),
      ownSeenSeq: Value(ownSeen),
      receivedThroughSeq: Value(
        math.max(
          existing?.receivedThroughSeq ?? 0,
          math.max(ownDelivered, ownSeen),
        ),
      ),
      verifiedHeadSeq: Value(existing?.verifiedHeadSeq ?? 0),
      receivedRangesJson: Value(existing?.receivedRangesJson ?? '[]'),
    );
    if (existing == null || existing.copyWithCompanion(values) != existing) {
      await into(localRooms).insertOnConflictUpdate(values);
    }
    if (user != null &&
        (deliveredSeq > (existing?.peerDeliveredSeq ?? 0) ||
            seenSeq > (existing?.peerSeenSeq ?? 0))) {
      await _applyPeerSequenceReceipts(
        room.roomId,
        user,
        deliveredSeq,
        seenSeq,
      );
    }
    if (ownDelivered > (existing?.ownDeliveredSeq ?? 0) ||
        ownSeen > (existing?.ownSeenSeq ?? 0)) {
      await _confirmSequenceTask(room.roomId, ownDelivered, ownSeen);
    }
    return existing?.copyWithCompanion(values) ??
        LocalRoomRow(
          roomId: room.roomId,
          roomType: room.roomType,
          peerUserId: room.peerUserId,
          displayTitle: room.displayTitle,
          displayAvatarUrl: room.displayAvatarUrl,
          pinAt: values.pinAt.value,
          isMuted: room.isMuted,
          unreadCount: room.unreadCount,
          clearedAt: values.clearedAt.value,
          deletedAt: values.deletedAt.value,
          sortTimestamp: room.sortTimestamp.millisecondsSinceEpoch,
          roomPts: room.roomPts,
          msgPts: room.msgPts,
          lastHistoryEditPts: room.lastHistoryEditPts,
          messagesSyncedPts: values.messagesSyncedPts.value,
          lastMessageJson: values.lastMessageJson.value,
          contentPts: values.contentPts.value,
          receiptProtocol: room.receiptProtocol,
          peerDeliveredSeq: values.peerDeliveredSeq.value,
          peerSeenSeq: values.peerSeenSeq.value,
          ownDeliveredSeq: values.ownDeliveredSeq.value,
          ownSeenSeq: values.ownSeenSeq.value,
          receivedThroughSeq: values.receivedThroughSeq.value,
          verifiedHeadSeq: values.verifiedHeadSeq.value,
          receivedRangesJson: values.receivedRangesJson.value,
        );
  }

  /// The caller has already atomically stored these own cursors in its room.
  /// Confirm only existing tasks; later task admission inherits the room's
  /// cursors so pruning/restart cannot turn acknowledged progress into a retry.
  Future<void> _confirmSequenceTask(
    String roomId,
    int delivered,
    int seen,
  ) async {
    await customUpdate(
      'UPDATE receipt_tasks SET '
      'delivered_confirmed_seq = MAX(delivered_confirmed_seq, ?), '
      'seen_confirmed_seq = MAX(seen_confirmed_seq, ?) '
      'WHERE room_id = ? AND (delivered_confirmed_seq < ? OR seen_confirmed_seq < ?)',
      variables: [
        Variable(delivered),
        Variable(seen),
        Variable(roomId),
        Variable(delivered),
        Variable(seen),
      ],
      updates: {receiptTasks},
    );
  }

  /// Create an inbox entry only once a draft has an actual pending send.
  /// Call alongside the optimistic message write in the same transaction.
  Future<void> upsertDraftRoom(UserProfile peer, ChatMessage pending) async {
    if (pending.roomId != 'draft_${peer.id}' ||
        !const ['queued', 'sending', 'failed'].contains(pending.status)) {
      return;
    }
    final existing = await room(pending.roomId);
    final newest = existing?.lastMessage;
    if (newest != null && newest.createdAt.isAfter(pending.createdAt)) return;
    await upsertRoom(
      ChatRoom(
        roomId: pending.roomId,
        roomType: 'direct',
        peerUserId: peer.id,
        displayTitle: peer.displayName,
        displayAvatarUrl: peer.avatarUrl,
        sortTimestamp: pending.createdAt,
        lastMessage: pending,
      ),
    );
  }

  Future<void> removeMessage(String id) =>
      (delete(localMessages)..where((m) => m.id.equals(id))).go();
  Future<void> setMessageStatus(String id, String status) =>
      (update(localMessages)..where((m) => m.id.equals(id))).write(
        LocalMessagesCompanion(status: Value(status)),
      );
  Future<void> remapDraft(String draftId, String realId) async {
    if (!draftId.startsWith('draft_') || draftId == realId) return;
    await _atomic(() async {
      await (update(localMessages)..where((m) => m.roomId.equals(draftId)))
          .write(LocalMessagesCompanion(roomId: Value(realId)));
      await (delete(localRooms)..where((r) => r.roomId.equals(draftId))).go();
    });
  }

  Future<void> markMessagesSynced(String roomId, int pts) =>
      (update(localRooms)..where(
            (r) =>
                r.roomId.equals(roomId) & r.messagesSyncedPts.equals(pts).not(),
          ))
          .write(LocalRoomsCompanion(messagesSyncedPts: Value(pts)));

  /// Only a contiguous, persisted range proves background delivery. A selected
  /// room may explicitly mark its verified snapshot head read instead.
  Future<int?> receiptTarget(String roomId, {bool seen = false}) async {
    final row = await roomRow(roomId);
    return row == null ? null : receiptTargetFromRoom(row, seen: seen);
  }

  /// Computes a target from the caller's transaction-consistent room snapshot.
  int? receiptTargetFromRoom(LocalRoomRow row, {bool seen = false}) {
    if (row.receiptProtocol != 'sequence') return null;
    var through = row.receivedThroughSeq;
    for (final range in jsonDecode(row.receivedRangesJson) as List) {
      final values = range as List;
      if ((values.first as num).toInt() > through + 1) break;
      through = math.max(through, (values.last as num).toInt());
    }
    final seq = seen ? math.max(row.verifiedHeadSeq, through) : through;
    return seq > 0 ? seq : null;
  }

  Future<void> recordMessageCoverage(
    String roomId,
    Map<String, dynamic> coverage, {
    Map<String, dynamic>? receiptState,
    bool verifyHead = false,
  }) => _atomic(() async {
    LocalRoomRow? currentRoom;
    if (receiptState != null) {
      currentRoom = await _applySequenceSnapshot(roomId, receiptState);
    }
    final from = intValue(coverage['fromSeq']);
    final end = intValue(coverage['throughSeq']);
    await _recordMessageRanges(
      roomId,
      [
        if (from > 0 && end >= from) [from, end],
      ],
      verifyHead: verifyHead,
      headSeq: intValue(coverage['headSeq']),
      row: currentRoom,
    );
  });

  Future<LocalRoomRow?> _recordMessageRanges(
    String roomId,
    List<List<int>> addedRanges, {
    LocalRoomRow? row,
    bool verifyHead = false,
    int headSeq = 0,
  }) async {
    row ??= await roomRow(roomId);
    if (row == null) return null;
    var through = math.max(
      row.receivedThroughSeq,
      math.max(row.ownDeliveredSeq, row.ownSeenSeq),
    );
    final ranges = (jsonDecode(row.receivedRangesJson) as List)
        .map((range) => (range as List).map((v) => (v as num).toInt()).toList())
        .toList();
    ranges.addAll(addedRanges);
    ranges.sort((a, b) => a.first.compareTo(b.first));
    var verifiedHead = verifyHead
        ? math.max(row.verifiedHeadSeq, headSeq)
        : row.verifiedHeadSeq;
    for (final range in ranges) {
      if (range.first > verifiedHead + 1) break;
      verifiedHead = math.max(verifiedHead, range.last);
    }
    final pending = <List<int>>[];
    for (final range in ranges) {
      if (range.first <= through + 1) {
        through = math.max(through, range.last);
      } else if (pending.isNotEmpty && range.first <= pending.last.last + 1) {
        pending.last[1] = math.max(pending.last.last, range.last);
      } else {
        pending.add([...range]);
      }
    }
    final values = LocalRoomsCompanion(
      receivedThroughSeq: Value(through),
      receivedRangesJson: Value(jsonEncode(pending)),
      verifiedHeadSeq: Value(verifiedHead),
    );
    if (row.copyWithCompanion(values) != row) {
      final changed = await customUpdate(
        'UPDATE local_rooms SET received_through_seq = ?, '
        'received_ranges_json = ?, verified_head_seq = ? WHERE room_id = ?',
        variables: [
          Variable(through),
          Variable(jsonEncode(pending)),
          Variable(verifiedHead),
          Variable(roomId),
        ],
      );
      if (changed > 0) {
        // These three internal coverage fields are absent from roomModel.
        // Raw room observers retain their notification; the inbox is unchanged.
        super.notifyUpdates({
          TableUpdate.onTable(localRooms, kind: UpdateKind.update),
        });
      }
    }
    return row.copyWithCompanion(values);
  }

  Future<
    ({
      ReceiptTaskRow? task,
      String? protocol,
      int delivered,
      int seen,
      int through,
    })
  >
  _receiptContext(String roomId) async {
    final row = await customSelect(
      'SELECT t.*, r.receipt_protocol AS room_protocol, '
      'COALESCE(r.own_delivered_seq, 0) AS room_delivered, '
      'COALESCE(r.own_seen_seq, 0) AS room_seen, '
      'COALESCE(r.received_through_seq, 0) AS room_through '
      'FROM (SELECT ? AS room_id) wanted '
      'LEFT JOIN receipt_tasks t ON t.room_id = wanted.room_id '
      'LEFT JOIN local_rooms r ON r.room_id = wanted.room_id',
      variables: [Variable(roomId)],
      readsFrom: {receiptTasks, localRooms},
    ).getSingle();
    return (
      task: row.data['room_id'] == null ? null : receiptTasks.map(row.data),
      protocol: row.readNullable<String>('room_protocol'),
      delivered: row.read<int>('room_delivered'),
      seen: row.read<int>('room_seen'),
      through: row.read<int>('room_through'),
    );
  }

  Future<void> queueReceipt(
    String roomId, {
    int? deliveredThroughSeq,
    int? seenThroughSeq,
    DateTime? deliveredThroughTimestamp,
    DateTime? seenThroughTimestamp,
  }) => _atomic(() async {
    final context = await _receiptContext(roomId);
    final existing = context.task;
    final row =
        existing ??
        ReceiptTaskRow(
          roomId: roomId,
          receiptProtocol: context.protocol ?? 'legacy',
          deliveredTargetSeq: 0,
          seenTargetSeq: 0,
          deliveredConfirmedSeq: context.delivered,
          seenConfirmedSeq: context.seen,
          deliveredTargetTimestamp: null,
          seenTargetTimestamp: null,
          deliveredConfirmedTimestamp: null,
          seenConfirmedTimestamp: null,
        );
    final seen = math.max(row.seenTargetSeq, seenThroughSeq ?? 0);
    final delivered = math.max(
      row.deliveredTargetSeq,
      math.max(deliveredThroughSeq ?? 0, seen),
    );
    final seenTs = math.max(
      row.seenTargetTimestamp ?? 0,
      seenThroughTimestamp?.millisecondsSinceEpoch ?? 0,
    );
    final deliveredTs = math.max(
      row.deliveredTargetTimestamp ?? 0,
      math.max(deliveredThroughTimestamp?.millisecondsSinceEpoch ?? 0, seenTs),
    );
    if (existing == null &&
        delivered <= context.delivered &&
        seen <= context.seen &&
        deliveredTs == 0 &&
        seenTs == 0) {
      return;
    }
    final values = ReceiptTasksCompanion(
      receiptProtocol: Value(
        context.protocol ?? existing?.receiptProtocol ?? 'legacy',
      ),
      deliveredConfirmedSeq: Value(
        math.max(row.deliveredConfirmedSeq, context.delivered),
      ),
      seenConfirmedSeq: Value(math.max(row.seenConfirmedSeq, context.seen)),
      deliveredTargetSeq: Value(delivered),
      seenTargetSeq: Value(seen),
      deliveredTargetTimestamp: Value(deliveredTs == 0 ? null : deliveredTs),
      seenTargetTimestamp: Value(seenTs == 0 ? null : seenTs),
    );
    if (existing == null || row.copyWithCompanion(values) != row) {
      await into(receiptTasks)
          .insertOnConflictUpdate(row.copyWithCompanion(values));
    }
  });

  Future<void> confirmReceipt(
    String roomId, {
    int? deliveredThroughSeq,
    int? seenThroughSeq,
    DateTime? deliveredThroughTimestamp,
    DateTime? seenThroughTimestamp,
  }) => _atomic(() async {
    final context = await _receiptContext(roomId);
    final task = context.task;
    final seen = math.max(
      task?.seenConfirmedSeq ?? 0,
      math.max(context.seen, seenThroughSeq ?? 0),
    );
    final delivered = math.max(
      task?.deliveredConfirmedSeq ?? 0,
      math.max(context.delivered, math.max(deliveredThroughSeq ?? 0, seen)),
    );
    final seenTs = math.max(
      task?.seenConfirmedTimestamp ?? 0,
      seenThroughTimestamp?.millisecondsSinceEpoch ?? 0,
    );
    final deliveredTs = math.max(
      task?.deliveredConfirmedTimestamp ?? 0,
      math.max(deliveredThroughTimestamp?.millisecondsSinceEpoch ?? 0, seenTs),
    );
    if (task != null) {
      final values = ReceiptTasksCompanion(
        deliveredConfirmedSeq: Value(delivered),
        seenConfirmedSeq: Value(seen),
        deliveredConfirmedTimestamp: Value(
          deliveredTs == 0 ? null : deliveredTs,
        ),
        seenConfirmedTimestamp: Value(seenTs == 0 ? null : seenTs),
      );
      if (task.copyWithCompanion(values) != task) {
        await (update(
          receiptTasks,
        )..where((r) => r.roomId.equals(roomId))).write(values);
      }
    }
    if (context.protocol != null &&
        (delivered > context.delivered ||
            seen > context.seen ||
            delivered > context.through)) {
      final values = LocalRoomsCompanion(
        ownDeliveredSeq: Value(math.max(context.delivered, delivered)),
        ownSeenSeq: Value(math.max(context.seen, seen)),
        receivedThroughSeq: Value(math.max(context.through, delivered)),
      );
      await (update(
        localRooms,
      )..where((r) => r.roomId.equals(roomId))).write(values);
    }
  });

  Future<List<ReceiptTarget>> pendingReceiptTargets() async {
    // Keep retry tasks when their room summary was pruned; the left join also
    // excludes confirmed work before transferring rows from SQLite.
    final rows = await customSelect(
      'SELECT t.*, '
      'MAX(t.delivered_confirmed_seq, COALESCE(r.own_delivered_seq, 0)) AS effective_delivered, '
      'MAX(t.seen_confirmed_seq, COALESCE(r.own_seen_seq, 0)) AS effective_seen '
      'FROM receipt_tasks t LEFT JOIN local_rooms r ON r.room_id = t.room_id '
      'WHERE t.delivered_target_seq > MAX(t.delivered_confirmed_seq, COALESCE(r.own_delivered_seq, 0)) '
      'OR t.seen_target_seq > MAX(t.seen_confirmed_seq, COALESCE(r.own_seen_seq, 0)) '
      'OR COALESCE(t.delivered_target_timestamp, 0) > COALESCE(t.delivered_confirmed_timestamp, 0) '
      'OR COALESCE(t.seen_target_timestamp, 0) > COALESCE(t.seen_confirmed_timestamp, 0)',
      readsFrom: {receiptTasks, localRooms},
    ).get();
    return rows.map((row) {
      final task = receiptTasks.map(row.data);
      return ReceiptTarget(
        roomId: task.roomId,
        receiptProtocol: task.receiptProtocol,
        deliveredThroughSeq:
            task.deliveredTargetSeq > row.read<int>('effective_delivered')
            ? task.deliveredTargetSeq
            : null,
        seenThroughSeq: task.seenTargetSeq > row.read<int>('effective_seen')
            ? task.seenTargetSeq
            : null,
        deliveredThroughTimestamp:
            (task.deliveredTargetTimestamp ?? 0) >
                (task.deliveredConfirmedTimestamp ?? 0)
            ? parseTime(task.deliveredTargetTimestamp)
            : null,
        seenThroughTimestamp:
            (task.seenTargetTimestamp ?? 0) > (task.seenConfirmedTimestamp ?? 0)
            ? parseTime(task.seenTargetTimestamp)
            : null,
      );
    }).toList();
  }

  Future<void> _applyPeerSequenceReceipts(
    String roomId,
    String userId,
    int delivered,
    int seen, {
    bool notifyProjections = true,
  }) async {
    final changed = await customUpdate(
      'UPDATE local_messages SET delivered_by_cursor = '
      'CASE WHEN message_seq <= ? THEN 1 ELSE delivered_by_cursor END, '
      'seen_by_cursor = CASE WHEN message_seq <= ? THEN 1 ELSE seen_by_cursor END '
      "WHERE room_id = ? AND sender_id = ? AND status = 'sent' AND message_seq IS NOT NULL "
      'AND ((message_seq <= ? AND delivered_by_cursor = 0) OR (message_seq <= ? AND seen_by_cursor = 0))',
      variables: [
        Variable(math.max(delivered, seen)),
        Variable(seen),
        Variable(roomId),
        Variable(userId),
        Variable(math.max(delivered, seen)),
        Variable(seen),
      ],
    );
    if (changed > 0) {
      final updates = {
        TableUpdate.onTable(localMessages, kind: UpdateKind.update),
      };
      if (notifyProjections) {
        notifyUpdates(updates);
      } else {
        super.notifyUpdates(updates);
      }
    }
  }

  Future<LocalRoomRow?> _applySequenceSnapshot(
    String roomId,
    Map<String, dynamic> state, {
    LocalRoomRow? previous,
    String? userId,
    bool historyPage = false,
  }) async {
    final row = previous ?? await roomRow(roomId);
    final user = userId ?? (await metadata())?.userId;
    if (row == null || user == null) return row;
    final seen = math.max(row.peerSeenSeq, intValue(state['peerSeenSeq']));
    final delivered = math.max(
      row.peerDeliveredSeq,
      math.max(seen, intValue(state['peerDeliveredSeq'])),
    );
    final ownSeen = math.max(row.ownSeenSeq, intValue(state['ownSeenSeq']));
    final ownDelivered = math.max(
      row.ownDeliveredSeq,
      math.max(ownSeen, intValue(state['ownDeliveredSeq'])),
    );
    final last = row.lastMessageJson == null
        ? null
        : applySequenceReceipts(
            ChatMessage.fromJson(jsonMap(jsonDecode(row.lastMessageJson!))),
            user,
            delivered,
            seen,
          );
    final values = LocalRoomsCompanion(
      peerDeliveredSeq: Value(delivered),
      peerSeenSeq: Value(seen),
      ownDeliveredSeq: Value(ownDelivered),
      ownSeenSeq: Value(ownSeen),
      receivedThroughSeq: Value(math.max(row.receivedThroughSeq, ownDelivered)),
      lastMessageJson: Value(last == null ? null : jsonEncode(last.toJson())),
    );
    if (row.copyWithCompanion(values) != row) {
      await (update(
        localRooms,
      )..where((r) => r.roomId.equals(roomId))).write(values);
    }
    if (delivered > row.peerDeliveredSeq || seen > row.peerSeenSeq) {
      await _applyPeerSequenceReceipts(
        roomId,
        user,
        delivered,
        seen,
        notifyProjections: !historyPage,
      );
    }
    if (ownDelivered > row.ownDeliveredSeq || ownSeen > row.ownSeenSeq) {
      await _confirmSequenceTask(roomId, ownDelivered, ownSeen);
    }
    return row.copyWithCompanion(values);
  }

  Future<bool> applyReceiptPayload(
    Map<String, dynamic> payload, {
    required int pts,
    String? myUserId,
  }) => _atomic(() async {
    if (!const [
      'room_delivered',
      'room_peer_seen',
    ].contains(payload['eventType'])) {
      throw const FormatException('Unknown compact receipt event.');
    }
    final roomId = payload['roomId'] as String;
    final previous = await roomRow(roomId);
    if (previous == null) return false;
    await _applySequenceSnapshot(
      roomId,
      payload,
      previous: previous,
      userId: myUserId,
    );
    if (previous.roomPts > pts) return true;
    final content = (payload['contentPts'] as num?)?.toInt();
    final certified =
        previous.messagesSyncedPts == previous.msgPts &&
        content != null &&
        previous.contentPts == content;
    await (update(localRooms)..where((r) => r.roomId.equals(roomId))).write(
      LocalRoomsCompanion(
        roomPts: Value(pts),
        msgPts: Value(pts),
        contentPts: Value(content),
        receiptProtocol: const Value('sequence'),
        messagesSyncedPts: certified ? Value(pts) : const Value.absent(),
      ),
    );
    return true;
  });

  /// Own read progress changes the badge, not this account's outgoing ticks or
  /// message cache revision. The inbox queue commits this with its cursor.
  Future<bool> applyUnreadPayload(
    Map<String, dynamic> payload, {
    required int pts,
  }) => _atomic(() async {
    final roomId = payload['roomId'];
    final unread = payload['unreadCount'];
    final delivered = payload['ownDeliveredSeq'];
    final seen = payload['ownSeenSeq'];
    if (payload['eventType'] != 'room_unread_cleared' ||
        roomId is! String ||
        roomId.isEmpty ||
        [unread, delivered, seen].any((value) => value is! int || value < 0)) {
      throw const FormatException('Invalid compact unread event.');
    }
    final previous = await roomRow(roomId);
    if (previous == null) return false;
    final ownSeen = math.max(previous.ownSeenSeq, seen as int);
    final ownDelivered = math.max(
      previous.ownDeliveredSeq,
      math.max(delivered as int, ownSeen),
    );
    final acceptsBadge = previous.roomPts <= pts;
    final values = LocalRoomsCompanion(
      unreadCount: acceptsBadge ? Value(unread as int) : const Value.absent(),
      roomPts: acceptsBadge ? Value(pts) : const Value.absent(),
      ownDeliveredSeq: Value(ownDelivered),
      ownSeenSeq: Value(ownSeen),
      receivedThroughSeq: Value(
        math.max(previous.receivedThroughSeq, ownDelivered),
      ),
    );
    if (previous.copyWithCompanion(values) != previous) {
      await (update(
        localRooms,
      )..where((r) => r.roomId.equals(roomId))).write(values);
    }
    if (ownDelivered > previous.ownDeliveredSeq ||
        ownSeen > previous.ownSeenSeq) {
      await _confirmSequenceTask(roomId, ownDelivered, ownSeen);
    }
    return true;
  });

  Future<({LocalRoomRow? room, LocalMessageRow? message})> _roomMessageContext(
    String roomId,
    ChatMessage message,
  ) async {
    final row = await customSelect(
      'SELECT r.*, ${localMessages.$columns.map((column) => 'existing.${column.name} AS existing_${column.name}').join(', ')} '
      'FROM (SELECT ? AS room_id) wanted '
      'LEFT JOIN local_rooms r ON r.room_id = wanted.room_id '
      'LEFT JOIN local_messages existing ON existing.sender_id = ? AND existing.idempotency_key = ?',
      variables: [
        Variable(roomId),
        Variable(message.senderId),
        Variable(message.idempotencyKey),
      ],
      readsFrom: {localRooms, localMessages},
    ).getSingle();
    return (
      room: row.data['room_id'] == null ? null : localRooms.map(row.data),
      message: row.data['existing_id'] == null
          ? null
          : localMessages.map({
              for (final column in localMessages.$columns)
                column.name: row.data['existing_${column.name}'],
            }),
    );
  }

  /// Must be invoked inside the queue's transaction or mutation reconciliation.
  Future<bool> applyRoomPayload(
    Map<String, dynamic> payload, {
    required String myUserId,
    String? openRoomId,
    bool markOpenSynced = true,
  }) => _atomic(() async {
    final room = ChatRoom.fromJson(payload);
    final event = payload['eventType'];
    final updated = payload['updatedMessage'] == null
        ? null
        : ChatMessage.fromJson(jsonMap(payload['updatedMessage']));
    final messages = <String, ChatMessage>{
      if (room.lastMessage != null) room.lastMessage!.id: room.lastMessage!,
    };
    if (updated != null) {
      if (event == 'message_deleted_me') {
        messages.remove(updated.id);
      } else {
        messages[updated.id] = updated;
      }
    }
    final context = messages.length == 1
        ? await _roomMessageContext(room.roomId, messages.values.single)
        : null;
    final previous =
        context?.room ?? (context == null ? await roomRow(room.roomId) : null);
    if (previous != null && previous.roomPts > room.roomPts) return false;
    final currentRoom = await _upsertRoom(room, previous, myUserId);
    ReplySnapshot? updatedQuote;
    if (updated != null) {
      if (event == 'message_deleted_me') {
        await removeMessage(updated.id);
      } else if (updated.isDeletedForAll || updated.isEdited) {
        updatedQuote = ReplySnapshot.fromMessage(updated);
      }
    }
    var duplicate = context?.message;
    if (duplicate != null &&
        (currentRoom.peerDeliveredSeq > (previous?.peerDeliveredSeq ?? 0) ||
            currentRoom.peerSeenSeq > (previous?.peerSeenSeq ?? 0))) {
      // _upsertRoom just updated these stored cursor flags in this transaction.
      final effective = applySequenceReceipts(
        messageModel(duplicate),
        myUserId,
        currentRoom.peerDeliveredSeq,
        currentRoom.peerSeenSeq,
      );
      duplicate = duplicate.copyWith(
        deliveredByCursor: effective.deliveredByCursor,
        seenByCursor: effective.seenByCursor,
      );
    }
    await _upsertMessages(
      messages.values.toList(),
      userId: myUserId,
      knownRooms: {room.roomId: currentRoom},
      knownDuplicates: context == null
          ? const {}
          : {
              (
                messages.values.single.senderId,
                messages.values.single.idempotencyKey,
              ): duplicate,
            },
    );
    if (updatedQuote != null) await _updateQuotes(room.roomId, updatedQuote);
    if (payload['quoteUpdate'] != null) {
      // Hidden originals must stay hidden. This snapshot only changes quotes
      // in messages which are already visible in this account's local cache.
      await _updateQuotes(
        room.roomId,
        ReplySnapshot.fromJson(jsonMap(payload['quoteUpdate'])),
      );
    }
    final action = parseTime(payload['actionTimestamp']);
    if (action != null &&
        payload['sequenceReceipt'] != true &&
        (event == 'room_delivered' || event == 'room_peer_seen')) {
      final isSeen = event == 'room_peer_seen';
      final changed = await customUpdate(
        'UPDATE local_messages SET delivered_by_cursor = 1'
        '${isSeen ? ', seen_by_cursor = 1' : ''} '
        "WHERE room_id = ? AND sender_id = ? AND status = 'sent' AND message_seq IS NULL AND created_at <= ? "
        'AND ${isSeen ? '(delivered_by_cursor = 0 OR seen_by_cursor = 0)' : 'delivered_by_cursor = 0'}',
        variables: [
          Variable(room.roomId),
          Variable(myUserId),
          Variable(action.millisecondsSinceEpoch),
        ],
      );
      if (changed > 0) {
        notifyUpdates({
          TableUpdate.onTable(localMessages, kind: UpdateKind.update),
        });
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
  });

  Future<void> _updateQuotes(String roomId, ReplySnapshot snapshot) async {
    await (update(localMessages)..where(
          (m) =>
              m.roomId.equals(roomId) &
              m.replyTargetId.equals(snapshot.messageId) &
              (m.replyToJson.isNull() |
                  m.replyToJson.equals(jsonEncode(snapshot.toJson())).not()),
        ))
        .write(
          LocalMessagesCompanion(
            replyToJson: Value(jsonEncode(snapshot.toJson())),
          ),
        );
  }

  Future<void> replaceFullInbox(List<Map<String, dynamic>> rooms) async {
    // Top page replaces stale room summaries, while message history remains
    // separately cached until opening a room verifies its content revision.
    final pending = await (select(
      localMessages,
    )..where((m) => m.status.isIn(['queued', 'sending', 'failed']))).get();
    final ids = {
      ...rooms.map((r) => r['roomId'] as String),
      ...pending.map((m) => m.roomId).where((id) => id.startsWith('draft_')),
    };
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
    int previousSyncedPts, {
    ReceiptWatermarks? receipts,
    String? myUserId,
    bool requireReceiptSummary = false,
    Map<String, dynamic>? coverage,
    Map<String, dynamic>? receiptState,
  }) => transaction(() async {
    final oldestCached = fresh.isEmpty ? null : await message(fresh.last.id);
    // The response can contain a newer snapshot than the inbox revision captured
    // before the request. Its history marker must govern the matching baseline.
    final snapshotHistoryEditPts =
        (coverage?['lastHistoryEditPts'] as num?)?.toInt() ?? historyEditPts;
    final overlap =
        fresh.isNotEmpty &&
        oldestCached?.roomId == roomId &&
        snapshotHistoryEditPts <= previousSyncedPts &&
        (!requireReceiptSummary || receipts != null) &&
        receipts?.hasGaps != true;
    if (!overlap) {
      await (delete(
        localMessages,
      )..where((m) => m.roomId.equals(roomId) & m.status.equals('sent'))).go();
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
    final rooms = await _upsertMessages(fresh, userId: myUserId);
    var currentRoom = rooms[roomId] ?? await roomRow(roomId);
    if (receiptState != null) {
      currentRoom = await _applySequenceSnapshot(
        roomId,
        receiptState,
        previous: currentRoom,
        userId: myUserId,
      );
    }
    if (coverage != null) {
      final from = intValue(coverage['fromSeq']);
      final through = intValue(coverage['throughSeq']);
      currentRoom = await _recordMessageRanges(
        roomId,
        [
          if (from > 0 && through >= from) [from, through],
        ],
        row: currentRoom,
        verifyHead: true,
        headSeq: intValue(coverage['headSeq']),
      );
    }
    if (receipts != null &&
        !receipts.hasGaps &&
        myUserId != null &&
        (overlap ||
            fresh.any(
              (message) =>
                  message.senderId == myUserId &&
                  message.status == 'sent' &&
                  message.messageSeq == null,
            ))) {
      // Replacement removed every retained sent row. With no outgoing legacy
      // rows in this page, timestamp watermarks cannot change this transaction.
      await _applyReceiptWatermarks(roomId, myUserId, receipts);
    }
    if (currentRoom != null) {
      final values = LocalRoomsCompanion(
        messagesSyncedPts: Value(
          coverage == null
              ? expectedMsgPts
              : (coverage['msgPts'] as num?)?.toInt() ?? expectedMsgPts,
        ),
        contentPts: coverage?['contentPts'] == null
            ? const Value.absent()
            : Value(intValue(coverage!['contentPts'])),
      );
      if (currentRoom.copyWithCompanion(values) != currentRoom) {
        await (update(
          localRooms,
        )..where((r) => r.roomId.equals(roomId))).write(values);
      }
    }
    return overlap;
  });

  Future<void> _applyReceiptWatermarks(
    String roomId,
    String senderId,
    ReceiptWatermarks receipts,
  ) async {
    final delivered = receipts.deliveredThrough?.millisecondsSinceEpoch;
    final seen = receipts.seenThrough?.millisecondsSinceEpoch;
    if (delivered == null && seen == null) return;
    final deliveredBound = delivered == null
        ? seen!
        : seen == null
        ? delivered
        : math.max(delivered, seen);
    final changed = await customUpdate(
      'UPDATE local_messages SET delivered_by_cursor = 1'
      '${seen == null ? '' : ', seen_by_cursor = CASE WHEN created_at <= ? THEN 1 ELSE seen_by_cursor END'} '
      "WHERE room_id = ? AND sender_id = ? AND status = 'sent' AND message_seq IS NULL "
      'AND ((created_at <= ? AND delivered_by_cursor = 0)'
      '${seen == null ? '' : ' OR (created_at <= ? AND seen_by_cursor = 0)'})',
      variables: [
        if (seen != null) Variable(seen),
        Variable(roomId),
        Variable(senderId),
        Variable(deliveredBound),
        if (seen != null) Variable(seen),
      ],
    );
    // Drift custom writes notify even when zero rows matched. A no-op receipt
    // must not rerun the room/message watchers and their SELECT queries.
    if (changed > 0) {
      notifyUpdates({
        TableUpdate.onTable(localMessages, kind: UpdateKind.update),
      });
    }
  }

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
    'messages': (await (select(localMessages)..limit(200)).get())
        .map(
          (m) => {
            ...(m.toJson()..remove('uploadBytes')),
            'uploadBytesLength': m.uploadBytes?.length,
          },
        )
        .toList(),
  };
}

/// Observes the executor rather than inferring database work from repository
/// methods. SQL text/values additionally require full debug capture.
class _DatabaseInspector extends QueryInterceptor {
  _DatabaseInspector(this.inspector);

  DebugInspector? inspector;
  final Map<TransactionExecutor, _ObservedTransaction> _transactions = {};
  int _nextTransactionId = 0;
  int _roomWatches = 0;
  int _messageWatches = 0;
  bool _openingObserved = false;

  bool get _enabled => inspector?.enabled == true;

  static const _tableNames = [
    'sync_metadata',
    'local_rooms',
    'local_messages',
    'receipt_tasks',
  ];
  static final _tablePatterns = {
    for (final table in _tableNames) table: RegExp('\\b$table\\b'),
  };

  List<String> _tables(Iterable<String> statements) {
    final result = <String>{};
    for (final statement in statements) {
      for (final entry in _tablePatterns.entries) {
        if (entry.value.hasMatch(statement)) result.add(entry.key);
      }
    }
    return result.toList();
  }

  Future<T> _query<T>(
    QueryExecutor executor,
    String operation,
    String statement,
    List<Object?> args,
    Future<T> Function() run, {
    Map<String, Object?> Function(T)? resultData,
  }) async {
    if (!_enabled) return run();
    final span = inspector!.begin(
      'drift',
      'query.$operation',
      sqlite: () => SqliteQueryDetails.capture(operation, statement, args),
      data: {
        'operation': operation,
        'table': _tables([statement]).join('/'),
        'argumentCount': args.length,
        if (_transactions[executor] case final transaction?)
          'transactionId': transaction.id,
      },
    );
    try {
      final result = await run();
      span?.finish(
        data: resultData?.call(result) ?? const {},
        sqliteResult: result,
      );
      return result;
    } on CancellationException {
      span?.finish(data: {'outcome': 'cancelled'});
      rethrow;
    } catch (error) {
      span?.finish(error: error);
      rethrow;
    }
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _query(
    executor,
    'select',
    statement,
    args,
    () => executor.runSelect(statement, args),
    resultData: (rows) => {'rowCount': rows.length},
  );

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _query(
    executor,
    'insert',
    statement,
    args,
    () => executor.runInsert(statement, args),
  );

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _query(
    executor,
    'update',
    statement,
    args,
    () => executor.runUpdate(statement, args),
    resultData: (count) => {'affectedRows': count},
  );

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _query(
    executor,
    'delete',
    statement,
    args,
    () => executor.runDelete(statement, args),
    resultData: (count) => {'affectedRows': count},
  );

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _query(
    executor,
    'custom',
    statement,
    args,
    () => executor.runCustom(statement, args),
  );

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) async {
    if (!_enabled) return executor.runBatched(statements);
    final span = inspector!.begin(
      'drift',
      'query.batch',
      sqlite: () => SqliteQueryDetails.batch(statements.statements, [
        for (final item in statements.arguments)
          (statementIndex: item.statementIndex, arguments: item.arguments),
      ]),
      data: {
        'operation': 'batch',
        'table': _tables(statements.statements).join('/'),
        'statementCount': statements.statements.length,
        'executionCount': statements.arguments.length,
        'argumentCount': statements.arguments.fold<int>(
          0,
          (count, item) => count + item.arguments.length,
        ),
        if (_transactions[executor] case final transaction?)
          'transactionId': transaction.id,
      },
    );
    try {
      await executor.runBatched(statements);
      span?.finish();
    } catch (error) {
      span?.finish(error: error);
      rethrow;
    }
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    final transaction = parent.beginTransaction();
    if (_enabled && _transactions.length < DebugInspector.activeSpanLimit) {
      final id = ++_nextTransactionId;
      final span = inspector!.begin(
        'drift',
        'transaction',
        data: {'transactionId': id},
      );
      if (span != null) {
        _transactions[transaction] = _ObservedTransaction(id, span);
        inspector!.record(
          'drift',
          'transaction.begin',
          data: {'transactionId': id},
        );
      }
    }
    return transaction;
  }

  Future<void> _finishTransaction(
    TransactionExecutor transaction,
    String outcome,
    Future<void> Function() finish,
  ) async {
    final observation = _transactions.remove(transaction);
    try {
      await finish();
      observation?.span?.finish(data: {'outcome': outcome});
    } catch (error) {
      observation?.span?.finish(data: {'outcome': outcome}, error: error);
      rethrow;
    }
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) =>
      _finishTransaction(inner, 'commit', inner.send);

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) =>
      _finishTransaction(inner, 'rollback', inner.rollback);

  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    if (!_enabled || _openingObserved) return executor.ensureOpen(user);
    _openingObserved = true;
    return inspector!.trace(
      'drift',
      'database.open',
      () => executor.ensureOpen(user),
    );
  }

  @override
  Future<void> close(QueryExecutor inner) async {
    try {
      if (_enabled) {
        await inspector!.trace('drift', 'database.close', inner.close);
      } else {
        await inner.close();
      }
    } finally {
      for (final observation in _transactions.values) {
        observation.span?.finish(data: {'outcome': 'closed'});
      }
      _transactions.clear();
    }
  }

  void updateWatchGauges() => inspector?.setGauges({
    'drift.roomSubscriptions': _roomWatches,
    'drift.messageSubscriptions': _messageWatches,
    'drift.subscriptions': _roomWatches + _messageWatches,
  });

  Stream<List<T>> watch<T>(
    String name,
    Stream<List<T>> source, {
    Map<String, Object?> data = const {},
  }) => Stream<List<T>>.multi((controller) {
    final context = inspector?.captureContext(detached: true);
    // A watch outlives individual traces and timeline clears. Emissions retain
    // the subscription's session identity without reviving an expired span.
    final emissionContext = DebugTraceContext(
      userId: context?.userId,
      sessionGeneration: context?.sessionGeneration,
      roomId: context?.roomId,
    );
    var finished = false;
    if (name == 'rooms') {
      _roomWatches++;
    } else {
      _messageWatches++;
    }
    updateWatchGauges();
    inspector?.record(
      'drift',
      'watch.subscribe',
      data: {'watch': name, ...data},
      context: context,
    );
    void finish(String event) {
      if (finished) return;
      finished = true;
      if (name == 'rooms') {
        _roomWatches--;
      } else {
        _messageWatches--;
      }
      updateWatchGauges();
      inspector?.record(
        'drift',
        event,
        data: {'watch': name, ...data},
        context: emissionContext,
      );
    }

    final subscription = source.listen(
      (rows) {
        updateWatchGauges();
        inspector?.record(
          'drift',
          'watch.emit',
          data: {'watch': name, ...data, 'rowCount': rows.length},
          context: emissionContext,
        );
        controller.addSync(rows);
      },
      onError: (Object error, StackTrace stack) {
        inspector?.record(
          'drift',
          'watch.error',
          data: {
            'watch': name,
            ...data,
            'errorType': error.runtimeType.toString(),
          },
          context: emissionContext,
        );
        controller.addErrorSync(error, stack);
      },
      onDone: () {
        finish('watch.done');
        controller.closeSync();
      },
    );
    controller.onPause = subscription.pause;
    controller.onResume = subscription.resume;
    controller.onCancel = () {
      finish('watch.cancel');
      return subscription.cancel();
    };
  }, isBroadcast: source.isBroadcast);
}

class _ObservedTransaction {
  const _ObservedTransaction(this.id, this.span);
  final int id;
  final DebugSpan? span;
}
