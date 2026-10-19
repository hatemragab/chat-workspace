# BACKEND SPECIFICATION (BACKEND_SPEC.md)

# Stack: NestJS + Mongoose (Replica Set Transactions) + ioredis (Lua Atomic) + Multer + Centrifugo

## 1. ENVIRONMENT VARIABLES (`backend/.env`)

```env
PORT=3000
NODE_ENV=development
MONGODB_URI=mongodb://localhost:27017/chat_app?replicaSet=rs0
REDIS_URL=redis://localhost:6379
JWT_SECRET=replace-with-independent-random-secret-at-least-32-characters
CENTRIFUGO_TOKEN_HMAC_SECRET_KEY=replace-with-dedicated-random-signing-secret
CENTRIFUGO_API_URL=http://127.0.0.1:9000/api
CENTRIFUGO_API_KEY=replace-with-dedicated-random-api-key
CENTRIFUGO_PROXY_SECRET=replace-with-dedicated-random-proxy-key
BASE_URL=http://localhost:3000
```

---

## 2. MONGODB COLLECTIONS & EXACT INDEXES

### 2.1 `users` Collection

```typescript
{
  _id: ObjectId,
  username: string,               // unique
  email: string,                  // unique
  passwordHash: string,
  displayName: string,
  avatarUrl: string | null,
  isDebugUser: boolean,           // true for User 1 .. User 5
  debugUserNumber: number | null, // 1..5
  pts: number,                    // Monotonic integer counter (default: 0)
  lastSeenAt: Date,
  createdAt: Date,
  updatedAt: Date
}
// Indexes:
// 1. { username: 1 } (unique)
// 2. { email: 1 } (unique)
// 3. { debugUserNumber: 1 }
```

### 2.2 `rooms` Collection (Common Metadata Only)

Created for Direct chats **ONLY** when the first message is sent (`POST /messages`).
**CRITICAL:** For `'group'` rooms, omit `directPairKey` (`undefined`, NEVER `null`).

```typescript
{
  _id: ObjectId,
  type: 'direct' | 'group',
  directPairKey?: string,         // ONLY set on 'direct' rooms: sorted "${minUserId}_${maxUserId}"
  title: string | null,           // Group title (null for direct)
  avatarUrl: string | null,       // Group avatar (null for direct)
  createdBy: ObjectId,
  participantIds: ObjectId[],
  createdAt: Date,
  updatedAt: Date
}
// Indexes:
// 1. { directPairKey: 1 } (unique: true, partialFilterExpression: { type: 'direct', directPairKey: { $type: 'string' } })
// 2. { participantIds: 1 }
```

### 2.3 `room_members` Collection (PRIMARY STARTER COLLECTION)

Stores only `lastMessageId` (not the embedded message object). Full message lookup is performed via `$lookup` during `GET /rooms` or hydrated on mutation.

```typescript
{
  _id: ObjectId,
  roomId: ObjectId,
  userId: ObjectId,
  roomType: 'direct' | 'group',
  peerUserId: ObjectId | null,      // Set for 'direct' rooms
  displayTitle: string,             // Group title OR peer's displayName
  displayAvatarUrl: string | null,  // Group avatar OR peer's avatarUrl
  pinAt: Date | null,               // Non-null = pinned; sorted DESC
  isMuted: boolean,
  unreadCount: number,              // Incremented on incoming message; remaining incoming count after bounded seen
  clearedAt: Date | null,           // Timestamp when user cleared/deleted chat for me
  deletedAt: Date | null,           // Non-null hides room from Main Chat List until new message
  lastMessageId: ObjectId | null,   // Reference to messages._id
  sortTimestamp: Date,              // Updated ONLY when a new message is written to the room!
  roomPts: number,                  // User's pts when ANY field on this room_member changed
  msgPts: number,                   // User's pts when a MESSAGE or TICK in this room changed
  lastHistoryEditPts: number,       // User's pts when an existing message was edited or deleted
  updatedAt: Date
}
// Indexes:
// 1. { userId: 1, deletedAt: 1, pinAt: -1, sortTimestamp: -1, roomId: -1 } (Starter Index for Full Sync & Load More)
// 2. { roomId: 1, userId: 1 } (unique)
// 3. { userId: 1, roomPts: 1 } (Fast MongoDB fallback delta index)
```

### 2.4 `messages` Collection

