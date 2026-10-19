import 'dart:convert';
import 'dart:typed_data';

Map<String, dynamic> jsonMap(Object? value) =>
    Map<String, dynamic>.from(value as Map);
DateTime? parseTime(Object? value) => value == null
    ? null
    : value is int
    ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
    : DateTime.parse(value.toString()).toUtc();
int intValue(Object? value) => (value as num?)?.toInt() ?? 0;

class UserProfile {
  const UserProfile({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.debugUserNumber,
  });
  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: (json['_id'] ?? json['id']) as String,
    username: json['username'] as String? ?? '',
    displayName: json['displayName'] as String? ?? '',
    avatarUrl: json['avatarUrl'] as String?,
    debugUserNumber: (json['debugUserNumber'] as num?)?.toInt(),
  );
  final String id, username, displayName;
  final String? avatarUrl;
  final int? debugUserNumber;
  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'debugUserNumber': debugUserNumber,
  };
}

class ReplySnapshot {
  const ReplySnapshot({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.type,
    required this.text,
    this.imageUrl,
    this.isDeleted = false,
  });
  factory ReplySnapshot.fromJson(Map<String, dynamic> json) => ReplySnapshot(
    messageId: json['messageId'] as String,
    senderId: json['senderId'] as String,
    senderName: json['senderName'] as String? ?? '',
    type: json['type'] as String? ?? 'text',
    text: json['text'] as String? ?? '',
    imageUrl: json['imageUrl'] as String?,
    isDeleted: json['isDeleted'] == true,
  );
  factory ReplySnapshot.fromMessage(ChatMessage message) => ReplySnapshot(
    messageId: message.id,
    senderId: message.senderId,
    senderName: message.senderName,
    type: message.type,
    text: message.text.length > 120
        ? message.text.substring(0, 120)
        : message.text,
    imageUrl: message.imageUrl,
    isDeleted: message.isDeletedForAll,
  );
  final String messageId, senderId, senderName, type, text;
  final String? imageUrl;
  final bool isDeleted;
  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'senderId': senderId,
    'senderName': senderName,
    'type': type,
    'text': text,
    'imageUrl': imageUrl,
    'isDeleted': isDeleted,
  };
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.idempotencyKey,
    required this.roomId,
    required this.senderId,
    required this.senderName,
    required this.type,
    required this.text,
    required this.createdAt,
    this.peerUserId,
    this.senderAvatarUrl,
    this.imageUrl,
    this.replyTo,
    this.status = 'sent',
    this.isEdited = false,
    this.isDeletedForAll = false,
    this.deliveredAt,
    this.seenAt,
    this.uploadBytes,
    this.uploadFilename,
    this.messageSeq,
    this.deliveredByCursor = false,
    this.seenByCursor = false,
    this.enqueueOrder,
    this.retryCount = 0,
    this.nextAttemptAt,
    this.lastErrorCode,
    this.lastErrorText,
    this.outcomeUnknown = false,
    this.outboxPaused = false,
  });
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: (json['_id'] ?? json['id']) as String,
    idempotencyKey: json['idempotencyKey'] as String,
    roomId: json['roomId'] as String,
    peerUserId: json['peerUserId'] as String?,
    senderId: json['senderId'] as String,
    senderName: json['senderName'] as String? ?? '',
    senderAvatarUrl: json['senderAvatarUrl'] as String?,
    type: json['type'] as String? ?? 'text',
    text: json['text'] as String? ?? '',
    imageUrl: json['imageUrl'] as String?,
    replyTo: json['replyTo'] == null
        ? null
        : ReplySnapshot.fromJson(jsonMap(json['replyTo'])),
    status: json['status'] as String? ?? 'sent',
    isEdited: json['isEdited'] == true,
    isDeletedForAll: json['isDeletedForAll'] == true,
    deliveredAt: parseTime(json['deliveredAt']),
    seenAt: parseTime(json['seenAt']),
    createdAt: parseTime(json['createdAt'])!,
    messageSeq: (json['messageSeq'] as num?)?.toInt(),
    deliveredByCursor: json['deliveredByCursor'] == true,
    seenByCursor: json['seenByCursor'] == true,
    enqueueOrder: (json['enqueueOrder'] as num?)?.toInt(),
    retryCount: intValue(json['retryCount']),
    nextAttemptAt: parseTime(json['nextAttemptAt']),
    lastErrorCode: json['lastErrorCode'] as String?,
    lastErrorText: json['lastErrorText'] as String?,
    outcomeUnknown: json['outcomeUnknown'] == true,
    outboxPaused: json['outboxPaused'] == true,
  );
  final String id,
      idempotencyKey,
      roomId,
      senderId,
      senderName,
      type,
      text,
      status;
  final String? peerUserId, senderAvatarUrl, imageUrl;
  final ReplySnapshot? replyTo;
  final bool isEdited, isDeletedForAll;
  final DateTime? deliveredAt, seenAt;
  final DateTime createdAt;
  final Uint8List? uploadBytes;
  final String? uploadFilename;
  final int? messageSeq;
  final bool deliveredByCursor, seenByCursor;
  final int? enqueueOrder;
  final int retryCount;
  final DateTime? nextAttemptAt;
  final String? lastErrorCode, lastErrorText;
  final bool outcomeUnknown, outboxPaused;
  bool get isSeen => seenAt != null || (status == 'sent' && seenByCursor);
  bool get isDelivered =>
      deliveredAt != null || (status == 'sent' && deliveredByCursor) || isSeen;
  Map<String, dynamic> toJson() => {
    'id': id,
    'idempotencyKey': idempotencyKey,
    'roomId': roomId,
    'peerUserId': peerUserId,
    'senderId': senderId,
    'senderName': senderName,
    'senderAvatarUrl': senderAvatarUrl,
    'type': type,
    'text': text,
    'imageUrl': imageUrl,
    'replyTo': replyTo?.toJson(),
    'status': status,
    'isEdited': isEdited,
    'isDeletedForAll': isDeletedForAll,
    'deliveredAt': deliveredAt?.toIso8601String(),
    'seenAt': seenAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'messageSeq': messageSeq,
    'deliveredByCursor': deliveredByCursor,
    'seenByCursor': seenByCursor,
    'enqueueOrder': enqueueOrder,
    'retryCount': retryCount,
    'nextAttemptAt': nextAttemptAt?.toIso8601String(),
    'lastErrorCode': lastErrorCode,
    'lastErrorText': lastErrorText,
    'outcomeUnknown': outcomeUnknown,
    'outboxPaused': outboxPaused,
  };
  ChatMessage copyWith({
    String? roomId,
    String? status,
    DateTime? deliveredAt,
    DateTime? seenAt,
    ReplySnapshot? replyTo,
    String? imageUrl,
    bool clearUpload = false,
    bool? deliveredByCursor,
    bool? seenByCursor,
    int? enqueueOrder,
    int? retryCount,
    DateTime? nextAttemptAt,
    String? lastErrorCode,
    String? lastErrorText,
    bool? outcomeUnknown,
    bool? outboxPaused,
    bool clearError = false,
    bool clearRetryAt = false,
    bool clearOutbox = false,
  }) => ChatMessage(
    id: id,
    idempotencyKey: idempotencyKey,
    roomId: roomId ?? this.roomId,
    peerUserId: peerUserId,
    senderId: senderId,
    senderName: senderName,
    senderAvatarUrl: senderAvatarUrl,
    type: type,
    text: text,
    createdAt: createdAt,
    imageUrl: imageUrl ?? this.imageUrl,
    replyTo: replyTo ?? this.replyTo,
    status: status ?? this.status,
    isEdited: isEdited,
    isDeletedForAll: isDeletedForAll,
    deliveredAt: deliveredAt ?? this.deliveredAt,
    seenAt: seenAt ?? this.seenAt,
    uploadBytes: clearUpload ? null : uploadBytes,
    uploadFilename: clearUpload ? null : uploadFilename,
    messageSeq: messageSeq,
    deliveredByCursor: deliveredByCursor ?? this.deliveredByCursor,
    seenByCursor: seenByCursor ?? this.seenByCursor,
    enqueueOrder: clearOutbox ? null : enqueueOrder ?? this.enqueueOrder,
    retryCount: clearOutbox ? 0 : retryCount ?? this.retryCount,
    nextAttemptAt: clearOutbox || clearRetryAt
        ? null
        : nextAttemptAt ?? this.nextAttemptAt,
    lastErrorCode: clearOutbox || clearError
        ? null
        : lastErrorCode ?? this.lastErrorCode,
    lastErrorText: clearOutbox || clearError
        ? null
        : lastErrorText ?? this.lastErrorText,
    outcomeUnknown: !clearOutbox && (outcomeUnknown ?? this.outcomeUnknown),
    outboxPaused: !clearOutbox && (outboxPaused ?? this.outboxPaused),
  );
}

