# MASTER WORKSPACE BLUEPRINT (CONTEXT.md)
# Project: Production Real-Time Chat (NestJS + MongoDB + Redis + Centrifugo + Flutter)

## 1. MONOREPO WORKSPACE STRUCTURE
```text
chat-workspace/
├── .gitignore
├── CONTEXT.md                 # Root architecture & synchronization contract (READ FIRST)
├── BACKEND_SPEC.md            # NestJS + MongoDB + Redis Lua + Centrifugo specification
├── FLUTTER_SPEC.md            # Flutter + Drift (SQLite) + v_chat UI specification
├── IMPLEMENTATION_ROADMAP.md  # Step-by-step AI build phases & verification tests
├── backend/                   # NestJS TypeScript Backend (http://localhost:3000)
│   ├── public/uploads/        # Local Multer uploaded images
│   └── src/
└── mobile_and_web/            # Flutter App supporting Android & Web
    ├── lib/
    └── web/                   # Contains sqlite3.wasm & drift_worker.js
```

### Local Host Infrastructure (Already Running — Do NOT Use Docker)
- **MongoDB:** Running locally in **Replica Set mode** (`mongodb://localhost:27017/chat_app?replicaSet=rs0`). Multi-document ACID transactions are supported and required for message/room mutations.
- **Redis:** Running locally at `redis://localhost:6379`.
- **Centrifugo v6:** Running locally at `http://localhost:8000`.
  - Namespace `inbox` is configured with `allow_user_limited_channels: true` and `history_size: 0`.
  - **CRITICAL CHANNEL SYNTAX:** Because `:` separates the namespace and `#` restricts the user in Centrifugo, the personal channel name MUST be **`inbox:user#<userId>`** (e.g. `inbox:user#670f...`).
  - Ensure `client.allowed_origins: ["*"]` is set in Centrifugo config for Flutter Web connections.

---

## 2. THE HARDENED `pts`, `roomPts`, AND `msgPts` SYNC CONTRACT

### 2.1 Why Redis Overwrites by `roomId` (Main Rooms List Delta Only)
- We do **NOT** store a per-message event log in MongoDB or Centrifugo.
- Redis holds **only the latest hydrated room state per `roomId`** for each user (`user:{userId}:rooms_data` HASH + `user:{userId}:dirty_rooms` ZSET scored by `roomPts`).
- If a noisy group receives 5,000 messages while a user is offline, Redis overwrites that single `roomId` key 5,000 times. Total memory used for that room = **1 entry**.

### 2.2 The Three Monotonic Counters Per Room
1. **Account `pts` (`users.pts`):** Increments by `+1` on every change affecting that user's inbox.
2. **Room Revision `roomPts` (`room_members.roomPts`):** Stamped with the user's new `pts` whenever *anything* about that room changes (new message, edit, delete, delivered, seen, pin, mute, unread cleared). Used as the score in `user:{userId}:dirty_rooms`.
3. **Message Content Revision `msgPts` (`room_members.msgPts`) & `lastHistoryEditPts`:**
   - `msgPts` is set equal to `newPts` **ONLY** when messages or delivery/seen ticks change (`message_new`, `message_edited`, `message_deleted_all`, `message_deleted_me`, `room_delivered`, `room_peer_seen`).
   - Pinning (`pinAt`), muting (`isMuted`), or clearing your own unread badge (`room_unread_cleared`) updates `roomPts` **without** changing `msgPts`.
   - `lastHistoryEditPts` is set equal to `newPts` **ONLY** on `message_edited`, `message_deleted_all`, or `message_deleted_me`.
   - **Client Bandwidth Rule:** When opening a room (after inbox delta sync completes), Flutter compares `localRoom.msgPts == localRoom.messagesSyncedPts`. If equal, **0 HTTP message requests** are made!

### 2.3 Strict Serialized Client Sync Rules (No Race Conditions)
1. **Mandatory Delta Sync Triggers:** Flutter MUST call `syncInboxDelta()` (`GET /rooms/delta?sincePts=localPts&epoch=localEpoch`) on:
   - App cold start / after login
   - Every Centrifugo `inbox:user#<userId>` subscription `SubscribedEvent` (initial connect & every reconnect)
   - App lifecycle `resumed`
   - Whenever a live socket event arrives with `pts > localPts + 1` or `epoch != localEpoch`.
2. **Single Serialized Queue for `localPts`:**
   - REST mutation responses (`POST /messages`, `PATCH /preferences`, etc.) return the updated resource so the UI can upgrade an optimistic `'sending'` message to `'sent'`, **but REST responses NEVER advance `SyncMetadata.localPts` directly**.
   - Only the serialized `InboxSyncQueue` (processing live `inbox:user#<userId>` events where `pts == localPts + 1` or `/rooms/delta` responses inside a single Drift transaction) advances `localPts`. This prevents a fast REST response (`pts=105`) from causing an in-flight socket event (`pts=104`) to be dropped.