```typescript
{
  _id: ObjectId,
  idempotencyKey: string,           // Client UUID v4
  roomId: ObjectId,
  roomType: 'direct' | 'group',
  senderId: ObjectId,
  senderName: string,
  senderAvatarUrl: string | null,
  type: 'text' | 'image',
  text: string,                     // If isDeletedForAll == true, set to "🚫 This message was deleted"
  imageUrl: string | null,          // Relative path e.g. "/public/uploads/17604800-photo.jpg"
  replyTo: {                        // Embedded snapshot
    messageId: ObjectId,
    senderId: ObjectId,
    senderName: string,
    type: 'text' | 'image',
    text: string,                   // Truncated to 120 chars (or "🚫 This message was deleted")
    imageUrl: string | null,        // Cleared to null if target message is deleted for all
    isDeleted: boolean
  } | null,
  isEdited: boolean,
  editedAt: Date | null,
  isDeletedForAll: boolean,
  deletedForUsers: ObjectId[],
  deliveredAt: Date | null,         // Direct rooms ONLY
  seenAt: Date | null,              // Direct rooms ONLY
  createdAt: Date,
  updatedAt: Date
}
// Indexes:
// 1. { senderId: 1, idempotencyKey: 1 } (unique)
// 2. { roomId: 1, createdAt: -1, _id: -1 } (Pagination & latest 30 fetch)
// 3. { roomId: 1, senderId: 1, seenAt: 1, deliveredAt: 1 }
// 4. { roomId: 1, "replyTo.messageId": 1 }
```

Measured access indexes also include partial string-reference indexes `media_image_reference` on `imageUrl` and `media_quote_reference` on `replyTo.imageUrl`. Four direct-room partial indexes (`direct_deliveredAt_boundary`, `direct_seenAt_boundary`, `direct_deliveredAt_gap`, `direct_seenAt_gap`) use `(roomId, senderId, createdAt DESC, _id DESC)` for acknowledged-date boundaries and null-receipt gaps respectively. Queries retain explicit direct-room/type predicates matching these partial filters. The 20,000-row local explain evidence is recorded in the fix report; indexes add write/storage cost and are not a production capacity claim. The source definitions in [models.ts](backend/src/models.ts) are authoritative.

### 2.5 `uploads` Collection

`filename` (unique), `ownerId`, `mime`, `bytes`, `width`, `height`, `frames`, nullable `attachedAt`, `orphanEligibleAt`, `state` (`retained`, `deleting`, `deleted`), nullable `deletedAt` and timestamps describe owned media. An additional `(attachedAt, orphanEligibleAt)` index supports explicit orphan inventory. There is no TTL index. Attachment is transactional with message/group creation; cleanup is a separately invoked dry-run-first operation under the policy below.

---

## 3. TRANSACTIONAL MONGODB + ATOMIC REDIS LUA `pts` ENGINE

### 3.1 Hydrated Room Payload (`HydratedRoomPayload`)

Stored in Redis `user:{userId}:rooms_data` (`field: roomId`). Content events and legacy receipt publications send this hydrated state to Centrifugo `inbox:user#<userId>`; the sequence extension below allows compact receipt publications:

```typescript
interface HydratedRoomPayload {
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
  lastHistoryEditPts: number;
  lastMessage: FullMessageDto | null; // Complete message object!
  updatedMessage?: FullMessageDto | null; // Populated when an older message is edited/deleted
  quoteUpdate?: NonNullable<FullMessageDto["replyTo"]> | null; // Quote-only change when original is hidden for this recipient
  eventType:
    | "message_new"
    | "message_edited"
    | "message_deleted_all"
    | "message_deleted_me"
    | "room_delivered" // Sent to message sender when peer receives messages
    | "room_peer_seen" // Sent to message sender when peer reads messages (turns ticks blue)
    | "room_unread_cleared" // Sent to reader's own devices with authoritative remaining unreadCount
    | "room_preferences"
    | "room_created";
  actionTimestamp: string; // ISO timestamp boundary for room_delivered / room_peer_seen
}
```

### 3.2 Atomic MongoDB Transaction + Redis Lua Script

1. **Inside a MongoDB Transaction (`session.withTransaction`):**
   - Perform the primary mutation (`messages` insert/update).
   - For each affected user:
     - Atomically increment `users.pts` (`findOneAndUpdate({ _id: userId }, { $inc: { pts: 1 } }, { new: true, session })`).
     - Update `room_members` (`roomPts = newPts`, plus `msgPts = newPts` if message/tick event, plus `lastHistoryEditPts = newPts` if edit/delete event).