class ChatRoom {
  const ChatRoom({
    required this.roomId,
    required this.roomType,
    required this.displayTitle,
    required this.sortTimestamp,
    this.peerUserId,
    this.displayAvatarUrl,
    this.pinAt,
    this.isMuted = false,
    this.unreadCount = 0,
    this.clearedAt,
    this.deletedAt,
    this.roomPts = 0,
    this.msgPts = 0,
    this.lastHistoryEditPts = 0,
    this.messagesSyncedPts = 0,
    this.lastMessage,
    this.contentPts,
    this.peerDeliveredSeq = 0,
    this.peerSeenSeq = 0,
    this.ownDeliveredSeq = 0,
    this.ownSeenSeq = 0,
    this.receiptProtocol = 'legacy',
  });
  factory ChatRoom.fromJson(Map<String, dynamic> json) => ChatRoom(
    roomId: (json['roomId'] ?? json['_id']) as String,
    roomType: json['roomType'] as String? ?? 'direct',
    peerUserId: json['peerUserId'] as String?,
    displayTitle: json['displayTitle'] as String? ?? '',
    displayAvatarUrl: json['displayAvatarUrl'] as String?,
    pinAt: parseTime(json['pinAt']),
    isMuted: json['isMuted'] == true,
    unreadCount: intValue(json['unreadCount']),
    clearedAt: parseTime(json['clearedAt']),
    deletedAt: parseTime(json['deletedAt']),
    sortTimestamp: parseTime(json['sortTimestamp'])!,
    roomPts: intValue(json['roomPts']),
    msgPts: intValue(json['msgPts']),
    lastHistoryEditPts: intValue(json['lastHistoryEditPts']),
    messagesSyncedPts: intValue(json['messagesSyncedPts']),
    contentPts: (json['contentPts'] as num?)?.toInt(),
    peerDeliveredSeq: intValue(json['peerDeliveredSeq']),
    peerSeenSeq: intValue(json['peerSeenSeq']),
    ownDeliveredSeq: intValue(json['ownDeliveredSeq']),
    ownSeenSeq: intValue(json['ownSeenSeq']),
    receiptProtocol: json['receiptProtocol'] as String? ?? 'legacy',
    lastMessage: json['lastMessage'] == null
        ? null
        : ChatMessage.fromJson(jsonMap(json['lastMessage'])),
  );
  final String roomId, roomType, displayTitle;
  final String? peerUserId, displayAvatarUrl;
  final bool isMuted;
  final int unreadCount, roomPts, msgPts, lastHistoryEditPts, messagesSyncedPts;
  final DateTime sortTimestamp;
  final DateTime? pinAt, clearedAt, deletedAt;
  final ChatMessage? lastMessage;
  final int? contentPts;
  final int peerDeliveredSeq, peerSeenSeq, ownDeliveredSeq, ownSeenSeq;
  final String receiptProtocol;
  Map<String, dynamic> toJson() => {
    'roomId': roomId,
    'roomType': roomType,
    'peerUserId': peerUserId,
    'displayTitle': displayTitle,
    'displayAvatarUrl': displayAvatarUrl,
    'pinAt': pinAt?.toIso8601String(),
    'isMuted': isMuted,
    'unreadCount': unreadCount,
    'clearedAt': clearedAt?.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
    'sortTimestamp': sortTimestamp.toIso8601String(),
    'roomPts': roomPts,
    'msgPts': msgPts,
    'lastHistoryEditPts': lastHistoryEditPts,
    'messagesSyncedPts': messagesSyncedPts,
    'lastMessage': lastMessage?.toJson(),
    'contentPts': contentPts,
    'peerDeliveredSeq': peerDeliveredSeq,
    'peerSeenSeq': peerSeenSeq,
    'ownDeliveredSeq': ownDeliveredSeq,
    'ownSeenSeq': ownSeenSeq,
    'receiptProtocol': receiptProtocol,
  };
}

