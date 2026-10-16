# FLUTTER CLIENT SPECIFICATION (FLUTTER_SPEC.md)
# Target Platforms: Android & Web ONLY (Flutter 3.44+ / Dart 3.12+)
# Stack: Flutter + Drift (SQLite) + centrifuge + v_platform + v_chat_bubbles + v_chat_input_ui

## 1. REQUIRED PACKAGES (`mobile_and_web/pubspec.yaml`)
- **Database:** `drift`, `drift_flutter`, `sqlite3_flutter_libs`, `path_provider`, `path` (Dev: `drift_dev`, `build_runner`)
- **Realtime & Networking:** `centrifuge: ^0.20.1`, `dio`, `shared_preferences`, `uuid`
- **UI & File Packages (Use Exact Exported Widget Names):**
  - `v_platform` (`VPlatformFile`, `VPlatformFileUtils`)
  - `v_chat_bubbles` (`VBubbleStyle.telegram`, `VTextBubble`, `VImageBubble`, `VDeletedBubble`, `VReplyData`, `VBubbleHeader`)
  - `v_chat_input_ui` (`VMessageInputWidget`)
- **State Management:** `flutter_riverpod`

---

## 2. SINGLE DRIFT SQLITE DATABASE & SERIALIZED SYNC QUEUE

We use **one single database (`chat_app_db`)** across Android and Web (`driftDatabase(name: 'chat_app_db')`).
On logout or switching between Debug Users `User 1..5`:
1. Disconnect Centrifugo (`await centrifugoClient.disconnect()`).
2. Clear the serialized sync queue and increment `sessionGenerationId++`.
3. Call `await db.clearAllTables()`.

### Exact Drift Tables (`app_database.dart`)

#### Table 1: `SyncMetadata` (Single row `id = 1`)
- `id`: `IntColumn` (PK, default `1`)
- `userId`: `TextColumn`
- `localPts`: `IntColumn` (default `0`)
- `localEpoch`: `TextColumn` (default `''`)

#### Table 2: `LocalRooms`
- `roomId`: `TextColumn` (PK)
- `roomType`: `TextColumn` (`'direct' | 'group'`)
- `peerUserId`: `TextColumn.nullable()`
- `displayTitle`: `TextColumn`
- `displayAvatarUrl`: `TextColumn.nullable()`
- `pinAt`: `IntColumn.nullable()` (epoch ms)
- `isMuted`: `BoolColumn` (default `false`)
- `unreadCount`: `IntColumn` (default `0`)
- `clearedAt`: `IntColumn.nullable()`
- `deletedAt`: `IntColumn.nullable()`
- `sortTimestamp`: `IntColumn` (epoch ms — updated ONLY on new message)
- `roomPts`: `IntColumn` (latest `roomPts` from server)
- `msgPts`: `IntColumn` (latest `msgPts` from server — only moves on message/tick events)
- `lastHistoryEditPts`: `IntColumn` (default `0` — moves when an existing message is edited/deleted)
- `messagesSyncedPts`: `IntColumn` (default `0` — equals `msgPts` when local messages are synced)
- `lastMessageJson`: `TextColumn.nullable()` (Full JSON of `lastMessage`)

#### Table 3: `LocalMessages`
- `id`: `TextColumn` (PK — server `_id`, or `temp_${idempotencyKey}` while `'sending'`)
- `idempotencyKey`: `TextColumn` (unique)
- `roomId`: `TextColumn` (indexed — for draft direct messages before room creation, use `"draft_${peerUserId}"` and update to real `roomId` on send completion)
- `peerUserId`: `TextColumn.nullable()` (used to retry failed first message in a lazy direct room after app restart)
- `senderId`: `TextColumn`
- `senderName`: `TextColumn`
- `senderAvatarUrl`: `TextColumn.nullable()`
- `type`: `TextColumn` (`'text' | 'image'`)
- `text`: `TextColumn`
- `imageUrl`: `TextColumn.nullable()`
- `replyToJson`: `TextColumn.nullable()`
- `status`: `TextColumn` (`'sending' | 'sent' | 'failed'`)
- `isEdited`: `BoolColumn` (default `false`)
- `isDeletedForAll`: `BoolColumn` (default `false`)
- `deliveredAt`: `IntColumn.nullable()`
- `seenAt`: `IntColumn.nullable()`
- `createdAt`: `IntColumn` (indexed, epoch ms)

