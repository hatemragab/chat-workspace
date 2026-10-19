import { Schema, InferSchemaType, Types } from "mongoose";

const objectId = Schema.Types.ObjectId;
export const UserSchema = new Schema(
  {
    username: { type: String, required: true },
    email: { type: String, required: true },
    passwordHash: { type: String, required: true, select: false },
    displayName: { type: String, required: true },
    avatarUrl: { type: String, default: null },
    isDebugUser: { type: Boolean, default: false },
    debugUserNumber: { type: Number, default: null },
    pts: { type: Number, default: 0 },
    lastSeenAt: { type: Date, default: Date.now },
  },
  { timestamps: true, collection: "users" },
);
UserSchema.index({ username: 1 }, { unique: true });
UserSchema.index({ email: 1 }, { unique: true });
UserSchema.index({ debugUserNumber: 1 });

export const RoomSchema = new Schema(
  {
    type: { type: String, enum: ["direct", "group"], required: true },
    directPairKey: { type: String, default: undefined },
    title: { type: String, default: null },
    avatarUrl: { type: String, default: null },
    createdBy: { type: objectId, required: true },
    participantIds: { type: [objectId], required: true },
    messageSeq: { type: Number, default: 0, min: 0 },
  },
  { timestamps: true, collection: "rooms" },
);
RoomSchema.index(
  { directPairKey: 1 },
  {
    unique: true,
    partialFilterExpression: {
      type: "direct",
      directPairKey: { $type: "string" },
    },
  },
);
RoomSchema.index({ participantIds: 1 });

export const RoomMemberSchema = new Schema(
  {
    roomId: { type: objectId, required: true },
    userId: { type: objectId, required: true },
    roomType: { type: String, enum: ["direct", "group"], required: true },
    peerUserId: { type: objectId, default: null },
    displayTitle: { type: String, required: true },
    displayAvatarUrl: { type: String, default: null },
    pinAt: { type: Date, default: null },
    isMuted: { type: Boolean, default: false },
    unreadCount: { type: Number, default: 0 },
    clearedAt: { type: Date, default: null },
    deletedAt: { type: Date, default: null },
    lastMessageId: { type: objectId, default: null },
    sortTimestamp: { type: Date, required: true },
    roomPts: { type: Number, default: 0 },
    msgPts: { type: Number, default: 0 },
    contentPts: { type: Number, default: 0 },
    headSeq: { type: Number, default: 0 },
    ownDeliveredSeq: { type: Number, default: 0 },
    ownSeenSeq: { type: Number, default: 0 },
    peerDeliveredSeq: { type: Number, default: 0 },
    peerSeenSeq: { type: Number, default: 0 },
    lastHistoryEditPts: { type: Number, default: 0 },
  },
  {
    timestamps: { createdAt: false, updatedAt: true },
    collection: "room_members",
  },
);
RoomMemberSchema.index({
  userId: 1,
  deletedAt: 1,
  pinAt: -1,
  sortTimestamp: -1,
  roomId: -1,
});
RoomMemberSchema.index({ roomId: 1, userId: 1 }, { unique: true });
RoomMemberSchema.index({ userId: 1, roomPts: 1 });

const ReplySchema = new Schema(
  {
    messageId: { type: objectId, required: true },
    senderId: { type: objectId, required: true },
    senderName: { type: String, required: true },
    type: { type: String, enum: ["text", "image"], required: true },
    text: { type: String, default: "" },
    imageUrl: { type: String, default: null },
    isDeleted: { type: Boolean, default: false },
  },
  { _id: false },
);
export const MessageSchema = new Schema(
  {
    idempotencyKey: { type: String, required: true },
    roomId: { type: objectId, required: true },
    roomType: { type: String, enum: ["direct", "group"], required: true },
    messageSeq: { type: Number, default: null, min: 1 },
    senderId: { type: objectId, required: true },
    senderName: { type: String, required: true },
    senderAvatarUrl: { type: String, default: null },
    type: { type: String, enum: ["text", "image"], required: true },
    text: { type: String, default: "" },
    imageUrl: { type: String, default: null },
    replyTo: { type: ReplySchema, default: null },
    isEdited: { type: Boolean, default: false },
    editedAt: { type: Date, default: null },
    isDeletedForAll: { type: Boolean, default: false },
    deletedForUsers: { type: [objectId], default: [] },
    deliveredAt: { type: Date, default: null },
    seenAt: { type: Date, default: null },
  },
  { timestamps: true, collection: "messages" },
);
MessageSchema.index({ senderId: 1, idempotencyKey: 1 }, { unique: true });
MessageSchema.index({ roomId: 1, createdAt: -1, _id: -1 });
MessageSchema.index(
  { roomId: 1, messageSeq: 1 },
  {
    unique: true,
    partialFilterExpression: { messageSeq: { $type: "number" } },
  },
);
MessageSchema.index({ roomId: 1, senderId: 1, seenAt: 1, deliveredAt: 1 });
MessageSchema.index({ roomId: 1, "replyTo.messageId": 1 });