2. **After Transaction Commits — Run Atomic Redis Lua Update (`upsertUserRoomDeltaLua`):**
   Use a single `redis.eval(...)` Lua script per user so concurrent requests (`pts=101` and `pts=102`) NEVER overwrite a newer room state with an older one:
   ```lua
   -- KEYS[1] = user:{userId}:meta
   -- KEYS[2] = user:{userId}:dirty_rooms
   -- KEYS[3] = user:{userId}:rooms_data
   -- ARGV[1] = newPts (number)
   -- ARGV[2] = roomId (string)
   -- ARGV[3] = roomPayloadJson (string)
   -- ARGV[4] = fallbackEpochUuid (string)
   -- ARGV[5] = ttlSeconds (604800)
   -- ARGV[6] = absolute post-commit deadline (Unix milliseconds)

   -- A delayed/replayed command must not mutate the cache after its deadline.
   if ARGV[6] then
     local now = redis.call('TIME')
     local nowMs = tonumber(now[1]) * 1000 + math.floor(tonumber(now[2]) / 1000)
     if tonumber(ARGV[6]) <= nowMs then
       return redis.error_reply('Inbox deadline expired')
     end
   end

   local newPts = tonumber(ARGV[1])
   local roomId = ARGV[2]
   local ttl = tonumber(ARGV[5])

   if redis.call('EXISTS', KEYS[1]) == 0 then
     redis.call('HSET', KEYS[1], 'epoch', ARGV[4], 'min_pts', newPts - 1, 'current_pts', newPts)
   else
     local curPts = tonumber(redis.call('HGET', KEYS[1], 'current_pts') or '0')
     if newPts > curPts then
       redis.call('HSET', KEYS[1], 'current_pts', newPts)
     end
   end

   local prevScore = tonumber(redis.call('ZSCORE', KEYS[2], roomId) or '0')
   if newPts >= prevScore then
     redis.call('ZADD', KEYS[2], newPts, roomId)
     redis.call('HSET', KEYS[3], roomId, ARGV[3])
   end

   redis.call('EXPIRE', KEYS[1], ttl)
   redis.call('EXPIRE', KEYS[2], ttl)
   redis.call('EXPIRE', KEYS[3], ttl)
   return redis.call('HGET', KEYS[1], 'epoch')
   ```
3. **Publish to Centrifugo (`inbox:user#<userId>`):**
   - Call Centrifugo HTTP API (`/api/publish`) with up to 3 attempts: the first is immediate, followed by delays of 300ms and 1000ms before the second and third attempts, within the remaining post-commit deadline:
     `{ channel: "inbox:user#" + userId, data: { pts: newPts, epoch, room: roomPayload } }`.

---

## 4. COMPLETE REST API ENDPOINTS & AUTHORIZATION RULES

### 4.1 Security & Membership Guards (Mandatory on All Endpoints)

- **Room Membership Check:** Every `/rooms/:roomId/*` and `/messages/*` endpoint MUST verify that a `room_members` row exists for `{ roomId, userId: currentUserId }` before reading or modifying data. Return `403 Forbidden` otherwise.
- **Upload Validation:** `POST /uploads/image` (Multer) MUST enforce `fileSize <= 5 * 1024 * 1024` (5MB), validate MIME type (`image/jpeg`, `image/png`, `image/webp`, `image/gif`), and generate a safe server extension (`.jpg`, `.png`, `.webp`, `.gif`).
- **Canonical Identity:** Normalize valid ObjectId strings to lowercase at body/query/route identity boundaries before comparisons, de-duplication and routing. Mixed-case self IDs cannot bypass self-send checks or create duplicate group members/presence targets.
- **Authentication Failure Classes:** Invalid, expired, retired or missing-user credentials return 401. MongoDB/Redis availability failures while validating an otherwise signed session return retryable 503 rather than masquerading as logout.
- **Upload Resource Budget:** Enforce the upload-specific user/IP rate limits before Multer reads a body (defaults 30/120 per minute), four active requests globally and two per user, with a 30-second request bound (UPLOAD_REQUEST_TIMEOUT_MS). Decode every image/frame with sharp after signature validation; defaults cap total decoded pixels at 16,000,000, each dimension at 8,192 and frames at 60. Reject malformed/truncated files and over-budget input. These are per-process concurrency limits, not a multi-instance capacity guarantee.
- **Private Media:** `GET /public/uploads/:filename` retains the URL shape but requires the bearer header and current visible-reference authorization; never put access tokens in media query strings. A new upload's owner may read its pending bytes while retained and unattached; after attachment, visible non-globally-deleted messages or visible quotes in a member room, a member group avatar or a current profile avatar visible to self/shared-room peers authorize reads. Hiding the only reference or global deletion revokes subsequent reads when no authorized reference survives; downloaded bytes cannot be recalled. Successful media responses use `Cache-Control: private, no-store` and nosniff. Missing credentials return 401; unknown/unauthorized files return 404 after authentication, without revealing file existence. Error responses also use `Cache-Control: no-store`.
- **Media Lifecycle:** The `uploads` collection retains filename, owner, MIME/byte/dimension/frame metadata, attachment and orphan eligibility times and cleanup state. Orphan eligibility is a cleanup threshold, not an access-expiry time; pending-owner retries remain available while the file is retained. There is no TTL/automatic deletion. `npm run media:cleanup` inventories by default; explicit apply requires a separate confirmation flag and only targets expired, never-attached, metadata-backed unreferenced files with race/inode checks. Unknown/legacy and attached files are retained. This task does not authorize executing media cleanup.