---

## 3. SERIALIZED `InboxSyncQueue` & CENTRIFUGO `inbox:user#<userId>`

### 3.1 Connection & Token Refresh
- Connect `centrifuge-dart` to `ws://localhost:8000/connection/websocket` with `token` and a `getToken` callback that calls `POST /auth/centrifugo-token` whenever the token expires.
- Subscribe to **`inbox:user#${currentUserId}`**.
- **Mandatory Sync Triggers:** Whenever `SubscribedEvent` fires (on initial connect AND every auto-reconnect) OR when the app resumes (`AppLifecycleState.resumed`), enqueue `syncInboxDelta()` in the `InboxSyncQueue`.

### 3.2 Serialized Event Processing (Prevents Interleaving & Race Conditions)
All live socket publications and `syncInboxDelta()` operations run sequentially inside a single async mutex/queue (`InboxSyncQueue`):
1. **When a live socket event `{ pts, epoch, room }` arrives:**
   - Inside a **single Drift transaction**, read `(localPts, localEpoch)` from `SyncMetadata`.
   - If `localEpoch.isEmpty || epoch != localEpoch || pts > localPts + 1`:
     -> **GAP DETECTED!** Trigger `syncInboxDelta()` immediately.
   - If `pts <= localPts`:
     -> Already reconciled via delta sync. Ignore.
   - If `pts == localPts + 1`:
     -> Apply `applyRoomPayloadInTx(room)` (only if `room.roomPts >= existingLocalRoom.roomPts`), set `SyncMetadata.localPts = pts`, and emit `room` on the broadcast stream `roomEventsStream`.