/// Boundaries are outgoing message creation times, not receipt event times.
/// A gap means the latest page is authoritative but older cache cannot be
/// certified by a timestamp boundary (for example, concurrent same-ms sends).
class ReceiptWatermarks {
  const ReceiptWatermarks({
    this.deliveredThrough,
    this.seenThrough,
    this.hasGaps = false,
  });
  factory ReceiptWatermarks.fromJson(Map<String, dynamic> json) =>
      ReceiptWatermarks(
        deliveredThrough: parseTime(json['deliveredThrough']),
        seenThrough: parseTime(json['seenThrough']),
        hasGaps: json['hasGaps'] == true,
      );
  final DateTime? deliveredThrough, seenThrough;
  final bool hasGaps;
}

/// Durable pending account receipt work. Null targets have no outstanding work.
class ReceiptTarget {
  const ReceiptTarget({
    required this.roomId,
    this.deliveredThroughSeq,
    this.seenThroughSeq,
    this.deliveredThroughTimestamp,
    this.seenThroughTimestamp,
    this.receiptProtocol = 'legacy',
  });
  final String roomId;
  final int? deliveredThroughSeq, seenThroughSeq;
  final DateTime? deliveredThroughTimestamp, seenThroughTimestamp;
  final String receiptProtocol;
}