### 4.2 Auth, Users & Debug Switcher

- `GET /auth/debug-users` (enabled when `NODE_ENV === 'development'`) -> Returns seeded `User 1..5`.
- `POST /auth/debug-login` `{ debugUserNumber: 1..5 }` -> Returns `{ user, accessToken, centrifugoToken }`.
- `POST /auth/signup`, `POST /auth/login` -> Standard auth returning `{ user, accessToken, centrifugoToken }`.
- `POST /auth/centrifugo-token` (JWT Guard) -> Returns a refreshed `{ centrifugoToken }` for Flutter's `getData` connect-proxy flow. NestJS verifies the signed 30-minute JWT and session retirement before assigning its single server-side inbox subscription. See [local realtime authentication](centrifugo/README.md).
- `GET /users` (JWT Guard) -> Returns list of users (`_id, username, displayName, avatarUrl`) so the client can start new Direct Chats or create Groups.
  - With `limit=1..100` and optional `afterUserId`, returns `{ users, nextCursor: ObjectId | null }` ordered by `_id ASC`, using an exclusive ID boundary. Supplying only `afterUserId` defaults the page to 100. The legacy no-argument array remains sorted by display name/ID and fails explicitly with 413 above `LEGACY_DIRECTORY_MAX_USERS` (default 10,000), rather than silently truncating.

### 4.3 Rooms & Delta Sync

- `GET /rooms/delta?sincePts={pts}&epoch={epoch}`:
  - Checks `user:{userId}:meta` in Redis:
    1. Exists?
    2. `meta.epoch === epoch`?
    3. `sincePts >= Number(meta.min_pts)`?
    4. `dirtyRoomIds = ZRANGEBYSCORE user:{userId}:dirty_rooms ({sincePts} +inf` has `<= 100` rooms?
  - If ANY check fails: return `{ requiresFullSync: true }`.
  - If ALL pass: fetch `HMGET user:{userId}:rooms_data ...dirtyRoomIds` and return:
    `{ requiresFullSync: false, pts: Number(meta.current_pts), epoch: meta.epoch, rooms: [...] }`.
- `GET /rooms?limit=25&beforeSortTimestamp=...&beforeRoomId=...`:
  - **Page 1 (No cursor — Full Sync):**
    - Reads `user.pts` from MongoDB. Ensures `user:{userId}:meta` exists in Redis (if not, initializes `epoch = uuid()`, `min_pts = user.pts`, `current_pts = user.pts`).
    - In legacy mode without `pinnedLimit`, queries ALL pinned rooms (`pinAt != null, deletedAt == null`, subject to the explicit budget below) sorted by `pinAt: -1, roomId: -1` PLUS the top 25 unpinned rooms (`pinAt == null, deletedAt == null`) sorted by `sortTimestamp: -1, roomId: -1`, performing `$lookup` on `messages` for `lastMessageId`.
    - Returns `{ pts: currentPts, epoch, rooms: [...], nextCursor: { beforeSortTimestamp, beforeRoomId } | null }`.
  - **Page 2+ (With cursor — Load More Unpinned Rooms):**
    - Queries `room_members` where `userId == myId`, `deletedAt == null`, `pinAt == null`, and `(sortTimestamp < beforeSortTimestamp) OR (sortTimestamp == beforeSortTimestamp AND roomId < ObjectId(beforeRoomId))` sorted by `sortTimestamp: -1, roomId: -1`, limit `25`.
  - **Optional bounded pinned pages:** `pinnedLimit=1..100` bounds the pinned slice and adds `pinnedNextCursor: { beforePinAt, beforePinnedRoomId } | null`. Follow-up `pinnedOnly=true` with that limit and both cursor fields returns only the next pinned slice (`pinAt DESC, roomId DESC`), with unpinned `nextCursor: null`. Consumers must finish pinned reconciliation before replacing their full inbox snapshot. Legacy all-pinned responses fail explicitly with 413 above `LEGACY_PINNED_MAX_ROOMS` (default 1,000). Pin pages do not replace or move the unpinned page boundary.
