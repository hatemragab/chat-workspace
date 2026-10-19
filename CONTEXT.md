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
  - Namespace `inbox` uses server-side subscriptions with `allow_user_limited_channels: false`, presence enabled and `history_size: 0`. See [local Centrifugo](centrifugo/README.md) for the v6.9.7 configuration and protected diagnostics on loopback port 9000.
  - **CRITICAL CHANNEL SYNTAX:** Because `:` separates the namespace and `#` restricts the user in Centrifugo, the personal channel name MUST be **`inbox:user#<userId>`** (e.g. `inbox:user#670f...`).
  - Configure explicit `client.allowed_origins` for the Flutter Web origins in use (locally `http://localhost:5173` and `http://localhost:5174`), matching API CORS. The NestJS connect proxy validates the signed connection-data JWT and current session before granting the personal subscription.

---

## 2. THE HARDENED `pts`, `roomPts`, AND `msgPts` SYNC CONTRACT

### 2.1 Why Redis Overwrites by `roomId` (Main Rooms List Delta Only)

- We do **NOT** store a per-message event log in MongoDB or Centrifugo.
- Redis holds **only the latest hydrated room state per `roomId`** for each user (`user:{userId}:rooms_data` HASH + `user:{userId}:dirty_rooms` ZSET scored by `roomPts`).
- If a noisy group receives 5,000 messages while a user is offline, Redis overwrites that single `roomId` key 5,000 times. Total memory used for that room = **1 entry**.

### 2.2 The Three Monotonic Counters Per Room

1. **Account `pts` (`users.pts`):** Increments by `+1` on every change affecting that user's inbox.
2. **Room Revision `roomPts` (`room_members.roomPts`):** Stamped with the user's new `pts` whenever _anything_ about that room changes (new message, edit, delete, delivered, seen, pin, mute, unread cleared). Used as the score in `user:{userId}:dirty_rooms`.
3. **Message Content Revision `msgPts` (`room_members.msgPts`) & `lastHistoryEditPts`:**
   - `msgPts` is set equal to `newPts` **ONLY** when messages or delivery/seen ticks change (`message_new`, `message_edited`, `message_deleted_all`, `message_deleted_me`, `room_delivered`, `room_peer_seen`).
   - Pinning (`pinAt`), muting (`isMuted`), or clearing your own unread badge (`room_unread_cleared`) updates `roomPts` **without** changing `msgPts`.
   - `lastHistoryEditPts` is set equal to `newPts` **ONLY** on `message_edited`, `message_deleted_all`, or `message_deleted_me`.
   - **Client Bandwidth Rule:** Opening a room renders cached Drift messages immediately, including sending/failed rows, while recovery runs in the background. After inbox delta sync completes, Flutter compares `localRoom.msgPts == localRoom.messagesSyncedPts`. If equal and cached messages exist, **0 HTTP message requests** are made. Cached display does not certify freshness; a verified baseline covers retained message content **and receipts**, not only the latest 30 rows. Saved-session restoration, cached pagination and local reply navigation remain available without the API.
   - Coalesced room deltas do not preserve every receipt event. The latest direct-message page therefore supplies cumulative outgoing receipt boundaries from the same MongoDB read snapshot. Flutter applies those boundaries to retained sent messages before certifying the cache. If the snapshot reports receipt gaps or a legacy server omits this information, discard uncertifiable older sent history and refetch it through normal pagination when needed.

### 2.3 Strict Serialized Client Sync Rules (No Race Conditions)

Sequence receipt extension: newly created messages have immutable per-room `messageSeq` values, allocated with the room counter inside the message transaction. Existing messages retain a null sequence and their exact dates. Durable `peerDeliveredSeq` / `peerSeenSeq` in room snapshots describe the caller's outgoing ticks; `ownDeliveredSeq` / `ownSeenSeq` describe this account's acknowledged incoming prefix. `contentPts` changes only for message content changes, unlike `msgPts`, which still includes receipts. Compact sequence publications carry `{pts, epoch, receipt: {roomId, eventType, peerDeliveredSeq, peerSeenSeq, contentPts}}`; complete hydrated Redis snapshots remain authoritative for recovery. `RECEIPT_PUSH_MODE=legacy` is the compatibility default, and `compact` enables the coordinated new-client rollout. See [sequence receipt validation](RECEIPT_SEQUENCE_VALIDATION.md).