2. **When `syncInboxDelta()` runs (`GET /rooms/delta?sincePts=$localPts&epoch=$localEpoch`):**
   - If `requiresFullSync == false`:
     - Inside one Drift transaction, apply each returned `room` (where `room.roomPts > localRoom.roomPts`) and set `SyncMetadata.localPts = response.pts`, `localEpoch = response.epoch`.
   - If `requiresFullSync == true`:
     - Call `GET /rooms?limit=25`.
     - Inside one Drift transaction: **delete all rows from `LocalRooms` that are not in the fresh top-25 response** (preventing stale unrefreshed rooms #26..#100 from lingering), reset `messagesSyncedPts = 0`, insert the fresh rooms, and set `SyncMetadata.localPts = response.pts`, `localEpoch = response.epoch`.

### 3.3 Exact `applyRoomPayloadInTx(room)` Rules
1. Upsert `LocalRooms` (`roomPts = room.roomPts`, `msgPts = room.msgPts`, `lastHistoryEditPts = room.lastHistoryEditPts`, `lastMessageJson = jsonEncode(room.lastMessage)`).
2. Upsert `room.lastMessage` into `LocalMessages` (matching by `idempotencyKey` first so an optimistic `'sending'` row upgrades cleanly to `'sent'`).
3. If `room.updatedMessage != null`:
   - If `room.eventType == 'message_deleted_me'`: delete `room.updatedMessage.id` from `LocalMessages`.
   - Else: upsert `room.updatedMessage` into `LocalMessages` and update any `LocalMessages.replyToJson` referencing that message ID.
4. **Strict Receipt Handling (`room_delivered` vs `room_peer_seen` vs `room_unread_cleared`):**
   - `room_unread_cleared`: Only updates `LocalRooms.unreadCount = 0` (already handled in step 1). **NEVER touches `LocalMessages.seenAt`!**
   - `room_delivered`:
     `UPDATE local_messages SET delivered_at = COALESCE(delivered_at, :actionTs) WHERE room_id = :roomId AND sender_id = :myUserId AND delivered_at IS NULL AND created_at <= :actionTs`
   - `room_peer_seen`:
     `UPDATE local_messages SET delivered_at = COALESCE(delivered_at, :actionTs), seen_at = COALESCE(seen_at, :actionTs) WHERE room_id = :roomId AND sender_id = :myUserId AND seen_at IS NULL AND created_at <= :actionTs`
5. **If the user currently has `room.roomId` open on the Messages Page:**
   - Advance `LocalRooms.messagesSyncedPts = room.msgPts` so `msgPts == messagesSyncedPts` remains true!

---

## 4. UI SCREENS, HOLE-FREE MESSAGE SYNC & 2-TIER REPLY JUMP

### 4.1 Screen 1: Debug User Switcher (`User 1..5`) & Auth
- One-tap login cards for `User 1..5` plus standard Login/Signup form.
- On startup, sweep `LocalMessages WHERE status = 'sending'` and mark interrupted rows as `'failed'` so the user can tap Retry.

### 4.2 Screen 2: Telegram-Style Main Rooms Tab
- **Reactive Drift Stream:**
  ```sql
  SELECT * FROM local_rooms
  WHERE deleted_at IS NULL
  ORDER BY
    CASE WHEN pin_at IS NOT NULL THEN 1 ELSE 0 END DESC,
    pin_at DESC,
    sort_timestamp DESC,
    room_id DESC
  ```
- **Load More Pagination Cursor:**
  - Find the **oldest unpinned room** (`pinAt == null`) in `LocalRooms` and call:
    `GET /rooms?limit=25&beforeSortTimestamp=${oldestUnpinned.sortTimestamp}&beforeRoomId=${oldestUnpinned.roomId}`.

### 4.3 Screen 3: Telegram-Style Messages Page (`VBubbleStyle.telegram` + `VMessageInputWidget`)
- **Windowed Reactive Stream:** Watch `SELECT * FROM local_messages WHERE room_id = :roomId ORDER BY created_at DESC, id DESC LIMIT :currentWindowLimit` (starts at `50`, increases by `+30` as the user scrolls up).
- **Zero-Bandwidth & Hole-Free Sync on Room Open / Reconnect:**
  - Wait for any active `syncInboxDelta()` to finish first so `localRoom.msgPts` is verified up to date.
  - Check: `if (localRoom.msgPts == localRoom.messagesSyncedPts && localMessagesCount > 0)` -> **Do nothing! Render 100% from local SQLite (0 HTTP requests).**
  - Otherwise (`msgPts != messagesSyncedPts`):
    1. Call `GET /rooms/:roomId/messages?limit=30`.
    2. **Hole & History-Edit Check (Inside 1 Drift Transaction):**
       - Check if `oldestReturnedMsg.id` already exists in `LocalMessages` AND `localRoom.lastHistoryEditPts <= localRoom.messagesSyncedPts`.
       - **If YES (Overlap & No Old Edits):** Upsert the 30 messages and prune any local message with `createdAt >= oldestReturnedMsg.createdAt` that is missing from the 30 returned messages.
       - **If NO (>30 messages arrived while offline, OR an older message was edited/deleted while offline):** Delete all non-sending rows in `LocalMessages` for `roomId` (`WHERE room_id = :roomId AND status != 'sending'`) and insert the fresh 30 messages so SQLite never has a pagination hole or stale old edit!
    3. Set `LocalRooms.messagesSyncedPts = localRoom.msgPts`.
- **2-Tier Reply Jump (`VReplyData` Tap):**
  - **Tier 1:** If `replyTo.messageId` is in `LocalMessages`, scroll to it and trigger the 1.5s highlight animation.
  - **Tier 2 (500+ Messages Back):** Call `GET /rooms/:roomId/messages/around/:targetMessageId?limit=30`, switch to in-memory `isJumpMode = true` centered on `targetMessageId` with a floating **`⬇ Return to Latest Messages`** button, and listen to `roomEventsStream` to apply live edits/deletes to the in-memory slice while open.