- `GET /rooms/direct-peer/:peerUserId`:
  - Checks if direct room exists by `directPairKey`. If not, returns `{ exists: false, room: null, peerUser }` without writing to DB.
- `POST /rooms/group` `{ title, participantIds, avatarUrl? }`:
  - Creates group room (omitting `directPairKey`) and `room_members` for all participants.
- `PATCH /rooms/:roomId/preferences` `{ pin?: boolean, isMuted?: boolean }`:
  - Omitted fields are unchanged. Present fields must be booleans; explicit `null`, strings, and numbers return `400` without changing preferences or revision counters.
  - Updates `pinAt` and/or `isMuted` on caller's `room_members` row (`roomPts = newPts`, `msgPts` unchanged, `sortTimestamp` unchanged), and publishes `eventType: 'room_preferences'`.

### 4.4 Messages, Idempotent Send, Edit/Delete & Reply Context

Post-commit inbox work uses bounded per-process concurrency (default 8), a waiting-work cap (1,000) and a shared 10-second deadline per mutation (`INBOX_FANOUT_DEADLINE_MS`). Expired waiting jobs are removed before execution. Redis has a 1,500ms response timeout (`REDIS_COMMAND_TIMEOUT_MS`); each post-commit command is additionally bounded by the remaining deadline. The upsert above and cache-invalidation Lua check Redis server time before mutating, preventing delayed/replayed work from applying after that deadline. Keep backend and Redis clocks synchronized. A timed-out response can still be ambiguous about work accepted before the deadline; MongoDB revision fences and full-sync recovery remain authoritative.

Each provider publish attempt is bounded by `REALTIME_PUBLISH_TIMEOUT_MS` (default 2,500ms) and the remaining deadline, within the three-attempt policy above. Deadline/queue/cache/provider failure is diagnostic and cannot roll back or fail an already committed send. These bounds cover the advisory post-commit lane, not the preceding MongoDB transaction or arbitrary proxy/client network time. They do not establish multi-instance or production capacity.

- `POST /messages` `{ roomId?, peerUserId?, idempotencyKey, type, text, imageUrl?, replyToMessageId? }`:
  - **Idempotency & Concurrency:** Check `messages.findOne({ senderId: myId, idempotencyKey })`. Also catch MongoDB error code `11000` (duplicate key) on concurrent retry and return the existing message + current room state (`200 OK`).
  - All clients use the same composite identity, including their local unique constraint and optimistic matching. Another sender reusing the UUID creates a separate message and must not replace a cached row.
  - **Reply Validation:** If `replyToMessageId` is set, verify the target message belongs to the same `roomId` and `deletedForUsers` does not contain `myId`.
  - **Image URL Validation:** If `type == 'image'`, require a safe `/public/uploads/` filename and authorized owned/reusable media. Mark new media attached in the same MongoDB transaction as the message; merely knowing a path does not grant access.
  - **Transaction:** Lazy-create direct room + `room_members` if `!roomId && peerUserId`. Insert message. Update all participants' `room_members` (`lastMessageId = msg._id`, `sortTimestamp = msg.createdAt`, `deletedAt = null`, `unreadCount += 1` for receivers, `roomPts = newPts`, `msgPts = newPts`).
- `GET /rooms/:roomId/messages?limit=30&beforeCreatedAt=...&beforeId=...`:
  - Verifies room membership. Filters `roomId`, `deletedForUsers: { $nin: [myId] }`, `createdAt > (clearedAt || 0)`.
  - If cursor provided: `$or: [{ createdAt: { $lt: beforeCreatedAt } }, { createdAt: beforeCreatedAt, _id: { $lt: ObjectId(beforeId) } }]`.
  - Sorted by `createdAt: -1, _id: -1`, limit `30`. Returns `{ messages, hasMore, receipts? }`.
  - For the latest page of a **direct** room, `receipts` is `{ deliveredThrough: string | null, seenThrough: string | null, hasGaps: boolean }`. Each boundary is the maximum **message `createdAt`**, in UTC ISO format, among the caller's outgoing messages actually delivered/seen. It is not the server action time or the peer's outgoing boundary. Membership, the page and receipt summary use one coherent MongoDB read snapshot.
  - `hasGaps` is true if an outgoing message at or before either corresponding acknowledged boundary is still unacknowledged, including equal-timestamp concurrency. Such a state cannot be represented safely as a timestamp prefix: clients retain the exact returned rows and invalidate uncertifiable older sent history instead of promoting ticks from the summary. Otherwise clients can update receipts throughout retained sent history before marking it current. Group rooms and older pagination pages may omit `receipts`. Existing consumers may ignore this additive response field; newer clients use a safe invalidation fallback if a legacy server omits it.
