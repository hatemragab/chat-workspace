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
  static const VerificationMeta _roomPageCursorJsonMeta =
      const VerificationMeta('roomPageCursorJson');
  @override
  late final GeneratedColumn<String> roomPageCursorJson =
      GeneratedColumn<String>(
        'room_page_cursor_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _roomPageEpochMeta = const VerificationMeta(
    'roomPageEpoch',
  );
  @override
  late final GeneratedColumn<String> roomPageEpoch = GeneratedColumn<String>(
    'room_page_epoch',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _roomPageKnownMeta = const VerificationMeta(
    'roomPageKnown',
  );
  @override
  late final GeneratedColumn<bool> roomPageKnown = GeneratedColumn<bool>(
    'room_page_known',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("room_page_known" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _lastOutboundOrderMeta = const VerificationMeta(
    'lastOutboundOrder',
  );
  @override
  late final GeneratedColumn<int> lastOutboundOrder = GeneratedColumn<int>(
    'last_outbound_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    userId,
    localPts,
    localEpoch,
    roomPageCursorJson,
    roomPageEpoch,
    roomPageKnown,
    lastOutboundOrder,
  ];
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
    if (data.containsKey('room_page_cursor_json')) {
      context.handle(
        _roomPageCursorJsonMeta,
        roomPageCursorJson.isAcceptableOrUnknown(
          data['room_page_cursor_json']!,
          _roomPageCursorJsonMeta,
        ),
      );
    }
    if (data.containsKey('room_page_epoch')) {
      context.handle(
        _roomPageEpochMeta,
        roomPageEpoch.isAcceptableOrUnknown(
          data['room_page_epoch']!,
          _roomPageEpochMeta,
        ),
      );
    }
    if (data.containsKey('room_page_known')) {
      context.handle(
        _roomPageKnownMeta,
        roomPageKnown.isAcceptableOrUnknown(
          data['room_page_known']!,
          _roomPageKnownMeta,
        ),
      );
    }
    if (data.containsKey('last_outbound_order')) {
      context.handle(
        _lastOutboundOrderMeta,
        lastOutboundOrder.isAcceptableOrUnknown(
          data['last_outbound_order']!,
          _lastOutboundOrderMeta,
        ),
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
      roomPageCursorJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_page_cursor_json'],
      ),
      roomPageEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_page_epoch'],
      ),
      roomPageKnown: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}room_page_known'],
      )!,
      lastOutboundOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_outbound_order'],
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
  final String? roomPageCursorJson;
  final String? roomPageEpoch;
  final bool roomPageKnown;
  final int lastOutboundOrder;
  const SyncMetadataRow({
    required this.id,
    required this.userId,
    required this.localPts,
    required this.localEpoch,
    this.roomPageCursorJson,
    this.roomPageEpoch,
    required this.roomPageKnown,
    required this.lastOutboundOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['user_id'] = Variable<String>(userId);
    map['local_pts'] = Variable<int>(localPts);
    map['local_epoch'] = Variable<String>(localEpoch);
    if (!nullToAbsent || roomPageCursorJson != null) {
      map['room_page_cursor_json'] = Variable<String>(roomPageCursorJson);
    }
    if (!nullToAbsent || roomPageEpoch != null) {
      map['room_page_epoch'] = Variable<String>(roomPageEpoch);
    }
    map['room_page_known'] = Variable<bool>(roomPageKnown);
    map['last_outbound_order'] = Variable<int>(lastOutboundOrder);
    return map;
  }

  SyncMetadataCompanion toCompanion(bool nullToAbsent) {
    return SyncMetadataCompanion(
      id: Value(id),
      userId: Value(userId),
      localPts: Value(localPts),
      localEpoch: Value(localEpoch),
      roomPageCursorJson: roomPageCursorJson == null && nullToAbsent
          ? const Value.absent()
          : Value(roomPageCursorJson),
      roomPageEpoch: roomPageEpoch == null && nullToAbsent
          ? const Value.absent()
          : Value(roomPageEpoch),
      roomPageKnown: Value(roomPageKnown),
      lastOutboundOrder: Value(lastOutboundOrder),
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
      roomPageCursorJson: serializer.fromJson<String?>(
        json['roomPageCursorJson'],
      ),
      roomPageEpoch: serializer.fromJson<String?>(json['roomPageEpoch']),
      roomPageKnown: serializer.fromJson<bool>(json['roomPageKnown']),
      lastOutboundOrder: serializer.fromJson<int>(json['lastOutboundOrder']),
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
      'roomPageCursorJson': serializer.toJson<String?>(roomPageCursorJson),
      'roomPageEpoch': serializer.toJson<String?>(roomPageEpoch),
      'roomPageKnown': serializer.toJson<bool>(roomPageKnown),
      'lastOutboundOrder': serializer.toJson<int>(lastOutboundOrder),
    };
  }

  SyncMetadataRow copyWith({
    int? id,
    String? userId,
    int? localPts,
    String? localEpoch,
    Value<String?> roomPageCursorJson = const Value.absent(),
    Value<String?> roomPageEpoch = const Value.absent(),
    bool? roomPageKnown,
    int? lastOutboundOrder,
  }) => SyncMetadataRow(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    localPts: localPts ?? this.localPts,
    localEpoch: localEpoch ?? this.localEpoch,
    roomPageCursorJson: roomPageCursorJson.present
        ? roomPageCursorJson.value
        : this.roomPageCursorJson,
    roomPageEpoch: roomPageEpoch.present
        ? roomPageEpoch.value
        : this.roomPageEpoch,
    roomPageKnown: roomPageKnown ?? this.roomPageKnown,
    lastOutboundOrder: lastOutboundOrder ?? this.lastOutboundOrder,
  );
  SyncMetadataRow copyWithCompanion(SyncMetadataCompanion data) {
    return SyncMetadataRow(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      localPts: data.localPts.present ? data.localPts.value : this.localPts,
      localEpoch: data.localEpoch.present
          ? data.localEpoch.value
          : this.localEpoch,
      roomPageCursorJson: data.roomPageCursorJson.present
          ? data.roomPageCursorJson.value
          : this.roomPageCursorJson,
      roomPageEpoch: data.roomPageEpoch.present
          ? data.roomPageEpoch.value
          : this.roomPageEpoch,
      roomPageKnown: data.roomPageKnown.present
          ? data.roomPageKnown.value
          : this.roomPageKnown,
      lastOutboundOrder: data.lastOutboundOrder.present
          ? data.lastOutboundOrder.value
          : this.lastOutboundOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetadataRow(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('localPts: $localPts, ')
          ..write('localEpoch: $localEpoch, ')
          ..write('roomPageCursorJson: $roomPageCursorJson, ')
          ..write('roomPageEpoch: $roomPageEpoch, ')
          ..write('roomPageKnown: $roomPageKnown, ')
          ..write('lastOutboundOrder: $lastOutboundOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    userId,
    localPts,
    localEpoch,
    roomPageCursorJson,
    roomPageEpoch,
    roomPageKnown,
    lastOutboundOrder,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncMetadataRow &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.localPts == this.localPts &&
          other.localEpoch == this.localEpoch &&
          other.roomPageCursorJson == this.roomPageCursorJson &&
          other.roomPageEpoch == this.roomPageEpoch &&
          other.roomPageKnown == this.roomPageKnown &&
          other.lastOutboundOrder == this.lastOutboundOrder);
}

class SyncMetadataCompanion extends UpdateCompanion<SyncMetadataRow> {
  final Value<int> id;
  final Value<String> userId;
  final Value<int> localPts;
  final Value<String> localEpoch;
  final Value<String?> roomPageCursorJson;
  final Value<String?> roomPageEpoch;
  final Value<bool> roomPageKnown;
  final Value<int> lastOutboundOrder;
  const SyncMetadataCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.localPts = const Value.absent(),
    this.localEpoch = const Value.absent(),
    this.roomPageCursorJson = const Value.absent(),
    this.roomPageEpoch = const Value.absent(),
    this.roomPageKnown = const Value.absent(),
    this.lastOutboundOrder = const Value.absent(),
  });
  SyncMetadataCompanion.insert({
    this.id = const Value.absent(),
    required String userId,
    this.localPts = const Value.absent(),
    this.localEpoch = const Value.absent(),
    this.roomPageCursorJson = const Value.absent(),
    this.roomPageEpoch = const Value.absent(),
    this.roomPageKnown = const Value.absent(),
    this.lastOutboundOrder = const Value.absent(),
  }) : userId = Value(userId);
  static Insertable<SyncMetadataRow> custom({
    Expression<int>? id,
    Expression<String>? userId,
    Expression<int>? localPts,
    Expression<String>? localEpoch,
    Expression<String>? roomPageCursorJson,
    Expression<String>? roomPageEpoch,
    Expression<bool>? roomPageKnown,
    Expression<int>? lastOutboundOrder,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (localPts != null) 'local_pts': localPts,
      if (localEpoch != null) 'local_epoch': localEpoch,
      if (roomPageCursorJson != null)
        'room_page_cursor_json': roomPageCursorJson,
      if (roomPageEpoch != null) 'room_page_epoch': roomPageEpoch,
      if (roomPageKnown != null) 'room_page_known': roomPageKnown,
      if (lastOutboundOrder != null) 'last_outbound_order': lastOutboundOrder,
    });
  }

  SyncMetadataCompanion copyWith({
    Value<int>? id,
    Value<String>? userId,
    Value<int>? localPts,
    Value<String>? localEpoch,
    Value<String?>? roomPageCursorJson,
    Value<String?>? roomPageEpoch,
    Value<bool>? roomPageKnown,
    Value<int>? lastOutboundOrder,
  }) {
    return SyncMetadataCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      localPts: localPts ?? this.localPts,
      localEpoch: localEpoch ?? this.localEpoch,
      roomPageCursorJson: roomPageCursorJson ?? this.roomPageCursorJson,
      roomPageEpoch: roomPageEpoch ?? this.roomPageEpoch,
      roomPageKnown: roomPageKnown ?? this.roomPageKnown,
      lastOutboundOrder: lastOutboundOrder ?? this.lastOutboundOrder,
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
    if (roomPageCursorJson.present) {
      map['room_page_cursor_json'] = Variable<String>(roomPageCursorJson.value);
    }
    if (roomPageEpoch.present) {
      map['room_page_epoch'] = Variable<String>(roomPageEpoch.value);
    }
    if (roomPageKnown.present) {
      map['room_page_known'] = Variable<bool>(roomPageKnown.value);
    }
    if (lastOutboundOrder.present) {
      map['last_outbound_order'] = Variable<int>(lastOutboundOrder.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetadataCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('localPts: $localPts, ')
          ..write('localEpoch: $localEpoch, ')
          ..write('roomPageCursorJson: $roomPageCursorJson, ')
          ..write('roomPageEpoch: $roomPageEpoch, ')
          ..write('roomPageKnown: $roomPageKnown, ')
          ..write('lastOutboundOrder: $lastOutboundOrder')
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
  static const VerificationMeta _contentPtsMeta = const VerificationMeta(
    'contentPts',
  );
  @override
  late final GeneratedColumn<int> contentPts = GeneratedColumn<int>(
    'content_pts',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _receiptProtocolMeta = const VerificationMeta(
    'receiptProtocol',
  );
  @override
  late final GeneratedColumn<String> receiptProtocol = GeneratedColumn<String>(
    'receipt_protocol',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('legacy'),
  );
  static const VerificationMeta _peerDeliveredSeqMeta = const VerificationMeta(
    'peerDeliveredSeq',
  );
  @override
  late final GeneratedColumn<int> peerDeliveredSeq = GeneratedColumn<int>(
    'peer_delivered_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _peerSeenSeqMeta = const VerificationMeta(
    'peerSeenSeq',
  );
  @override
  late final GeneratedColumn<int> peerSeenSeq = GeneratedColumn<int>(
    'peer_seen_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ownDeliveredSeqMeta = const VerificationMeta(
    'ownDeliveredSeq',
  );
  @override
  late final GeneratedColumn<int> ownDeliveredSeq = GeneratedColumn<int>(
    'own_delivered_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ownSeenSeqMeta = const VerificationMeta(
    'ownSeenSeq',
  );
  @override
  late final GeneratedColumn<int> ownSeenSeq = GeneratedColumn<int>(
    'own_seen_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _receivedThroughSeqMeta =
      const VerificationMeta('receivedThroughSeq');
  @override
  late final GeneratedColumn<int> receivedThroughSeq = GeneratedColumn<int>(
    'received_through_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _verifiedHeadSeqMeta = const VerificationMeta(
    'verifiedHeadSeq',
  );
  @override
  late final GeneratedColumn<int> verifiedHeadSeq = GeneratedColumn<int>(
    'verified_head_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _receivedRangesJsonMeta =
      const VerificationMeta('receivedRangesJson');
  @override
  late final GeneratedColumn<String> receivedRangesJson =
      GeneratedColumn<String>(
        'received_ranges_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('[]'),
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
    contentPts,
    receiptProtocol,
    peerDeliveredSeq,
    peerSeenSeq,
    ownDeliveredSeq,
    ownSeenSeq,
    receivedThroughSeq,
    verifiedHeadSeq,
    receivedRangesJson,
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
    if (data.containsKey('content_pts')) {
      context.handle(
        _contentPtsMeta,
        contentPts.isAcceptableOrUnknown(data['content_pts']!, _contentPtsMeta),
      );
    }
    if (data.containsKey('receipt_protocol')) {
      context.handle(
        _receiptProtocolMeta,
        receiptProtocol.isAcceptableOrUnknown(
          data['receipt_protocol']!,
          _receiptProtocolMeta,
        ),
      );
    }
    if (data.containsKey('peer_delivered_seq')) {
      context.handle(
        _peerDeliveredSeqMeta,
        peerDeliveredSeq.isAcceptableOrUnknown(
          data['peer_delivered_seq']!,
          _peerDeliveredSeqMeta,
        ),
      );
    }
    if (data.containsKey('peer_seen_seq')) {
      context.handle(
        _peerSeenSeqMeta,
        peerSeenSeq.isAcceptableOrUnknown(
          data['peer_seen_seq']!,
          _peerSeenSeqMeta,
        ),
      );
    }
    if (data.containsKey('own_delivered_seq')) {
      context.handle(
        _ownDeliveredSeqMeta,
        ownDeliveredSeq.isAcceptableOrUnknown(
          data['own_delivered_seq']!,
          _ownDeliveredSeqMeta,
        ),
      );
    }
    if (data.containsKey('own_seen_seq')) {
      context.handle(
        _ownSeenSeqMeta,
        ownSeenSeq.isAcceptableOrUnknown(
          data['own_seen_seq']!,
          _ownSeenSeqMeta,
        ),
      );
    }
    if (data.containsKey('received_through_seq')) {
      context.handle(
        _receivedThroughSeqMeta,
        receivedThroughSeq.isAcceptableOrUnknown(
          data['received_through_seq']!,
          _receivedThroughSeqMeta,
        ),
      );
    }
    if (data.containsKey('verified_head_seq')) {
      context.handle(
        _verifiedHeadSeqMeta,
        verifiedHeadSeq.isAcceptableOrUnknown(
          data['verified_head_seq']!,
          _verifiedHeadSeqMeta,
        ),
      );
    }
    if (data.containsKey('received_ranges_json')) {
      context.handle(
        _receivedRangesJsonMeta,
        receivedRangesJson.isAcceptableOrUnknown(
          data['received_ranges_json']!,
          _receivedRangesJsonMeta,
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
      contentPts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}content_pts'],
      ),
      receiptProtocol: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receipt_protocol'],
      )!,
      peerDeliveredSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}peer_delivered_seq'],
      )!,
      peerSeenSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}peer_seen_seq'],
      )!,
      ownDeliveredSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}own_delivered_seq'],
      )!,
      ownSeenSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}own_seen_seq'],
      )!,
      receivedThroughSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}received_through_seq'],
      )!,
      verifiedHeadSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}verified_head_seq'],
      )!,
      receivedRangesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}received_ranges_json'],
      )!,
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
  final int? contentPts;
  final String receiptProtocol;
  final int peerDeliveredSeq;
  final int peerSeenSeq;
  final int ownDeliveredSeq;
  final int ownSeenSeq;
  final int receivedThroughSeq;
  final int verifiedHeadSeq;
  final String receivedRangesJson;
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
    this.contentPts,
    required this.receiptProtocol,
    required this.peerDeliveredSeq,
    required this.peerSeenSeq,
    required this.ownDeliveredSeq,
    required this.ownSeenSeq,
    required this.receivedThroughSeq,
    required this.verifiedHeadSeq,
    required this.receivedRangesJson,
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
    if (!nullToAbsent || contentPts != null) {
      map['content_pts'] = Variable<int>(contentPts);
    }
    map['receipt_protocol'] = Variable<String>(receiptProtocol);
    map['peer_delivered_seq'] = Variable<int>(peerDeliveredSeq);
    map['peer_seen_seq'] = Variable<int>(peerSeenSeq);
    map['own_delivered_seq'] = Variable<int>(ownDeliveredSeq);
    map['own_seen_seq'] = Variable<int>(ownSeenSeq);
    map['received_through_seq'] = Variable<int>(receivedThroughSeq);
    map['verified_head_seq'] = Variable<int>(verifiedHeadSeq);
    map['received_ranges_json'] = Variable<String>(receivedRangesJson);
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
      contentPts: contentPts == null && nullToAbsent
          ? const Value.absent()
          : Value(contentPts),
      receiptProtocol: Value(receiptProtocol),
      peerDeliveredSeq: Value(peerDeliveredSeq),
      peerSeenSeq: Value(peerSeenSeq),
      ownDeliveredSeq: Value(ownDeliveredSeq),
      ownSeenSeq: Value(ownSeenSeq),
      receivedThroughSeq: Value(receivedThroughSeq),
      verifiedHeadSeq: Value(verifiedHeadSeq),
      receivedRangesJson: Value(receivedRangesJson),
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
      contentPts: serializer.fromJson<int?>(json['contentPts']),
      receiptProtocol: serializer.fromJson<String>(json['receiptProtocol']),
      peerDeliveredSeq: serializer.fromJson<int>(json['peerDeliveredSeq']),
      peerSeenSeq: serializer.fromJson<int>(json['peerSeenSeq']),
      ownDeliveredSeq: serializer.fromJson<int>(json['ownDeliveredSeq']),
      ownSeenSeq: serializer.fromJson<int>(json['ownSeenSeq']),
      receivedThroughSeq: serializer.fromJson<int>(json['receivedThroughSeq']),
      verifiedHeadSeq: serializer.fromJson<int>(json['verifiedHeadSeq']),
      receivedRangesJson: serializer.fromJson<String>(
        json['receivedRangesJson'],
      ),
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
      'contentPts': serializer.toJson<int?>(contentPts),
      'receiptProtocol': serializer.toJson<String>(receiptProtocol),
      'peerDeliveredSeq': serializer.toJson<int>(peerDeliveredSeq),
      'peerSeenSeq': serializer.toJson<int>(peerSeenSeq),
      'ownDeliveredSeq': serializer.toJson<int>(ownDeliveredSeq),
      'ownSeenSeq': serializer.toJson<int>(ownSeenSeq),
      'receivedThroughSeq': serializer.toJson<int>(receivedThroughSeq),
      'verifiedHeadSeq': serializer.toJson<int>(verifiedHeadSeq),
      'receivedRangesJson': serializer.toJson<String>(receivedRangesJson),
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
    Value<int?> contentPts = const Value.absent(),
    String? receiptProtocol,
    int? peerDeliveredSeq,
    int? peerSeenSeq,
    int? ownDeliveredSeq,
    int? ownSeenSeq,
    int? receivedThroughSeq,
    int? verifiedHeadSeq,
    String? receivedRangesJson,
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
    contentPts: contentPts.present ? contentPts.value : this.contentPts,
    receiptProtocol: receiptProtocol ?? this.receiptProtocol,
    peerDeliveredSeq: peerDeliveredSeq ?? this.peerDeliveredSeq,
    peerSeenSeq: peerSeenSeq ?? this.peerSeenSeq,
    ownDeliveredSeq: ownDeliveredSeq ?? this.ownDeliveredSeq,
    ownSeenSeq: ownSeenSeq ?? this.ownSeenSeq,
    receivedThroughSeq: receivedThroughSeq ?? this.receivedThroughSeq,
    verifiedHeadSeq: verifiedHeadSeq ?? this.verifiedHeadSeq,
    receivedRangesJson: receivedRangesJson ?? this.receivedRangesJson,
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
      contentPts: data.contentPts.present
          ? data.contentPts.value
          : this.contentPts,
      receiptProtocol: data.receiptProtocol.present
          ? data.receiptProtocol.value
          : this.receiptProtocol,
      peerDeliveredSeq: data.peerDeliveredSeq.present
          ? data.peerDeliveredSeq.value
          : this.peerDeliveredSeq,
      peerSeenSeq: data.peerSeenSeq.present
          ? data.peerSeenSeq.value
          : this.peerSeenSeq,
      ownDeliveredSeq: data.ownDeliveredSeq.present
          ? data.ownDeliveredSeq.value
          : this.ownDeliveredSeq,
      ownSeenSeq: data.ownSeenSeq.present
          ? data.ownSeenSeq.value
          : this.ownSeenSeq,
      receivedThroughSeq: data.receivedThroughSeq.present
          ? data.receivedThroughSeq.value
          : this.receivedThroughSeq,
      verifiedHeadSeq: data.verifiedHeadSeq.present
          ? data.verifiedHeadSeq.value
          : this.verifiedHeadSeq,
      receivedRangesJson: data.receivedRangesJson.present
          ? data.receivedRangesJson.value
          : this.receivedRangesJson,
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
          ..write('lastMessageJson: $lastMessageJson, ')
          ..write('contentPts: $contentPts, ')
          ..write('receiptProtocol: $receiptProtocol, ')
          ..write('peerDeliveredSeq: $peerDeliveredSeq, ')
          ..write('peerSeenSeq: $peerSeenSeq, ')
          ..write('ownDeliveredSeq: $ownDeliveredSeq, ')
          ..write('ownSeenSeq: $ownSeenSeq, ')
          ..write('receivedThroughSeq: $receivedThroughSeq, ')
          ..write('verifiedHeadSeq: $verifiedHeadSeq, ')
          ..write('receivedRangesJson: $receivedRangesJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
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
    contentPts,
    receiptProtocol,
    peerDeliveredSeq,
    peerSeenSeq,
    ownDeliveredSeq,
    ownSeenSeq,
    receivedThroughSeq,
    verifiedHeadSeq,
    receivedRangesJson,
  ]);
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
          other.lastMessageJson == this.lastMessageJson &&
          other.contentPts == this.contentPts &&
          other.receiptProtocol == this.receiptProtocol &&
          other.peerDeliveredSeq == this.peerDeliveredSeq &&
          other.peerSeenSeq == this.peerSeenSeq &&
          other.ownDeliveredSeq == this.ownDeliveredSeq &&
          other.ownSeenSeq == this.ownSeenSeq &&
          other.receivedThroughSeq == this.receivedThroughSeq &&
          other.verifiedHeadSeq == this.verifiedHeadSeq &&
          other.receivedRangesJson == this.receivedRangesJson);
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
  final Value<int?> contentPts;
  final Value<String> receiptProtocol;
  final Value<int> peerDeliveredSeq;
  final Value<int> peerSeenSeq;
  final Value<int> ownDeliveredSeq;
  final Value<int> ownSeenSeq;
  final Value<int> receivedThroughSeq;
  final Value<int> verifiedHeadSeq;
  final Value<String> receivedRangesJson;
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
    this.contentPts = const Value.absent(),
    this.receiptProtocol = const Value.absent(),
    this.peerDeliveredSeq = const Value.absent(),
    this.peerSeenSeq = const Value.absent(),
    this.ownDeliveredSeq = const Value.absent(),
    this.ownSeenSeq = const Value.absent(),
    this.receivedThroughSeq = const Value.absent(),
    this.verifiedHeadSeq = const Value.absent(),
    this.receivedRangesJson = const Value.absent(),
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
    this.contentPts = const Value.absent(),
    this.receiptProtocol = const Value.absent(),
    this.peerDeliveredSeq = const Value.absent(),
    this.peerSeenSeq = const Value.absent(),
    this.ownDeliveredSeq = const Value.absent(),
    this.ownSeenSeq = const Value.absent(),
    this.receivedThroughSeq = const Value.absent(),
    this.verifiedHeadSeq = const Value.absent(),
    this.receivedRangesJson = const Value.absent(),
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
    Expression<int>? contentPts,
    Expression<String>? receiptProtocol,
    Expression<int>? peerDeliveredSeq,
    Expression<int>? peerSeenSeq,
    Expression<int>? ownDeliveredSeq,
    Expression<int>? ownSeenSeq,
    Expression<int>? receivedThroughSeq,
    Expression<int>? verifiedHeadSeq,
    Expression<String>? receivedRangesJson,
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
      if (contentPts != null) 'content_pts': contentPts,
      if (receiptProtocol != null) 'receipt_protocol': receiptProtocol,
      if (peerDeliveredSeq != null) 'peer_delivered_seq': peerDeliveredSeq,
      if (peerSeenSeq != null) 'peer_seen_seq': peerSeenSeq,
      if (ownDeliveredSeq != null) 'own_delivered_seq': ownDeliveredSeq,
      if (ownSeenSeq != null) 'own_seen_seq': ownSeenSeq,
      if (receivedThroughSeq != null)
        'received_through_seq': receivedThroughSeq,
      if (verifiedHeadSeq != null) 'verified_head_seq': verifiedHeadSeq,
      if (receivedRangesJson != null)
        'received_ranges_json': receivedRangesJson,
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
    Value<int?>? contentPts,
    Value<String>? receiptProtocol,
    Value<int>? peerDeliveredSeq,
    Value<int>? peerSeenSeq,
    Value<int>? ownDeliveredSeq,
    Value<int>? ownSeenSeq,
    Value<int>? receivedThroughSeq,
    Value<int>? verifiedHeadSeq,
    Value<String>? receivedRangesJson,
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
      contentPts: contentPts ?? this.contentPts,
      receiptProtocol: receiptProtocol ?? this.receiptProtocol,
      peerDeliveredSeq: peerDeliveredSeq ?? this.peerDeliveredSeq,
      peerSeenSeq: peerSeenSeq ?? this.peerSeenSeq,
      ownDeliveredSeq: ownDeliveredSeq ?? this.ownDeliveredSeq,
      ownSeenSeq: ownSeenSeq ?? this.ownSeenSeq,
      receivedThroughSeq: receivedThroughSeq ?? this.receivedThroughSeq,
      verifiedHeadSeq: verifiedHeadSeq ?? this.verifiedHeadSeq,
      receivedRangesJson: receivedRangesJson ?? this.receivedRangesJson,
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
    if (contentPts.present) {
      map['content_pts'] = Variable<int>(contentPts.value);
    }
    if (receiptProtocol.present) {
      map['receipt_protocol'] = Variable<String>(receiptProtocol.value);
    }
    if (peerDeliveredSeq.present) {
      map['peer_delivered_seq'] = Variable<int>(peerDeliveredSeq.value);
    }
    if (peerSeenSeq.present) {
      map['peer_seen_seq'] = Variable<int>(peerSeenSeq.value);
    }
    if (ownDeliveredSeq.present) {
      map['own_delivered_seq'] = Variable<int>(ownDeliveredSeq.value);
    }
    if (ownSeenSeq.present) {
      map['own_seen_seq'] = Variable<int>(ownSeenSeq.value);
    }
    if (receivedThroughSeq.present) {
      map['received_through_seq'] = Variable<int>(receivedThroughSeq.value);
    }
    if (verifiedHeadSeq.present) {
      map['verified_head_seq'] = Variable<int>(verifiedHeadSeq.value);
    }
    if (receivedRangesJson.present) {
      map['received_ranges_json'] = Variable<String>(receivedRangesJson.value);
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
          ..write('contentPts: $contentPts, ')
          ..write('receiptProtocol: $receiptProtocol, ')
          ..write('peerDeliveredSeq: $peerDeliveredSeq, ')
          ..write('peerSeenSeq: $peerSeenSeq, ')
          ..write('ownDeliveredSeq: $ownDeliveredSeq, ')
          ..write('ownSeenSeq: $ownSeenSeq, ')
          ..write('receivedThroughSeq: $receivedThroughSeq, ')
          ..write('verifiedHeadSeq: $verifiedHeadSeq, ')
          ..write('receivedRangesJson: $receivedRangesJson, ')
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
  static const VerificationMeta _replyTargetIdMeta = const VerificationMeta(
    'replyTargetId',
  );
  @override
  late final GeneratedColumn<String> replyTargetId = GeneratedColumn<String>(
    'reply_target_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _uploadBytesMeta = const VerificationMeta(
    'uploadBytes',
  );
  @override
  late final GeneratedColumn<Uint8List> uploadBytes =
      GeneratedColumn<Uint8List>(
        'upload_bytes',
        aliasedName,
        true,
        type: DriftSqlType.blob,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _uploadFilenameMeta = const VerificationMeta(
    'uploadFilename',
  );
  @override
  late final GeneratedColumn<String> uploadFilename = GeneratedColumn<String>(
    'upload_filename',
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
  static const VerificationMeta _messageSeqMeta = const VerificationMeta(
    'messageSeq',
  );
  @override
  late final GeneratedColumn<int> messageSeq = GeneratedColumn<int>(
    'message_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deliveredByCursorMeta = const VerificationMeta(
    'deliveredByCursor',
  );
  @override
  late final GeneratedColumn<bool> deliveredByCursor = GeneratedColumn<bool>(
    'delivered_by_cursor',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("delivered_by_cursor" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _seenByCursorMeta = const VerificationMeta(
    'seenByCursor',
  );
  @override
  late final GeneratedColumn<bool> seenByCursor = GeneratedColumn<bool>(
    'seen_by_cursor',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("seen_by_cursor" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _enqueueOrderMeta = const VerificationMeta(
    'enqueueOrder',
  );
  @override
  late final GeneratedColumn<int> enqueueOrder = GeneratedColumn<int>(
    'enqueue_order',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _retryCountMeta = const VerificationMeta(
    'retryCount',
  );
  @override
  late final GeneratedColumn<int> retryCount = GeneratedColumn<int>(
    'retry_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<int> nextAttemptAt = GeneratedColumn<int>(
    'next_attempt_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastErrorCodeMeta = const VerificationMeta(
    'lastErrorCode',
  );
  @override
  late final GeneratedColumn<String> lastErrorCode = GeneratedColumn<String>(
    'last_error_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastErrorTextMeta = const VerificationMeta(
    'lastErrorText',
  );
  @override
  late final GeneratedColumn<String> lastErrorText = GeneratedColumn<String>(
    'last_error_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _outcomeUnknownMeta = const VerificationMeta(
    'outcomeUnknown',
  );
  @override
  late final GeneratedColumn<bool> outcomeUnknown = GeneratedColumn<bool>(
    'outcome_unknown',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("outcome_unknown" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _outboxPausedMeta = const VerificationMeta(
    'outboxPaused',
  );
  @override
  late final GeneratedColumn<bool> outboxPaused = GeneratedColumn<bool>(
    'outbox_paused',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("outbox_paused" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
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
    replyTargetId,
    uploadBytes,
    uploadFilename,
    status,
    isEdited,
    isDeletedForAll,
    deliveredAt,
    seenAt,
    createdAt,
    messageSeq,
    deliveredByCursor,
    seenByCursor,
    enqueueOrder,
    retryCount,
    nextAttemptAt,
    lastErrorCode,
    lastErrorText,
    outcomeUnknown,
    outboxPaused,
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
    if (data.containsKey('reply_target_id')) {
      context.handle(
        _replyTargetIdMeta,
        replyTargetId.isAcceptableOrUnknown(
          data['reply_target_id']!,
          _replyTargetIdMeta,
        ),
      );
    }
    if (data.containsKey('upload_bytes')) {
      context.handle(
        _uploadBytesMeta,
        uploadBytes.isAcceptableOrUnknown(
          data['upload_bytes']!,
          _uploadBytesMeta,
        ),
      );
    }
    if (data.containsKey('upload_filename')) {
      context.handle(
        _uploadFilenameMeta,
        uploadFilename.isAcceptableOrUnknown(
          data['upload_filename']!,
          _uploadFilenameMeta,
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
    if (data.containsKey('message_seq')) {
      context.handle(
        _messageSeqMeta,
        messageSeq.isAcceptableOrUnknown(data['message_seq']!, _messageSeqMeta),
      );
    }
    if (data.containsKey('delivered_by_cursor')) {
      context.handle(
        _deliveredByCursorMeta,
        deliveredByCursor.isAcceptableOrUnknown(
          data['delivered_by_cursor']!,
          _deliveredByCursorMeta,
        ),
      );
    }
    if (data.containsKey('seen_by_cursor')) {
      context.handle(
        _seenByCursorMeta,
        seenByCursor.isAcceptableOrUnknown(
          data['seen_by_cursor']!,
          _seenByCursorMeta,
        ),
      );
    }
    if (data.containsKey('enqueue_order')) {
      context.handle(
        _enqueueOrderMeta,
        enqueueOrder.isAcceptableOrUnknown(
          data['enqueue_order']!,
          _enqueueOrderMeta,
        ),
      );
    }
    if (data.containsKey('retry_count')) {
      context.handle(
        _retryCountMeta,
        retryCount.isAcceptableOrUnknown(data['retry_count']!, _retryCountMeta),
      );
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    }
    if (data.containsKey('last_error_code')) {
      context.handle(
        _lastErrorCodeMeta,
        lastErrorCode.isAcceptableOrUnknown(
          data['last_error_code']!,
          _lastErrorCodeMeta,
        ),
      );
    }
    if (data.containsKey('last_error_text')) {
      context.handle(
        _lastErrorTextMeta,
        lastErrorText.isAcceptableOrUnknown(
          data['last_error_text']!,
          _lastErrorTextMeta,
        ),
      );
    }
    if (data.containsKey('outcome_unknown')) {
      context.handle(
        _outcomeUnknownMeta,
        outcomeUnknown.isAcceptableOrUnknown(
          data['outcome_unknown']!,
          _outcomeUnknownMeta,
        ),
      );
    }
    if (data.containsKey('outbox_paused')) {
      context.handle(
        _outboxPausedMeta,
        outboxPaused.isAcceptableOrUnknown(
          data['outbox_paused']!,
          _outboxPausedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {senderId, idempotencyKey},
  ];
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
      replyTargetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_target_id'],
      ),
      uploadBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}upload_bytes'],
      ),
      uploadFilename: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}upload_filename'],
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
      messageSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_seq'],
      ),
      deliveredByCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}delivered_by_cursor'],
      )!,
      seenByCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}seen_by_cursor'],
      )!,
      enqueueOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}enqueue_order'],
      ),
      retryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retry_count'],
      )!,
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_attempt_at'],
      ),
      lastErrorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error_code'],
      ),
      lastErrorText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error_text'],
      ),
      outcomeUnknown: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}outcome_unknown'],
      )!,
      outboxPaused: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}outbox_paused'],
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
  final String? replyTargetId;
  final Uint8List? uploadBytes;
  final String? uploadFilename;
  final String status;
  final bool isEdited;
  final bool isDeletedForAll;
  final int? deliveredAt;
  final int? seenAt;
  final int createdAt;
  final int? messageSeq;
  final bool deliveredByCursor;
  final bool seenByCursor;
  final int? enqueueOrder;
  final int retryCount;
  final int? nextAttemptAt;
  final String? lastErrorCode;
  final String? lastErrorText;
  final bool outcomeUnknown;
  final bool outboxPaused;
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
    this.replyTargetId,
    this.uploadBytes,
    this.uploadFilename,
    required this.status,
    required this.isEdited,
    required this.isDeletedForAll,
    this.deliveredAt,
    this.seenAt,
    required this.createdAt,
    this.messageSeq,
    required this.deliveredByCursor,
    required this.seenByCursor,
    this.enqueueOrder,
    required this.retryCount,
    this.nextAttemptAt,
    this.lastErrorCode,
    this.lastErrorText,
    required this.outcomeUnknown,
    required this.outboxPaused,
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
    if (!nullToAbsent || replyTargetId != null) {
      map['reply_target_id'] = Variable<String>(replyTargetId);
    }
    if (!nullToAbsent || uploadBytes != null) {
      map['upload_bytes'] = Variable<Uint8List>(uploadBytes);
    }
    if (!nullToAbsent || uploadFilename != null) {
      map['upload_filename'] = Variable<String>(uploadFilename);
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
    if (!nullToAbsent || messageSeq != null) {
      map['message_seq'] = Variable<int>(messageSeq);
    }
    map['delivered_by_cursor'] = Variable<bool>(deliveredByCursor);
    map['seen_by_cursor'] = Variable<bool>(seenByCursor);
    if (!nullToAbsent || enqueueOrder != null) {
      map['enqueue_order'] = Variable<int>(enqueueOrder);
    }
    map['retry_count'] = Variable<int>(retryCount);
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt);
    }
    if (!nullToAbsent || lastErrorCode != null) {
      map['last_error_code'] = Variable<String>(lastErrorCode);
    }
    if (!nullToAbsent || lastErrorText != null) {
      map['last_error_text'] = Variable<String>(lastErrorText);
    }
    map['outcome_unknown'] = Variable<bool>(outcomeUnknown);
    map['outbox_paused'] = Variable<bool>(outboxPaused);
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
      replyTargetId: replyTargetId == null && nullToAbsent
          ? const Value.absent()
          : Value(replyTargetId),
      uploadBytes: uploadBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(uploadBytes),
      uploadFilename: uploadFilename == null && nullToAbsent
          ? const Value.absent()
          : Value(uploadFilename),
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
      messageSeq: messageSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(messageSeq),
      deliveredByCursor: Value(deliveredByCursor),
      seenByCursor: Value(seenByCursor),
      enqueueOrder: enqueueOrder == null && nullToAbsent
          ? const Value.absent()
          : Value(enqueueOrder),
      retryCount: Value(retryCount),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      lastErrorCode: lastErrorCode == null && nullToAbsent
          ? const Value.absent()
          : Value(lastErrorCode),
      lastErrorText: lastErrorText == null && nullToAbsent
          ? const Value.absent()
          : Value(lastErrorText),
      outcomeUnknown: Value(outcomeUnknown),
      outboxPaused: Value(outboxPaused),
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
      replyTargetId: serializer.fromJson<String?>(json['replyTargetId']),
      uploadBytes: serializer.fromJson<Uint8List?>(json['uploadBytes']),
      uploadFilename: serializer.fromJson<String?>(json['uploadFilename']),
      status: serializer.fromJson<String>(json['status']),
      isEdited: serializer.fromJson<bool>(json['isEdited']),
      isDeletedForAll: serializer.fromJson<bool>(json['isDeletedForAll']),
      deliveredAt: serializer.fromJson<int?>(json['deliveredAt']),
      seenAt: serializer.fromJson<int?>(json['seenAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      messageSeq: serializer.fromJson<int?>(json['messageSeq']),
      deliveredByCursor: serializer.fromJson<bool>(json['deliveredByCursor']),
      seenByCursor: serializer.fromJson<bool>(json['seenByCursor']),
      enqueueOrder: serializer.fromJson<int?>(json['enqueueOrder']),
      retryCount: serializer.fromJson<int>(json['retryCount']),
      nextAttemptAt: serializer.fromJson<int?>(json['nextAttemptAt']),
      lastErrorCode: serializer.fromJson<String?>(json['lastErrorCode']),
      lastErrorText: serializer.fromJson<String?>(json['lastErrorText']),
      outcomeUnknown: serializer.fromJson<bool>(json['outcomeUnknown']),
      outboxPaused: serializer.fromJson<bool>(json['outboxPaused']),
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
      'replyTargetId': serializer.toJson<String?>(replyTargetId),
      'uploadBytes': serializer.toJson<Uint8List?>(uploadBytes),
      'uploadFilename': serializer.toJson<String?>(uploadFilename),
      'status': serializer.toJson<String>(status),
      'isEdited': serializer.toJson<bool>(isEdited),
      'isDeletedForAll': serializer.toJson<bool>(isDeletedForAll),
      'deliveredAt': serializer.toJson<int?>(deliveredAt),
      'seenAt': serializer.toJson<int?>(seenAt),
      'createdAt': serializer.toJson<int>(createdAt),
      'messageSeq': serializer.toJson<int?>(messageSeq),
      'deliveredByCursor': serializer.toJson<bool>(deliveredByCursor),
      'seenByCursor': serializer.toJson<bool>(seenByCursor),
      'enqueueOrder': serializer.toJson<int?>(enqueueOrder),
      'retryCount': serializer.toJson<int>(retryCount),
      'nextAttemptAt': serializer.toJson<int?>(nextAttemptAt),
      'lastErrorCode': serializer.toJson<String?>(lastErrorCode),
      'lastErrorText': serializer.toJson<String?>(lastErrorText),
      'outcomeUnknown': serializer.toJson<bool>(outcomeUnknown),
      'outboxPaused': serializer.toJson<bool>(outboxPaused),
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
    Value<String?> replyTargetId = const Value.absent(),
    Value<Uint8List?> uploadBytes = const Value.absent(),
    Value<String?> uploadFilename = const Value.absent(),
    String? status,
    bool? isEdited,
    bool? isDeletedForAll,
    Value<int?> deliveredAt = const Value.absent(),
    Value<int?> seenAt = const Value.absent(),
    int? createdAt,
    Value<int?> messageSeq = const Value.absent(),
    bool? deliveredByCursor,
    bool? seenByCursor,
    Value<int?> enqueueOrder = const Value.absent(),
    int? retryCount,
    Value<int?> nextAttemptAt = const Value.absent(),
    Value<String?> lastErrorCode = const Value.absent(),
    Value<String?> lastErrorText = const Value.absent(),
    bool? outcomeUnknown,
    bool? outboxPaused,
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
    replyTargetId: replyTargetId.present
        ? replyTargetId.value
        : this.replyTargetId,
    uploadBytes: uploadBytes.present ? uploadBytes.value : this.uploadBytes,
    uploadFilename: uploadFilename.present
        ? uploadFilename.value
        : this.uploadFilename,
    status: status ?? this.status,
    isEdited: isEdited ?? this.isEdited,
    isDeletedForAll: isDeletedForAll ?? this.isDeletedForAll,
    deliveredAt: deliveredAt.present ? deliveredAt.value : this.deliveredAt,
    seenAt: seenAt.present ? seenAt.value : this.seenAt,
    createdAt: createdAt ?? this.createdAt,
    messageSeq: messageSeq.present ? messageSeq.value : this.messageSeq,
    deliveredByCursor: deliveredByCursor ?? this.deliveredByCursor,
    seenByCursor: seenByCursor ?? this.seenByCursor,
    enqueueOrder: enqueueOrder.present ? enqueueOrder.value : this.enqueueOrder,
    retryCount: retryCount ?? this.retryCount,
    nextAttemptAt: nextAttemptAt.present
        ? nextAttemptAt.value
        : this.nextAttemptAt,
    lastErrorCode: lastErrorCode.present
        ? lastErrorCode.value
        : this.lastErrorCode,
    lastErrorText: lastErrorText.present
        ? lastErrorText.value
        : this.lastErrorText,
    outcomeUnknown: outcomeUnknown ?? this.outcomeUnknown,
    outboxPaused: outboxPaused ?? this.outboxPaused,
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
      replyTargetId: data.replyTargetId.present
          ? data.replyTargetId.value
          : this.replyTargetId,
      uploadBytes: data.uploadBytes.present
          ? data.uploadBytes.value
          : this.uploadBytes,
      uploadFilename: data.uploadFilename.present
          ? data.uploadFilename.value
          : this.uploadFilename,
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
      messageSeq: data.messageSeq.present
          ? data.messageSeq.value
          : this.messageSeq,
      deliveredByCursor: data.deliveredByCursor.present
          ? data.deliveredByCursor.value
          : this.deliveredByCursor,
      seenByCursor: data.seenByCursor.present
          ? data.seenByCursor.value
          : this.seenByCursor,
      enqueueOrder: data.enqueueOrder.present
          ? data.enqueueOrder.value
          : this.enqueueOrder,
      retryCount: data.retryCount.present
          ? data.retryCount.value
          : this.retryCount,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      lastErrorCode: data.lastErrorCode.present
          ? data.lastErrorCode.value
          : this.lastErrorCode,
      lastErrorText: data.lastErrorText.present
          ? data.lastErrorText.value
          : this.lastErrorText,
      outcomeUnknown: data.outcomeUnknown.present
          ? data.outcomeUnknown.value
          : this.outcomeUnknown,
      outboxPaused: data.outboxPaused.present
          ? data.outboxPaused.value
          : this.outboxPaused,
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
          ..write('replyTargetId: $replyTargetId, ')
          ..write('uploadBytes: $uploadBytes, ')
          ..write('uploadFilename: $uploadFilename, ')
          ..write('status: $status, ')
          ..write('isEdited: $isEdited, ')
          ..write('isDeletedForAll: $isDeletedForAll, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('seenAt: $seenAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('messageSeq: $messageSeq, ')
          ..write('deliveredByCursor: $deliveredByCursor, ')
          ..write('seenByCursor: $seenByCursor, ')
          ..write('enqueueOrder: $enqueueOrder, ')
          ..write('retryCount: $retryCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastErrorCode: $lastErrorCode, ')
          ..write('lastErrorText: $lastErrorText, ')
          ..write('outcomeUnknown: $outcomeUnknown, ')
          ..write('outboxPaused: $outboxPaused')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
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
    replyTargetId,
    $driftBlobEquality.hash(uploadBytes),
    uploadFilename,
    status,
    isEdited,
    isDeletedForAll,
    deliveredAt,
    seenAt,
    createdAt,
    messageSeq,
    deliveredByCursor,
    seenByCursor,
    enqueueOrder,
    retryCount,
    nextAttemptAt,
    lastErrorCode,
    lastErrorText,
    outcomeUnknown,
    outboxPaused,
  ]);
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
          other.replyTargetId == this.replyTargetId &&
          $driftBlobEquality.equals(other.uploadBytes, this.uploadBytes) &&
          other.uploadFilename == this.uploadFilename &&
          other.status == this.status &&
          other.isEdited == this.isEdited &&
          other.isDeletedForAll == this.isDeletedForAll &&
          other.deliveredAt == this.deliveredAt &&
          other.seenAt == this.seenAt &&
          other.createdAt == this.createdAt &&
          other.messageSeq == this.messageSeq &&
          other.deliveredByCursor == this.deliveredByCursor &&
          other.seenByCursor == this.seenByCursor &&
          other.enqueueOrder == this.enqueueOrder &&
          other.retryCount == this.retryCount &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.lastErrorCode == this.lastErrorCode &&
          other.lastErrorText == this.lastErrorText &&
          other.outcomeUnknown == this.outcomeUnknown &&
          other.outboxPaused == this.outboxPaused);
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
  final Value<String?> replyTargetId;
  final Value<Uint8List?> uploadBytes;
  final Value<String?> uploadFilename;
  final Value<String> status;
  final Value<bool> isEdited;
  final Value<bool> isDeletedForAll;
  final Value<int?> deliveredAt;
  final Value<int?> seenAt;
  final Value<int> createdAt;
  final Value<int?> messageSeq;
  final Value<bool> deliveredByCursor;
  final Value<bool> seenByCursor;
  final Value<int?> enqueueOrder;
  final Value<int> retryCount;
  final Value<int?> nextAttemptAt;
  final Value<String?> lastErrorCode;
  final Value<String?> lastErrorText;
  final Value<bool> outcomeUnknown;
  final Value<bool> outboxPaused;
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
    this.replyTargetId = const Value.absent(),
    this.uploadBytes = const Value.absent(),
    this.uploadFilename = const Value.absent(),
    this.status = const Value.absent(),
    this.isEdited = const Value.absent(),
    this.isDeletedForAll = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.seenAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.messageSeq = const Value.absent(),
    this.deliveredByCursor = const Value.absent(),
    this.seenByCursor = const Value.absent(),
    this.enqueueOrder = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
    this.lastErrorText = const Value.absent(),
    this.outcomeUnknown = const Value.absent(),
    this.outboxPaused = const Value.absent(),
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
    this.replyTargetId = const Value.absent(),
    this.uploadBytes = const Value.absent(),
    this.uploadFilename = const Value.absent(),
    required String status,
    this.isEdited = const Value.absent(),
    this.isDeletedForAll = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.seenAt = const Value.absent(),
    required int createdAt,
    this.messageSeq = const Value.absent(),
    this.deliveredByCursor = const Value.absent(),
    this.seenByCursor = const Value.absent(),
    this.enqueueOrder = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
    this.lastErrorText = const Value.absent(),
    this.outcomeUnknown = const Value.absent(),
    this.outboxPaused = const Value.absent(),
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
    Expression<String>? replyTargetId,
    Expression<Uint8List>? uploadBytes,
    Expression<String>? uploadFilename,
    Expression<String>? status,
    Expression<bool>? isEdited,
    Expression<bool>? isDeletedForAll,
    Expression<int>? deliveredAt,
    Expression<int>? seenAt,
    Expression<int>? createdAt,
    Expression<int>? messageSeq,
    Expression<bool>? deliveredByCursor,
    Expression<bool>? seenByCursor,
    Expression<int>? enqueueOrder,
    Expression<int>? retryCount,
    Expression<int>? nextAttemptAt,
    Expression<String>? lastErrorCode,
    Expression<String>? lastErrorText,
    Expression<bool>? outcomeUnknown,
    Expression<bool>? outboxPaused,
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
      if (replyTargetId != null) 'reply_target_id': replyTargetId,
      if (uploadBytes != null) 'upload_bytes': uploadBytes,
      if (uploadFilename != null) 'upload_filename': uploadFilename,
      if (status != null) 'status': status,
      if (isEdited != null) 'is_edited': isEdited,
      if (isDeletedForAll != null) 'is_deleted_for_all': isDeletedForAll,
      if (deliveredAt != null) 'delivered_at': deliveredAt,
      if (seenAt != null) 'seen_at': seenAt,
      if (createdAt != null) 'created_at': createdAt,
      if (messageSeq != null) 'message_seq': messageSeq,
      if (deliveredByCursor != null) 'delivered_by_cursor': deliveredByCursor,
      if (seenByCursor != null) 'seen_by_cursor': seenByCursor,
      if (enqueueOrder != null) 'enqueue_order': enqueueOrder,
      if (retryCount != null) 'retry_count': retryCount,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (lastErrorCode != null) 'last_error_code': lastErrorCode,
      if (lastErrorText != null) 'last_error_text': lastErrorText,
      if (outcomeUnknown != null) 'outcome_unknown': outcomeUnknown,
      if (outboxPaused != null) 'outbox_paused': outboxPaused,
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
    Value<String?>? replyTargetId,
    Value<Uint8List?>? uploadBytes,
    Value<String?>? uploadFilename,
    Value<String>? status,
    Value<bool>? isEdited,
    Value<bool>? isDeletedForAll,
    Value<int?>? deliveredAt,
    Value<int?>? seenAt,
    Value<int>? createdAt,
    Value<int?>? messageSeq,
    Value<bool>? deliveredByCursor,
    Value<bool>? seenByCursor,
    Value<int?>? enqueueOrder,
    Value<int>? retryCount,
    Value<int?>? nextAttemptAt,
    Value<String?>? lastErrorCode,
    Value<String?>? lastErrorText,
    Value<bool>? outcomeUnknown,
    Value<bool>? outboxPaused,
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
      replyTargetId: replyTargetId ?? this.replyTargetId,
      uploadBytes: uploadBytes ?? this.uploadBytes,
      uploadFilename: uploadFilename ?? this.uploadFilename,
      status: status ?? this.status,
      isEdited: isEdited ?? this.isEdited,
      isDeletedForAll: isDeletedForAll ?? this.isDeletedForAll,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      seenAt: seenAt ?? this.seenAt,
      createdAt: createdAt ?? this.createdAt,
      messageSeq: messageSeq ?? this.messageSeq,
      deliveredByCursor: deliveredByCursor ?? this.deliveredByCursor,
      seenByCursor: seenByCursor ?? this.seenByCursor,
      enqueueOrder: enqueueOrder ?? this.enqueueOrder,
      retryCount: retryCount ?? this.retryCount,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      lastErrorText: lastErrorText ?? this.lastErrorText,
      outcomeUnknown: outcomeUnknown ?? this.outcomeUnknown,
      outboxPaused: outboxPaused ?? this.outboxPaused,
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
    if (replyTargetId.present) {
      map['reply_target_id'] = Variable<String>(replyTargetId.value);
    }
    if (uploadBytes.present) {
      map['upload_bytes'] = Variable<Uint8List>(uploadBytes.value);
    }
    if (uploadFilename.present) {
      map['upload_filename'] = Variable<String>(uploadFilename.value);
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
    if (messageSeq.present) {
      map['message_seq'] = Variable<int>(messageSeq.value);
    }
    if (deliveredByCursor.present) {
      map['delivered_by_cursor'] = Variable<bool>(deliveredByCursor.value);
    }
    if (seenByCursor.present) {
      map['seen_by_cursor'] = Variable<bool>(seenByCursor.value);
    }
    if (enqueueOrder.present) {
      map['enqueue_order'] = Variable<int>(enqueueOrder.value);
    }
    if (retryCount.present) {
      map['retry_count'] = Variable<int>(retryCount.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt.value);
    }
    if (lastErrorCode.present) {
      map['last_error_code'] = Variable<String>(lastErrorCode.value);
    }
    if (lastErrorText.present) {
      map['last_error_text'] = Variable<String>(lastErrorText.value);
    }
    if (outcomeUnknown.present) {
      map['outcome_unknown'] = Variable<bool>(outcomeUnknown.value);
    }
    if (outboxPaused.present) {
      map['outbox_paused'] = Variable<bool>(outboxPaused.value);
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
          ..write('replyTargetId: $replyTargetId, ')
          ..write('uploadBytes: $uploadBytes, ')
          ..write('uploadFilename: $uploadFilename, ')
          ..write('status: $status, ')
          ..write('isEdited: $isEdited, ')
          ..write('isDeletedForAll: $isDeletedForAll, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('seenAt: $seenAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('messageSeq: $messageSeq, ')
          ..write('deliveredByCursor: $deliveredByCursor, ')
          ..write('seenByCursor: $seenByCursor, ')
          ..write('enqueueOrder: $enqueueOrder, ')
          ..write('retryCount: $retryCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastErrorCode: $lastErrorCode, ')
          ..write('lastErrorText: $lastErrorText, ')
          ..write('outcomeUnknown: $outcomeUnknown, ')
          ..write('outboxPaused: $outboxPaused, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReceiptTasksTable extends ReceiptTasks
    with TableInfo<$ReceiptTasksTable, ReceiptTaskRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReceiptTasksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _roomIdMeta = const VerificationMeta('roomId');
  @override
  late final GeneratedColumn<String> roomId = GeneratedColumn<String>(
    'room_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receiptProtocolMeta = const VerificationMeta(
    'receiptProtocol',
  );
  @override
  late final GeneratedColumn<String> receiptProtocol = GeneratedColumn<String>(
    'receipt_protocol',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('legacy'),
  );
  static const VerificationMeta _deliveredTargetSeqMeta =
      const VerificationMeta('deliveredTargetSeq');
  @override
  late final GeneratedColumn<int> deliveredTargetSeq = GeneratedColumn<int>(
    'delivered_target_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _seenTargetSeqMeta = const VerificationMeta(
    'seenTargetSeq',
  );
  @override
  late final GeneratedColumn<int> seenTargetSeq = GeneratedColumn<int>(
    'seen_target_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _deliveredConfirmedSeqMeta =
      const VerificationMeta('deliveredConfirmedSeq');
  @override
  late final GeneratedColumn<int> deliveredConfirmedSeq = GeneratedColumn<int>(
    'delivered_confirmed_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _seenConfirmedSeqMeta = const VerificationMeta(
    'seenConfirmedSeq',
  );
  @override
  late final GeneratedColumn<int> seenConfirmedSeq = GeneratedColumn<int>(
    'seen_confirmed_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _deliveredTargetTimestampMeta =
      const VerificationMeta('deliveredTargetTimestamp');
  @override
  late final GeneratedColumn<int> deliveredTargetTimestamp =
      GeneratedColumn<int>(
        'delivered_target_timestamp',
        aliasedName,
        true,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _seenTargetTimestampMeta =
      const VerificationMeta('seenTargetTimestamp');
  @override
  late final GeneratedColumn<int> seenTargetTimestamp = GeneratedColumn<int>(
    'seen_target_timestamp',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deliveredConfirmedTimestampMeta =
      const VerificationMeta('deliveredConfirmedTimestamp');
  @override
  late final GeneratedColumn<int> deliveredConfirmedTimestamp =
      GeneratedColumn<int>(
        'delivered_confirmed_timestamp',
        aliasedName,
        true,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _seenConfirmedTimestampMeta =
      const VerificationMeta('seenConfirmedTimestamp');
  @override
  late final GeneratedColumn<int> seenConfirmedTimestamp = GeneratedColumn<int>(
    'seen_confirmed_timestamp',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    roomId,
    receiptProtocol,
    deliveredTargetSeq,
    seenTargetSeq,
    deliveredConfirmedSeq,
    seenConfirmedSeq,
    deliveredTargetTimestamp,
    seenTargetTimestamp,
    deliveredConfirmedTimestamp,
    seenConfirmedTimestamp,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'receipt_tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReceiptTaskRow> instance, {
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
    if (data.containsKey('receipt_protocol')) {
      context.handle(
        _receiptProtocolMeta,
        receiptProtocol.isAcceptableOrUnknown(
          data['receipt_protocol']!,
          _receiptProtocolMeta,
        ),
      );
    }
    if (data.containsKey('delivered_target_seq')) {
      context.handle(
        _deliveredTargetSeqMeta,
        deliveredTargetSeq.isAcceptableOrUnknown(
          data['delivered_target_seq']!,
          _deliveredTargetSeqMeta,
        ),
      );
    }
    if (data.containsKey('seen_target_seq')) {
      context.handle(
        _seenTargetSeqMeta,
        seenTargetSeq.isAcceptableOrUnknown(
          data['seen_target_seq']!,
          _seenTargetSeqMeta,
        ),
      );
    }
    if (data.containsKey('delivered_confirmed_seq')) {
      context.handle(
        _deliveredConfirmedSeqMeta,
        deliveredConfirmedSeq.isAcceptableOrUnknown(
          data['delivered_confirmed_seq']!,
          _deliveredConfirmedSeqMeta,
        ),
      );
    }
    if (data.containsKey('seen_confirmed_seq')) {
      context.handle(
        _seenConfirmedSeqMeta,
        seenConfirmedSeq.isAcceptableOrUnknown(
          data['seen_confirmed_seq']!,
          _seenConfirmedSeqMeta,
        ),
      );
    }
    if (data.containsKey('delivered_target_timestamp')) {
      context.handle(
        _deliveredTargetTimestampMeta,
        deliveredTargetTimestamp.isAcceptableOrUnknown(
          data['delivered_target_timestamp']!,
          _deliveredTargetTimestampMeta,
        ),
      );
    }
    if (data.containsKey('seen_target_timestamp')) {
      context.handle(
        _seenTargetTimestampMeta,
        seenTargetTimestamp.isAcceptableOrUnknown(
          data['seen_target_timestamp']!,
          _seenTargetTimestampMeta,
        ),
      );
    }
    if (data.containsKey('delivered_confirmed_timestamp')) {
      context.handle(
        _deliveredConfirmedTimestampMeta,
        deliveredConfirmedTimestamp.isAcceptableOrUnknown(
          data['delivered_confirmed_timestamp']!,
          _deliveredConfirmedTimestampMeta,
        ),
      );
    }
    if (data.containsKey('seen_confirmed_timestamp')) {
      context.handle(
        _seenConfirmedTimestampMeta,
        seenConfirmedTimestamp.isAcceptableOrUnknown(
          data['seen_confirmed_timestamp']!,
          _seenConfirmedTimestampMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {roomId};
  @override
  ReceiptTaskRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReceiptTaskRow(
      roomId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_id'],
      )!,
      receiptProtocol: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receipt_protocol'],
      )!,
      deliveredTargetSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delivered_target_seq'],
      )!,
      seenTargetSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seen_target_seq'],
      )!,
      deliveredConfirmedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delivered_confirmed_seq'],
      )!,
      seenConfirmedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seen_confirmed_seq'],
      )!,
      deliveredTargetTimestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delivered_target_timestamp'],
      ),
      seenTargetTimestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seen_target_timestamp'],
      ),
      deliveredConfirmedTimestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delivered_confirmed_timestamp'],
      ),
      seenConfirmedTimestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seen_confirmed_timestamp'],
      ),
    );
  }

  @override
  $ReceiptTasksTable createAlias(String alias) {
    return $ReceiptTasksTable(attachedDatabase, alias);
  }
}

class ReceiptTaskRow extends DataClass implements Insertable<ReceiptTaskRow> {
  final String roomId;
  final String receiptProtocol;
  final int deliveredTargetSeq;
  final int seenTargetSeq;
  final int deliveredConfirmedSeq;
  final int seenConfirmedSeq;
  final int? deliveredTargetTimestamp;
  final int? seenTargetTimestamp;
  final int? deliveredConfirmedTimestamp;
  final int? seenConfirmedTimestamp;
  const ReceiptTaskRow({
    required this.roomId,
    required this.receiptProtocol,
    required this.deliveredTargetSeq,
    required this.seenTargetSeq,
    required this.deliveredConfirmedSeq,
    required this.seenConfirmedSeq,
    this.deliveredTargetTimestamp,
    this.seenTargetTimestamp,
    this.deliveredConfirmedTimestamp,
    this.seenConfirmedTimestamp,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['room_id'] = Variable<String>(roomId);
    map['receipt_protocol'] = Variable<String>(receiptProtocol);
    map['delivered_target_seq'] = Variable<int>(deliveredTargetSeq);
    map['seen_target_seq'] = Variable<int>(seenTargetSeq);
    map['delivered_confirmed_seq'] = Variable<int>(deliveredConfirmedSeq);
    map['seen_confirmed_seq'] = Variable<int>(seenConfirmedSeq);
    if (!nullToAbsent || deliveredTargetTimestamp != null) {
      map['delivered_target_timestamp'] = Variable<int>(
        deliveredTargetTimestamp,
      );
    }
    if (!nullToAbsent || seenTargetTimestamp != null) {
      map['seen_target_timestamp'] = Variable<int>(seenTargetTimestamp);
    }
    if (!nullToAbsent || deliveredConfirmedTimestamp != null) {
      map['delivered_confirmed_timestamp'] = Variable<int>(
        deliveredConfirmedTimestamp,
      );
    }
    if (!nullToAbsent || seenConfirmedTimestamp != null) {
      map['seen_confirmed_timestamp'] = Variable<int>(seenConfirmedTimestamp);
    }
    return map;
  }

  ReceiptTasksCompanion toCompanion(bool nullToAbsent) {
    return ReceiptTasksCompanion(
      roomId: Value(roomId),
      receiptProtocol: Value(receiptProtocol),
      deliveredTargetSeq: Value(deliveredTargetSeq),
      seenTargetSeq: Value(seenTargetSeq),
      deliveredConfirmedSeq: Value(deliveredConfirmedSeq),
      seenConfirmedSeq: Value(seenConfirmedSeq),
      deliveredTargetTimestamp: deliveredTargetTimestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(deliveredTargetTimestamp),
      seenTargetTimestamp: seenTargetTimestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(seenTargetTimestamp),
      deliveredConfirmedTimestamp:
          deliveredConfirmedTimestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(deliveredConfirmedTimestamp),
      seenConfirmedTimestamp: seenConfirmedTimestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(seenConfirmedTimestamp),
    );
  }

  factory ReceiptTaskRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReceiptTaskRow(
      roomId: serializer.fromJson<String>(json['roomId']),
      receiptProtocol: serializer.fromJson<String>(json['receiptProtocol']),
      deliveredTargetSeq: serializer.fromJson<int>(json['deliveredTargetSeq']),
      seenTargetSeq: serializer.fromJson<int>(json['seenTargetSeq']),
      deliveredConfirmedSeq: serializer.fromJson<int>(
        json['deliveredConfirmedSeq'],
      ),
      seenConfirmedSeq: serializer.fromJson<int>(json['seenConfirmedSeq']),
      deliveredTargetTimestamp: serializer.fromJson<int?>(
        json['deliveredTargetTimestamp'],
      ),
      seenTargetTimestamp: serializer.fromJson<int?>(
        json['seenTargetTimestamp'],
      ),
      deliveredConfirmedTimestamp: serializer.fromJson<int?>(
        json['deliveredConfirmedTimestamp'],
      ),
      seenConfirmedTimestamp: serializer.fromJson<int?>(
        json['seenConfirmedTimestamp'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'roomId': serializer.toJson<String>(roomId),
      'receiptProtocol': serializer.toJson<String>(receiptProtocol),
      'deliveredTargetSeq': serializer.toJson<int>(deliveredTargetSeq),
      'seenTargetSeq': serializer.toJson<int>(seenTargetSeq),
      'deliveredConfirmedSeq': serializer.toJson<int>(deliveredConfirmedSeq),
      'seenConfirmedSeq': serializer.toJson<int>(seenConfirmedSeq),
      'deliveredTargetTimestamp': serializer.toJson<int?>(
        deliveredTargetTimestamp,
      ),
      'seenTargetTimestamp': serializer.toJson<int?>(seenTargetTimestamp),
      'deliveredConfirmedTimestamp': serializer.toJson<int?>(
        deliveredConfirmedTimestamp,
      ),
      'seenConfirmedTimestamp': serializer.toJson<int?>(seenConfirmedTimestamp),
    };
  }

  ReceiptTaskRow copyWith({
    String? roomId,
    String? receiptProtocol,
    int? deliveredTargetSeq,
    int? seenTargetSeq,
    int? deliveredConfirmedSeq,
    int? seenConfirmedSeq,
    Value<int?> deliveredTargetTimestamp = const Value.absent(),
    Value<int?> seenTargetTimestamp = const Value.absent(),
    Value<int?> deliveredConfirmedTimestamp = const Value.absent(),
    Value<int?> seenConfirmedTimestamp = const Value.absent(),
  }) => ReceiptTaskRow(
    roomId: roomId ?? this.roomId,
    receiptProtocol: receiptProtocol ?? this.receiptProtocol,
    deliveredTargetSeq: deliveredTargetSeq ?? this.deliveredTargetSeq,
    seenTargetSeq: seenTargetSeq ?? this.seenTargetSeq,
    deliveredConfirmedSeq: deliveredConfirmedSeq ?? this.deliveredConfirmedSeq,
    seenConfirmedSeq: seenConfirmedSeq ?? this.seenConfirmedSeq,
    deliveredTargetTimestamp: deliveredTargetTimestamp.present
        ? deliveredTargetTimestamp.value
        : this.deliveredTargetTimestamp,
    seenTargetTimestamp: seenTargetTimestamp.present
        ? seenTargetTimestamp.value
        : this.seenTargetTimestamp,
    deliveredConfirmedTimestamp: deliveredConfirmedTimestamp.present
        ? deliveredConfirmedTimestamp.value
        : this.deliveredConfirmedTimestamp,
    seenConfirmedTimestamp: seenConfirmedTimestamp.present
        ? seenConfirmedTimestamp.value
        : this.seenConfirmedTimestamp,
  );
  ReceiptTaskRow copyWithCompanion(ReceiptTasksCompanion data) {
    return ReceiptTaskRow(
      roomId: data.roomId.present ? data.roomId.value : this.roomId,
      receiptProtocol: data.receiptProtocol.present
          ? data.receiptProtocol.value
          : this.receiptProtocol,
      deliveredTargetSeq: data.deliveredTargetSeq.present
          ? data.deliveredTargetSeq.value
          : this.deliveredTargetSeq,
      seenTargetSeq: data.seenTargetSeq.present
          ? data.seenTargetSeq.value
          : this.seenTargetSeq,
      deliveredConfirmedSeq: data.deliveredConfirmedSeq.present
          ? data.deliveredConfirmedSeq.value
          : this.deliveredConfirmedSeq,
      seenConfirmedSeq: data.seenConfirmedSeq.present
          ? data.seenConfirmedSeq.value
          : this.seenConfirmedSeq,
      deliveredTargetTimestamp: data.deliveredTargetTimestamp.present
          ? data.deliveredTargetTimestamp.value
          : this.deliveredTargetTimestamp,
      seenTargetTimestamp: data.seenTargetTimestamp.present
          ? data.seenTargetTimestamp.value
          : this.seenTargetTimestamp,
      deliveredConfirmedTimestamp: data.deliveredConfirmedTimestamp.present
          ? data.deliveredConfirmedTimestamp.value
          : this.deliveredConfirmedTimestamp,
      seenConfirmedTimestamp: data.seenConfirmedTimestamp.present
          ? data.seenConfirmedTimestamp.value
          : this.seenConfirmedTimestamp,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReceiptTaskRow(')
          ..write('roomId: $roomId, ')
          ..write('receiptProtocol: $receiptProtocol, ')
          ..write('deliveredTargetSeq: $deliveredTargetSeq, ')
          ..write('seenTargetSeq: $seenTargetSeq, ')
          ..write('deliveredConfirmedSeq: $deliveredConfirmedSeq, ')
          ..write('seenConfirmedSeq: $seenConfirmedSeq, ')
          ..write('deliveredTargetTimestamp: $deliveredTargetTimestamp, ')
          ..write('seenTargetTimestamp: $seenTargetTimestamp, ')
          ..write('deliveredConfirmedTimestamp: $deliveredConfirmedTimestamp, ')
          ..write('seenConfirmedTimestamp: $seenConfirmedTimestamp')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    roomId,
    receiptProtocol,
    deliveredTargetSeq,
    seenTargetSeq,
    deliveredConfirmedSeq,
    seenConfirmedSeq,
    deliveredTargetTimestamp,
    seenTargetTimestamp,
    deliveredConfirmedTimestamp,
    seenConfirmedTimestamp,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReceiptTaskRow &&
          other.roomId == this.roomId &&
          other.receiptProtocol == this.receiptProtocol &&
          other.deliveredTargetSeq == this.deliveredTargetSeq &&
          other.seenTargetSeq == this.seenTargetSeq &&
          other.deliveredConfirmedSeq == this.deliveredConfirmedSeq &&
          other.seenConfirmedSeq == this.seenConfirmedSeq &&
          other.deliveredTargetTimestamp == this.deliveredTargetTimestamp &&
          other.seenTargetTimestamp == this.seenTargetTimestamp &&
          other.deliveredConfirmedTimestamp ==
              this.deliveredConfirmedTimestamp &&
          other.seenConfirmedTimestamp == this.seenConfirmedTimestamp);
}

class ReceiptTasksCompanion extends UpdateCompanion<ReceiptTaskRow> {
  final Value<String> roomId;
  final Value<String> receiptProtocol;
  final Value<int> deliveredTargetSeq;
  final Value<int> seenTargetSeq;
  final Value<int> deliveredConfirmedSeq;
  final Value<int> seenConfirmedSeq;
  final Value<int?> deliveredTargetTimestamp;
  final Value<int?> seenTargetTimestamp;
  final Value<int?> deliveredConfirmedTimestamp;
  final Value<int?> seenConfirmedTimestamp;
  final Value<int> rowid;
  const ReceiptTasksCompanion({
    this.roomId = const Value.absent(),
    this.receiptProtocol = const Value.absent(),
    this.deliveredTargetSeq = const Value.absent(),
    this.seenTargetSeq = const Value.absent(),
    this.deliveredConfirmedSeq = const Value.absent(),
    this.seenConfirmedSeq = const Value.absent(),
    this.deliveredTargetTimestamp = const Value.absent(),
    this.seenTargetTimestamp = const Value.absent(),
    this.deliveredConfirmedTimestamp = const Value.absent(),
    this.seenConfirmedTimestamp = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReceiptTasksCompanion.insert({
    required String roomId,
    this.receiptProtocol = const Value.absent(),
    this.deliveredTargetSeq = const Value.absent(),
    this.seenTargetSeq = const Value.absent(),
    this.deliveredConfirmedSeq = const Value.absent(),
    this.seenConfirmedSeq = const Value.absent(),
    this.deliveredTargetTimestamp = const Value.absent(),
    this.seenTargetTimestamp = const Value.absent(),
    this.deliveredConfirmedTimestamp = const Value.absent(),
    this.seenConfirmedTimestamp = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : roomId = Value(roomId);
  static Insertable<ReceiptTaskRow> custom({
    Expression<String>? roomId,
    Expression<String>? receiptProtocol,
    Expression<int>? deliveredTargetSeq,
    Expression<int>? seenTargetSeq,
    Expression<int>? deliveredConfirmedSeq,
    Expression<int>? seenConfirmedSeq,
    Expression<int>? deliveredTargetTimestamp,
    Expression<int>? seenTargetTimestamp,
    Expression<int>? deliveredConfirmedTimestamp,
    Expression<int>? seenConfirmedTimestamp,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (roomId != null) 'room_id': roomId,
      if (receiptProtocol != null) 'receipt_protocol': receiptProtocol,
      if (deliveredTargetSeq != null)
        'delivered_target_seq': deliveredTargetSeq,
      if (seenTargetSeq != null) 'seen_target_seq': seenTargetSeq,
      if (deliveredConfirmedSeq != null)
        'delivered_confirmed_seq': deliveredConfirmedSeq,
      if (seenConfirmedSeq != null) 'seen_confirmed_seq': seenConfirmedSeq,
      if (deliveredTargetTimestamp != null)
        'delivered_target_timestamp': deliveredTargetTimestamp,
      if (seenTargetTimestamp != null)
        'seen_target_timestamp': seenTargetTimestamp,
      if (deliveredConfirmedTimestamp != null)
        'delivered_confirmed_timestamp': deliveredConfirmedTimestamp,
      if (seenConfirmedTimestamp != null)
        'seen_confirmed_timestamp': seenConfirmedTimestamp,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReceiptTasksCompanion copyWith({
    Value<String>? roomId,
    Value<String>? receiptProtocol,
    Value<int>? deliveredTargetSeq,
    Value<int>? seenTargetSeq,
    Value<int>? deliveredConfirmedSeq,
    Value<int>? seenConfirmedSeq,
    Value<int?>? deliveredTargetTimestamp,
    Value<int?>? seenTargetTimestamp,
    Value<int?>? deliveredConfirmedTimestamp,
    Value<int?>? seenConfirmedTimestamp,
    Value<int>? rowid,
  }) {
    return ReceiptTasksCompanion(
      roomId: roomId ?? this.roomId,
      receiptProtocol: receiptProtocol ?? this.receiptProtocol,
      deliveredTargetSeq: deliveredTargetSeq ?? this.deliveredTargetSeq,
      seenTargetSeq: seenTargetSeq ?? this.seenTargetSeq,
      deliveredConfirmedSeq:
          deliveredConfirmedSeq ?? this.deliveredConfirmedSeq,
      seenConfirmedSeq: seenConfirmedSeq ?? this.seenConfirmedSeq,
      deliveredTargetTimestamp:
          deliveredTargetTimestamp ?? this.deliveredTargetTimestamp,
      seenTargetTimestamp: seenTargetTimestamp ?? this.seenTargetTimestamp,
      deliveredConfirmedTimestamp:
          deliveredConfirmedTimestamp ?? this.deliveredConfirmedTimestamp,
      seenConfirmedTimestamp:
          seenConfirmedTimestamp ?? this.seenConfirmedTimestamp,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (roomId.present) {
      map['room_id'] = Variable<String>(roomId.value);
    }
    if (receiptProtocol.present) {
      map['receipt_protocol'] = Variable<String>(receiptProtocol.value);
    }
    if (deliveredTargetSeq.present) {
      map['delivered_target_seq'] = Variable<int>(deliveredTargetSeq.value);
    }
    if (seenTargetSeq.present) {
      map['seen_target_seq'] = Variable<int>(seenTargetSeq.value);
    }
    if (deliveredConfirmedSeq.present) {
      map['delivered_confirmed_seq'] = Variable<int>(
        deliveredConfirmedSeq.value,
      );
    }
    if (seenConfirmedSeq.present) {
      map['seen_confirmed_seq'] = Variable<int>(seenConfirmedSeq.value);
    }
    if (deliveredTargetTimestamp.present) {
      map['delivered_target_timestamp'] = Variable<int>(
        deliveredTargetTimestamp.value,
      );
    }
    if (seenTargetTimestamp.present) {
      map['seen_target_timestamp'] = Variable<int>(seenTargetTimestamp.value);
    }
    if (deliveredConfirmedTimestamp.present) {
      map['delivered_confirmed_timestamp'] = Variable<int>(
        deliveredConfirmedTimestamp.value,
      );
    }
    if (seenConfirmedTimestamp.present) {
      map['seen_confirmed_timestamp'] = Variable<int>(
        seenConfirmedTimestamp.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReceiptTasksCompanion(')
          ..write('roomId: $roomId, ')
          ..write('receiptProtocol: $receiptProtocol, ')
          ..write('deliveredTargetSeq: $deliveredTargetSeq, ')
          ..write('seenTargetSeq: $seenTargetSeq, ')
          ..write('deliveredConfirmedSeq: $deliveredConfirmedSeq, ')
          ..write('seenConfirmedSeq: $seenConfirmedSeq, ')
          ..write('deliveredTargetTimestamp: $deliveredTargetTimestamp, ')
          ..write('seenTargetTimestamp: $seenTargetTimestamp, ')
          ..write('deliveredConfirmedTimestamp: $deliveredConfirmedTimestamp, ')
          ..write('seenConfirmedTimestamp: $seenConfirmedTimestamp, ')
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
  late final $ReceiptTasksTable receiptTasks = $ReceiptTasksTable(this);
  late final Index localMessagesRoomCreated = Index(
    'local_messages_room_created',
    'CREATE INDEX local_messages_room_created ON local_messages (room_id, created_at, id)',
  );
  late final Index localMessagesReplyTarget = Index(
    'local_messages_reply_target',
    'CREATE INDEX local_messages_reply_target ON local_messages (room_id, reply_target_id)',
  );
  late final Index localMessagesOutbox = Index(
    'local_messages_outbox',
    'CREATE INDEX local_messages_outbox ON local_messages (sender_id, status, enqueue_order)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    syncMetadata,
    localRooms,
    localMessages,
    receiptTasks,
    localMessagesRoomCreated,
    localMessagesReplyTarget,
    localMessagesOutbox,
  ];
}

typedef $$SyncMetadataTableCreateCompanionBuilder =
    SyncMetadataCompanion Function({
      Value<int> id,
      required String userId,
      Value<int> localPts,
      Value<String> localEpoch,
      Value<String?> roomPageCursorJson,
      Value<String?> roomPageEpoch,
      Value<bool> roomPageKnown,
      Value<int> lastOutboundOrder,
    });
typedef $$SyncMetadataTableUpdateCompanionBuilder =
    SyncMetadataCompanion Function({
      Value<int> id,
      Value<String> userId,
      Value<int> localPts,
      Value<String> localEpoch,
      Value<String?> roomPageCursorJson,
      Value<String?> roomPageEpoch,
      Value<bool> roomPageKnown,
      Value<int> lastOutboundOrder,
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

  ColumnFilters<String> get roomPageCursorJson => $composableBuilder(
    column: $table.roomPageCursorJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roomPageEpoch => $composableBuilder(
    column: $table.roomPageEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get roomPageKnown => $composableBuilder(
    column: $table.roomPageKnown,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastOutboundOrder => $composableBuilder(
    column: $table.lastOutboundOrder,
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

  ColumnOrderings<String> get roomPageCursorJson => $composableBuilder(
    column: $table.roomPageCursorJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roomPageEpoch => $composableBuilder(
    column: $table.roomPageEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get roomPageKnown => $composableBuilder(
    column: $table.roomPageKnown,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastOutboundOrder => $composableBuilder(
    column: $table.lastOutboundOrder,
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

  GeneratedColumn<String> get roomPageCursorJson => $composableBuilder(
    column: $table.roomPageCursorJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get roomPageEpoch => $composableBuilder(
    column: $table.roomPageEpoch,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get roomPageKnown => $composableBuilder(
    column: $table.roomPageKnown,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastOutboundOrder => $composableBuilder(
    column: $table.lastOutboundOrder,
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
                Value<String?> roomPageCursorJson = const Value.absent(),
                Value<String?> roomPageEpoch = const Value.absent(),
                Value<bool> roomPageKnown = const Value.absent(),
                Value<int> lastOutboundOrder = const Value.absent(),
              }) => SyncMetadataCompanion(
                id: id,
                userId: userId,
                localPts: localPts,
                localEpoch: localEpoch,
                roomPageCursorJson: roomPageCursorJson,
                roomPageEpoch: roomPageEpoch,
                roomPageKnown: roomPageKnown,
                lastOutboundOrder: lastOutboundOrder,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String userId,
                Value<int> localPts = const Value.absent(),
                Value<String> localEpoch = const Value.absent(),
                Value<String?> roomPageCursorJson = const Value.absent(),
                Value<String?> roomPageEpoch = const Value.absent(),
                Value<bool> roomPageKnown = const Value.absent(),
                Value<int> lastOutboundOrder = const Value.absent(),
              }) => SyncMetadataCompanion.insert(
                id: id,
                userId: userId,
                localPts: localPts,
                localEpoch: localEpoch,
                roomPageCursorJson: roomPageCursorJson,
                roomPageEpoch: roomPageEpoch,
                roomPageKnown: roomPageKnown,
                lastOutboundOrder: lastOutboundOrder,
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
  Value<int?> contentPts,
  Value<String> receiptProtocol,
  Value<int> peerDeliveredSeq,
  Value<int> peerSeenSeq,
  Value<int> ownDeliveredSeq,
  Value<int> ownSeenSeq,
  Value<int> receivedThroughSeq,
  Value<int> verifiedHeadSeq,
  Value<String> receivedRangesJson,
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
  Value<int?> contentPts,
  Value<String> receiptProtocol,
  Value<int> peerDeliveredSeq,
  Value<int> peerSeenSeq,
  Value<int> ownDeliveredSeq,
  Value<int> ownSeenSeq,
  Value<int> receivedThroughSeq,
  Value<int> verifiedHeadSeq,
  Value<String> receivedRangesJson,
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

  ColumnFilters<int> get contentPts => $composableBuilder(
    column: $table.contentPts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiptProtocol => $composableBuilder(
    column: $table.receiptProtocol,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get peerDeliveredSeq => $composableBuilder(
    column: $table.peerDeliveredSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get peerSeenSeq => $composableBuilder(
    column: $table.peerSeenSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ownDeliveredSeq => $composableBuilder(
    column: $table.ownDeliveredSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ownSeenSeq => $composableBuilder(
    column: $table.ownSeenSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get receivedThroughSeq => $composableBuilder(
    column: $table.receivedThroughSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get verifiedHeadSeq => $composableBuilder(
    column: $table.verifiedHeadSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receivedRangesJson => $composableBuilder(
    column: $table.receivedRangesJson,
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

  ColumnOrderings<int> get contentPts => $composableBuilder(
    column: $table.contentPts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiptProtocol => $composableBuilder(
    column: $table.receiptProtocol,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get peerDeliveredSeq => $composableBuilder(
    column: $table.peerDeliveredSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get peerSeenSeq => $composableBuilder(
    column: $table.peerSeenSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ownDeliveredSeq => $composableBuilder(
    column: $table.ownDeliveredSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ownSeenSeq => $composableBuilder(
    column: $table.ownSeenSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get receivedThroughSeq => $composableBuilder(
    column: $table.receivedThroughSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get verifiedHeadSeq => $composableBuilder(
    column: $table.verifiedHeadSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receivedRangesJson => $composableBuilder(
    column: $table.receivedRangesJson,
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

  GeneratedColumn<int> get contentPts => $composableBuilder(
    column: $table.contentPts,
    builder: (column) => column,
  );

  GeneratedColumn<String> get receiptProtocol => $composableBuilder(
    column: $table.receiptProtocol,
    builder: (column) => column,
  );

  GeneratedColumn<int> get peerDeliveredSeq => $composableBuilder(
    column: $table.peerDeliveredSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get peerSeenSeq => $composableBuilder(
    column: $table.peerSeenSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get ownDeliveredSeq => $composableBuilder(
    column: $table.ownDeliveredSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get ownSeenSeq => $composableBuilder(
    column: $table.ownSeenSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get receivedThroughSeq => $composableBuilder(
    column: $table.receivedThroughSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get verifiedHeadSeq => $composableBuilder(
    column: $table.verifiedHeadSeq,
    builder: (column) => column,
  );

  GeneratedColumn<String> get receivedRangesJson => $composableBuilder(
    column: $table.receivedRangesJson,
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
                Value<int?> contentPts = const Value.absent(),
                Value<String> receiptProtocol = const Value.absent(),
                Value<int> peerDeliveredSeq = const Value.absent(),
                Value<int> peerSeenSeq = const Value.absent(),
                Value<int> ownDeliveredSeq = const Value.absent(),
                Value<int> ownSeenSeq = const Value.absent(),
                Value<int> receivedThroughSeq = const Value.absent(),
                Value<int> verifiedHeadSeq = const Value.absent(),
                Value<String> receivedRangesJson = const Value.absent(),
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
                contentPts: contentPts,
                receiptProtocol: receiptProtocol,
                peerDeliveredSeq: peerDeliveredSeq,
                peerSeenSeq: peerSeenSeq,
                ownDeliveredSeq: ownDeliveredSeq,
                ownSeenSeq: ownSeenSeq,
                receivedThroughSeq: receivedThroughSeq,
                verifiedHeadSeq: verifiedHeadSeq,
                receivedRangesJson: receivedRangesJson,
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
                Value<int?> contentPts = const Value.absent(),
                Value<String> receiptProtocol = const Value.absent(),
                Value<int> peerDeliveredSeq = const Value.absent(),
                Value<int> peerSeenSeq = const Value.absent(),
                Value<int> ownDeliveredSeq = const Value.absent(),
                Value<int> ownSeenSeq = const Value.absent(),
                Value<int> receivedThroughSeq = const Value.absent(),
                Value<int> verifiedHeadSeq = const Value.absent(),
                Value<String> receivedRangesJson = const Value.absent(),
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
                contentPts: contentPts,
                receiptProtocol: receiptProtocol,
                peerDeliveredSeq: peerDeliveredSeq,
                peerSeenSeq: peerSeenSeq,
                ownDeliveredSeq: ownDeliveredSeq,
                ownSeenSeq: ownSeenSeq,
                receivedThroughSeq: receivedThroughSeq,
                verifiedHeadSeq: verifiedHeadSeq,
                receivedRangesJson: receivedRangesJson,
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
      Value<String?> replyTargetId,
      Value<Uint8List?> uploadBytes,
      Value<String?> uploadFilename,
      required String status,
      Value<bool> isEdited,
      Value<bool> isDeletedForAll,
      Value<int?> deliveredAt,
      Value<int?> seenAt,
      required int createdAt,
      Value<int?> messageSeq,
      Value<bool> deliveredByCursor,
      Value<bool> seenByCursor,
      Value<int?> enqueueOrder,
      Value<int> retryCount,
      Value<int?> nextAttemptAt,
      Value<String?> lastErrorCode,
      Value<String?> lastErrorText,
      Value<bool> outcomeUnknown,
      Value<bool> outboxPaused,
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
      Value<String?> replyTargetId,
      Value<Uint8List?> uploadBytes,
      Value<String?> uploadFilename,
      Value<String> status,
      Value<bool> isEdited,
      Value<bool> isDeletedForAll,
      Value<int?> deliveredAt,
      Value<int?> seenAt,
      Value<int> createdAt,
      Value<int?> messageSeq,
      Value<bool> deliveredByCursor,
      Value<bool> seenByCursor,
      Value<int?> enqueueOrder,
      Value<int> retryCount,
      Value<int?> nextAttemptAt,
      Value<String?> lastErrorCode,
      Value<String?> lastErrorText,
      Value<bool> outcomeUnknown,
      Value<bool> outboxPaused,
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

  ColumnFilters<String> get replyTargetId => $composableBuilder(
    column: $table.replyTargetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get uploadBytes => $composableBuilder(
    column: $table.uploadBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get uploadFilename => $composableBuilder(
    column: $table.uploadFilename,
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

  ColumnFilters<int> get messageSeq => $composableBuilder(
    column: $table.messageSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deliveredByCursor => $composableBuilder(
    column: $table.deliveredByCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get seenByCursor => $composableBuilder(
    column: $table.seenByCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get enqueueOrder => $composableBuilder(
    column: $table.enqueueOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastErrorText => $composableBuilder(
    column: $table.lastErrorText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get outcomeUnknown => $composableBuilder(
    column: $table.outcomeUnknown,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get outboxPaused => $composableBuilder(
    column: $table.outboxPaused,
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

  ColumnOrderings<String> get replyTargetId => $composableBuilder(
    column: $table.replyTargetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get uploadBytes => $composableBuilder(
    column: $table.uploadBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get uploadFilename => $composableBuilder(
    column: $table.uploadFilename,
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

  ColumnOrderings<int> get messageSeq => $composableBuilder(
    column: $table.messageSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deliveredByCursor => $composableBuilder(
    column: $table.deliveredByCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get seenByCursor => $composableBuilder(
    column: $table.seenByCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get enqueueOrder => $composableBuilder(
    column: $table.enqueueOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastErrorText => $composableBuilder(
    column: $table.lastErrorText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get outcomeUnknown => $composableBuilder(
    column: $table.outcomeUnknown,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get outboxPaused => $composableBuilder(
    column: $table.outboxPaused,
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

  GeneratedColumn<String> get replyTargetId => $composableBuilder(
    column: $table.replyTargetId,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get uploadBytes => $composableBuilder(
    column: $table.uploadBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get uploadFilename => $composableBuilder(
    column: $table.uploadFilename,
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

  GeneratedColumn<int> get messageSeq => $composableBuilder(
    column: $table.messageSeq,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deliveredByCursor => $composableBuilder(
    column: $table.deliveredByCursor,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get seenByCursor => $composableBuilder(
    column: $table.seenByCursor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get enqueueOrder => $composableBuilder(
    column: $table.enqueueOrder,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastErrorText => $composableBuilder(
    column: $table.lastErrorText,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get outcomeUnknown => $composableBuilder(
    column: $table.outcomeUnknown,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get outboxPaused => $composableBuilder(
    column: $table.outboxPaused,
    builder: (column) => column,
  );
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
                Value<String?> replyTargetId = const Value.absent(),
                Value<Uint8List?> uploadBytes = const Value.absent(),
                Value<String?> uploadFilename = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<bool> isEdited = const Value.absent(),
                Value<bool> isDeletedForAll = const Value.absent(),
                Value<int?> deliveredAt = const Value.absent(),
                Value<int?> seenAt = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int?> messageSeq = const Value.absent(),
                Value<bool> deliveredByCursor = const Value.absent(),
                Value<bool> seenByCursor = const Value.absent(),
                Value<int?> enqueueOrder = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<int?> nextAttemptAt = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
                Value<String?> lastErrorText = const Value.absent(),
                Value<bool> outcomeUnknown = const Value.absent(),
                Value<bool> outboxPaused = const Value.absent(),
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
                replyTargetId: replyTargetId,
                uploadBytes: uploadBytes,
                uploadFilename: uploadFilename,
                status: status,
                isEdited: isEdited,
                isDeletedForAll: isDeletedForAll,
                deliveredAt: deliveredAt,
                seenAt: seenAt,
                createdAt: createdAt,
                messageSeq: messageSeq,
                deliveredByCursor: deliveredByCursor,
                seenByCursor: seenByCursor,
                enqueueOrder: enqueueOrder,
                retryCount: retryCount,
                nextAttemptAt: nextAttemptAt,
                lastErrorCode: lastErrorCode,
                lastErrorText: lastErrorText,
                outcomeUnknown: outcomeUnknown,
                outboxPaused: outboxPaused,
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
                Value<String?> replyTargetId = const Value.absent(),
                Value<Uint8List?> uploadBytes = const Value.absent(),
                Value<String?> uploadFilename = const Value.absent(),
                required String status,
                Value<bool> isEdited = const Value.absent(),
                Value<bool> isDeletedForAll = const Value.absent(),
                Value<int?> deliveredAt = const Value.absent(),
                Value<int?> seenAt = const Value.absent(),
                required int createdAt,
                Value<int?> messageSeq = const Value.absent(),
                Value<bool> deliveredByCursor = const Value.absent(),
                Value<bool> seenByCursor = const Value.absent(),
                Value<int?> enqueueOrder = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<int?> nextAttemptAt = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
                Value<String?> lastErrorText = const Value.absent(),
                Value<bool> outcomeUnknown = const Value.absent(),
                Value<bool> outboxPaused = const Value.absent(),
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
                replyTargetId: replyTargetId,
                uploadBytes: uploadBytes,
                uploadFilename: uploadFilename,
                status: status,
                isEdited: isEdited,
                isDeletedForAll: isDeletedForAll,
                deliveredAt: deliveredAt,
                seenAt: seenAt,
                createdAt: createdAt,
                messageSeq: messageSeq,
                deliveredByCursor: deliveredByCursor,
                seenByCursor: seenByCursor,
                enqueueOrder: enqueueOrder,
                retryCount: retryCount,
                nextAttemptAt: nextAttemptAt,
                lastErrorCode: lastErrorCode,
                lastErrorText: lastErrorText,
                outcomeUnknown: outcomeUnknown,
                outboxPaused: outboxPaused,
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
typedef $$ReceiptTasksTableCreateCompanionBuilder =
    ReceiptTasksCompanion Function({
      required String roomId,
      Value<String> receiptProtocol,
      Value<int> deliveredTargetSeq,
      Value<int> seenTargetSeq,
      Value<int> deliveredConfirmedSeq,
      Value<int> seenConfirmedSeq,
      Value<int?> deliveredTargetTimestamp,
      Value<int?> seenTargetTimestamp,
      Value<int?> deliveredConfirmedTimestamp,
      Value<int?> seenConfirmedTimestamp,
      Value<int> rowid,
    });
typedef $$ReceiptTasksTableUpdateCompanionBuilder =
    ReceiptTasksCompanion Function({
      Value<String> roomId,
      Value<String> receiptProtocol,
      Value<int> deliveredTargetSeq,
      Value<int> seenTargetSeq,
      Value<int> deliveredConfirmedSeq,
      Value<int> seenConfirmedSeq,
      Value<int?> deliveredTargetTimestamp,
      Value<int?> seenTargetTimestamp,
      Value<int?> deliveredConfirmedTimestamp,
      Value<int?> seenConfirmedTimestamp,
      Value<int> rowid,
    });

class $$ReceiptTasksTableFilterComposer
    extends Composer<_$AppDatabase, $ReceiptTasksTable> {
  $$ReceiptTasksTableFilterComposer({
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

  ColumnFilters<String> get receiptProtocol => $composableBuilder(
    column: $table.receiptProtocol,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deliveredTargetSeq => $composableBuilder(
    column: $table.deliveredTargetSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seenTargetSeq => $composableBuilder(
    column: $table.seenTargetSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deliveredConfirmedSeq => $composableBuilder(
    column: $table.deliveredConfirmedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seenConfirmedSeq => $composableBuilder(
    column: $table.seenConfirmedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deliveredTargetTimestamp => $composableBuilder(
    column: $table.deliveredTargetTimestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seenTargetTimestamp => $composableBuilder(
    column: $table.seenTargetTimestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deliveredConfirmedTimestamp => $composableBuilder(
    column: $table.deliveredConfirmedTimestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seenConfirmedTimestamp => $composableBuilder(
    column: $table.seenConfirmedTimestamp,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReceiptTasksTableOrderingComposer
    extends Composer<_$AppDatabase, $ReceiptTasksTable> {
  $$ReceiptTasksTableOrderingComposer({
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

  ColumnOrderings<String> get receiptProtocol => $composableBuilder(
    column: $table.receiptProtocol,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deliveredTargetSeq => $composableBuilder(
    column: $table.deliveredTargetSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seenTargetSeq => $composableBuilder(
    column: $table.seenTargetSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deliveredConfirmedSeq => $composableBuilder(
    column: $table.deliveredConfirmedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seenConfirmedSeq => $composableBuilder(
    column: $table.seenConfirmedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deliveredTargetTimestamp => $composableBuilder(
    column: $table.deliveredTargetTimestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seenTargetTimestamp => $composableBuilder(
    column: $table.seenTargetTimestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deliveredConfirmedTimestamp => $composableBuilder(
    column: $table.deliveredConfirmedTimestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seenConfirmedTimestamp => $composableBuilder(
    column: $table.seenConfirmedTimestamp,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReceiptTasksTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReceiptTasksTable> {
  $$ReceiptTasksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get roomId =>
      $composableBuilder(column: $table.roomId, builder: (column) => column);

  GeneratedColumn<String> get receiptProtocol => $composableBuilder(
    column: $table.receiptProtocol,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deliveredTargetSeq => $composableBuilder(
    column: $table.deliveredTargetSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get seenTargetSeq => $composableBuilder(
    column: $table.seenTargetSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deliveredConfirmedSeq => $composableBuilder(
    column: $table.deliveredConfirmedSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get seenConfirmedSeq => $composableBuilder(
    column: $table.seenConfirmedSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deliveredTargetTimestamp => $composableBuilder(
    column: $table.deliveredTargetTimestamp,
    builder: (column) => column,
  );

  GeneratedColumn<int> get seenTargetTimestamp => $composableBuilder(
    column: $table.seenTargetTimestamp,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deliveredConfirmedTimestamp => $composableBuilder(
    column: $table.deliveredConfirmedTimestamp,
    builder: (column) => column,
  );

  GeneratedColumn<int> get seenConfirmedTimestamp => $composableBuilder(
    column: $table.seenConfirmedTimestamp,
    builder: (column) => column,
  );
}

class $$ReceiptTasksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReceiptTasksTable,
          ReceiptTaskRow,
          $$ReceiptTasksTableFilterComposer,
          $$ReceiptTasksTableOrderingComposer,
          $$ReceiptTasksTableAnnotationComposer,
          $$ReceiptTasksTableCreateCompanionBuilder,
          $$ReceiptTasksTableUpdateCompanionBuilder,
          (
            ReceiptTaskRow,
            BaseReferences<_$AppDatabase, $ReceiptTasksTable, ReceiptTaskRow>,
          ),
          ReceiptTaskRow,
          PrefetchHooks Function()
        > {
  $$ReceiptTasksTableTableManager(_$AppDatabase db, $ReceiptTasksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReceiptTasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReceiptTasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReceiptTasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> roomId = const Value.absent(),
                Value<String> receiptProtocol = const Value.absent(),
                Value<int> deliveredTargetSeq = const Value.absent(),
                Value<int> seenTargetSeq = const Value.absent(),
                Value<int> deliveredConfirmedSeq = const Value.absent(),
                Value<int> seenConfirmedSeq = const Value.absent(),
                Value<int?> deliveredTargetTimestamp = const Value.absent(),
                Value<int?> seenTargetTimestamp = const Value.absent(),
                Value<int?> deliveredConfirmedTimestamp = const Value.absent(),
                Value<int?> seenConfirmedTimestamp = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReceiptTasksCompanion(
                roomId: roomId,
                receiptProtocol: receiptProtocol,
                deliveredTargetSeq: deliveredTargetSeq,
                seenTargetSeq: seenTargetSeq,
                deliveredConfirmedSeq: deliveredConfirmedSeq,
                seenConfirmedSeq: seenConfirmedSeq,
                deliveredTargetTimestamp: deliveredTargetTimestamp,
                seenTargetTimestamp: seenTargetTimestamp,
                deliveredConfirmedTimestamp: deliveredConfirmedTimestamp,
                seenConfirmedTimestamp: seenConfirmedTimestamp,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String roomId,
                Value<String> receiptProtocol = const Value.absent(),
                Value<int> deliveredTargetSeq = const Value.absent(),
                Value<int> seenTargetSeq = const Value.absent(),
                Value<int> deliveredConfirmedSeq = const Value.absent(),
                Value<int> seenConfirmedSeq = const Value.absent(),
                Value<int?> deliveredTargetTimestamp = const Value.absent(),
                Value<int?> seenTargetTimestamp = const Value.absent(),
                Value<int?> deliveredConfirmedTimestamp = const Value.absent(),
                Value<int?> seenConfirmedTimestamp = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReceiptTasksCompanion.insert(
                roomId: roomId,
                receiptProtocol: receiptProtocol,
                deliveredTargetSeq: deliveredTargetSeq,
                seenTargetSeq: seenTargetSeq,
                deliveredConfirmedSeq: deliveredConfirmedSeq,
                seenConfirmedSeq: seenConfirmedSeq,
                deliveredTargetTimestamp: deliveredTargetTimestamp,
                seenTargetTimestamp: seenTargetTimestamp,
                deliveredConfirmedTimestamp: deliveredConfirmedTimestamp,
                seenConfirmedTimestamp: seenConfirmedTimestamp,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReceiptTasksTable, ReceiptTaskRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ReceiptTasksTable,
                    ReceiptTaskRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReceiptTasksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReceiptTasksTable,
      ReceiptTaskRow,
      $$ReceiptTasksTableFilterComposer,
      $$ReceiptTasksTableOrderingComposer,
      $$ReceiptTasksTableAnnotationComposer,
      $$ReceiptTasksTableCreateCompanionBuilder,
      $$ReceiptTasksTableUpdateCompanionBuilder,
      (
        ReceiptTaskRow,
        BaseReferences<_$AppDatabase, $ReceiptTasksTable, ReceiptTaskRow>,
      ),
      ReceiptTaskRow,
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
  $$ReceiptTasksTableTableManager get receiptTasks =>
      $$ReceiptTasksTableTableManager(_db, _db.receiptTasks);
}
