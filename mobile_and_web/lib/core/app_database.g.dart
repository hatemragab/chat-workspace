// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $SyncMetadataTable extends SyncMetadata
    with TableInfo<$SyncMetadataTable, SyncMetadataRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncMetadataTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localPtsMeta = const VerificationMeta(
    'localPts',
  );
  @override
  late final GeneratedColumn<int> localPts = GeneratedColumn<int>(
    'local_pts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _localEpochMeta = const VerificationMeta(
    'localEpoch',
  );
  @override
  late final GeneratedColumn<String> localEpoch = GeneratedColumn<String>(
    'local_epoch',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [id, userId, localPts, localEpoch];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_metadata';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncMetadataRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('local_pts')) {
      context.handle(
        _localPtsMeta,
        localPts.isAcceptableOrUnknown(data['local_pts']!, _localPtsMeta),
      );
    }
    if (data.containsKey('local_epoch')) {
      context.handle(
        _localEpochMeta,
        localEpoch.isAcceptableOrUnknown(data['local_epoch']!, _localEpochMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncMetadataRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncMetadataRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      localPts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_pts'],
      )!,
      localEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_epoch'],
      )!,
    );
  }

  @override
  $SyncMetadataTable createAlias(String alias) {
    return $SyncMetadataTable(attachedDatabase, alias);
  }
}

class SyncMetadataRow extends DataClass implements Insertable<SyncMetadataRow> {
  final int id;
  final String userId;
  final int localPts;
  final String localEpoch;
  const SyncMetadataRow({
    required this.id,
    required this.userId,
    required this.localPts,
    required this.localEpoch,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['user_id'] = Variable<String>(userId);
    map['local_pts'] = Variable<int>(localPts);
    map['local_epoch'] = Variable<String>(localEpoch);
    return map;
  }

  SyncMetadataCompanion toCompanion(bool nullToAbsent) {
    return SyncMetadataCompanion(
      id: Value(id),
      userId: Value(userId),
      localPts: Value(localPts),
      localEpoch: Value(localEpoch),
    );
  }

  factory SyncMetadataRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncMetadataRow(
      id: serializer.fromJson<int>(json['id']),
      userId: serializer.fromJson<String>(json['userId']),
      localPts: serializer.fromJson<int>(json['localPts']),
      localEpoch: serializer.fromJson<String>(json['localEpoch']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'userId': serializer.toJson<String>(userId),
      'localPts': serializer.toJson<int>(localPts),
      'localEpoch': serializer.toJson<String>(localEpoch),
    };
  }

  SyncMetadataRow copyWith({
    int? id,
    String? userId,
    int? localPts,
    String? localEpoch,
  }) => SyncMetadataRow(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    localPts: localPts ?? this.localPts,
    localEpoch: localEpoch ?? this.localEpoch,
  );
  SyncMetadataRow copyWithCompanion(SyncMetadataCompanion data) {
    return SyncMetadataRow(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      localPts: data.localPts.present ? data.localPts.value : this.localPts,
      localEpoch: data.localEpoch.present
          ? data.localEpoch.value
          : this.localEpoch,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetadataRow(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('localPts: $localPts, ')
          ..write('localEpoch: $localEpoch')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, userId, localPts, localEpoch);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncMetadataRow &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.localPts == this.localPts &&
          other.localEpoch == this.localEpoch);
}

class SyncMetadataCompanion extends UpdateCompanion<SyncMetadataRow> {
  final Value<int> id;
  final Value<String> userId;
  final Value<int> localPts;
  final Value<String> localEpoch;
  const SyncMetadataCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.localPts = const Value.absent(),
    this.localEpoch = const Value.absent(),
  });
  SyncMetadataCompanion.insert({
    this.id = const Value.absent(),
    required String userId,
    this.localPts = const Value.absent(),
    this.localEpoch = const Value.absent(),
  }) : userId = Value(userId);
  static Insertable<SyncMetadataRow> custom({
    Expression<int>? id,
    Expression<String>? userId,
    Expression<int>? localPts,
    Expression<String>? localEpoch,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (localPts != null) 'local_pts': localPts,
      if (localEpoch != null) 'local_epoch': localEpoch,
    });
  }

  SyncMetadataCompanion copyWith({
    Value<int>? id,
    Value<String>? userId,
    Value<int>? localPts,
    Value<String>? localEpoch,
  }) {
    return SyncMetadataCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      localPts: localPts ?? this.localPts,
      localEpoch: localEpoch ?? this.localEpoch,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (localPts.present) {
      map['local_pts'] = Variable<int>(localPts.value);
    }
    if (localEpoch.present) {
      map['local_epoch'] = Variable<String>(localEpoch.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetadataCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('localPts: $localPts, ')
          ..write('localEpoch: $localEpoch')
          ..write(')'))
        .toString();
  }
}

class $LocalRoomsTable extends LocalRooms
    with TableInfo<$LocalRoomsTable, LocalRoomRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalRoomsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _roomIdMeta = const VerificationMeta('roomId');
  @override
  late final GeneratedColumn<String> roomId = GeneratedColumn<String>(
    'room_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roomTypeMeta = const VerificationMeta(
    'roomType',
  );
  @override
  late final GeneratedColumn<String> roomType = GeneratedColumn<String>(
    'room_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerUserIdMeta = const VerificationMeta(
    'peerUserId',
  );
  @override
  late final GeneratedColumn<String> peerUserId = GeneratedColumn<String>(
    'peer_user_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _displayTitleMeta = const VerificationMeta(
    'displayTitle',
  );
  @override
  late final GeneratedColumn<String> displayTitle = GeneratedColumn<String>(
    'display_title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayAvatarUrlMeta = const VerificationMeta(
    'displayAvatarUrl',
  );
  @override
  late final GeneratedColumn<String> displayAvatarUrl = GeneratedColumn<String>(
    'display_avatar_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pinAtMeta = const VerificationMeta('pinAt');
  @override
  late final GeneratedColumn<int> pinAt = GeneratedColumn<int>(
    'pin_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isMutedMeta = const VerificationMeta(
    'isMuted',
  );
  @override
  late final GeneratedColumn<bool> isMuted = GeneratedColumn<bool>(
    'is_muted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_muted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _unreadCountMeta = const VerificationMeta(
    'unreadCount',
  );
  @override
  late final GeneratedColumn<int> unreadCount = GeneratedColumn<int>(
    'unread_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _clearedAtMeta = const VerificationMeta(
    'clearedAt',
  );
  @override
  late final GeneratedColumn<int> clearedAt = GeneratedColumn<int>(
    'cleared_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortTimestampMeta = const VerificationMeta(
    'sortTimestamp',
  );
  @override
  late final GeneratedColumn<int> sortTimestamp = GeneratedColumn<int>(
    'sort_timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roomPtsMeta = const VerificationMeta(
    'roomPts',
  );
  @override
  late final GeneratedColumn<int> roomPts = GeneratedColumn<int>(
    'room_pts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _msgPtsMeta = const VerificationMeta('msgPts');
  @override
  late final GeneratedColumn<int> msgPts = GeneratedColumn<int>(
    'msg_pts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastHistoryEditPtsMeta =
      const VerificationMeta('lastHistoryEditPts');
  @override
  late final GeneratedColumn<int> lastHistoryEditPts = GeneratedColumn<int>(
    'last_history_edit_pts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _messagesSyncedPtsMeta = const VerificationMeta(
    'messagesSyncedPts',
  );
  @override
  late final GeneratedColumn<int> messagesSyncedPts = GeneratedColumn<int>(
    'messages_synced_pts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastMessageJsonMeta = const VerificationMeta(
    'lastMessageJson',
  );
  @override
  late final GeneratedColumn<String> lastMessageJson = GeneratedColumn<String>(
    'last_message_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    roomId,
    roomType,
    peerUserId,
    displayTitle,
    displayAvatarUrl,
    pinAt,
    isMuted,
    unreadCount,
    clearedAt,
    deletedAt,
    sortTimestamp,
    roomPts,
    msgPts,
    lastHistoryEditPts,
    messagesSyncedPts,
    lastMessageJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_rooms';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalRoomRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('room_id')) {
      context.handle(
        _roomIdMeta,
        roomId.isAcceptableOrUnknown(data['room_id']!, _roomIdMeta),
      );
    } else if (isInserting) {
      context.missing(_roomIdMeta);
    }
    if (data.containsKey('room_type')) {
      context.handle(
        _roomTypeMeta,
        roomType.isAcceptableOrUnknown(data['room_type']!, _roomTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_roomTypeMeta);
    }
    if (data.containsKey('peer_user_id')) {
      context.handle(
        _peerUserIdMeta,
        peerUserId.isAcceptableOrUnknown(
          data['peer_user_id']!,
          _peerUserIdMeta,
        ),
      );
    }
    if (data.containsKey('display_title')) {
      context.handle(
        _displayTitleMeta,
        displayTitle.isAcceptableOrUnknown(
          data['display_title']!,
          _displayTitleMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayTitleMeta);
    }
    if (data.containsKey('display_avatar_url')) {
      context.handle(
        _displayAvatarUrlMeta,
        displayAvatarUrl.isAcceptableOrUnknown(
          data['display_avatar_url']!,
          _displayAvatarUrlMeta,
        ),
      );
    }
    if (data.containsKey('pin_at')) {
      context.handle(
        _pinAtMeta,
        pinAt.isAcceptableOrUnknown(data['pin_at']!, _pinAtMeta),
      );
    }
    if (data.containsKey('is_muted')) {
      context.handle(
        _isMutedMeta,
        isMuted.isAcceptableOrUnknown(data['is_muted']!, _isMutedMeta),
      );
    }
    if (data.containsKey('unread_count')) {
      context.handle(
        _unreadCountMeta,
        unreadCount.isAcceptableOrUnknown(
          data['unread_count']!,
          _unreadCountMeta,
        ),
      );
    }
    if (data.containsKey('cleared_at')) {
      context.handle(
        _clearedAtMeta,
        clearedAt.isAcceptableOrUnknown(data['cleared_at']!, _clearedAtMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('sort_timestamp')) {
      context.handle(
        _sortTimestampMeta,
        sortTimestamp.isAcceptableOrUnknown(
          data['sort_timestamp']!,
          _sortTimestampMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sortTimestampMeta);
    }
    if (data.containsKey('room_pts')) {
      context.handle(
        _roomPtsMeta,
        roomPts.isAcceptableOrUnknown(data['room_pts']!, _roomPtsMeta),
      );
    } else if (isInserting) {
      context.missing(_roomPtsMeta);
    }
    if (data.containsKey('msg_pts')) {
      context.handle(
        _msgPtsMeta,
        msgPts.isAcceptableOrUnknown(data['msg_pts']!, _msgPtsMeta),
      );
    } else if (isInserting) {
      context.missing(_msgPtsMeta);
    }
    if (data.containsKey('last_history_edit_pts')) {
      context.handle(
        _lastHistoryEditPtsMeta,
        lastHistoryEditPts.isAcceptableOrUnknown(
          data['last_history_edit_pts']!,
          _lastHistoryEditPtsMeta,
        ),
      );
    }
    if (data.containsKey('messages_synced_pts')) {
      context.handle(
        _messagesSyncedPtsMeta,
        messagesSyncedPts.isAcceptableOrUnknown(
          data['messages_synced_pts']!,
          _messagesSyncedPtsMeta,
        ),
      );
    }
    if (data.containsKey('last_message_json')) {
      context.handle(
        _lastMessageJsonMeta,
        lastMessageJson.isAcceptableOrUnknown(
          data['last_message_json']!,
          _lastMessageJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {roomId};
  @override
  LocalRoomRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalRoomRow(
      roomId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_id'],
      )!,
      roomType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_type'],
      )!,
      peerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_user_id'],
      ),
      displayTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_title'],
      )!,
      displayAvatarUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_avatar_url'],
      ),
      pinAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pin_at'],
      ),
      isMuted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_muted'],
      )!,
      unreadCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread_count'],
      )!,
      clearedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cleared_at'],
      ),
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      sortTimestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_timestamp'],
      )!,
      roomPts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}room_pts'],
      )!,
      msgPts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}msg_pts'],
      )!,
      lastHistoryEditPts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_history_edit_pts'],
      )!,
      messagesSyncedPts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}messages_synced_pts'],
      )!,
      lastMessageJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_message_json'],
      ),
    );
  }

  @override
  $LocalRoomsTable createAlias(String alias) {
    return $LocalRoomsTable(attachedDatabase, alias);
  }
}