ChatMessage applySequenceReceipts(
  ChatMessage message,
  String myUserId,
  int deliveredSeq,
  int seenSeq,
) {
  final seq = message.messageSeq;
  if (message.senderId != myUserId || message.status != 'sent' || seq == null) {
    return message;
  }
  return message.copyWith(
    deliveredByCursor:
        message.deliveredByCursor || seq <= deliveredSeq || seq <= seenSeq,
    seenByCursor: message.seenByCursor || seq <= seenSeq,
  );
}

String encodeJson(Object? object) => jsonEncode(object);

/// Applies live mutations to a historical jump slice without merging it into
/// the latest SQLite window. New tail messages do not move the jump viewport.
List<ChatMessage> reconcileJumpSlice(
  List<ChatMessage> messages,
  Map<String, dynamic> payload, {
  String? myUserId,
}) {
  final raw = payload['updatedMessage'];
  final updated = raw == null ? null : ChatMessage.fromJson(jsonMap(raw));
  final quote = payload['quoteUpdate'] == null
      ? updated != null && (updated.isDeletedForAll || updated.isEdited)
            ? ReplySnapshot.fromMessage(updated)
            : null
      : ReplySnapshot.fromJson(jsonMap(payload['quoteUpdate']));
  final visible =
      updated != null && payload['eventType'] == 'message_deleted_me'
      ? messages.where((message) => message.id != updated.id)
      : messages;
  return visible.map((message) {
    if (myUserId != null) {
      message = applySequenceReceipts(
        message,
        myUserId,
        intValue(payload['peerDeliveredSeq']),
        intValue(payload['peerSeenSeq']),
      );
      final event = payload['eventType'];
      final boundary = parseTime(payload['actionTimestamp']);
      if (payload['sequenceReceipt'] != true &&
          boundary != null &&
          (event == 'room_delivered' || event == 'room_peer_seen') &&
          message.senderId == myUserId &&
          message.status == 'sent' &&
          message.messageSeq == null &&
          !message.createdAt.isAfter(boundary)) {
        message = message.copyWith(
          deliveredByCursor: true,
          seenByCursor: message.seenByCursor || event == 'room_peer_seen',
        );
      }
    }
    if (updated != null && message.id == updated.id) {
      return updated.copyWith(
        deliveredAt: updated.deliveredAt ?? message.deliveredAt,
        seenAt: updated.seenAt ?? message.seenAt,
        deliveredByCursor:
            updated.deliveredByCursor || message.deliveredByCursor,
        seenByCursor: updated.seenByCursor || message.seenByCursor,
      );
    }
    if (quote != null && message.replyTo?.messageId == quote.messageId) {
      return message.copyWith(replyTo: quote);
    }
    return message;
  }).toList();
}
