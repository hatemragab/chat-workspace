# BACKEND SPECIFICATION (BACKEND_SPEC.md)
# Stack: NestJS + Mongoose (Replica Set Transactions) + ioredis (Lua Atomic) + Multer + Centrifugo

## 1. ENVIRONMENT VARIABLES (`backend/.env`)
```env
PORT=3000
NODE_ENV=development
MONGODB_URI=mongodb://localhost:27017/chat_app?replicaSet=rs0
REDIS_URL=redis://localhost:6379
JWT_SECRET=super_secret_jwt_key_change_in_prod
CENTRIFUGO_TOKEN_HMAC_SECRET_KEY=centrifugo_hmac_secret_key
CENTRIFUGO_API_URL=http://localhost:8000/api
CENTRIFUGO_API_KEY=centrifugo_http_api_key
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
  unreadCount: number,              // Incremented on incoming message; reset to 0 on seen
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

---

## 3. TRANSACTIONAL MONGODB + ATOMIC REDIS LUA `pts` ENGINE

### 3.1 Hydrated Room Payload (`HydratedRoomPayload`)
Stored in Redis `user:{userId}:rooms_data` (`field: roomId`) and published to Centrifugo `inbox:user#<userId>`:
```typescript
interface HydratedRoomPayload {
  roomId: string;
  roomType: 'direct' | 'group';
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
  lastMessage: FullMessageDto | null;     // Complete message object!
  updatedMessage?: FullMessageDto | null; // Populated when an older message is edited/deleted
  eventType:
    | 'message_new'
    | 'message_edited'
    | 'message_deleted_all'
    | 'message_deleted_me'
    | 'room_delivered'       // Sent to message sender when peer receives messages
    | 'room_peer_seen'       // Sent to message sender when peer reads messages (turns ticks blue)
    | 'room_unread_cleared'  // Sent to reader's own devices when reader opens room (sets unreadCount=0)
    | 'room_preferences'
    | 'room_created';
  actionTimestamp: string;   // ISO timestamp boundary for room_delivered / room_peer_seen
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
   - Call Centrifugo HTTP API (`/api/publish` or `/api/broadcast`) with retry backoff (3 attempts: 100ms, 300ms, 1000ms):
     `{ channel: "inbox:user#" + userId, data: { pts: newPts, epoch, room: roomPayload } }`.

---

## 4. COMPLETE REST API ENDPOINTS & AUTHORIZATION RULES

### 4.1 Security & Membership Guards (Mandatory on All Endpoints)
- **Room Membership Check:** Every `/rooms/:roomId/*` and `/messages/*` endpoint MUST verify that a `room_members` row exists for `{ roomId, userId: currentUserId }` before reading or modifying data. Return `403 Forbidden` otherwise.
- **Upload Validation:** `POST /uploads/image` (Multer) MUST enforce `fileSize <= 5 * 1024 * 1024` (5MB), validate MIME type (`image/jpeg`, `image/png`, `image/webp`, `image/gif`), and generate a safe server extension (`.jpg`, `.png`, `.webp`, `.gif`).

### 4.2 Auth, Users & Debug Switcher
- `GET /auth/debug-users` (enabled when `NODE_ENV === 'development'`) -> Returns seeded `User 1..5`.
- `POST /auth/debug-login` `{ debugUserNumber: 1..5 }` -> Returns `{ user, accessToken, centrifugoToken }`.
- `POST /auth/signup`, `POST /auth/login` -> Standard auth returning `{ user, accessToken, centrifugoToken }`.
- `POST /auth/centrifugo-token` (JWT Guard) -> Returns a refreshed `{ centrifugoToken }` so Flutter's `centrifuge-dart` `getToken` callback can renew expired tokens automatically.
- `GET /users` (JWT Guard) -> Returns list of users (`_id, username, displayName, avatarUrl`) so the client can start new Direct Chats or create Groups.

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
    - Queries ALL pinned rooms (`pinAt != null, deletedAt == null`) sorted by `pinAt: -1, roomId: -1` PLUS the top 25 unpinned rooms (`pinAt == null, deletedAt == null`) sorted by `sortTimestamp: -1, roomId: -1`, performing `$lookup` on `messages` for `lastMessageId`.
    - Returns `{ pts: currentPts, epoch, rooms: [...], nextCursor: { beforeSortTimestamp, beforeRoomId } | null }`.
  - **Page 2+ (With cursor — Load More Unpinned Rooms):**
    - Queries `room_members` where `userId == myId`, `deletedAt == null`, `pinAt == null`, and `(sortTimestamp < beforeSortTimestamp) OR (sortTimestamp == beforeSortTimestamp AND roomId < ObjectId(beforeRoomId))` sorted by `sortTimestamp: -1, roomId: -1`, limit `25`.
- `GET /rooms/direct-peer/:peerUserId`:
  - Checks if direct room exists by `directPairKey`. If not, returns `{ exists: false, room: null, peerUser }` without writing to DB.
- `POST /rooms/group` `{ title, participantIds, avatarUrl? }`:
  - Creates group room (omitting `directPairKey`) and `room_members` for all participants.
- `PATCH /rooms/:roomId/preferences` `{ pin?: boolean, isMuted?: boolean }`:
  - Updates `pinAt` and/or `isMuted` on caller's `room_members` row (`roomPts = newPts`, `msgPts` unchanged, `sortTimestamp` unchanged), and publishes `eventType: 'room_preferences'`.

### 4.4 Messages, Idempotent Send, Edit/Delete & Reply Context
- `POST /messages` `{ roomId?, peerUserId?, idempotencyKey, type, text, imageUrl?, replyToMessageId? }`:
  - **Idempotency & Concurrency:** Check `messages.findOne({ senderId: myId, idempotencyKey })`. Also catch MongoDB error code `11000` (duplicate key) on concurrent retry and return the existing message + current room state (`200 OK`).
  - **Reply Validation:** If `replyToMessageId` is set, verify the target message belongs to the same `roomId` and `deletedForUsers` does not contain `myId`.
  - **Image URL Validation:** If `type == 'image'`, verify `imageUrl` starts with `"/public/uploads/"`.
  - **Transaction:** Lazy-create direct room + `room_members` if `!roomId && peerUserId`. Insert message. Update all participants' `room_members` (`lastMessageId = msg._id`, `sortTimestamp = msg.createdAt`, `deletedAt = null`, `unreadCount += 1` for receivers, `roomPts = newPts`, `msgPts = newPts`).
- `GET /rooms/:roomId/messages?limit=30&beforeCreatedAt=...&beforeId=...`:
  - Verifies room membership. Filters `roomId`, `deletedForUsers: { $nin: [myId] }`, `createdAt > (clearedAt || 0)`.
  - If cursor provided: `$or: [{ createdAt: { $lt: beforeCreatedAt } }, { createdAt: beforeCreatedAt, _id: { $lt: ObjectId(beforeId) } }]`.
  - Sorted by `createdAt: -1, _id: -1`, limit `30`. Returns `{ messages, hasMore }`.
- `GET /rooms/:roomId/messages/around/:targetMessageId?limit=30`:
  - Verifies room membership and that `targetMsg` is in `roomId`, not in `deletedForUsers`, and `!targetMsg.isDeletedForAll`.
  - Queries 15 messages with `(createdAt < target.createdAt) OR (createdAt == target.createdAt AND _id < target._id)` and 15 messages after, **explicitly includes `targetMsg`**, and returns `{ targetMessageId, messages: [...sorted DESC] }`.
- `PATCH /messages/:messageId` `{ text }` (Sender Only):
  - Updates `text`, `isEdited = true`, `editedAt = now`.
  - Updates `room_members` for all participants (`roomPts = newPts`, `msgPts = newPts`, `lastHistoryEditPts = newPts`) and publishes `eventType: 'message_edited'` with `updatedMessage`.
- `DELETE /messages/:messageId/for-all` (Sender Only):
  - Sets `isDeletedForAll = true`, `text = "🚫 This message was deleted"`, `imageUrl = null`.
  - Updates any messages in `roomId` where `replyTo.messageId == messageId` -> sets `replyTo.isDeleted = true`, `replyTo.text = "🚫 This message was deleted"`, and **`replyTo.imageUrl = null`**.
  - Updates `room_members` for all participants (`roomPts = newPts`, `msgPts = newPts`, `lastHistoryEditPts = newPts`) and publishes `eventType: 'message_deleted_all'`.
- `DELETE /messages/:messageId/for-me` (Any Participant):
  - Adds `myId` to `messages.deletedForUsers`.
  - If caller's `room_members.lastMessageId == messageId`, rolls back `lastMessageId` to the previous visible message for caller (`sortTimestamp` unchanged).
  - Updates ONLY caller's `room_members` (`roomPts = newPts`, `msgPts = newPts`, `lastHistoryEditPts = newPts`) and publishes `eventType: 'message_deleted_me'`.

### 4.5 Room-Level Delivered & Seen (Strict Separation of Reader vs. Sender Events)
- `POST /rooms/:roomId/delivered` & `POST /rooms/delivered-batch` `{ roomIds: string[], upToTimestamp?: string }`:
  - Verifies caller is a member of each room (`roomType == 'direct'`).
  - Updates `messages` where `roomId == X`, `senderId != myId`, `deliveredAt == null`, and `createdAt <= (upToTimestamp || now)` -> sets `deliveredAt = now`.
  - If `modifiedCount > 0`: increments **the peer sender's** `pts` (`roomPts = newPts`, `msgPts = newPts`) and publishes **`eventType: 'room_delivered'`** (`actionTimestamp: now`) ONLY to `inbox:user#<peerSenderId>`.
- `POST /rooms/:roomId/seen` `{ upToTimestamp?: string }`:
  - Verifies caller is a member of `roomId`.
  - **Step 1 (Reader's Own Unread Badge Sync):** If caller's `unreadCount > 0`, sets `unreadCount = 0`, increments **caller's** `pts` (`roomPts = newPts`, **`msgPts` UNCHANGED**), and publishes **`eventType: 'room_unread_cleared'`** to `inbox:user#<callerId>`.
  - **Step 2 (Sender's Blue Ticks — Direct Rooms Only):** Runs pipeline update on `messages` where `roomId == X`, `senderId != myId`, `seenAt == null`, and `createdAt <= (upToTimestamp || now)`:
    `$set: { deliveredAt: { $ifNull: ['$deliveredAt', now] }, seenAt: now, updatedAt: now }`.
    If `modifiedCount > 0`: increments **the peer sender's** `pts` (`roomPts = newPts`, `msgPts = newPts`) and publishes **`eventType: 'room_peer_seen'`** (`actionTimestamp: now`) ONLY to `inbox:user#<peerSenderId>`.