import 'dart:convert';

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
  };
  ChatMessage copyWith({
    String? roomId,
    String? status,
    DateTime? deliveredAt,
    DateTime? seenAt,
    ReplySnapshot? replyTo,
  }) => ChatMessage.fromJson({
    ...toJson(),
    'roomId': ?roomId,
    'status': ?status,
    if (deliveredAt != null) 'deliveredAt': deliveredAt.toIso8601String(),
    if (seenAt != null) 'seenAt': seenAt.toIso8601String(),
    if (replyTo != null) 'replyTo': replyTo.toJson(),
  });
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
  };
}

String encodeJson(Object? object) => jsonEncode(object);

/// Applies live mutations to a historical jump slice without merging it into
/// the latest SQLite window. New tail messages do not move the jump viewport.
List<ChatMessage> reconcileJumpSlice(
  List<ChatMessage> messages,
  Map<String, dynamic> payload,
) {
  final raw = payload['updatedMessage'];
  if (raw == null) return messages;
  final updated = ChatMessage.fromJson(jsonMap(raw));
  if (payload['eventType'] == 'message_deleted_me') {
    return messages.where((message) => message.id != updated.id).toList();
  }
  return messages.map((message) {
    if (message.id == updated.id) return updated;
    if ((updated.isDeletedForAll || updated.isEdited) &&
        message.replyTo?.messageId == updated.id) {
      return message.copyWith(replyTo: ReplySnapshot.fromMessage(updated));
    }
    return message;
  }).toList();
}
