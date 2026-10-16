import { OpenAPIObject } from "@nestjs/swagger";
const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });
const id = { type: "string" as const, pattern: "^[0-9a-fA-F]{24}$" };
const date = { type: "string" as const, format: "date-time" };
const nullableDate = { ...date, nullable: true };
const string = { type: "string" as const };
const integer = { type: "integer" as const, format: "int64", minimum: 0 };
const boolean = { type: "boolean" as const };
const object = (
  properties: Record<string, object>,
  required: string[] = Object.keys(properties),
) => ({ type: "object" as const, properties, required });
const array = (items: object) => ({ type: "array" as const, items });
const reply = object({
  messageId: id,
  senderId: id,
  senderName: string,
  type: { ...string, enum: ["text", "image"] },
  text: string,
  imageUrl: { ...string, nullable: true },
  isDeleted: boolean,
});
const message = object({
  _id: id,
  id,
  idempotencyKey: { ...string, format: "uuid" },
  roomId: id,
  roomType: { ...string, enum: ["direct", "group"] },
  senderId: id,
  senderName: string,
  senderAvatarUrl: { ...string, nullable: true },
  type: { ...string, enum: ["text", "image"] },
  text: string,
  imageUrl: { ...string, nullable: true },
  replyTo: { ...reply, nullable: true },
  isEdited: boolean,
  editedAt: nullableDate,
  isDeletedForAll: boolean,
  deliveredAt: nullableDate,
  seenAt: nullableDate,
  createdAt: date,
  updatedAt: date,
});
const room = object(
  {
    roomId: id,
    roomType: { ...string, enum: ["direct", "group"] },
    peerUserId: { ...id, nullable: true },
    displayTitle: string,
    displayAvatarUrl: { ...string, nullable: true },
    pinAt: nullableDate,
    isMuted: boolean,
    unreadCount: integer,
    clearedAt: nullableDate,
    deletedAt: nullableDate,
    sortTimestamp: date,
    roomPts: integer,
    msgPts: integer,
    lastHistoryEditPts: integer,
    lastMessage: { ...message, nullable: true },
    updatedMessage: { ...message, nullable: true },
    eventType: {
      ...string,
      enum: [
        "message_new",
        "message_edited",
        "message_deleted_all",
        "message_deleted_me",
        "room_delivered",
        "room_peer_seen",
        "room_unread_cleared",
        "room_preferences",
        "room_created",
      ],
    },
    actionTimestamp: date,
  },
  [
    "roomId",
    "roomType",
    "peerUserId",
    "displayTitle",
    "displayAvatarUrl",
    "pinAt",
    "isMuted",
    "unreadCount",
    "clearedAt",
    "deletedAt",
    "sortTimestamp",
    "roomPts",
    "msgPts",
    "lastHistoryEditPts",
    "lastMessage",
    "eventType",
    "actionTimestamp",
  ],
);
const user = object({
  _id: id,
  id,
  username: string,
  email: { ...string, format: "email" },
  displayName: string,
  avatarUrl: { ...string, nullable: true },
  isDebugUser: boolean,
  debugUserNumber: { type: "integer", nullable: true },
  pts: integer,
  lastSeenAt: date,
});
const peer = object({
  _id: id,
  id,
  username: string,
  displayName: string,
  avatarUrl: { ...string, nullable: true },
});
const problem = object({
  type: string,
  title: string,
  status: { type: "integer" },
  detail: string,
  instance: string,
  requestId: { ...string, maxLength: 64 },
  message: { oneOf: [string, array(string)] },
});
const auth = object({
  user: ref("User"),
  accessToken: string,
  centrifugoToken: string,
});
const ok = object({ ok: boolean });
const pathParameter = (name: string) => ({
  name,
  in: "path" as const,
  required: true,
  schema: id,
});
const queryParameter = (name: string, schema: object, required = false) => ({
  name,
  in: "query" as const,
  required,
  schema,
});
const content = (schema: object) => ({ "application/json": { schema } });
function operation(
  summary: string,
  response: object,
  body?: object,
  parameters: object[] = [],
  publicRoute = false,
  status = "200",
) {
  return {
    summary,
    security: publicRoute ? [] : [{ bearerAuth: [] }],
    parameters: [
      {
        name: "X-Request-ID",
        in: "header",
        required: false,
        description:
          "Optional correlation ID using 1-64 letters, digits, dots, underscores or hyphens; invalid values are replaced with a generated UUID.",
        schema: {
          type: "string",
          maxLength: 64,
          pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$",
        },
      },
      ...parameters,
    ],
    ...(body
      ? { requestBody: { required: true, content: content(body) } }
      : {}),
    responses: {
      [status]: {
        description: "Success",
        headers: {
          "X-Request-ID": {
            description: "Request correlation ID",
            schema: { type: "string", maxLength: 64 },
          },
        },
        content: content(response),
      },
      ...Object.fromEntries(
        [400, 401, 403, 404, 409, 413, 429, 500, 503].map((code) => [
          code,
          {
            description:
              code === 400
                ? "Validation failure"
                : code === 403
                  ? "Membership or sender permission required"
                  : "Request failed",
            headers: {
              "X-Request-ID": {
                description: "Request correlation ID",
                schema: { type: "string", maxLength: 64 },
              },
            },
            content: { "application/problem+json": { schema: ref("Problem") } },
          },
        ]),
      ),
    },
  };
}
const roomId = pathParameter("roomId");
const messageId = pathParameter("messageId");
const boundary = object({ upToTimestamp: date }, []);
const roomResponse = object({ room: ref("HydratedRoom") });
const messageResponse = object({
  message: ref("Message"),
  room: ref("HydratedRoom"),
});
export const openApiDocument = {
  openapi: "3.0.3",
  info: {
    title: "Chat REST API",
    version: "1.0.0",
    description:
      "REST commands and durable recovery with account-scoped advisory Centrifugo events. CamelCase and action routes follow the approved BACKEND_SPEC.md. All authenticated responses are private and must not be cached. Debug endpoints exist only in development. Date boundaries are ISO 8601 UTC; tied timestamps use ObjectId cursors.",
  },
  servers: [{ url: "http://localhost:3000" }],
  paths: {
    "/health": {
      get: operation(
        "Check MongoDB and Redis readiness",
        object({ status: string, mongo: string, redis: string }),
        undefined,
        [],
        true,
      ),
    },
    "/auth/debug-users": {
      get: operation(
        "List development debug users",
        array(ref("User")),
        undefined,
        [],
        true,
      ),
    },
    "/auth/debug-login": {
      post: operation(
        "Log in as a development debug user",
        ref("AuthSession"),
        object({
          debugUserNumber: { type: "integer", minimum: 1, maximum: 5 },
        }),
        [],
        true,
      ),
    },
    "/auth/signup": {
      post: operation(
        "Create an account",
        ref("AuthSession"),
        object({
          username: {
            ...string,
            minLength: 3,
            maxLength: 40,
            pattern: "^[a-zA-Z0-9_]+$",
          },
          email: { ...string, format: "email", maxLength: 254 },
          password: { ...string, minLength: 8, maxLength: 72 },
          displayName: { ...string, minLength: 1, maxLength: 80 },
        }),
        [],
        true,
        "201",
      ),
    },
    "/auth/login": {
      post: operation(
        "Log in using email or username and password",
        ref("AuthSession"),
        object(
          {
            email: { ...string, format: "email" },
            username: string,
            password: string,
          },
          ["password"],
        ),
        [],
        true,
      ),
    },
    "/auth/centrifugo-token": {
      post: operation(
        "Refresh the user-scoped realtime JWT",
        object({ centrifugoToken: string }),
      ),
    },
    "/users": {
      get: operation(
        "List users available for direct and group chats",
        array(ref("PeerUser")),
      ),
    },
    "/rooms": {
      get: operation(
        "Load all pinned and a cursor page of unpinned rooms from a consistent MongoDB snapshot",
        object({
          pts: integer,
          epoch: string,
          rooms: array(ref("HydratedRoom")),
          nextCursor: {
            ...object({ beforeSortTimestamp: date, beforeRoomId: id }),
            nullable: true,
          },
        }),
        undefined,
        [
          queryParameter("limit", {
            type: "integer",
            minimum: 1,
            maximum: 100,
            default: 25,
          }),
          queryParameter("beforeSortTimestamp", date),
          queryParameter("beforeRoomId", id),
        ],
      ),
    },
    "/rooms/delta": {
      get: operation(
        "Recover latest changed rooms; full sync required on epoch mismatch, expired cache, >100 dirty rooms or a cache consistency fence",
        {
          oneOf: [
            object({ requiresFullSync: { type: "boolean", enum: [true] } }),
            object({
              requiresFullSync: { type: "boolean", enum: [false] },
              pts: integer,
              epoch: string,
              rooms: array(ref("HydratedRoom")),
            }),
          ],
        },
        undefined,
        [
          queryParameter("sincePts", integer, true),
          queryParameter("epoch", string, true),
        ],
      ),
    },
    "/rooms/direct-peer/{peerUserId}": {
      get: operation(
        "Resolve a direct room without creating it",
        object({
          exists: boolean,
          room: { ...room, nullable: true },
          peerUser: ref("PeerUser"),
        }),
        undefined,
        [pathParameter("peerUserId")],
      ),
    },
    "/rooms/group": {
      post: operation(
        "Create a group including the caller",
        roomResponse,
        object(
          {
            title: { ...string, minLength: 1, maxLength: 100 },
            participantIds: {
              ...array(id),
              minItems: 1,
              maxItems: 99,
              uniqueItems: true,
            },
            avatarUrl: string,
          },
          ["title", "participantIds"],
        ),
        [],
        false,
        "201",
      ),
    },
    "/rooms/{roomId}/preferences": {
      patch: operation(
        "Set pin and mute without changing message revisions or order",
        roomResponse,
        object({ pin: boolean, isMuted: boolean }, []),
        [roomId],
      ),
    },
    "/rooms/{roomId}/messages": {
      get: operation(
        "Load visible messages, newest first; both cursor fields must be supplied together",
        object({ messages: array(ref("Message")), hasMore: boolean }),
        undefined,
        [
          roomId,
          queryParameter("limit", {
            type: "integer",
            minimum: 1,
            maximum: 100,
            default: 30,
          }),
          queryParameter("beforeCreatedAt", date),
          queryParameter("beforeId", id),
        ],
      ),
    },
    "/rooms/{roomId}/messages/around/{targetMessageId}": {
      get: operation(
        "Return an explicit visible target with messages before and after, sorted descending",
        object({ targetMessageId: id, messages: array(ref("Message")) }),
        undefined,
        [
          roomId,
          pathParameter("targetMessageId"),
          queryParameter("limit", {
            type: "integer",
            minimum: 1,
            maximum: 100,
            default: 30,
          }),
        ],
      ),
    },
    "/rooms/{roomId}/delivered": {
      post: operation(
        "Mark incoming direct messages delivered through the supplied boundary",
        ok,
        boundary,
        [roomId],
      ),
    },
    "/rooms/delivered-batch": {
      post: operation(
        "Atomically mark incoming messages delivered for up to 100 direct rooms; any invalid member aborts the batch",
        ok,
        object(
          {
            roomIds: {
              ...array(id),
              minItems: 1,
              maxItems: 100,
              uniqueItems: true,
            },
            upToTimestamp: date,
          },
          ["roomIds"],
        ),
      ),
    },
    "/rooms/{roomId}/seen": {
      post: operation(
        "Clear own unread count and separately mark incoming direct messages seen",
        ok,
        boundary,
        [roomId],
      ),
    },
    "/messages": {
      post: operation(
        "Idempotent send; provide exactly one of roomId or peerUserId; lazy direct-room creation",
        messageResponse,
        object(
          {
            roomId: id,
            peerUserId: id,
            idempotencyKey: { ...string, format: "uuid" },
            type: { ...string, enum: ["text", "image"] },
            text: { ...string, maxLength: 10000 },
            imageUrl: string,
            replyToMessageId: id,
          },
          ["idempotencyKey", "type", "text"],
        ),
      ),
    },
    "/messages/{messageId}": {
      patch: operation(
        "Edit own text message and embedded reply previews; image messages cannot be edited",
        messageResponse,
        object({ text: { ...string, minLength: 1, maxLength: 10000 } }),
        [messageId],
      ),
    },
    "/messages/{messageId}/for-all": {
      delete: operation(
        "Delete own message for everyone and remove quoted image URLs",
        messageResponse,
        undefined,
        [messageId],
      ),
    },
    "/messages/{messageId}/for-me": {
      delete: operation(
        "Hide a message for the caller and roll back the last-message preview",
        messageResponse,
        undefined,
        [messageId],
      ),
    },
    "/uploads/image": {
      post: {
        ...operation(
          "Upload a validated JPEG, PNG, GIF or WebP image, at most 5 MiB",
          object({ imageUrl: string }),
          undefined,
          [],
          false,
          "201",
        ),
        requestBody: {
          required: true,
          content: {
            "multipart/form-data": {
              schema: object({ file: { type: "string", format: "binary" } }),
            },
          },
        },
      },
    },
    "/presence/heartbeat": {
      post: operation("Renew a 45-second online presence lease", ok),
    },
    "/presence/status": {
      post: operation(
        "Read online status for up to 100 userIds",
        object({ statuses: { type: "object", additionalProperties: boolean } }),
        object({ userIds: { ...array(id), maxItems: 100 } }),
      ),
      get: operation(
        "Read online status for up to 100 comma-separated userIds",
        object({ statuses: { type: "object", additionalProperties: boolean } }),
        undefined,
        [queryParameter("userIds", string, true)],
      ),
    },
  },
  components: {
    securitySchemes: {
      bearerAuth: { type: "http", scheme: "bearer", bearerFormat: "JWT" },
    },
    schemas: {
      User: user,
      PeerUser: peer,
      AuthSession: auth,
      Message: message,
      HydratedRoom: room,
      Problem: problem,
      InboxPublication: object({
        pts: integer,
        epoch: string,
        room: ref("HydratedRoom"),
      }),
    },
  },
} as unknown as OpenAPIObject;