// Media authorization starts with an exact retained path, not a room history scan.
MessageSchema.index(
  { imageUrl: 1 },
  {
    name: "media_image_reference",
    partialFilterExpression: { imageUrl: { $type: "string" } },
  },
);
MessageSchema.index(
  { "replyTo.imageUrl": 1 },
  {
    name: "media_quote_reference",
    partialFilterExpression: { "replyTo.imageUrl": { $type: "string" } },
  },
);
// Receipt explain over 20,000 rows showed 2,002/4,002 boundary reads and
// 1,000/2,000 document gap scans. These direct-only partial indexes bound both.
for (const field of ["deliveredAt", "seenAt"] as const) {
  MessageSchema.index(
    { roomId: 1, senderId: 1, createdAt: -1, _id: -1 },
    {
      name: `direct_${field}_boundary`,
      partialFilterExpression: {
        roomType: "direct",
        [field]: { $type: "date" },
      },
    },
  );
  MessageSchema.index(
    { roomId: 1, senderId: 1, createdAt: -1, _id: -1 },
    {
      name: `direct_${field}_gap`,
      partialFilterExpression: { roomType: "direct", [field]: null },
    },
  );
}

export const UploadSchema = new Schema(
  {
    filename: { type: String, required: true },
    ownerId: { type: objectId, required: true },
    mime: { type: String, required: true },
    bytes: { type: Number, required: true },
    width: { type: Number, required: true },
    height: { type: Number, required: true },
    frames: { type: Number, required: true },
    attachedAt: { type: Date, default: null },
    deletedAt: { type: Date, default: null },
    orphanEligibleAt: { type: Date, required: true },
    state: {
      type: String,
      enum: ["retained", "deleting", "deleted"],
      default: "retained",
    },
  },
  { timestamps: true, collection: "uploads" },
);
UploadSchema.index({ filename: 1 }, { unique: true });
UploadSchema.index({ attachedAt: 1, orphanEligibleAt: 1 });
export type Upload = InferSchemaType<typeof UploadSchema> & {
  _id: Types.ObjectId;
};

export type User = InferSchemaType<typeof UserSchema> & { _id: Types.ObjectId };
export type Room = InferSchemaType<typeof RoomSchema> & { _id: Types.ObjectId };
export type RoomMember = InferSchemaType<typeof RoomMemberSchema> & {
  _id: Types.ObjectId;
};
export type Message = InferSchemaType<typeof MessageSchema> & {
  _id: Types.ObjectId;
};
export type EventType =
  | "message_new"
  | "message_edited"
  | "message_deleted_all"
  | "message_deleted_me"
  | "room_delivered"
  | "room_peer_seen"
  | "room_unread_cleared"
  | "room_preferences"
  | "room_created";
export const iso = (d: Date | null | undefined): string | null =>
  d ? new Date(d).toISOString() : null;
export function userDto(user: User) {
  return {
    _id: user._id.toString(),
    id: user._id.toString(),
    username: user.username,
    email: user.email,
    displayName: user.displayName,
    avatarUrl: user.avatarUrl,
    isDebugUser: user.isDebugUser,
    debugUserNumber: user.debugUserNumber,
    pts: user.pts,
    lastSeenAt: iso(user.lastSeenAt),
  };
}
export function messageDto(message: Message) {
  return {
    _id: message._id.toString(),
    id: message._id.toString(),
    idempotencyKey: message.idempotencyKey,
    roomId: message.roomId.toString(),
    roomType: message.roomType,
    messageSeq: message.messageSeq ?? null,
    senderId: message.senderId.toString(),
    senderName: message.senderName,
    senderAvatarUrl: message.senderAvatarUrl,
    type: message.type,
    text: message.text,
    imageUrl: message.imageUrl,
    replyTo: message.replyTo
      ? {
          messageId: message.replyTo.messageId.toString(),
          senderId: message.replyTo.senderId.toString(),
          senderName: message.replyTo.senderName,
          type: message.replyTo.type,
          text: message.replyTo.text,
          imageUrl: message.replyTo.imageUrl,
          isDeleted: message.replyTo.isDeleted,
        }
      : null,
    isEdited: message.isEdited,
    editedAt: iso(message.editedAt),
    isDeletedForAll: message.isDeletedForAll,
    deliveredAt: iso(message.deliveredAt),
    seenAt: iso(message.seenAt),
    createdAt: iso(message.createdAt),
    updatedAt: iso(message.updatedAt),
  };
}
export type FullMessageDto = ReturnType<typeof messageDto>;
export type ReplySnapshotDto = NonNullable<FullMessageDto["replyTo"]>;
export function replySnapshotDto(message: Message): ReplySnapshotDto {
  return {
    messageId: message._id.toString(),
    senderId: message.senderId.toString(),
    senderName: message.senderName,
    type: message.type,
    text: message.text.slice(0, 120),
    imageUrl: message.imageUrl,
    isDeleted: message.isDeletedForAll,
  };
}
export interface ReceiptSummaryDto {
  deliveredThrough: string | null;
  seenThrough: string | null;
  hasGaps: boolean;
}
export interface HydratedRoomPayload {
  roomId: string;
  roomType: "direct" | "group";
  peerUserId: string | null;
  displayTitle: string;
  displayAvatarUrl: string | null;
  pinAt: string | null;
  isMuted: boolean;
  unreadCount: number;
  clearedAt: string | null;
  deletedAt: string | null;
  sortTimestamp: string;
  roomPts: number;
  msgPts: number;
  contentPts?: number;
  headSeq?: number;
  ownDeliveredSeq?: number;
  ownSeenSeq?: number;
  peerDeliveredSeq?: number;
  peerSeenSeq?: number;
  /** Present only for a receipt mutation restricted to sequenced messages. */
  sequenceReceipt?: boolean;
  receiptProtocol?: "legacy" | "sequence";
  lastHistoryEditPts: number;
  lastMessage: FullMessageDto | null;
  updatedMessage?: FullMessageDto | null;
  quoteUpdate?: ReplySnapshotDto;
  eventType: EventType;
  actionTimestamp: string;
}
