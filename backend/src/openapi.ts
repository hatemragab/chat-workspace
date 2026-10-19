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
  messageSeq: {
    ...integer,
    minimum: 1,
    maximum: Number.MAX_SAFE_INTEGER,
    nullable: true,
  },
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
    contentPts: integer,
    headSeq: integer,
    ownDeliveredSeq: integer,
    ownSeenSeq: integer,
    peerDeliveredSeq: integer,
    peerSeenSeq: integer,
    sequenceReceipt: {
      ...boolean,
      description:
        "True for sequence-only receipt mutations: do not apply actionTimestamp to legacy messages.",
    },
    receiptProtocol: {
      ...string,
      enum: ["legacy", "sequence"],
      description:
        "Use upToSeq only when sequence is advertised. Legacy mode rejects sequence commands to preserve mixed-client compatibility.",
    },
    lastHistoryEditPts: integer,
    lastMessage: { ...message, nullable: true },
    updatedMessage: { ...message, nullable: true },
    quoteUpdate: {
      ...reply,
      description:
        "Quote-only update when the changed original is hidden for this recipient. Update matching reply previews without inserting or resurfacing the original; text is at most 120 characters.",
    },
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
  lastSeenAt: {
    ...date,
    description:
      "Last known authenticated connection activity, persisted after the user's final socket disappears. Snapshot timing is approximate (30 seconds by default); provider failures do not mark users offline.",
  },
});
const peer = object({
  _id: id,
  id,
  username: string,
  displayName: string,
  avatarUrl: { ...string, nullable: true },
});
const problem = object(
  {
    type: string,
    title: string,
    status: { type: "integer" },
    detail: string,
    instance: string,
    requestId: { ...string, maxLength: 64 },
    message: { oneOf: [string, array(string)] },
    code: {
      ...string,
      description:
        "Stable error category, for example VALIDATION_FAILED, BAD_REQUEST, AUTHENTICATION_REQUIRED, RATE_LIMITED or SERVICE_UNAVAILABLE. Clients must tolerate additional codes.",
    },
    retryable: {
      ...boolean,
      description:
        "True for 408, 429, 500, 502, 503 and 504. A retry still requires an idempotent operation and capped backoff; false requires user action or a changed request.",
    },
    retryAfterSeconds: {
      ...integer,
      description:
        "429 cooldown matching the Retry-After header (currently 60 seconds).",
    },
  },
  [
    "type",
    "title",
    "status",
    "detail",
    "instance",
    "requestId",
    "message",
    "code",
    "retryable",
  ],
);
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
        [
          400, 401, 403, 404, 408, 409, 413, 415, 422, 429, 500, 502, 503, 504,
        ].map((code) => [
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
              ...(code === 429
                ? {
                    "Retry-After": {
                      description:
                        "Minimum retry delay in seconds, exposed to browser clients through CORS.",
                      schema: { type: "integer", minimum: 0, example: 60 },
                    },
                  }
                : {}),
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
const sequence = { ...integer, maximum: Number.MAX_SAFE_INTEGER };
const receiptState = object({
  ownDeliveredSeq: sequence,
  ownSeenSeq: sequence,
  peerDeliveredSeq: sequence,
  peerSeenSeq: sequence,
});
const receiptAck = object({
  ok: boolean,
  rooms: array(
    object({ roomId: id, ownDeliveredSeq: sequence, ownSeenSeq: sequence }),
  ),
});
const boundary = {
  ...object({ upToTimestamp: date, upToSeq: sequence }, []),
  description:
    "Omit both for the legacy timestamp-now command, or supply exactly one boundary. upToSeq requires compact protocol and must not exceed the committed head. Delivery covers positive sequences only; Seen additionally marks retained nullable legacy incoming history read. Null, fractional, negative and unsafe integers are rejected.",
};
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
        "Check MongoDB primary and Redis concurrently with 1,500 ms driver deadlines; uncached and public, independent of realtime provider availability",
        object({ status: string, mongo: string, redis: string }),
        undefined,
        [],
        true,
      ),
      head: {
        summary:
          "Run the same bounded readiness checks as GET /health, returning headers and status without a response body",
        security: [],
        responses: {
          "200": { description: "MongoDB primary and Redis responded" },
          "503": {
            description: "A required dependency is unavailable or timed out",
          },
        },
      },
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
        {
          oneOf: [
            array(ref("PeerUser")),
            object({
              users: array(ref("PeerUser")),
              nextCursor: { ...id, nullable: true },
            }),
          ],
        },
        undefined,
        [
          queryParameter("limit", {
            type: "integer",
            minimum: 1,
            maximum: 100,
          }),
          queryParameter("afterUserId", id),
        ],
      ),
    },
    "/rooms": {
      get: operation(
        "Load all pinned and a cursor page of unpinned rooms from a consistent MongoDB snapshot",
        object(
          {
            pts: integer,
            epoch: string,
            rooms: array(ref("HydratedRoom")),
            nextCursor: {
              ...object({ beforeSortTimestamp: date, beforeRoomId: id }),
              nullable: true,
            },
            pinnedNextCursor: {
              ...object({ beforePinAt: date, beforePinnedRoomId: id }),
              nullable: true,
            },
          },
          ["pts", "epoch", "rooms", "nextCursor"],
        ),
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
          queryParameter("pinnedLimit", {
            type: "integer",
            minimum: 1,
            maximum: 100,
          }),
          queryParameter("beforePinAt", date),
          queryParameter("beforePinnedRoomId", id),
          queryParameter("pinnedOnly", boolean),
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
        "Set non-null boolean pin and mute values without changing message revisions or order; null is rejected",
        roomResponse,
        object({ pin: boolean, isMuted: boolean }, []),
        [roomId],
      ),
    },
    "/rooms/{roomId}/messages": {
      get: operation(
        "Load visible messages, newest first; both cursor fields must be supplied together",
        object(
          {
            messages: array(ref("Message")),
            hasMore: boolean,
            receiptState,
            coverage: {
              ...object({
                roomPts: integer,
                msgPts: integer,
                contentPts: integer,
                lastHistoryEditPts: integer,
                headSeq: sequence,
                fromSeq: sequence,
                throughSeq: sequence,
              }),
              description:
                "Same MongoDB snapshot as returned rows. Every visible sequenced message in inclusive [fromSeq,throughSeq] was returned; absent sequences in that interval are not visible to this account. fromSeq=throughSeq+1 means empty coverage. headSeq alone never certifies downloaded bodies. Combine adjoining ranges from previous acknowledged delivery before sending upToSeq. contentPts excludes receipts/preferences.",
            },
            receipts: {
              ...object({
                deliveredThrough: nullableDate,
                seenThrough: nullableDate,
                hasGaps: boolean,
              }),
              description:
                "Latest direct-room page only: maximum CREATED timestamp boundaries of the caller's outgoing messages with persisted delivered/seen receipts, from the same MongoDB snapshot as messages. Null means no outgoing message has that receipt. hasGaps flags any unacknowledged outgoing message at/before either boundary; when true clients must reset older cache instead of promoting ticks by boundary. Omitted on groups and older cursor pages.",
            },
          },
          ["messages", "hasMore"],
        ),
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
        receiptAck,
        boundary,
        [roomId],
      ),
    },
    "/rooms/delivered-batch": {
      post: operation(
        "Atomically mark incoming messages delivered for up to 100 direct rooms; any invalid member aborts the batch",
        receiptAck,
        object(
          {
            roomIds: {
              ...array(id),
              minItems: 1,
              maxItems: 100,
              uniqueItems: true,
            },
            upToTimestamp: date,
            targets: {
              ...array(object({ roomId: id, upToSeq: sequence })),
              minItems: 1,
              maxItems: 100,
            },
          },
          [],
        ),
      ),
    },
    "/rooms/{roomId}/seen": {
      post: operation(
        "Clear own unread count and separately mark incoming direct messages seen",
        receiptAck,
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
          "Upload a fully decoded JPEG, PNG, GIF or WebP image: 5 MiB, configured pixel/frame/dimension limits, authenticated rate/concurrency budgets; returns a retained owner-only pending path",
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
    "/public/uploads/{filename}": {
      get: {
        ...operation(
          "Read retained media using bearer authentication and currently visible message/quote membership; pending uploads are owner-only",
          string,
          undefined,
          [
            {
              name: "filename",
              in: "path",
              required: true,
              schema: {
                type: "string",
                pattern:
                  "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,199}\\.(jpg|jpeg|png|webp|gif)$",
              },
            },
          ],
        ),
        responses: {
          ...operation("Read media", string).responses,
          "200": {
            description:
              "Private media; Cache-Control private, no-store. Global/per-user deletion revokes new reads where no visible reference remains.",
            content: {
              "image/png": { schema: { type: "string", format: "binary" } },
              "image/jpeg": { schema: { type: "string", format: "binary" } },
              "image/gif": { schema: { type: "string", format: "binary" } },
              "image/webp": { schema: { type: "string", format: "binary" } },
            },
          },
        },
      },
    },
    "/presence/heartbeat": {
      post: {
        ...operation(
          "Deprecated compatibility no-op; Centrifugo connections determine presence",
          ok,
        ),
        deprecated: true,
      },
    },
    "/presence/offline": {
      post: operation(
        "Atomically retire this login and queue persistent disconnect retries; other logins remain online, and last seen is recorded only after the final socket disappears",
        ok,
      ),
    },
    "/presence/status": {
      post: operation(
        "Read Centrifugo connection presence for self and shared-room contacts, up to 100 userIds; unauthorized IDs are omitted",
        object({
          statuses: { type: "object", additionalProperties: boolean },
          lastSeenAt: {
            type: "object",
            additionalProperties: { ...date, nullable: true },
            description:
              "Last known connection activity for authorized offline users only. Approximate; recorded by the backend observer.",
          },
        }),
        object({ userIds: { ...array(id), maxItems: 100 } }),
      ),
      get: operation(
        "Read Centrifugo connection presence for self and shared-room contacts, up to 100 comma-separated userIds; unauthorized IDs are omitted",
        object({
          statuses: { type: "object", additionalProperties: boolean },
          lastSeenAt: {
            type: "object",
            additionalProperties: { ...date, nullable: true },
            description:
              "Last known connection activity for authorized offline users only. Approximate; recorded by the backend observer.",
          },
        }),
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
      PresencePublication: object({
        type: { ...string, enum: ["presence_changed"] },
        userId: id,
        online: boolean,
      }),
      InboxPublication: object({
        pts: integer,
        epoch: string,
        room: ref("HydratedRoom"),
      }),
      CompactReceiptPublication: object({
        pts: integer,
        epoch: string,
        receipt: object({
          roomId: id,
          eventType: { ...string, enum: ["room_delivered", "room_peer_seen"] },
          peerDeliveredSeq: sequence,
          peerSeenSeq: sequence,
          contentPts: integer,
        }),
      }),
      CompactUnreadPublication: {
        ...object({
          pts: integer,
          epoch: string,
          unread: object({
            eventType: { ...string, enum: ["room_unread_cleared"] },
            roomId: id,
            unreadCount: integer,
            ownDeliveredSeq: sequence,
            ownSeenSeq: sequence,
          }),
        }),
        description:
          "Compact-mode own-account unread patch for direct/group rooms. unreadCount may remain positive after a bounded read. Stamp roomPts from pts; preserve msgPts, contentPts, history, ordering, message rows and exact dates. Merge own acknowledgement cursors monotonically. Apply through the serialized inbox transaction. Redis/full recovery remains hydrated; legacy mode uses InboxPublication. No additional own-progress events are produced.",
      },
    },
  },
} as unknown as OpenAPIObject;