class LocalRoomRow extends DataClass implements Insertable<LocalRoomRow> {
  final String roomId;
  final String roomType;
  final String? peerUserId;
  final String displayTitle;
  final String? displayAvatarUrl;
  final int? pinAt;
  final bool isMuted;
  final int unreadCount;
  final int? clearedAt;
  final int? deletedAt;
  final int sortTimestamp;
  final int roomPts;
  final int msgPts;
  final int lastHistoryEditPts;
  final int messagesSyncedPts;
  final String? lastMessageJson;
  const LocalRoomRow({
    required this.roomId,
    required this.roomType,
    this.peerUserId,
    required this.displayTitle,
    this.displayAvatarUrl,
    this.pinAt,
    required this.isMuted,
    required this.unreadCount,
    this.clearedAt,
    this.deletedAt,
    required this.sortTimestamp,
    required this.roomPts,
    required this.msgPts,
    required this.lastHistoryEditPts,
    required this.messagesSyncedPts,
    this.lastMessageJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['room_id'] = Variable<String>(roomId);
    map['room_type'] = Variable<String>(roomType);
    if (!nullToAbsent || peerUserId != null) {
      map['peer_user_id'] = Variable<String>(peerUserId);
    }
    map['display_title'] = Variable<String>(displayTitle);
    if (!nullToAbsent || displayAvatarUrl != null) {
      map['display_avatar_url'] = Variable<String>(displayAvatarUrl);
    }
    if (!nullToAbsent || pinAt != null) {
      map['pin_at'] = Variable<int>(pinAt);
    }
    map['is_muted'] = Variable<bool>(isMuted);
    map['unread_count'] = Variable<int>(unreadCount);
    if (!nullToAbsent || clearedAt != null) {
      map['cleared_at'] = Variable<int>(clearedAt);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    map['sort_timestamp'] = Variable<int>(sortTimestamp);
    map['room_pts'] = Variable<int>(roomPts);
    map['msg_pts'] = Variable<int>(msgPts);
    map['last_history_edit_pts'] = Variable<int>(lastHistoryEditPts);
    map['messages_synced_pts'] = Variable<int>(messagesSyncedPts);
    if (!nullToAbsent || lastMessageJson != null) {
      map['last_message_json'] = Variable<String>(lastMessageJson);
    }
    return map;
  }

  LocalRoomsCompanion toCompanion(bool nullToAbsent) {
    return LocalRoomsCompanion(
      roomId: Value(roomId),
      roomType: Value(roomType),
      peerUserId: peerUserId == null && nullToAbsent
          ? const Value.absent()
          : Value(peerUserId),
      displayTitle: Value(displayTitle),
      displayAvatarUrl: displayAvatarUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(displayAvatarUrl),
      pinAt: pinAt == null && nullToAbsent
          ? const Value.absent()
          : Value(pinAt),
      isMuted: Value(isMuted),
      unreadCount: Value(unreadCount),
      clearedAt: clearedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(clearedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      sortTimestamp: Value(sortTimestamp),
      roomPts: Value(roomPts),
      msgPts: Value(msgPts),
      lastHistoryEditPts: Value(lastHistoryEditPts),
      messagesSyncedPts: Value(messagesSyncedPts),
      lastMessageJson: lastMessageJson == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessageJson),
    );
  }

  factory LocalRoomRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalRoomRow(
      roomId: serializer.fromJson<String>(json['roomId']),
      roomType: serializer.fromJson<String>(json['roomType']),
      peerUserId: serializer.fromJson<String?>(json['peerUserId']),
      displayTitle: serializer.fromJson<String>(json['displayTitle']),
      displayAvatarUrl: serializer.fromJson<String?>(json['displayAvatarUrl']),
      pinAt: serializer.fromJson<int?>(json['pinAt']),
      isMuted: serializer.fromJson<bool>(json['isMuted']),
      unreadCount: serializer.fromJson<int>(json['unreadCount']),
      clearedAt: serializer.fromJson<int?>(json['clearedAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      sortTimestamp: serializer.fromJson<int>(json['sortTimestamp']),
      roomPts: serializer.fromJson<int>(json['roomPts']),
      msgPts: serializer.fromJson<int>(json['msgPts']),
      lastHistoryEditPts: serializer.fromJson<int>(json['lastHistoryEditPts']),
      messagesSyncedPts: serializer.fromJson<int>(json['messagesSyncedPts']),
      lastMessageJson: serializer.fromJson<String?>(json['lastMessageJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'roomId': serializer.toJson<String>(roomId),
      'roomType': serializer.toJson<String>(roomType),
      'peerUserId': serializer.toJson<String?>(peerUserId),
      'displayTitle': serializer.toJson<String>(displayTitle),
      'displayAvatarUrl': serializer.toJson<String?>(displayAvatarUrl),
      'pinAt': serializer.toJson<int?>(pinAt),
      'isMuted': serializer.toJson<bool>(isMuted),
      'unreadCount': serializer.toJson<int>(unreadCount),
      'clearedAt': serializer.toJson<int?>(clearedAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'sortTimestamp': serializer.toJson<int>(sortTimestamp),
      'roomPts': serializer.toJson<int>(roomPts),
      'msgPts': serializer.toJson<int>(msgPts),
      'lastHistoryEditPts': serializer.toJson<int>(lastHistoryEditPts),
      'messagesSyncedPts': serializer.toJson<int>(messagesSyncedPts),
      'lastMessageJson': serializer.toJson<String?>(lastMessageJson),
    };
  }

  LocalRoomRow copyWith({
    String? roomId,
    String? roomType,
    Value<String?> peerUserId = const Value.absent(),
    String? displayTitle,
    Value<String?> displayAvatarUrl = const Value.absent(),
    Value<int?> pinAt = const Value.absent(),
    bool? isMuted,
    int? unreadCount,
    Value<int?> clearedAt = const Value.absent(),
    Value<int?> deletedAt = const Value.absent(),
    int? sortTimestamp,
    int? roomPts,
    int? msgPts,
    int? lastHistoryEditPts,
    int? messagesSyncedPts,
    Value<String?> lastMessageJson = const Value.absent(),
  }) => LocalRoomRow(
    roomId: roomId ?? this.roomId,
    roomType: roomType ?? this.roomType,
    peerUserId: peerUserId.present ? peerUserId.value : this.peerUserId,
    displayTitle: displayTitle ?? this.displayTitle,
    displayAvatarUrl: displayAvatarUrl.present
        ? displayAvatarUrl.value
        : this.displayAvatarUrl,
    pinAt: pinAt.present ? pinAt.value : this.pinAt,
    isMuted: isMuted ?? this.isMuted,
    unreadCount: unreadCount ?? this.unreadCount,
    clearedAt: clearedAt.present ? clearedAt.value : this.clearedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    sortTimestamp: sortTimestamp ?? this.sortTimestamp,
    roomPts: roomPts ?? this.roomPts,
    msgPts: msgPts ?? this.msgPts,
    lastHistoryEditPts: lastHistoryEditPts ?? this.lastHistoryEditPts,
    messagesSyncedPts: messagesSyncedPts ?? this.messagesSyncedPts,
    lastMessageJson: lastMessageJson.present
        ? lastMessageJson.value
        : this.lastMessageJson,
  );
  LocalRoomRow copyWithCompanion(LocalRoomsCompanion data) {
    return LocalRoomRow(
      roomId: data.roomId.present ? data.roomId.value : this.roomId,
      roomType: data.roomType.present ? data.roomType.value : this.roomType,
      peerUserId: data.peerUserId.present
          ? data.peerUserId.value
          : this.peerUserId,
      displayTitle: data.displayTitle.present
          ? data.displayTitle.value
          : this.displayTitle,
      displayAvatarUrl: data.displayAvatarUrl.present
          ? data.displayAvatarUrl.value
          : this.displayAvatarUrl,
      pinAt: data.pinAt.present ? data.pinAt.value : this.pinAt,
      isMuted: data.isMuted.present ? data.isMuted.value : this.isMuted,
      unreadCount: data.unreadCount.present
          ? data.unreadCount.value
          : this.unreadCount,
      clearedAt: data.clearedAt.present ? data.clearedAt.value : this.clearedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      sortTimestamp: data.sortTimestamp.present
          ? data.sortTimestamp.value
          : this.sortTimestamp,
      roomPts: data.roomPts.present ? data.roomPts.value : this.roomPts,
      msgPts: data.msgPts.present ? data.msgPts.value : this.msgPts,
      lastHistoryEditPts: data.lastHistoryEditPts.present
          ? data.lastHistoryEditPts.value
          : this.lastHistoryEditPts,
      messagesSyncedPts: data.messagesSyncedPts.present
          ? data.messagesSyncedPts.value
          : this.messagesSyncedPts,
      lastMessageJson: data.lastMessageJson.present
          ? data.lastMessageJson.value
          : this.lastMessageJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalRoomRow(')
          ..write('roomId: $roomId, ')
          ..write('roomType: $roomType, ')
          ..write('peerUserId: $peerUserId, ')
          ..write('displayTitle: $displayTitle, ')
          ..write('displayAvatarUrl: $displayAvatarUrl, ')
          ..write('pinAt: $pinAt, ')
          ..write('isMuted: $isMuted, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('clearedAt: $clearedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('sortTimestamp: $sortTimestamp, ')
          ..write('roomPts: $roomPts, ')
          ..write('msgPts: $msgPts, ')
          ..write('lastHistoryEditPts: $lastHistoryEditPts, ')
          ..write('messagesSyncedPts: $messagesSyncedPts, ')
          ..write('lastMessageJson: $lastMessageJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    roomId,
    roomType,
    peerUserId,
    displayTitle,
    displayAvatarUrl,
    pinAt,
    isMuted,
    unreadCount,
    clearedAt,
    deletedAt,
    sortTimestamp,
    roomPts,
    msgPts,
    lastHistoryEditPts,
    messagesSyncedPts,
    lastMessageJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalRoomRow &&
          other.roomId == this.roomId &&
          other.roomType == this.roomType &&
          other.peerUserId == this.peerUserId &&
          other.displayTitle == this.displayTitle &&
          other.displayAvatarUrl == this.displayAvatarUrl &&
          other.pinAt == this.pinAt &&
          other.isMuted == this.isMuted &&
          other.unreadCount == this.unreadCount &&
          other.clearedAt == this.clearedAt &&
          other.deletedAt == this.deletedAt &&
          other.sortTimestamp == this.sortTimestamp &&
          other.roomPts == this.roomPts &&
          other.msgPts == this.msgPts &&
          other.lastHistoryEditPts == this.lastHistoryEditPts &&
          other.messagesSyncedPts == this.messagesSyncedPts &&
          other.lastMessageJson == this.lastMessageJson);
}

class LocalRoomsCompanion extends UpdateCompanion<LocalRoomRow> {
  final Value<String> roomId;
  final Value<String> roomType;
  final Value<String?> peerUserId;
  final Value<String> displayTitle;
  final Value<String?> displayAvatarUrl;
  final Value<int?> pinAt;
  final Value<bool> isMuted;
  final Value<int> unreadCount;
  final Value<int?> clearedAt;
  final Value<int?> deletedAt;
  final Value<int> sortTimestamp;
  final Value<int> roomPts;
  final Value<int> msgPts;
  final Value<int> lastHistoryEditPts;
  final Value<int> messagesSyncedPts;
  final Value<String?> lastMessageJson;
  final Value<int> rowid;
  const LocalRoomsCompanion({
    this.roomId = const Value.absent(),
    this.roomType = const Value.absent(),
    this.peerUserId = const Value.absent(),
    this.displayTitle = const Value.absent(),
    this.displayAvatarUrl = const Value.absent(),
    this.pinAt = const Value.absent(),
    this.isMuted = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.clearedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.sortTimestamp = const Value.absent(),
    this.roomPts = const Value.absent(),
    this.msgPts = const Value.absent(),
    this.lastHistoryEditPts = const Value.absent(),
    this.messagesSyncedPts = const Value.absent(),
    this.lastMessageJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalRoomsCompanion.insert({
    required String roomId,
    required String roomType,
    this.peerUserId = const Value.absent(),
    required String displayTitle,
    this.displayAvatarUrl = const Value.absent(),
    this.pinAt = const Value.absent(),
    this.isMuted = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.clearedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    required int sortTimestamp,
    required int roomPts,
    required int msgPts,
    this.lastHistoryEditPts = const Value.absent(),
    this.messagesSyncedPts = const Value.absent(),
    this.lastMessageJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : roomId = Value(roomId),
       roomType = Value(roomType),
       displayTitle = Value(displayTitle),
       sortTimestamp = Value(sortTimestamp),
       roomPts = Value(roomPts),
       msgPts = Value(msgPts);
  static Insertable<LocalRoomRow> custom({
    Expression<String>? roomId,
    Expression<String>? roomType,
    Expression<String>? peerUserId,
    Expression<String>? displayTitle,
    Expression<String>? displayAvatarUrl,
    Expression<int>? pinAt,
    Expression<bool>? isMuted,
    Expression<int>? unreadCount,
    Expression<int>? clearedAt,
    Expression<int>? deletedAt,
    Expression<int>? sortTimestamp,
    Expression<int>? roomPts,
    Expression<int>? msgPts,
    Expression<int>? lastHistoryEditPts,
    Expression<int>? messagesSyncedPts,
    Expression<String>? lastMessageJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (roomId != null) 'room_id': roomId,
      if (roomType != null) 'room_type': roomType,
      if (peerUserId != null) 'peer_user_id': peerUserId,
      if (displayTitle != null) 'display_title': displayTitle,
      if (displayAvatarUrl != null) 'display_avatar_url': displayAvatarUrl,
      if (pinAt != null) 'pin_at': pinAt,
      if (isMuted != null) 'is_muted': isMuted,
      if (unreadCount != null) 'unread_count': unreadCount,
      if (clearedAt != null) 'cleared_at': clearedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (sortTimestamp != null) 'sort_timestamp': sortTimestamp,
      if (roomPts != null) 'room_pts': roomPts,
      if (msgPts != null) 'msg_pts': msgPts,
      if (lastHistoryEditPts != null)
        'last_history_edit_pts': lastHistoryEditPts,
      if (messagesSyncedPts != null) 'messages_synced_pts': messagesSyncedPts,
      if (lastMessageJson != null) 'last_message_json': lastMessageJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalRoomsCompanion copyWith({
    Value<String>? roomId,
    Value<String>? roomType,
    Value<String?>? peerUserId,
    Value<String>? displayTitle,
    Value<String?>? displayAvatarUrl,
    Value<int?>? pinAt,
    Value<bool>? isMuted,
    Value<int>? unreadCount,
    Value<int?>? clearedAt,
    Value<int?>? deletedAt,
    Value<int>? sortTimestamp,
    Value<int>? roomPts,
    Value<int>? msgPts,
    Value<int>? lastHistoryEditPts,
    Value<int>? messagesSyncedPts,
    Value<String?>? lastMessageJson,
    Value<int>? rowid,
  }) {
    return LocalRoomsCompanion(
      roomId: roomId ?? this.roomId,
      roomType: roomType ?? this.roomType,
      peerUserId: peerUserId ?? this.peerUserId,
      displayTitle: displayTitle ?? this.displayTitle,
      displayAvatarUrl: displayAvatarUrl ?? this.displayAvatarUrl,
      pinAt: pinAt ?? this.pinAt,
      isMuted: isMuted ?? this.isMuted,
      unreadCount: unreadCount ?? this.unreadCount,
      clearedAt: clearedAt ?? this.clearedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      sortTimestamp: sortTimestamp ?? this.sortTimestamp,
      roomPts: roomPts ?? this.roomPts,
      msgPts: msgPts ?? this.msgPts,
      lastHistoryEditPts: lastHistoryEditPts ?? this.lastHistoryEditPts,
      messagesSyncedPts: messagesSyncedPts ?? this.messagesSyncedPts,
      lastMessageJson: lastMessageJson ?? this.lastMessageJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (roomId.present) {
      map['room_id'] = Variable<String>(roomId.value);
    }
    if (roomType.present) {
      map['room_type'] = Variable<String>(roomType.value);
    }
    if (peerUserId.present) {
      map['peer_user_id'] = Variable<String>(peerUserId.value);
    }
    if (displayTitle.present) {
      map['display_title'] = Variable<String>(displayTitle.value);
    }
    if (displayAvatarUrl.present) {
      map['display_avatar_url'] = Variable<String>(displayAvatarUrl.value);
    }
    if (pinAt.present) {
      map['pin_at'] = Variable<int>(pinAt.value);
    }
    if (isMuted.present) {
      map['is_muted'] = Variable<bool>(isMuted.value);
    }
    if (unreadCount.present) {
      map['unread_count'] = Variable<int>(unreadCount.value);
    }
    if (clearedAt.present) {
      map['cleared_at'] = Variable<int>(clearedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (sortTimestamp.present) {
      map['sort_timestamp'] = Variable<int>(sortTimestamp.value);
    }
    if (roomPts.present) {
      map['room_pts'] = Variable<int>(roomPts.value);
    }
    if (msgPts.present) {
      map['msg_pts'] = Variable<int>(msgPts.value);
    }
    if (lastHistoryEditPts.present) {
      map['last_history_edit_pts'] = Variable<int>(lastHistoryEditPts.value);
    }
    if (messagesSyncedPts.present) {
      map['messages_synced_pts'] = Variable<int>(messagesSyncedPts.value);
    }
    if (lastMessageJson.present) {
      map['last_message_json'] = Variable<String>(lastMessageJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalRoomsCompanion(')
          ..write('roomId: $roomId, ')
          ..write('roomType: $roomType, ')
          ..write('peerUserId: $peerUserId, ')
          ..write('displayTitle: $displayTitle, ')
          ..write('displayAvatarUrl: $displayAvatarUrl, ')
          ..write('pinAt: $pinAt, ')
          ..write('isMuted: $isMuted, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('clearedAt: $clearedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('sortTimestamp: $sortTimestamp, ')
          ..write('roomPts: $roomPts, ')
          ..write('msgPts: $msgPts, ')
          ..write('lastHistoryEditPts: $lastHistoryEditPts, ')
          ..write('messagesSyncedPts: $messagesSyncedPts, ')
          ..write('lastMessageJson: $lastMessageJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMessagesTable extends LocalMessages
    with TableInfo<$LocalMessagesTable, LocalMessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _idempotencyKeyMeta = const VerificationMeta(
    'idempotencyKey',
  );
  @override
  late final GeneratedColumn<String> idempotencyKey = GeneratedColumn<String>(
    'idempotency_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _roomIdMeta = const VerificationMeta('roomId');
  @override
  late final GeneratedColumn<String> roomId = GeneratedColumn<String>(
    'room_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerUserIdMeta = const VerificationMeta(
    'peerUserId',
  );
  @override
  late final GeneratedColumn<String> peerUserId = GeneratedColumn<String>(
    'peer_user_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _senderIdMeta = const VerificationMeta(
    'senderId',
  );
  @override
  late final GeneratedColumn<String> senderId = GeneratedColumn<String>(
    'sender_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderNameMeta = const VerificationMeta(
    'senderName',
  );
  @override
  late final GeneratedColumn<String> senderName = GeneratedColumn<String>(
    'sender_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderAvatarUrlMeta = const VerificationMeta(
    'senderAvatarUrl',
  );
  @override
  late final GeneratedColumn<String> senderAvatarUrl = GeneratedColumn<String>(
    'sender_avatar_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _imageUrlMeta = const VerificationMeta(
    'imageUrl',
  );
  @override
  late final GeneratedColumn<String> imageUrl = GeneratedColumn<String>(
    'image_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _replyToJsonMeta = const VerificationMeta(
    'replyToJson',
  );
  @override
  late final GeneratedColumn<String> replyToJson = GeneratedColumn<String>(
    'reply_to_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isEditedMeta = const VerificationMeta(
    'isEdited',
  );
  @override
  late final GeneratedColumn<bool> isEdited = GeneratedColumn<bool>(
    'is_edited',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_edited" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isDeletedForAllMeta = const VerificationMeta(
    'isDeletedForAll',
  );
  @override
  late final GeneratedColumn<bool> isDeletedForAll = GeneratedColumn<bool>(
    'is_deleted_for_all',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_deleted_for_all" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _deliveredAtMeta = const VerificationMeta(
    'deliveredAt',
  );
  @override
  late final GeneratedColumn<int> deliveredAt = GeneratedColumn<int>(
    'delivered_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seenAtMeta = const VerificationMeta('seenAt');
  @override
  late final GeneratedColumn<int> seenAt = GeneratedColumn<int>(
    'seen_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    idempotencyKey,
    roomId,
    peerUserId,
    senderId,
    senderName,
    senderAvatarUrl,
    type,
    content,
    imageUrl,
    replyToJson,
    status,
    isEdited,
    isDeletedForAll,
    deliveredAt,
    seenAt,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalMessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('idempotency_key')) {
      context.handle(
        _idempotencyKeyMeta,
        idempotencyKey.isAcceptableOrUnknown(
          data['idempotency_key']!,
          _idempotencyKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_idempotencyKeyMeta);
    }
    if (data.containsKey('room_id')) {
      context.handle(
        _roomIdMeta,
        roomId.isAcceptableOrUnknown(data['room_id']!, _roomIdMeta),
      );
    } else if (isInserting) {
      context.missing(_roomIdMeta);
    }
    if (data.containsKey('peer_user_id')) {
      context.handle(
        _peerUserIdMeta,
        peerUserId.isAcceptableOrUnknown(
          data['peer_user_id']!,
          _peerUserIdMeta,
        ),
      );
    }
    if (data.containsKey('sender_id')) {
      context.handle(
        _senderIdMeta,
        senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    if (data.containsKey('sender_name')) {
      context.handle(
        _senderNameMeta,
        senderName.isAcceptableOrUnknown(data['sender_name']!, _senderNameMeta),
      );
    } else if (isInserting) {
      context.missing(_senderNameMeta);
    }
    if (data.containsKey('sender_avatar_url')) {
      context.handle(
        _senderAvatarUrlMeta,
        senderAvatarUrl.isAcceptableOrUnknown(
          data['sender_avatar_url']!,
          _senderAvatarUrlMeta,
        ),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('text')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['text']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('image_url')) {
      context.handle(
        _imageUrlMeta,
        imageUrl.isAcceptableOrUnknown(data['image_url']!, _imageUrlMeta),
      );
    }
    if (data.containsKey('reply_to_json')) {
      context.handle(
        _replyToJsonMeta,
        replyToJson.isAcceptableOrUnknown(
          data['reply_to_json']!,
          _replyToJsonMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('is_edited')) {
      context.handle(
        _isEditedMeta,
        isEdited.isAcceptableOrUnknown(data['is_edited']!, _isEditedMeta),
      );
    }
    if (data.containsKey('is_deleted_for_all')) {
      context.handle(
        _isDeletedForAllMeta,
        isDeletedForAll.isAcceptableOrUnknown(
          data['is_deleted_for_all']!,
          _isDeletedForAllMeta,
        ),
      );
    }
    if (data.containsKey('delivered_at')) {
      context.handle(
        _deliveredAtMeta,
        deliveredAt.isAcceptableOrUnknown(
          data['delivered_at']!,
          _deliveredAtMeta,
        ),
      );
    }
    if (data.containsKey('seen_at')) {
      context.handle(
        _seenAtMeta,
        seenAt.isAcceptableOrUnknown(data['seen_at']!, _seenAtMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalMessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      idempotencyKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}idempotency_key'],
      )!,
      roomId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_id'],
      )!,
      peerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_user_id'],
      ),
      senderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_id'],
      )!,
      senderName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_name'],
      )!,
      senderAvatarUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_avatar_url'],
      ),
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}text'],
      )!,
      imageUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}image_url'],
      ),
      replyToJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_to_json'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      isEdited: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_edited'],
      )!,
      isDeletedForAll: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_deleted_for_all'],
      )!,
      deliveredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delivered_at'],
      ),
      seenAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seen_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $LocalMessagesTable createAlias(String alias) {
    return $LocalMessagesTable(attachedDatabase, alias);
  }
}

class LocalMessageRow extends DataClass implements Insertable<LocalMessageRow> {
  final String id;
  final String idempotencyKey;
  final String roomId;
  final String? peerUserId;
  final String senderId;
  final String senderName;
  final String? senderAvatarUrl;
  final String type;
  final String content;
  final String? imageUrl;
  final String? replyToJson;
  final String status;
  final bool isEdited;
  final bool isDeletedForAll;
  final int? deliveredAt;
  final int? seenAt;
  final int createdAt;
  const LocalMessageRow({
    required this.id,
    required this.idempotencyKey,
    required this.roomId,
    this.peerUserId,
    required this.senderId,
    required this.senderName,
    this.senderAvatarUrl,
    required this.type,
    required this.content,
    this.imageUrl,
    this.replyToJson,
    required this.status,
    required this.isEdited,
    required this.isDeletedForAll,
    this.deliveredAt,
    this.seenAt,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['idempotency_key'] = Variable<String>(idempotencyKey);
    map['room_id'] = Variable<String>(roomId);
    if (!nullToAbsent || peerUserId != null) {
      map['peer_user_id'] = Variable<String>(peerUserId);
    }
    map['sender_id'] = Variable<String>(senderId);
    map['sender_name'] = Variable<String>(senderName);
    if (!nullToAbsent || senderAvatarUrl != null) {
      map['sender_avatar_url'] = Variable<String>(senderAvatarUrl);
    }
    map['type'] = Variable<String>(type);
    map['text'] = Variable<String>(content);
    if (!nullToAbsent || imageUrl != null) {
      map['image_url'] = Variable<String>(imageUrl);
    }
    if (!nullToAbsent || replyToJson != null) {
      map['reply_to_json'] = Variable<String>(replyToJson);
    }
    map['status'] = Variable<String>(status);
    map['is_edited'] = Variable<bool>(isEdited);
    map['is_deleted_for_all'] = Variable<bool>(isDeletedForAll);
    if (!nullToAbsent || deliveredAt != null) {
      map['delivered_at'] = Variable<int>(deliveredAt);
    }
    if (!nullToAbsent || seenAt != null) {
      map['seen_at'] = Variable<int>(seenAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  LocalMessagesCompanion toCompanion(bool nullToAbsent) {
    return LocalMessagesCompanion(
      id: Value(id),
      idempotencyKey: Value(idempotencyKey),
      roomId: Value(roomId),
      peerUserId: peerUserId == null && nullToAbsent
          ? const Value.absent()
          : Value(peerUserId),
      senderId: Value(senderId),
      senderName: Value(senderName),
      senderAvatarUrl: senderAvatarUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(senderAvatarUrl),
      type: Value(type),
      content: Value(content),
      imageUrl: imageUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(imageUrl),
      replyToJson: replyToJson == null && nullToAbsent
          ? const Value.absent()
          : Value(replyToJson),
      status: Value(status),
      isEdited: Value(isEdited),
      isDeletedForAll: Value(isDeletedForAll),
      deliveredAt: deliveredAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deliveredAt),
      seenAt: seenAt == null && nullToAbsent
          ? const Value.absent()
          : Value(seenAt),
      createdAt: Value(createdAt),
    );
  }

  factory LocalMessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMessageRow(
      id: serializer.fromJson<String>(json['id']),
      idempotencyKey: serializer.fromJson<String>(json['idempotencyKey']),
      roomId: serializer.fromJson<String>(json['roomId']),
      peerUserId: serializer.fromJson<String?>(json['peerUserId']),
      senderId: serializer.fromJson<String>(json['senderId']),
      senderName: serializer.fromJson<String>(json['senderName']),
      senderAvatarUrl: serializer.fromJson<String?>(json['senderAvatarUrl']),
      type: serializer.fromJson<String>(json['type']),
      content: serializer.fromJson<String>(json['content']),
      imageUrl: serializer.fromJson<String?>(json['imageUrl']),
      replyToJson: serializer.fromJson<String?>(json['replyToJson']),
      status: serializer.fromJson<String>(json['status']),
      isEdited: serializer.fromJson<bool>(json['isEdited']),
      isDeletedForAll: serializer.fromJson<bool>(json['isDeletedForAll']),
      deliveredAt: serializer.fromJson<int?>(json['deliveredAt']),
      seenAt: serializer.fromJson<int?>(json['seenAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'idempotencyKey': serializer.toJson<String>(idempotencyKey),
      'roomId': serializer.toJson<String>(roomId),
      'peerUserId': serializer.toJson<String?>(peerUserId),
      'senderId': serializer.toJson<String>(senderId),
      'senderName': serializer.toJson<String>(senderName),
      'senderAvatarUrl': serializer.toJson<String?>(senderAvatarUrl),
      'type': serializer.toJson<String>(type),
      'content': serializer.toJson<String>(content),
      'imageUrl': serializer.toJson<String?>(imageUrl),
      'replyToJson': serializer.toJson<String?>(replyToJson),
      'status': serializer.toJson<String>(status),
      'isEdited': serializer.toJson<bool>(isEdited),
      'isDeletedForAll': serializer.toJson<bool>(isDeletedForAll),
      'deliveredAt': serializer.toJson<int?>(deliveredAt),
      'seenAt': serializer.toJson<int?>(seenAt),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  LocalMessageRow copyWith({
    String? id,
    String? idempotencyKey,
    String? roomId,
    Value<String?> peerUserId = const Value.absent(),
    String? senderId,
    String? senderName,
    Value<String?> senderAvatarUrl = const Value.absent(),
    String? type,
    String? content,
    Value<String?> imageUrl = const Value.absent(),
    Value<String?> replyToJson = const Value.absent(),
    String? status,
    bool? isEdited,
    bool? isDeletedForAll,
    Value<int?> deliveredAt = const Value.absent(),
    Value<int?> seenAt = const Value.absent(),
    int? createdAt,
  }) => LocalMessageRow(
    id: id ?? this.id,
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    roomId: roomId ?? this.roomId,
    peerUserId: peerUserId.present ? peerUserId.value : this.peerUserId,
    senderId: senderId ?? this.senderId,
    senderName: senderName ?? this.senderName,
    senderAvatarUrl: senderAvatarUrl.present
        ? senderAvatarUrl.value
        : this.senderAvatarUrl,
    type: type ?? this.type,
    content: content ?? this.content,
    imageUrl: imageUrl.present ? imageUrl.value : this.imageUrl,
    replyToJson: replyToJson.present ? replyToJson.value : this.replyToJson,
    status: status ?? this.status,
    isEdited: isEdited ?? this.isEdited,
    isDeletedForAll: isDeletedForAll ?? this.isDeletedForAll,
    deliveredAt: deliveredAt.present ? deliveredAt.value : this.deliveredAt,
    seenAt: seenAt.present ? seenAt.value : this.seenAt,
    createdAt: createdAt ?? this.createdAt,
  );
  LocalMessageRow copyWithCompanion(LocalMessagesCompanion data) {
    return LocalMessageRow(
      id: data.id.present ? data.id.value : this.id,
      idempotencyKey: data.idempotencyKey.present
          ? data.idempotencyKey.value
          : this.idempotencyKey,
      roomId: data.roomId.present ? data.roomId.value : this.roomId,
      peerUserId: data.peerUserId.present
          ? data.peerUserId.value
          : this.peerUserId,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      senderName: data.senderName.present
          ? data.senderName.value
          : this.senderName,
      senderAvatarUrl: data.senderAvatarUrl.present
          ? data.senderAvatarUrl.value
          : this.senderAvatarUrl,
      type: data.type.present ? data.type.value : this.type,
      content: data.content.present ? data.content.value : this.content,
      imageUrl: data.imageUrl.present ? data.imageUrl.value : this.imageUrl,
      replyToJson: data.replyToJson.present
          ? data.replyToJson.value
          : this.replyToJson,
      status: data.status.present ? data.status.value : this.status,
      isEdited: data.isEdited.present ? data.isEdited.value : this.isEdited,
      isDeletedForAll: data.isDeletedForAll.present
          ? data.isDeletedForAll.value
          : this.isDeletedForAll,
      deliveredAt: data.deliveredAt.present
          ? data.deliveredAt.value
          : this.deliveredAt,
      seenAt: data.seenAt.present ? data.seenAt.value : this.seenAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessageRow(')
          ..write('id: $id, ')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('roomId: $roomId, ')
          ..write('peerUserId: $peerUserId, ')
          ..write('senderId: $senderId, ')
          ..write('senderName: $senderName, ')
          ..write('senderAvatarUrl: $senderAvatarUrl, ')
          ..write('type: $type, ')
          ..write('content: $content, ')
          ..write('imageUrl: $imageUrl, ')
          ..write('replyToJson: $replyToJson, ')
          ..write('status: $status, ')
          ..write('isEdited: $isEdited, ')
          ..write('isDeletedForAll: $isDeletedForAll, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('seenAt: $seenAt, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    idempotencyKey,
    roomId,
    peerUserId,
    senderId,
    senderName,
    senderAvatarUrl,
    type,
    content,
    imageUrl,
    replyToJson,
    status,
    isEdited,
    isDeletedForAll,
    deliveredAt,
    seenAt,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMessageRow &&
          other.id == this.id &&
          other.idempotencyKey == this.idempotencyKey &&
          other.roomId == this.roomId &&
          other.peerUserId == this.peerUserId &&
          other.senderId == this.senderId &&
          other.senderName == this.senderName &&
          other.senderAvatarUrl == this.senderAvatarUrl &&
          other.type == this.type &&
          other.content == this.content &&
          other.imageUrl == this.imageUrl &&
          other.replyToJson == this.replyToJson &&
          other.status == this.status &&
          other.isEdited == this.isEdited &&
          other.isDeletedForAll == this.isDeletedForAll &&
          other.deliveredAt == this.deliveredAt &&
          other.seenAt == this.seenAt &&
          other.createdAt == this.createdAt);
}

class LocalMessagesCompanion extends UpdateCompanion<LocalMessageRow> {
  final Value<String> id;
  final Value<String> idempotencyKey;
  final Value<String> roomId;
  final Value<String?> peerUserId;
  final Value<String> senderId;
  final Value<String> senderName;
  final Value<String?> senderAvatarUrl;
  final Value<String> type;
  final Value<String> content;
  final Value<String?> imageUrl;
  final Value<String?> replyToJson;
  final Value<String> status;
  final Value<bool> isEdited;
  final Value<bool> isDeletedForAll;
  final Value<int?> deliveredAt;
  final Value<int?> seenAt;
  final Value<int> createdAt;
  final Value<int> rowid;
  const LocalMessagesCompanion({
    this.id = const Value.absent(),
    this.idempotencyKey = const Value.absent(),
    this.roomId = const Value.absent(),
    this.peerUserId = const Value.absent(),
    this.senderId = const Value.absent(),
    this.senderName = const Value.absent(),
    this.senderAvatarUrl = const Value.absent(),
    this.type = const Value.absent(),
    this.content = const Value.absent(),
    this.imageUrl = const Value.absent(),
    this.replyToJson = const Value.absent(),
    this.status = const Value.absent(),
    this.isEdited = const Value.absent(),
    this.isDeletedForAll = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.seenAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMessagesCompanion.insert({
    required String id,
    required String idempotencyKey,
    required String roomId,
    this.peerUserId = const Value.absent(),
    required String senderId,
    required String senderName,
    this.senderAvatarUrl = const Value.absent(),
    required String type,
    required String content,
    this.imageUrl = const Value.absent(),
    this.replyToJson = const Value.absent(),
    required String status,
    this.isEdited = const Value.absent(),
    this.isDeletedForAll = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.seenAt = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       idempotencyKey = Value(idempotencyKey),
       roomId = Value(roomId),
       senderId = Value(senderId),
       senderName = Value(senderName),
       type = Value(type),
       content = Value(content),
       status = Value(status),
       createdAt = Value(createdAt);
  static Insertable<LocalMessageRow> custom({
    Expression<String>? id,
    Expression<String>? idempotencyKey,
    Expression<String>? roomId,
    Expression<String>? peerUserId,
    Expression<String>? senderId,
    Expression<String>? senderName,
    Expression<String>? senderAvatarUrl,
    Expression<String>? type,
    Expression<String>? content,
    Expression<String>? imageUrl,
    Expression<String>? replyToJson,
    Expression<String>? status,
    Expression<bool>? isEdited,
    Expression<bool>? isDeletedForAll,
    Expression<int>? deliveredAt,
    Expression<int>? seenAt,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      if (roomId != null) 'room_id': roomId,
      if (peerUserId != null) 'peer_user_id': peerUserId,
      if (senderId != null) 'sender_id': senderId,
      if (senderName != null) 'sender_name': senderName,
      if (senderAvatarUrl != null) 'sender_avatar_url': senderAvatarUrl,
      if (type != null) 'type': type,
      if (content != null) 'text': content,
      if (imageUrl != null) 'image_url': imageUrl,
      if (replyToJson != null) 'reply_to_json': replyToJson,
      if (status != null) 'status': status,
      if (isEdited != null) 'is_edited': isEdited,
      if (isDeletedForAll != null) 'is_deleted_for_all': isDeletedForAll,
      if (deliveredAt != null) 'delivered_at': deliveredAt,
      if (seenAt != null) 'seen_at': seenAt,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? idempotencyKey,
    Value<String>? roomId,
    Value<String?>? peerUserId,
    Value<String>? senderId,
    Value<String>? senderName,
    Value<String?>? senderAvatarUrl,
    Value<String>? type,
    Value<String>? content,
    Value<String?>? imageUrl,
    Value<String?>? replyToJson,
    Value<String>? status,
    Value<bool>? isEdited,
    Value<bool>? isDeletedForAll,
    Value<int?>? deliveredAt,
    Value<int?>? seenAt,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return LocalMessagesCompanion(
      id: id ?? this.id,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      roomId: roomId ?? this.roomId,
      peerUserId: peerUserId ?? this.peerUserId,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      senderAvatarUrl: senderAvatarUrl ?? this.senderAvatarUrl,
      type: type ?? this.type,
      content: content ?? this.content,
      imageUrl: imageUrl ?? this.imageUrl,
      replyToJson: replyToJson ?? this.replyToJson,
      status: status ?? this.status,
      isEdited: isEdited ?? this.isEdited,
      isDeletedForAll: isDeletedForAll ?? this.isDeletedForAll,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      seenAt: seenAt ?? this.seenAt,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (idempotencyKey.present) {
      map['idempotency_key'] = Variable<String>(idempotencyKey.value);
    }
    if (roomId.present) {
      map['room_id'] = Variable<String>(roomId.value);
    }
    if (peerUserId.present) {
      map['peer_user_id'] = Variable<String>(peerUserId.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<String>(senderId.value);
    }
    if (senderName.present) {
      map['sender_name'] = Variable<String>(senderName.value);
    }
    if (senderAvatarUrl.present) {
      map['sender_avatar_url'] = Variable<String>(senderAvatarUrl.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (content.present) {
      map['text'] = Variable<String>(content.value);
    }
    if (imageUrl.present) {
      map['image_url'] = Variable<String>(imageUrl.value);
    }
    if (replyToJson.present) {
      map['reply_to_json'] = Variable<String>(replyToJson.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (isEdited.present) {
      map['is_edited'] = Variable<bool>(isEdited.value);
    }
    if (isDeletedForAll.present) {
      map['is_deleted_for_all'] = Variable<bool>(isDeletedForAll.value);
    }
    if (deliveredAt.present) {
      map['delivered_at'] = Variable<int>(deliveredAt.value);
    }
    if (seenAt.present) {
      map['seen_at'] = Variable<int>(seenAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessagesCompanion(')
          ..write('id: $id, ')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('roomId: $roomId, ')
          ..write('peerUserId: $peerUserId, ')
          ..write('senderId: $senderId, ')
          ..write('senderName: $senderName, ')
          ..write('senderAvatarUrl: $senderAvatarUrl, ')
          ..write('type: $type, ')
          ..write('content: $content, ')
          ..write('imageUrl: $imageUrl, ')
          ..write('replyToJson: $replyToJson, ')
          ..write('status: $status, ')
          ..write('isEdited: $isEdited, ')
          ..write('isDeletedForAll: $isDeletedForAll, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('seenAt: $seenAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SyncMetadataTable syncMetadata = $SyncMetadataTable(this);
  late final $LocalRoomsTable localRooms = $LocalRoomsTable(this);
  late final $LocalMessagesTable localMessages = $LocalMessagesTable(this);
  late final Index localMessagesRoomCreated = Index(
    'local_messages_room_created',
    'CREATE INDEX local_messages_room_created ON local_messages (room_id, created_at, id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    syncMetadata,
    localRooms,
    localMessages,
    localMessagesRoomCreated,
  ];
}

typedef $$SyncMetadataTableCreateCompanionBuilder =
    SyncMetadataCompanion Function({
      Value<int> id,
      required String userId,
      Value<int> localPts,
      Value<String> localEpoch,
    });
typedef $$SyncMetadataTableUpdateCompanionBuilder =
    SyncMetadataCompanion Function({
      Value<int> id,
      Value<String> userId,
      Value<int> localPts,
      Value<String> localEpoch,
    });

class $$SyncMetadataTableFilterComposer
    extends Composer<_$AppDatabase, $SyncMetadataTable> {
  $$SyncMetadataTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get localPts => $composableBuilder(
    column: $table.localPts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localEpoch => $composableBuilder(
    column: $table.localEpoch,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncMetadataTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncMetadataTable> {
  $$SyncMetadataTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get localPts => $composableBuilder(
    column: $table.localPts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localEpoch => $composableBuilder(
    column: $table.localEpoch,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncMetadataTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncMetadataTable> {
  $$SyncMetadataTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<int> get localPts =>
      $composableBuilder(column: $table.localPts, builder: (column) => column);

  GeneratedColumn<String> get localEpoch => $composableBuilder(
    column: $table.localEpoch,
    builder: (column) => column,
  );
}

class $$SyncMetadataTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncMetadataTable,
          SyncMetadataRow,
          $$SyncMetadataTableFilterComposer,
          $$SyncMetadataTableOrderingComposer,
          $$SyncMetadataTableAnnotationComposer,
          $$SyncMetadataTableCreateCompanionBuilder,
          $$SyncMetadataTableUpdateCompanionBuilder,
          (
            SyncMetadataRow,
            BaseReferences<_$AppDatabase, $SyncMetadataTable, SyncMetadataRow>,
          ),
          SyncMetadataRow,
          PrefetchHooks Function()
        > {
  $$SyncMetadataTableTableManager(_$AppDatabase db, $SyncMetadataTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncMetadataTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncMetadataTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncMetadataTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<int> localPts = const Value.absent(),
                Value<String> localEpoch = const Value.absent(),
              }) => SyncMetadataCompanion(
                id: id,
                userId: userId,
                localPts: localPts,
                localEpoch: localEpoch,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String userId,
                Value<int> localPts = const Value.absent(),
                Value<String> localEpoch = const Value.absent(),
              }) => SyncMetadataCompanion.insert(
                id: id,
                userId: userId,
                localPts: localPts,
                localEpoch: localEpoch,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncMetadataTable, SyncMetadataRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SyncMetadataTable,
                    SyncMetadataRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncMetadataTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncMetadataTable,
      SyncMetadataRow,
      $$SyncMetadataTableFilterComposer,
      $$SyncMetadataTableOrderingComposer,
      $$SyncMetadataTableAnnotationComposer,
      $$SyncMetadataTableCreateCompanionBuilder,
      $$SyncMetadataTableUpdateCompanionBuilder,
      (
        SyncMetadataRow,
        BaseReferences<_$AppDatabase, $SyncMetadataTable, SyncMetadataRow>,
      ),
      SyncMetadataRow,
      PrefetchHooks Function()
    >;
typedef $$LocalRoomsTableCreateCompanionBuilder = LocalRoomsCompanion Function({
  required String roomId,
  required String roomType,
  Value<String?> peerUserId,
  required String displayTitle,
  Value<String?> displayAvatarUrl,
  Value<int?> pinAt,
  Value<bool> isMuted,
  Value<int> unreadCount,
  Value<int?> clearedAt,
  Value<int?> deletedAt,
  required int sortTimestamp,
  required int roomPts,
  required int msgPts,
  Value<int> lastHistoryEditPts,
  Value<int> messagesSyncedPts,
  Value<String?> lastMessageJson,
  Value<int> rowid,
});
typedef $$LocalRoomsTableUpdateCompanionBuilder = LocalRoomsCompanion Function({
  Value<String> roomId,
  Value<String> roomType,
  Value<String?> peerUserId,
  Value<String> displayTitle,
  Value<String?> displayAvatarUrl,
  Value<int?> pinAt,
  Value<bool> isMuted,
  Value<int> unreadCount,
  Value<int?> clearedAt,
  Value<int?> deletedAt,
  Value<int> sortTimestamp,
  Value<int> roomPts,
  Value<int> msgPts,
  Value<int> lastHistoryEditPts,
  Value<int> messagesSyncedPts,
  Value<String?> lastMessageJson,
  Value<int> rowid,
});

class $$LocalRoomsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalRoomsTable> {
  $$LocalRoomsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get roomId => $composableBuilder(
    column: $table.roomId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roomType => $composableBuilder(
    column: $table.roomType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayTitle => $composableBuilder(
    column: $table.displayTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayAvatarUrl => $composableBuilder(
    column: $table.displayAvatarUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pinAt => $composableBuilder(
    column: $table.pinAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isMuted => $composableBuilder(
    column: $table.isMuted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get clearedAt => $composableBuilder(
    column: $table.clearedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortTimestamp => $composableBuilder(
    column: $table.sortTimestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get roomPts => $composableBuilder(
    column: $table.roomPts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get msgPts => $composableBuilder(
    column: $table.msgPts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastHistoryEditPts => $composableBuilder(
    column: $table.lastHistoryEditPts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get messagesSyncedPts => $composableBuilder(
    column: $table.messagesSyncedPts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastMessageJson => $composableBuilder(
    column: $table.lastMessageJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalRoomsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalRoomsTable> {
  $$LocalRoomsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get roomId => $composableBuilder(
    column: $table.roomId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roomType => $composableBuilder(
    column: $table.roomType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayTitle => $composableBuilder(
    column: $table.displayTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayAvatarUrl => $composableBuilder(
    column: $table.displayAvatarUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pinAt => $composableBuilder(
    column: $table.pinAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isMuted => $composableBuilder(
    column: $table.isMuted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get clearedAt => $composableBuilder(
    column: $table.clearedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortTimestamp => $composableBuilder(
    column: $table.sortTimestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get roomPts => $composableBuilder(
    column: $table.roomPts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get msgPts => $composableBuilder(
    column: $table.msgPts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastHistoryEditPts => $composableBuilder(
    column: $table.lastHistoryEditPts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get messagesSyncedPts => $composableBuilder(
    column: $table.messagesSyncedPts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastMessageJson => $composableBuilder(
    column: $table.lastMessageJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalRoomsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalRoomsTable> {
  $$LocalRoomsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get roomId =>
      $composableBuilder(column: $table.roomId, builder: (column) => column);

  GeneratedColumn<String> get roomType =>
      $composableBuilder(column: $table.roomType, builder: (column) => column);

  GeneratedColumn<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayTitle => $composableBuilder(
    column: $table.displayTitle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayAvatarUrl => $composableBuilder(
    column: $table.displayAvatarUrl,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pinAt =>
      $composableBuilder(column: $table.pinAt, builder: (column) => column);

  GeneratedColumn<bool> get isMuted =>
      $composableBuilder(column: $table.isMuted, builder: (column) => column);

  GeneratedColumn<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get clearedAt =>
      $composableBuilder(column: $table.clearedAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<int> get sortTimestamp => $composableBuilder(
    column: $table.sortTimestamp,
    builder: (column) => column,
  );

  GeneratedColumn<int> get roomPts =>
      $composableBuilder(column: $table.roomPts, builder: (column) => column);

  GeneratedColumn<int> get msgPts =>
      $composableBuilder(column: $table.msgPts, builder: (column) => column);

  GeneratedColumn<int> get lastHistoryEditPts => $composableBuilder(
    column: $table.lastHistoryEditPts,
    builder: (column) => column,
  );

  GeneratedColumn<int> get messagesSyncedPts => $composableBuilder(
    column: $table.messagesSyncedPts,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastMessageJson => $composableBuilder(
    column: $table.lastMessageJson,
    builder: (column) => column,
  );
}

class $$LocalRoomsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalRoomsTable,
          LocalRoomRow,
          $$LocalRoomsTableFilterComposer,
          $$LocalRoomsTableOrderingComposer,
          $$LocalRoomsTableAnnotationComposer,
          $$LocalRoomsTableCreateCompanionBuilder,
          $$LocalRoomsTableUpdateCompanionBuilder,
          (
            LocalRoomRow,
            BaseReferences<_$AppDatabase, $LocalRoomsTable, LocalRoomRow>,
          ),
          LocalRoomRow,
          PrefetchHooks Function()
        > {
  $$LocalRoomsTableTableManager(_$AppDatabase db, $LocalRoomsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalRoomsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalRoomsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalRoomsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> roomId = const Value.absent(),
                Value<String> roomType = const Value.absent(),
                Value<String?> peerUserId = const Value.absent(),
                Value<String> displayTitle = const Value.absent(),
                Value<String?> displayAvatarUrl = const Value.absent(),
                Value<int?> pinAt = const Value.absent(),
                Value<bool> isMuted = const Value.absent(),
                Value<int> unreadCount = const Value.absent(),
                Value<int?> clearedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<int> sortTimestamp = const Value.absent(),
                Value<int> roomPts = const Value.absent(),
                Value<int> msgPts = const Value.absent(),
                Value<int> lastHistoryEditPts = const Value.absent(),
                Value<int> messagesSyncedPts = const Value.absent(),
                Value<String?> lastMessageJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalRoomsCompanion(
                roomId: roomId,
                roomType: roomType,
                peerUserId: peerUserId,
                displayTitle: displayTitle,
                displayAvatarUrl: displayAvatarUrl,
                pinAt: pinAt,
                isMuted: isMuted,
                unreadCount: unreadCount,
                clearedAt: clearedAt,
                deletedAt: deletedAt,
                sortTimestamp: sortTimestamp,
                roomPts: roomPts,
                msgPts: msgPts,
                lastHistoryEditPts: lastHistoryEditPts,
                messagesSyncedPts: messagesSyncedPts,
                lastMessageJson: lastMessageJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String roomId,
                required String roomType,
                Value<String?> peerUserId = const Value.absent(),
                required String displayTitle,
                Value<String?> displayAvatarUrl = const Value.absent(),
                Value<int?> pinAt = const Value.absent(),
                Value<bool> isMuted = const Value.absent(),
                Value<int> unreadCount = const Value.absent(),
                Value<int?> clearedAt = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                required int sortTimestamp,
                required int roomPts,
                required int msgPts,
                Value<int> lastHistoryEditPts = const Value.absent(),
                Value<int> messagesSyncedPts = const Value.absent(),
                Value<String?> lastMessageJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalRoomsCompanion.insert(
                roomId: roomId,
                roomType: roomType,
                peerUserId: peerUserId,
                displayTitle: displayTitle,
                displayAvatarUrl: displayAvatarUrl,
                pinAt: pinAt,
                isMuted: isMuted,
                unreadCount: unreadCount,
                clearedAt: clearedAt,
                deletedAt: deletedAt,
                sortTimestamp: sortTimestamp,
                roomPts: roomPts,
                msgPts: msgPts,
                lastHistoryEditPts: lastHistoryEditPts,
                messagesSyncedPts: messagesSyncedPts,
                lastMessageJson: lastMessageJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalRoomsTable, LocalRoomRow>(table),
                  BaseReferences<_$AppDatabase, $LocalRoomsTable, LocalRoomRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalRoomsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalRoomsTable,
      LocalRoomRow,
      $$LocalRoomsTableFilterComposer,
      $$LocalRoomsTableOrderingComposer,
      $$LocalRoomsTableAnnotationComposer,
      $$LocalRoomsTableCreateCompanionBuilder,
      $$LocalRoomsTableUpdateCompanionBuilder,
      (
        LocalRoomRow,
        BaseReferences<_$AppDatabase, $LocalRoomsTable, LocalRoomRow>,
      ),
      LocalRoomRow,
      PrefetchHooks Function()
    >;
typedef $$LocalMessagesTableCreateCompanionBuilder =
    LocalMessagesCompanion Function({
      required String id,
      required String idempotencyKey,
      required String roomId,
      Value<String?> peerUserId,
      required String senderId,
      required String senderName,
      Value<String?> senderAvatarUrl,
      required String type,
      required String content,
      Value<String?> imageUrl,
      Value<String?> replyToJson,
      required String status,
      Value<bool> isEdited,
      Value<bool> isDeletedForAll,
      Value<int?> deliveredAt,
      Value<int?> seenAt,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$LocalMessagesTableUpdateCompanionBuilder =
    LocalMessagesCompanion Function({
      Value<String> id,
      Value<String> idempotencyKey,
      Value<String> roomId,
      Value<String?> peerUserId,
      Value<String> senderId,
      Value<String> senderName,
      Value<String?> senderAvatarUrl,
      Value<String> type,
      Value<String> content,
      Value<String?> imageUrl,
      Value<String?> replyToJson,
      Value<String> status,
      Value<bool> isEdited,
      Value<bool> isDeletedForAll,
      Value<int?> deliveredAt,
      Value<int?> seenAt,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$LocalMessagesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roomId => $composableBuilder(
    column: $table.roomId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderName => $composableBuilder(
    column: $table.senderName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderAvatarUrl => $composableBuilder(
    column: $table.senderAvatarUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imageUrl => $composableBuilder(
    column: $table.imageUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyToJson => $composableBuilder(
    column: $table.replyToJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isEdited => $composableBuilder(
    column: $table.isEdited,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDeletedForAll => $composableBuilder(
    column: $table.isDeletedForAll,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seenAt => $composableBuilder(
    column: $table.seenAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalMessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roomId => $composableBuilder(
    column: $table.roomId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderName => $composableBuilder(
    column: $table.senderName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderAvatarUrl => $composableBuilder(
    column: $table.senderAvatarUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imageUrl => $composableBuilder(
    column: $table.imageUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyToJson => $composableBuilder(
    column: $table.replyToJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isEdited => $composableBuilder(
    column: $table.isEdited,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDeletedForAll => $composableBuilder(
    column: $table.isDeletedForAll,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seenAt => $composableBuilder(
    column: $table.seenAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalMessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get roomId =>
      $composableBuilder(column: $table.roomId, builder: (column) => column);

  GeneratedColumn<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumn<String> get senderName => $composableBuilder(
    column: $table.senderName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get senderAvatarUrl => $composableBuilder(
    column: $table.senderAvatarUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get imageUrl =>
      $composableBuilder(column: $table.imageUrl, builder: (column) => column);

  GeneratedColumn<String> get replyToJson => $composableBuilder(
    column: $table.replyToJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<bool> get isEdited =>
      $composableBuilder(column: $table.isEdited, builder: (column) => column);

  GeneratedColumn<bool> get isDeletedForAll => $composableBuilder(
    column: $table.isDeletedForAll,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get seenAt =>
      $composableBuilder(column: $table.seenAt, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$LocalMessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalMessagesTable,
          LocalMessageRow,
          $$LocalMessagesTableFilterComposer,
          $$LocalMessagesTableOrderingComposer,
          $$LocalMessagesTableAnnotationComposer,
          $$LocalMessagesTableCreateCompanionBuilder,
          $$LocalMessagesTableUpdateCompanionBuilder,
          (
            LocalMessageRow,
            BaseReferences<_$AppDatabase, $LocalMessagesTable, LocalMessageRow>,
          ),
          LocalMessageRow,
          PrefetchHooks Function()
        > {
  $$LocalMessagesTableTableManager(_$AppDatabase db, $LocalMessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> idempotencyKey = const Value.absent(),
                Value<String> roomId = const Value.absent(),
                Value<String?> peerUserId = const Value.absent(),
                Value<String> senderId = const Value.absent(),
                Value<String> senderName = const Value.absent(),
                Value<String?> senderAvatarUrl = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String?> imageUrl = const Value.absent(),
                Value<String?> replyToJson = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<bool> isEdited = const Value.absent(),
                Value<bool> isDeletedForAll = const Value.absent(),
                Value<int?> deliveredAt = const Value.absent(),
                Value<int?> seenAt = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalMessagesCompanion(
                id: id,
                idempotencyKey: idempotencyKey,
                roomId: roomId,
                peerUserId: peerUserId,
                senderId: senderId,
                senderName: senderName,
                senderAvatarUrl: senderAvatarUrl,
                type: type,
                content: content,
                imageUrl: imageUrl,
                replyToJson: replyToJson,
                status: status,
                isEdited: isEdited,
                isDeletedForAll: isDeletedForAll,
                deliveredAt: deliveredAt,
                seenAt: seenAt,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String idempotencyKey,
                required String roomId,
                Value<String?> peerUserId = const Value.absent(),
                required String senderId,
                required String senderName,
                Value<String?> senderAvatarUrl = const Value.absent(),
                required String type,
                required String content,
                Value<String?> imageUrl = const Value.absent(),
                Value<String?> replyToJson = const Value.absent(),
                required String status,
                Value<bool> isEdited = const Value.absent(),
                Value<bool> isDeletedForAll = const Value.absent(),
                Value<int?> deliveredAt = const Value.absent(),
                Value<int?> seenAt = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalMessagesCompanion.insert(
                id: id,
                idempotencyKey: idempotencyKey,
                roomId: roomId,
                peerUserId: peerUserId,
                senderId: senderId,
                senderName: senderName,
                senderAvatarUrl: senderAvatarUrl,
                type: type,
                content: content,
                imageUrl: imageUrl,
                replyToJson: replyToJson,
                status: status,
                isEdited: isEdited,
                isDeletedForAll: isDeletedForAll,
                deliveredAt: deliveredAt,
                seenAt: seenAt,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalMessagesTable, LocalMessageRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $LocalMessagesTable,
                    LocalMessageRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalMessagesTable,
      LocalMessageRow,
      $$LocalMessagesTableFilterComposer,
      $$LocalMessagesTableOrderingComposer,
      $$LocalMessagesTableAnnotationComposer,
      $$LocalMessagesTableCreateCompanionBuilder,
      $$LocalMessagesTableUpdateCompanionBuilder,
      (
        LocalMessageRow,
        BaseReferences<_$AppDatabase, $LocalMessagesTable, LocalMessageRow>,
      ),
      LocalMessageRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SyncMetadataTableTableManager get syncMetadata =>
      $$SyncMetadataTableTableManager(_db, _db.syncMetadata);
  $$LocalRoomsTableTableManager get localRooms =>
      $$LocalRoomsTableTableManager(_db, _db.localRooms);
  $$LocalMessagesTableTableManager get localMessages =>
      $$LocalMessagesTableTableManager(_db, _db.localMessages);
}
