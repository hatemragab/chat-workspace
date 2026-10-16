import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from "@nestjs/common";
import { ClientSession, FilterQuery, Types } from "mongoose";
import { DatabaseService } from "../infrastructure/database.service";
import { RedisSyncService } from "../infrastructure/redis-sync.service";
import { CentrifugoService } from "../infrastructure/centrifugo.service";
import {
  EventType,
  HydratedRoomPayload,
  Message,
  Room,
  RoomMember,
  iso,
  messageDto,
  userDto,
} from "../models";
import {
  BoundaryDto,
  DeltaQuery,
  EditMessageDto,
  GroupDto,
  MessagesQuery,
  PreferencesDto,
  RoomsQuery,
  SendMessageDto,
} from "./dto";

const DELETED_TEXT = "🚫 This message was deleted";
const MESSAGE_EVENTS = new Set<EventType>([
  "message_new",
  "message_edited",
  "message_deleted_all",
  "message_deleted_me",
  "room_delivered",
  "room_peer_seen",
]);
const HISTORY_EVENTS = new Set<EventType>([
  "message_edited",
  "message_deleted_all",
  "message_deleted_me",
]);
const oid = (id: string) => new Types.ObjectId(id);
export function directPairKey(first: string, second: string) {
  return [first, second].sort().join("_");
}
export function cursorBefore(
  dateField: string,
  idField: string,
  timestamp: string,
  id: string,
) {
  const date = new Date(timestamp);
  return {
    $or: [
      { [dateField]: { $lt: date } },
      { [dateField]: date, [idField]: { $lt: oid(id) } },
    ],
  };
}
interface PendingEvent {
  userId: string;
  room: HydratedRoomPayload;
}

@Injectable()
export class ChatService {
  private readonly logger = new Logger(ChatService.name);
  constructor(
    private readonly db: DatabaseService,
    private readonly redis: RedisSyncService,
    private readonly centrifugo: CentrifugoService,
  ) {}