Under the same compact mode, own unread changes carry `{pts, epoch, unread: {eventType: "room_unread_cleared", roomId, unreadCount, ownDeliveredSeq, ownSeenSeq}}`. The count is authoritative and may remain above zero after a bounded read. Apply the badge and monotonic own cursors with inbox progress in one SQLite transaction. Preserve message revisions, content coverage, preview, ordering and peer ticks. Gaps, unknown rooms and missed events recover from hydrated REST/Redis state; the compact patch never replaces that state.

Delivered acknowledgement requires verified received coverage, not the largest sequence observed. Message responses provide a snapshot-proven sequence coverage interval. A foreground room-read action captures its exact boundary and preserves that target across retry; it cannot clear unread messages above the boundary. Drift stores cursor-derived receipt flags separately from exact receipt timestamps. Receipt state, room revisions and inbox progress are applied transactionally without certifying missing message content.

1. **Mandatory Delta Sync Triggers:** Flutter MUST call `syncInboxDelta()` (`GET /rooms/delta?sincePts=localPts&epoch=localEpoch`) on:
   - App cold start / after login
   - Every Centrifugo `inbox:user#<userId>` subscription `SubscribedEvent` (initial connect & every reconnect)
   - App lifecycle `resumed`
   - Whenever a live socket event arrives with `pts > localPts + 1` or `epoch != localEpoch`.
2. **Single Serialized Queue for `localPts`:**
   - REST mutation responses (`POST /messages`, `PATCH /preferences`, etc.) return the updated resource so the UI can upgrade an optimistic `'sending'` message to `'sent'`, **but REST responses NEVER advance `SyncMetadata.localPts` directly**.
   - Only the serialized `InboxSyncQueue` (processing live `inbox:user#<userId>` events where `pts == localPts + 1` or `/rooms/delta` responses inside a single Drift transaction) advances `localPts`. This prevents a fast REST response (`pts=105`) from causing an in-flight socket event (`pts=104`) to be dropped.

### 2.4 Cross-Layer Identity and Recovery Invariants

- The identity of an idempotent send is **`(senderId, idempotencyKey)`** in MongoDB, SQLite, optimistic acknowledgement matching, and retry. A UUID is not globally unique across senders as an API constraint; two senders may legitimately use the same UUID.
- Capture the initiating account/session and conversation before asynchronous UI work. A text send, complete image batch, direct-room lookup, local write, and acknowledgement must retain that identity or cancel when it becomes invalid. Never rebind old work to a newly selected conversation/account.
- A delayed delete-for-me continuation must recheck its initiating session after mutation reconciliation and inside its local delete transaction. It must not delete a later account's shared message.
- Remapping `draft_<peerUserId>` to a server room ID does not create a different conversation. Preserve its composer text and reply context; clear them on an actual account/conversation change.
- Resolve later optimistic sends in a captured lazy batch through that session's known draft-to-room mapping. Pending or failed images must stay visible in their original conversation with their retry identity intact.
- Persist a local draft inbox summary only when its first optimistic send exists. Keep pending/failed draft summaries across restart and server full sync, then remove the summary atomically when its messages remap to a real room. This does not create a server room on opening a draft.
- Drift schema version 4 preserves the version-3 baseline repair for upgrades from versions 1/2 and adds an account/epoch-scoped server room-page cursor, indexed reply targets and bounded pending-upload bytes. Message rows, drafts, receipts and inbox progress survive the upgrade. Later launches retain newly verified baselines.
- Room pagination retains the API's exclusive unpinned page boundary. Live deltas, room activity and pin/unpin changes never derive or move that boundary from the current local sort order.
- A Web origin permits one active `chat_app_db` writer through an exclusive Web Lock. Duplicate tabs and unsupported lock environments display a retryable ownership screen before opening the database; the two local ports remain independent origins.
- A running session's genuine 401 pauses remote work and offers reauthentication while preserving cached conversations, pending sends and upload bytes. Same-account reauthentication preserves that work; explicit logout or changing accounts clears it. Database/Redis authentication dependency failures return retryable 503 and do not retire the session.
- Seen receipts require the selected conversation to be foreground. A hidden subscribed client may remain online and receive/deliver messages without marking them Seen. Presence-query degradation is reported separately from messaging transport status.
- A hidden original message can still have visible replies. Safe quote-only updates must sanitize those replies without reintroducing the hidden original into SQLite or a historical jump.
- After reconnect/full recovery, a historical jump must recover changes indicated by `lastHistoryEditPts` even when the coalesced room payload has no explicit `updatedMessage`. New tail messages alone do not move the historical viewport.
- Optional debug-user discovery and mandatory network recovery must not block local persisted-session restoration, interrupted-send recovery or cached conversation rendering. Incomplete network setup remains retryable in the background without duplicating the local session.