- `GET /rooms/:roomId/messages/around/:targetMessageId?limit=30`:
  - Verifies room membership and that `targetMsg` is in `roomId`, not in `deletedForUsers`, and `!targetMsg.isDeletedForAll`.
  - Queries 15 messages with `(createdAt < target.createdAt) OR (createdAt == target.createdAt AND _id < target._id)` and 15 messages after, **explicitly includes `targetMsg`**, and returns `{ targetMessageId, messages: [...sorted DESC] }`.
  - Membership, target and both context sides use one MongoDB snapshot. Concurrent edit/delete therefore yields a coherent before/after snapshot; client revision fences reconcile later changes.
- `PATCH /messages/:messageId` `{ text }` (Sender Only):
  - Updates `text`, `isEdited = true`, `editedAt = now`.
  - Updates `room_members` for all participants (`roomPts = newPts`, `msgPts = newPts`, `lastHistoryEditPts = newPts`) and publishes `eventType: 'message_edited'` with `updatedMessage`.
  - If the original is hidden for a participant, omit its full `updatedMessage`. When that participant still has a visible matching reply, include a `quoteUpdate` snapshot with only the existing reply fields and text truncated to 120 characters. Without a visible matching reply, omit `quoteUpdate`. Clients rewrite references without inserting the hidden original.
- `DELETE /messages/:messageId/for-all` (Sender Only):
  - Sets `isDeletedForAll = true`, `text = "🚫 This message was deleted"`, `imageUrl = null`.
  - Updates any messages in `roomId` where `replyTo.messageId == messageId` -> sets `replyTo.isDeleted = true`, `replyTo.text = "🚫 This message was deleted"`, and **`replyTo.imageUrl = null`**.
  - A participant who hid the original but still has a visible matching reply receives a quote-only `quoteUpdate` carrying that target ID, deletion text, `isDeleted: true` and `imageUrl: null`. Without a visible matching reply, omit `quoteUpdate`. Visible replies must be sanitized even though the original remains hidden. This is not permission to reinsert the original message locally.
  - Updates `room_members` for all participants (`roomPts = newPts`, `msgPts = newPts`, `lastHistoryEditPts = newPts`) and publishes `eventType: 'message_deleted_all'`.
- `DELETE /messages/:messageId/for-me` (Any Participant):
  - Adds `myId` to `messages.deletedForUsers`.
  - If caller's `room_members.lastMessageId == messageId`, rolls back `lastMessageId` to the previous visible message for caller (`sortTimestamp` unchanged).
  - Updates ONLY caller's `room_members` (`roomPts = newPts`, `msgPts = newPts`, `lastHistoryEditPts = newPts`) and publishes `eventType: 'message_deleted_me'`.

### 4.5 Room-Level Delivered & Seen (Strict Separation of Reader vs. Sender Events)

- `POST /rooms/:roomId/delivered` & `POST /rooms/delivered-batch` `{ roomIds: string[], upToTimestamp?: string }`:
  - Verifies caller is a member of each room (`roomType == 'direct'`).
  - Updates `messages` where `roomId == X`, `senderId != myId`, `deliveredAt == null`, and `createdAt <= (upToTimestamp || now)` -> sets `deliveredAt = now`.
  - If `modifiedCount > 0`: increments **the peer sender's** `pts` (`roomPts = newPts`, `msgPts = newPts`) and publishes **`eventType: 'room_delivered'`** (`actionTimestamp: boundary`) ONLY to `inbox:user#<peerSenderId>`. The boundary is `min(upToTimestamp, now)`, or `now` when omitted.