  async membership(
    roomId: string,
    userId: string,
    session?: ClientSession,
  ): Promise<RoomMember> {
    const member = await this.db.members
      .findOne({ roomId: oid(roomId), userId: oid(userId) })
      .session(session ?? null)
      .lean();
    if (!member) throw new ForbiddenException("Room membership required");
    return member;
  }
  private async hydrate(
    member: RoomMember,
    eventType: EventType = "room_preferences",
    actionTimestamp = new Date(),
    updated?: Message | null,
    session?: ClientSession,
    lookedUp?: Message | null,
  ): Promise<HydratedRoomPayload> {
    let lastMessage = lookedUp;
    if (lastMessage === undefined)
      lastMessage = member.lastMessageId
        ? await this.db.messages
            .findOne({
              _id: member.lastMessageId,
              deletedForUsers: { $nin: [member.userId] },
              ...(member.clearedAt
                ? { createdAt: { $gt: member.clearedAt } }
                : {}),
            })
            .session(session ?? null)
            .lean()
        : null;
    return {
      roomId: member.roomId.toString(),
      roomType: member.roomType as "direct" | "group",
      peerUserId: member.peerUserId?.toString() ?? null,
      displayTitle: member.displayTitle,
      displayAvatarUrl: member.displayAvatarUrl ?? null,
      pinAt: iso(member.pinAt),
      isMuted: member.isMuted,
      unreadCount: member.unreadCount,
      clearedAt: iso(member.clearedAt),
      deletedAt: iso(member.deletedAt),
      sortTimestamp: member.sortTimestamp.toISOString(),
      roomPts: member.roomPts,
      msgPts: member.msgPts,
      lastHistoryEditPts: member.lastHistoryEditPts,
      lastMessage: lastMessage ? messageDto(lastMessage) : null,
      ...(updated === undefined
        ? {}
        : { updatedMessage: updated ? messageDto(updated) : null }),
      eventType,
      actionTimestamp: actionTimestamp.toISOString(),
    };
  }
  private async bump(
    userId: string,
    roomId: string,
    type: EventType,
    session: ClientSession,
    events: PendingEvent[],
    changes: Record<string, unknown> = {},
    updated?: Message | null,
    timestamp = new Date(),
  ) {
    const user = await this.db.users
      .findOneAndUpdate(
        { _id: oid(userId) },
        { $inc: { pts: 1 } },
        { new: true, session },
      )
      .lean();
    if (!user) throw new NotFoundException("Participant no longer exists");
    const revisions = {
      roomPts: user.pts,
      ...(MESSAGE_EVENTS.has(type) ? { msgPts: user.pts } : {}),
      ...(HISTORY_EVENTS.has(type) ? { lastHistoryEditPts: user.pts } : {}),
    };
    const member = await this.db.members
      .findOneAndUpdate(
        { userId: oid(userId), roomId: oid(roomId) },
        { $set: { ...changes, ...revisions } },
        { new: true, session },
      )
      .lean();
    if (!member) throw new ForbiddenException("Room membership required");
    const room = await this.hydrate(member, type, timestamp, updated, session);
    events.push({ userId, room });
    return room;
  }
  private async transaction<T>(
    work: (session: ClientSession, events: PendingEvent[]) => Promise<T>,
  ): Promise<T> {
    const session = await this.db.connection.startSession();
    let events: PendingEvent[] = [];
    let result: T | undefined;
    try {
      await session.withTransaction(
        async () => {
          events = [];
          result = await work(session, events);
        },
        { readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } },
      );
    } finally {
      await session.endSession();
    }
    // MongoDB is authoritative. A failed cache or publication cannot turn a committed send into an HTTP failure.
    await Promise.all(
      events.map(async (event) => {
        try {
          const epoch = await this.redis.upsert(event.userId, event.room);
          await this.centrifugo.publish(event.userId, epoch, event.room);
        } catch {
          await this.redis.invalidate(event.userId);
          this.logger.warn(
            "Post-commit inbox cache update failed; next reconciliation requires a full sync",
          );
        }
      }),
    );
    return result as T;
  }

  async rooms(userId: string, query: RoomsQuery) {
    if (!!query.beforeRoomId !== !!query.beforeSortTimestamp)
      throw new BadRequestException("Both room cursor fields are required");
    const session = await this.db.connection.startSession();
    let pts = 0;
    let rooms: HydratedRoomPayload[] = [];
    let nextCursor: {
      beforeSortTimestamp: string;
      beforeRoomId: string;
    } | null = null;
    try {
      await session.withTransaction(
        async () => {
          pts = (await this.db.users.findById(userId).session(session).lean())!
            .pts;
          const base = { userId: oid(userId), deletedAt: null };
          const aggregate = async (
            match: Record<string, unknown>,
            sort: Record<string, 1 | -1>,
            limit?: number,
          ) => {
            const rows = await this.db.members
              .aggregate<RoomMember & { lastMessages: Message[] }>([
                { $match: match },
                { $sort: sort },
                ...(limit ? [{ $limit: limit }] : []),
                {
                  $lookup: {
                    from: "messages",
                    localField: "lastMessageId",
                    foreignField: "_id",
                    as: "lastMessages",
                  },
                },
              ])
              .session(session);
            return rows;
          };
          const pinned = query.beforeRoomId
            ? []
            : await aggregate(
                { ...base, pinAt: { $ne: null } },
                { pinAt: -1, roomId: -1 },
              );
          const unpinned = await aggregate(
            {
              ...base,
              pinAt: null,
              ...(query.beforeRoomId
                ? cursorBefore(
                    "sortTimestamp",
                    "roomId",
                    query.beforeSortTimestamp!,
                    query.beforeRoomId,
                  )
                : {}),
            },
            { sortTimestamp: -1, roomId: -1 },
            query.limit + 1,
          );
          const hasMore = unpinned.length > query.limit;
          const page = unpinned.slice(0, query.limit);
          const last = page.at(-1);
          nextCursor =
            hasMore && last
              ? {
                  beforeSortTimestamp: last.sortTimestamp.toISOString(),
                  beforeRoomId: last.roomId.toString(),
                }
              : null;
          rooms = [];
          for (const member of [...pinned, ...page]) {
            const lastMsg = member.lastMessages[0];
            const visible =
              lastMsg &&
              !lastMsg.deletedForUsers.some((id) => id.equals(member.userId)) &&
              (!member.clearedAt || lastMsg.createdAt > member.clearedAt);
            rooms.push(
              await this.hydrate(
                member,
                "room_preferences",
                new Date(),
                undefined,
                session,
                visible ? lastMsg : null,
              ),
            );
          }
        },
        { readConcern: { level: "snapshot" } },
      );
    } finally {
      await session.endSession();
    }
    const epoch = await this.redis.ensureEpoch(userId, pts);
    return { pts, epoch, rooms, nextCursor };
  }
  async delta(userId: string, query: DeltaQuery) {
    const delta = await this.redis.delta(userId, query.sincePts, query.epoch);
    if (delta.requiresFullSync) return delta;
    // Fence committed-but-not-yet-cached mutations and out-of-order post-commit writes.
    const user = await this.db.users.findById(userId).lean();
    if (!user || user.pts !== delta.pts) return { requiresFullSync: true };
    const changed = await this.db.members
      .find({ userId: oid(userId), roomPts: { $gt: query.sincePts } })
      .select("roomId roomPts")
      .lean();
    const revisions = new Map(
      delta.rooms.map((room) => [room.roomId, room.roomPts]),
    );
    if (
      changed.some(
        (member) => revisions.get(member.roomId.toString()) !== member.roomPts,
      )
    )
      return { requiresFullSync: true };
    return delta;
  }
  async directPeer(userId: string, peerId: string) {
    if (userId === peerId) throw new BadRequestException("Choose another user");
    const peer = await this.db.users.findById(peerId).lean();
    if (!peer) throw new NotFoundException("Peer not found");
    const room = await this.db.rooms
      .findOne({ type: "direct", directPairKey: directPairKey(userId, peerId) })
      .lean();
    return {
      exists: !!room,
      room: room
        ? await this.hydrate(await this.membership(room._id.toString(), userId))
        : null,
      peerUser: {
        _id: peer._id.toString(),
        id: peer._id.toString(),
        username: peer.username,
        displayName: peer.displayName,
        avatarUrl: peer.avatarUrl,
      },
    };
  }
  async createGroup(userId: string, dto: GroupDto) {
    if (!dto.title.trim())
      throw new BadRequestException("Group title is required");
    this.validateImagePath(dto.avatarUrl);
    const ids = [...new Set([userId, ...dto.participantIds])];
    return this.transaction(async (session, events) => {
      if (
        (await this.db.users
          .countDocuments({ _id: { $in: ids.map(oid) } })
          .session(session)) !== ids.length
      )
        throw new BadRequestException("Unknown participant");
      const [room] = await this.db.rooms.create(
        [
          {
            type: "group",
            title: dto.title.trim(),
            avatarUrl: dto.avatarUrl ?? null,
            createdBy: oid(userId),
            participantIds: ids.map(oid),
          },
        ],
        { session },
      );
      await this.db.members.insertMany(
        ids.map((id) => ({
          roomId: room._id,
          userId: oid(id),
          roomType: "group",
          displayTitle: room.title,
          displayAvatarUrl: room.avatarUrl,
          sortTimestamp: room.createdAt,
        })),
        { session },
      );
      let own: HydratedRoomPayload | undefined;
      for (const id of ids) {
        const payload = await this.bump(
          id,
          room._id.toString(),
          "room_created",
          session,
          events,
        );
        if (id === userId) own = payload;
      }
      return { room: own! };
    });
  }
  async preferences(userId: string, roomId: string, dto: PreferencesDto) {
    if (dto.pin === undefined && dto.isMuted === undefined)
      throw new BadRequestException("Provide pin or isMuted");
    return this.transaction(async (session, events) => {
      await this.membership(roomId, userId, session);
      return {
        room: await this.bump(
          userId,
          roomId,
          "room_preferences",
          session,
          events,
          {
            ...(dto.pin !== undefined
              ? { pinAt: dto.pin ? new Date() : null }
              : {}),
            ...(dto.isMuted !== undefined ? { isMuted: dto.isMuted } : {}),
          },
        ),
      };
    });
  }
  private validateImagePath(path?: string) {
    if (
      path !== undefined &&
      !/^\/public\/uploads\/[a-zA-Z0-9][a-zA-Z0-9_-]*\.(jpg|jpeg|png|webp|gif)$/i.test(
        path,
      )
    )
      throw new BadRequestException("Image must be a server upload path");
  }
  private async existingSend(userId: string, key: string) {
    const message = await this.db.messages
      .findOne({ senderId: oid(userId), idempotencyKey: key })
      .lean();
    if (!message) return null;
    const member = await this.membership(message.roomId.toString(), userId);
    return { message: messageDto(message), room: await this.hydrate(member) };
  }
  async send(userId: string, dto: SendMessageDto) {
    const existing = await this.existingSend(userId, dto.idempotencyKey);
    if (existing) return existing;
    if (!!dto.roomId === !!dto.peerUserId)
      throw new BadRequestException("Provide either roomId or peerUserId");
    if (dto.type === "text" && !dto.text.trim())
      throw new BadRequestException("Text is required");
    if (dto.type === "image" && !dto.imageUrl)
      throw new BadRequestException("Image URL is required");
    this.validateImagePath(dto.imageUrl);
    if (dto.peerUserId === userId)
      throw new BadRequestException("Choose another user");
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        return await this.transaction(async (session, events) => {
          let room: Room | null = dto.roomId
            ? await this.db.rooms.findById(dto.roomId).session(session).lean()
            : null;
          if (dto.roomId) {
            await this.membership(dto.roomId, userId, session);
            if (!room) throw new NotFoundException("Room not found");
          }
          const sender = await this.db.users
            .findById(userId)
            .session(session)
            .lean();
          if (!sender) throw new NotFoundException("Sender not found");
          if (!dto.roomId) {
            const peer = await this.db.users
              .findById(dto.peerUserId)
              .session(session)
              .lean();
            if (!peer) throw new NotFoundException("Peer not found");
            const pair = directPairKey(userId, peer._id.toString());
            room = await this.db.rooms
              .findOne({ type: "direct", directPairKey: pair })
              .session(session)
              .lean();
            if (!room) {
              const [created] = await this.db.rooms.create(
                [
                  {
                    type: "direct",
                    directPairKey: pair,
                    createdBy: sender._id,
                    participantIds: [sender._id, peer._id],
                  },
                ],
                { session },
              );
              room = created.toObject();
              await this.db.members.insertMany(
                [
                  {
                    roomId: room._id,
                    userId: sender._id,
                    roomType: "direct",
                    peerUserId: peer._id,
                    displayTitle: peer.displayName,
                    displayAvatarUrl: peer.avatarUrl,
                    sortTimestamp: room.createdAt,
                  },
                  {
                    roomId: room._id,
                    userId: peer._id,
                    roomType: "direct",
                    peerUserId: sender._id,
                    displayTitle: sender.displayName,
                    displayAvatarUrl: sender.avatarUrl,
                    sortTimestamp: room.createdAt,
                  },
                ],
                { session },
              );
            }
            await this.membership(room._id.toString(), userId, session);
          }
          let replyTo: Message["replyTo"] = null;
          if (dto.replyToMessageId) {
            const member = await this.membership(
              room!._id.toString(),
              userId,
              session,
            );
            const target = await this.db.messages
              .findOne({
                _id: oid(dto.replyToMessageId),
                roomId: room!._id,
                deletedForUsers: { $nin: [sender._id] },
                ...(member.clearedAt
                  ? { createdAt: { $gt: member.clearedAt } }
                  : {}),
              })
              .session(session)
              .lean();
            if (!target)
              throw new BadRequestException(
                "Reply target is not visible in this room",
              );
            replyTo = {
              messageId: target._id,
              senderId: target.senderId,
              senderName: target.senderName,
              type: target.type,
              text: target.text.slice(0, 120),
              imageUrl: target.imageUrl,
              isDeleted: target.isDeletedForAll,
            };
          }
          const [written] = await this.db.messages.create(
            [
              {
                idempotencyKey: dto.idempotencyKey,
                roomId: room!._id,
                roomType: room!.type,
                senderId: sender._id,
                senderName: sender.displayName,
                senderAvatarUrl: sender.avatarUrl,
                type: dto.type,
                text: dto.text,
                imageUrl: dto.type === "image" ? dto.imageUrl : null,
                replyTo,
              },
            ],
            { session },
          );
          const message = written.toObject();
          let own: HydratedRoomPayload | undefined;
          const members = await this.db.members
            .find({ roomId: room!._id })
            .session(session)
            .lean();
          for (const member of members) {
            const id = member.userId.toString();
            const payload = await this.bump(
              id,
              room!._id.toString(),
              "message_new",
              session,
              events,
              {
                lastMessageId: message._id,
                sortTimestamp: message.createdAt,
                deletedAt: null,
                unreadCount: member.unreadCount + (id === userId ? 0 : 1),
              },
            );
            if (id === userId) own = payload;
          }
          return { message: messageDto(message), room: own! };
        });
      } catch (error) {
        if ((error as { code?: number }).code !== 11000) throw error;
        const sent = await this.existingSend(userId, dto.idempotencyKey);
        if (sent) return sent;
        if (attempt === 3) throw error;
      }
    }
    throw new BadRequestException("Unable to send message");
  }
  private visibleFilter(
    roomId: string,
    userId: string,
    member: RoomMember,
  ): FilterQuery<Message> {
    return {
      roomId: oid(roomId),
      deletedForUsers: { $nin: [oid(userId)] },
      ...(member.clearedAt ? { createdAt: { $gt: member.clearedAt } } : {}),
    };
  }
  async messages(userId: string, roomId: string, query: MessagesQuery) {
    const member = await this.membership(roomId, userId);
    if (!!query.beforeCreatedAt !== !!query.beforeId)
      throw new BadRequestException("Both message cursor fields are required");
    const messages = await this.db.messages
      .find({
        ...this.visibleFilter(roomId, userId, member),
        ...(query.beforeId
          ? cursorBefore(
              "createdAt",
              "_id",
              query.beforeCreatedAt!,
              query.beforeId,
            )
          : {}),
      })
      .sort({ createdAt: -1, _id: -1 })
      .limit(query.limit + 1)
      .lean();
    return {
      messages: messages.slice(0, query.limit).map(messageDto),
      hasMore: messages.length > query.limit,
    };
  }
  async around(
    userId: string,
    roomId: string,
    targetId: string,
    query: MessagesQuery,
  ) {
    const member = await this.membership(roomId, userId);
    const filter = this.visibleFilter(roomId, userId, member);
    const target = await this.db.messages
      .findOne({ ...filter, _id: oid(targetId), isDeletedForAll: false })
      .lean();
    if (!target)
      throw new NotFoundException("Reply target is no longer available");
    const count = Math.floor(query.limit / 2);
    const before = await this.db.messages
      .find({
        ...filter,
        ...cursorBefore(
          "createdAt",
          "_id",
          target.createdAt.toISOString(),
          targetId,
        ),
      })
      .sort({ createdAt: -1, _id: -1 })
      .limit(count || 1)
      .lean();
    const after = await this.db.messages
      .find({
        ...filter,
        $or: [
          { createdAt: { $gt: target.createdAt } },
          { createdAt: target.createdAt, _id: { $gt: target._id } },
        ],
      })
      .sort({ createdAt: 1, _id: 1 })
      .limit(count || 1)
      .lean();
    const messages = [...after.reverse(), target, ...before];
    return { targetMessageId: targetId, messages: messages.map(messageDto) };
  }
  private async messageWithMembership(
    userId: string,
    messageId: string,
    session: ClientSession,
  ) {
    const message = await this.db.messages
      .findById(messageId)
      .session(session)
      .lean();
    if (!message) throw new NotFoundException("Message not found");
    const member = await this.membership(
      message.roomId.toString(),
      userId,
      session,
    );
    if (
      message.deletedForUsers.some((id) => id.toString() === userId) ||
      (member.clearedAt && message.createdAt <= member.clearedAt)
    )
      throw new NotFoundException("Message not visible");
    return { message, member };
  }
  async edit(userId: string, messageId: string, dto: EditMessageDto) {
    if (!dto.text.trim()) throw new BadRequestException("Text is required");
    return this.transaction(async (session, events) => {
      const { message } = await this.messageWithMembership(
        userId,
        messageId,
        session,
      );
      if (message.senderId.toString() !== userId)
        throw new ForbiddenException("Only the sender may edit");
      if (message.isDeletedForAll)
        throw new BadRequestException("Deleted messages cannot be edited");
      if (message.type !== "text")
        throw new BadRequestException("Only text messages may be edited");
      const now = new Date();
      const updated = await this.db.messages
        .findOneAndUpdate(
          { _id: message._id },
          { $set: { text: dto.text, isEdited: true, editedAt: now } },
          { new: true, session },
        )
        .lean();
      await this.db.messages.updateMany(
        { roomId: message.roomId, "replyTo.messageId": message._id },
        { $set: { "replyTo.text": dto.text.slice(0, 120) } },
        { session },
      );
      let own: HydratedRoomPayload | undefined;
      const members = await this.db.members
        .find({ roomId: message.roomId })
        .session(session)
        .lean();
      for (const member of members) {
        const visible =
          !updated!.deletedForUsers.some((id) => id.equals(member.userId)) &&
          (!member.clearedAt || updated!.createdAt > member.clearedAt);
        const payload = await this.bump(
          member.userId.toString(),
          message.roomId.toString(),
          "message_edited",
          session,
          events,
          {},
          visible ? updated : undefined,
        );
        if (member.userId.toString() === userId) own = payload;
      }
      return { message: messageDto(updated!), room: own! };
    });
  }
  async deleteForAll(userId: string, messageId: string) {
    return this.transaction(async (session, events) => {
      const { message } = await this.messageWithMembership(
        userId,
        messageId,
        session,
      );
      if (message.senderId.toString() !== userId)
        throw new ForbiddenException("Only the sender may delete for everyone");
      if (message.isDeletedForAll)
        return {
          message: messageDto(message),
          room: await this.hydrate(
            await this.membership(message.roomId.toString(), userId, session),
            "message_deleted_all",
            new Date(),
            message,
            session,
          ),
        };
      const updated = await this.db.messages
        .findOneAndUpdate(
          { _id: message._id },
          {
            $set: { isDeletedForAll: true, text: DELETED_TEXT, imageUrl: null },
          },
          { new: true, session },
        )
        .lean();
      await this.db.messages.updateMany(
        { roomId: message.roomId, "replyTo.messageId": message._id },
        {
          $set: {
            "replyTo.isDeleted": true,
            "replyTo.text": DELETED_TEXT,
            "replyTo.imageUrl": null,
          },
        },
        { session },
      );
      let own: HydratedRoomPayload | undefined;
      const members = await this.db.members
        .find({ roomId: message.roomId })
        .session(session)
        .lean();
      for (const member of members) {
        const visible =
          !updated!.deletedForUsers.some((id) => id.equals(member.userId)) &&
          (!member.clearedAt || updated!.createdAt > member.clearedAt);
        const payload = await this.bump(
          member.userId.toString(),
          message.roomId.toString(),
          "message_deleted_all",
          session,
          events,
          {},
          visible ? updated : undefined,
        );
        if (member.userId.toString() === userId) own = payload;
      }
      return { message: messageDto(updated!), room: own! };
    });
  }
  async deleteForMe(userId: string, messageId: string) {
    return this.transaction(async (session, events) => {
      const original = await this.db.messages
        .findById(messageId)
        .session(session)
        .lean();
      if (!original) throw new NotFoundException("Message not found");
      const member = await this.membership(
        original.roomId.toString(),
        userId,
        session,
      );
      if (original.deletedForUsers.some((id) => id.toString() === userId))
        return {
          message: messageDto(original),
          room: await this.hydrate(
            member,
            "message_deleted_me",
            new Date(),
            original,
            session,
          ),
        };
      const updated = await this.db.messages
        .findOneAndUpdate(
          { _id: original._id },
          { $addToSet: { deletedForUsers: oid(userId) } },
          { new: true, session },
        )
        .lean();
      let changes: Record<string, unknown> = {};
      if (member.lastMessageId?.equals(original._id)) {
        const previous = await this.db.messages
          .findOne(
            this.visibleFilter(original.roomId.toString(), userId, member),
          )
          .sort({ createdAt: -1, _id: -1 })
          .session(session)
          .lean();
        changes = { lastMessageId: previous?._id ?? null };
      }
      return {
        message: messageDto(updated!),
        room: await this.bump(
          userId,
          original.roomId.toString(),
          "message_deleted_me",
          session,
          events,
          changes,
          updated,
        ),
      };
    });
  }
  async delivered(userId: string, roomIds: string[], dto: BoundaryDto) {
    return this.receipts(userId, roomIds, dto, false);
  }
  async seen(userId: string, roomId: string, dto: BoundaryDto) {
    return this.receipts(userId, [roomId], dto, true);
  }
  private async receipts(
    userId: string,
    roomIds: string[],
    dto: BoundaryDto,
    seen: boolean,
  ) {
    return this.transaction(async (session, events) => {
      // Validate the whole batch before writing so a foreign room cannot partially apply.
      const members: RoomMember[] = [];
      for (const id of roomIds) {
        const member = await this.membership(id, userId, session);
        if (!seen && member.roomType !== "direct")
          throw new BadRequestException(
            "Delivery receipts require direct rooms",
          );
        members.push(member);
      }
      const now = new Date();
      const boundary = dto.upToTimestamp
        ? new Date(
            Math.min(new Date(dto.upToTimestamp).getTime(), now.getTime()),
          )
        : now;
      for (const member of members) {
        const roomId = member.roomId.toString();
        if (seen && member.unreadCount > 0)
          await this.bump(
            userId,
            roomId,
            "room_unread_cleared",
            session,
            events,
            { unreadCount: 0 },
            undefined,
            now,
          );
        if (member.roomType !== "direct") continue;
        const filter: FilterQuery<Message> = {
          roomId: member.roomId,
          senderId: { $ne: oid(userId) },
          [seen ? "seenAt" : "deliveredAt"]: null,
          createdAt: { $lte: boundary },
        };
        const result = seen
          ? await this.db.messages.updateMany(
              filter,
              [
                {
                  $set: {
                    deliveredAt: { $ifNull: ["$deliveredAt", now] },
                    seenAt: now,
                    updatedAt: now,
                  },
                },
              ],
              { session },
            )
          : await this.db.messages.updateMany(
              filter,
              { $set: { deliveredAt: now } },
              { session },
            );
        if (result.modifiedCount > 0 && member.peerUserId)
          await this.bump(
            member.peerUserId.toString(),
            roomId,
            seen ? "room_peer_seen" : "room_delivered",
            session,
            events,
            {},
            undefined,
            boundary,
          );
      }
      return { ok: true };
    });
  }
}