### 2.5 Presence Lifecycle

Centrifugo inbox presence is the authority for online/offline: a user is online while at least one client is subscribed to `inbox:user#<userId>`. NestJS reads authorized contact snapshots through batched server `presence_stats` calls. A separate last-seen observer checks previously connected users in batches of up to 100 every 30 seconds by default, persisting the last known connection activity to MongoDB only after the final socket disappears. There are no application Redis presence leases or client heartbeats; provider snapshots remain the online/offline authority. Foreground Flutter clients refresh peer snapshots every 30 seconds, on startup/reconnect/resume/manual sync; hidden clients stop snapshot polling but an open socket still counts as online. Logout atomically revokes only the old login and queues persistent disconnect retries for its realtime clients; other connected logins remain online. A separate bounded authentication worker processes pending disconnects, including after API restart. Connections use the actual login expiry and Centrifugo's native expiration timer; periodic server refresh callbacks are disabled. Redis remains responsible for room deltas, rate limits, authentication revocation and disconnect retries. Presence does not advance inbox/message revisions. See [the complete local contract](centrifugo/README.md).

### 2.6 Optional Debug Traffic Inspection

HTTP completion records include UTC timestamps, authenticated user IDs and request IDs, excluding OPTIONS. In development, `DEBUG_TRAFFIC_LOGGING_ENABLED=true` enables full application JSON plus correlated realtime publication attempts through the shared backend logger. Record the causative actor separately from each recipient, and retain the same publication ID across retry attempts. Debug Flutter clients independently support full HTTP/realtime reception logging, a runtime switch and counts over their latest 60 records. Credentials are always redacted and binary payloads use metadata. This instrumentation does not change authentication, API/event payloads, inbox counters or the no-message-event-log architecture.

Backend development terminals use compact summaries. Console mode (`pretty`, `json` or `silent`) and private append-only JSONL capture are independent. `npm run start:debug` in `backend/` starts the API manually with full redacted capture; `npm run logs` separately starts the loopback Logdy viewer on port 8082 for expandable JSON, filtering and export. File capture has a bounded asynchronous queue and remains best-effort debugging. The viewer's bounded buffers do not replace the full JSONL file. See [Backend logging](BACKEND_LOGGING.md).

The separate [backend logs MCP server](tools/backend-logs-mcp/README.md) reads that capture over a host-owned stdio connection. Its read-only tools search records, trace request/publication attempts and scoped Flutter events, summarize warnings/errors, and list constrained local archives. It has no database/network listener or service-control capability; fixed-file access, payload opt-in, bounded queries and explicit coverage preserve the same debugging boundary.

Debug Flutter builds now include **Workspace menu → Flutter inspector**, also linked from Sync diagnostics. The bounded recorder starts enabled with local log sharing in debug app launches and traces actions, network/realtime, inbox jobs, Drift query/watch activity, state notifications and principal widget builds with captured identity and causal IDs. Full debug traffic logging also starts enabled and adds redacted SQLite details; it can be disabled at launch or runtime. Inspector notifications remain independent of application state and do not change cursor/reconciliation rules. Resource gauges, slow operations and JSON export support diagnosis; Chrome/Flutter DevTools supply heap and representative performance analysis. See [Flutter debugging](FLUTTER_DEBUGGING.md).