- `POST /rooms/:roomId/seen` `{ upToTimestamp?: string }`:
  - Verifies caller is a member of `roomId`.
  - **Step 1 (Reader's Own Unread Badge Sync):** If caller's `unreadCount > 0`, sets `unreadCount = 0`, increments **caller's** `pts` (`roomPts = newPts`, **`msgPts` UNCHANGED**), and publishes **`eventType: 'room_unread_cleared'`** to `inbox:user#<callerId>`.
  - **Step 2 (Sender's Blue Ticks — Direct Rooms Only):** Runs pipeline update on `messages` where `roomId == X`, `senderId != myId`, `seenAt == null`, and `createdAt <= (upToTimestamp || now)`:
    `$set: { deliveredAt: { $ifNull: ['$deliveredAt', now] }, seenAt: now, updatedAt: now }`.
    If `modifiedCount > 0`: increments **the peer sender's** `pts` (`roomPts = newPts`, `msgPts = newPts`) and publishes **`eventType: 'room_peer_seen'`** (`actionTimestamp: boundary`) ONLY to `inbox:user#<peerSenderId>`, using the same clamped boundary as delivery.

### 4.6 Sequence receipt extension

New messages receive a positive, immutable `messageSeq` from a per-room counter in the same MongoDB transaction as insertion. The `(roomId, messageSeq)` unique partial index applies only to sequenced messages; existing messages keep a null sequence, retain their exact receipt dates and use the legacy path. Idempotent send retries keep the original sequence. No history renumbering or destructive migration is required.

Room members retain `headSeq`, `contentPts`, `ownDeliveredSeq`, `ownSeenSeq`, `peerDeliveredSeq` and `peerSeenSeq`. Own cursors describe incoming acknowledgement; peer cursors describe outgoing statuses. Seen implies delivered, and cursor values never decrease. `contentPts` changes for message content events; `msgPts` still includes peer receipts. Receipts do not move sort order or history-edit revisions.

Receipt endpoints accept an explicit safe integer `upToSeq` alongside the compatible timestamp form. Sequence requests reject future positions. The transaction applies sequence predicates, stores exact per-message dates and updates cumulative state. Bounded Seen leaves messages above its boundary unread. Delivery batches support per-room sequence targets. Boundary forms must not be ambiguously combined.

Message responses add `receiptState` (the four own/peer cursors) and `coverage` (`roomPts`, `msgPts`, `contentPts`, `lastHistoryEditPts`, `headSeq`, `fromSeq`, `throughSeq`) from the same MongoDB snapshot. The interval proves all visible sequenced bodies within it are included; chronological pagination cannot assume sequence order. Clients join verified intervals instead of acknowledging a maximum observed sequence across a hole.

`RECEIPT_PUSH_MODE=legacy` preserves full publications for older clients. Hydrated rooms advertise `receiptProtocol: legacy | sequence`; sequence acknowledgements are accepted only under the coordinated `compact` mode. A sequence Seen action includes legacy pre-cutover history; if legacy dates change, its peer receipt publication remains hydrated. Sequence Delivery acknowledges only sequenced bodies. Under `compact`, sequenced-only peer receipt changes publish `{pts, epoch, receipt: {roomId, eventType, peerDeliveredSeq, peerSeenSeq, contentPts}}`. Own unread changes publish `{pts, epoch, unread: {eventType: "room_unread_cleared", roomId, unreadCount, ownDeliveredSeq, ownSeenSeq}}`, including partial reads with a nonzero remaining count. This event advances account `pts` and `roomPts` only; it preserves `msgPts`, `contentPts`, history revisions and message ordering. Redis retains complete hydrated snapshots with durable cursors, so coalesced preferences cannot erase receipt or unread state. Legacy peer receipt events remain hydrated. Own progress is returned in the acknowledgement response without an additional progress-only publication; lagging own checkpoints are safe. See [implementation validation](RECEIPT_SEQUENCE_VALIDATION.md).

### 4.7 Presence and Explicit Logout

- Centrifugo connection presence on `inbox:user#<userId>` determines online status. There is no application presence lease. A bounded last-seen observer retains tracked users in Redis across API restarts and reads Centrifugo snapshots in batches of up to 100 (`LAST_SEEN_CHECK_SECONDS=30`, configurable 1–300 seconds). Connect admission and confirmed online snapshots record last known connection activity; after all sockets disappear, MongoDB `$max` persists that time as `lastSeenAt`, then clears only the observation metadata. Provider/MongoDB failure keeps the observation pending; reconnection versions and visibility leases fence stale completion. This is an approximate observation timestamp, not an exact disconnect time, and dependency outages can increase the gap. Another active login prevents offline persistence. Last-seen updates never advance inbox/message counters or room order.
- Authenticated no-body `POST /presence/heartbeat` remains a deprecated compatibility no-op returning `{ok:true}`; it validates/rate-limits requests but does not create presence keys or update online status.
- No-body `POST /presence/offline` idempotently retires that login for the maximum 24-hour access-token lifetime, rejects subsequent authenticated API/token requests and disconnects only its Centrifugo clients. Other connected devices remain online. Redis auth revocations use `auth-session:<userId>:retired:<sessionHash>`; existing legacy revocation keys are honored until their original TTL expires.
  - Retirement precedes and is independent of the compatibility heartbeat bucket and provider-work quota. Separate logout limits (`REALTIME_LOGOUT_USER_LIMIT`, `REALTIME_LOGOUT_IP_LIMIT`; defaults 30/user and 120/IP per minute) bound disconnect work after retirement. Quota exhaustion still returns `{ok:true}` and does not undo retirement.
  - Retirement and one persistent disconnect job are written atomically in Redis before optional immediate provider work. Quota-skipped/failed work remains queued without another client request. A worker resumes on API startup, checks pending work every second, permits four concurrent jobs per process, and retries failures with 1/2/4/8/16/30-second capped backoff. Redis-time visibility leases (60 seconds) and completion fencing support multiple workers and recovery after crashes. Successful early passes retain a final verification at least 15 seconds after retirement to cover bounded in-flight connects. Jobs/completed tombstones expire after 24 hours plus 60 seconds. The same otherwise valid retired login may call this idempotent endpoint again; other authenticated endpoints remain denied. Provider disconnect failure still returns `{ok:true}` once revocation and retry work are retained. Redis loss also loses these auth records unless Redis persistence recovers them.
  - Connect/reconnect validates the signed connection-data JWT, user and login revocation, then returns `expire_at = sessionExpiresAt`. Periodic server refresh callbacks are disabled. Centrifugo's native expiration timer closes the socket at the login expiry plus its configured grace; direct JWT verification/client token refresh cannot bypass admission. The protected old refresh callback remains fail-closed (`expired: true`) for provider restart compatibility.
- GET/POST `/presence/status` returns current boolean statuses for at most 100 IDs, restricted to self and shared-room contacts; unrelated IDs are omitted before provider queries. A single bounded Centrifugo batch reads each permitted inbox's `presence_stats`. Provider errors/malformed responses return 503 rather than falsely reporting offline. Snapshots are not cached. The additive `lastSeenAt` map includes only permitted offline users and reads their retained MongoDB timestamps; it never discloses unrelated users or changes directory discovery.
- Flutter refreshes current authorized snapshots while foreground; the backend no longer emits application `presence_changed` hints. Existing clients may still accept legacy hints as invalidations. Presence never advances inbox/message counters. Socket failure detection and provider presence cleanup govern offline timing. See [local Centrifugo and presence](centrifugo/README.md).

## 5. Operational Debug Traffic Logs

- HTTP completion JSON includes `timestamp`, validated `userId` (`null` if anonymous), `requestId`, route/method, status and duration. Successful public auth may identify the user from its trusted response. OPTIONS produces no traffic log.
- `HTTP_LOGGING_ENABLED` controls HTTP completion logging. Opt-in `DEBUG_TRAFFIC_LOGGING_ENABLED` adds complete JSON request/response bodies, parameters, queries and sanitized headers, and enables realtime publish-attempt logging. `HTTP_LOGGING_ENABLED` defaults true and full debug capture defaults false in the logger itself; `npm run start:dev` and `npm run start:debug` default it on and configure private Logdy input files, preserving explicit environment settings. Full capture requires development, or production with the explicit `ALLOW_PRODUCTION_DEBUG_TRAFFIC_LOGGING` override as well. A safe startup record exposes the requested/effective policy; oversized records become omission envelopes.
- Every realtime attempt records the original HTTP actor and request ID through async context, recipient/channel, complete published data, provider response/result, duration, and a publication ID stable across retries. A provider-accepted publication is not proof of client receipt.
- Always redact credentials recursively, including bearer material and credential URL parameters. Represent binary uploads/streams as metadata. Logging failures must not change requests, responses, committed mutations or publication retries. Do not add log fields to application wire payloads or persist a new message event log.

Local traffic presentation is independent of capture: development terminals default to compact summaries; `TRAFFIC_LOG_FORMAT=json` retains structured stdout and `silent` suppresses traffic console output. Explicit `TRAFFIC_LOG_FILE` enables asynchronous, bounded-queue, credential-redacted append-only JSONL capture. File/console failures never alter request or publication behavior. The separate loopback Logdy viewer provides expandable JSON, filtering and export without adding application endpoints or a message event log. See [Backend logging](BACKEND_LOGGING.md).
