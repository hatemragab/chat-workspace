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

1. Immediately mark the session stopping, increment `sessionGenerationId++`, invalidate navigation/jump work and cancel the presence timer, including while startup HTTP is pending. Queued and newly initiated work must fail its session fence before applying data or issuing authenticated requests.
2. Best-effort release the old authentication session with `POST /presence/offline` before clearing its bearer, bounded to three seconds.
3. Disconnect/close Centrifugo, retire the serialized sync queue and cancel subscriptions. Discard waiting jobs and fence unfinished HTTP results without waiting for an unresponsive startup request. Local writes and cleanup remain transactionally serialized.
4. Call `await db.clearAllTables()`, remove persisted credentials/pagination, clear the bearer and account state. A new login resets the stopping fence.

Capture and validate the initiating session generation **before** asynchronous work, after local/database and HTTP awaits, and immediately before each write or request. A direct-room lookup started by account A must not remap account B's draft, select A's room under B, or issue receipts with B's credentials. Serialize local remaps and delete-for-me writes with cleanup and recheck their original generation inside the transaction. A stale completion or failure must not alter the later account's messages, initialization state or error UI.

### Exact Drift Tables (`app_database.dart`)

#### Table 1: `SyncMetadata` (Single row `id = 1`)

- `id`: `IntColumn` (PK, default `1`)
- `userId`: `TextColumn`
- `localPts`: `IntColumn` (default `0`)
- `localEpoch`: `TextColumn` (default `''`)
- `roomPageCursorJson`: `TextColumn.nullable()` (authoritative exclusive unpinned API page boundary)
- `roomPageEpoch`: `TextColumn.nullable()` (epoch that certified the page boundary)
- `roomPageKnown`: `BoolColumn` (default `false`; distinguishes exhausted `null` from unknown)

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
- `idempotencyKey`: `TextColumn` (not individually unique; unique together with `senderId`)
- `roomId`: `TextColumn` (indexed — for draft direct messages before room creation, use `"draft_${peerUserId}"` and update to real `roomId` on send completion)
- `peerUserId`: `TextColumn.nullable()` (used to retry failed first message in a lazy direct room after app restart)
- `senderId`: `TextColumn`
- `senderName`: `TextColumn`
- `senderAvatarUrl`: `TextColumn.nullable()`
- `type`: `TextColumn` (`'text' | 'image'`)
- `text`: `TextColumn`
- `imageUrl`: `TextColumn.nullable()`
- `replyToJson`: `TextColumn.nullable()`
- `replyTargetId`: `TextColumn.nullable()` (indexed together with `roomId`; derived from the reply snapshot)
- `uploadBytes`: `BlobColumn.nullable()` (bounded pending image bytes retained until upload acknowledgement)
- `uploadFilename`: `TextColumn.nullable()` (pending image filename)
- `status`: `TextColumn` (`'queued' | 'sending' | 'sent' | 'failed'`)
- `isEdited`: `BoolColumn` (default `false`)
- `isDeletedForAll`: `BoolColumn` (default `false`)
- `deliveredAt`: `IntColumn.nullable()`
- `seenAt`: `IntColumn.nullable()`
- `createdAt`: `IntColumn` (indexed, epoch ms)

Use a unique composite constraint on **`(senderId, idempotencyKey)`**. Every optimistic acknowledgement/lookup uses both values; another sender's identical UUID must coexist. Schema version 2 introduced this scope. Schema version 4 upgrades older databases while preserving message IDs, content, room mapping, receipts, sending/failed state and the inbox cursor; version 1 also replaces its UUID-only constraint. Upgrades from versions 1/2 reset only `LocalRooms.messagesSyncedPts` once because those baselines could incorrectly certify stale content/receipts. Version 4 adds the nullable cursor/upload fields, backfills reply target IDs and creates the compound reply index. Opening the room runs normal latest-page recovery. Do not clear the database or repeat baseline invalidation on subsequent launches.

On Web, acquire the exclusive `chat_app_db:single-active-tab` Web Lock before opening Drift or creating a controller. Another active tab, denied access or an unsupported Web Locks environment shows an ownership notice with Retry. Closing, reloading or crashing releases the browser-owned lock. This is one active writer per origin; different ports have independent ownership.

---

## 3. SERIALIZED `InboxSyncQueue` & CENTRIFUGO `inbox:user#<userId>`

### 3.1 Connection & Token Refresh

- Connect `centrifuge-dart` to `ws://localhost:8000/connection/websocket` with fresh signed JWT connection data from `getData` and `POST /auth/centrifugo-token`. The NestJS connect proxy verifies session revocation and returns the sole server-side inbox subscription with the access session's actual expiry. Periodic server refresh callbacks are disabled; logout uses backend-driven disconnects with persistent retries, and Centrifugo's native timer enforces session expiry. Do not add SDK token refresh that bypasses connect-proxy revocation checks. See [local realtime authentication](centrifugo/README.md).
- Subscribe to **`inbox:user#${currentUserId}`**.
- **Mandatory Sync Triggers:** Whenever client-level server `SubscribedEvent` fires (on initial connect AND every auto-reconnect) OR when the app resumes (`AppLifecycleState.resumed`), enqueue `syncInboxDelta()` in the `InboxSyncQueue`.

### 3.2 Serialized Event Processing (Prevents Interleaving & Race Conditions)

All live socket publications and `syncInboxDelta()` operations run sequentially inside a single async mutex/queue (`InboxSyncQueue`):

Consecutive contiguous publications may be applied in batches of at most 64 within one Drift transaction. Validate every event's epoch and sequence, apply all message/receipt/quote mutations, advance only the final contiguous cursor and emit each applied room mutation for historical jump views. Gaps still trigger REST reconciliation. Diagnostics measure queue wait separately from execution; batching does not permit concurrent cursor writers.

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
     - Call `GET /rooms?limit=25&pinnedLimit=100`, then exhaust `pinnedNextCursor` through bounded pinned-only pages.
     - Inside one Drift transaction: **replace server-room summaries with the fresh 25 unpinned rooms and all reconciled pinned rooms** (preventing stale unrefreshed unpinned rooms from lingering), reset `messagesSyncedPts = 0`, insert the fresh rooms, and set `SyncMetadata.localPts = response.pts`, `localEpoch = response.epoch` plus the authoritative unpinned page boundary. Preserve local `draft_<peerUserId>` summaries while they contain pending/failed sends; they are local work rather than server inbox snapshots.

### 3.3 Exact `applyRoomPayloadInTx(room)` Rules

1. Upsert `LocalRooms` (`roomPts = room.roomPts`, `msgPts = room.msgPts`, `lastHistoryEditPts = room.lastHistoryEditPts`, `lastMessageJson = jsonEncode(room.lastMessage)`).
2. Upsert `room.lastMessage` into `LocalMessages` (matching by `(senderId, idempotencyKey)` first so an optimistic `'sending'` row upgrades cleanly to `'sent'`).
3. If `room.updatedMessage != null`:
   - If `room.eventType == 'message_deleted_me'`: delete `room.updatedMessage.id` from `LocalMessages`.
   - Else: upsert `room.updatedMessage` into `LocalMessages` and update any `LocalMessages.replyToJson` referencing that message ID.
4. Independently, if `room.quoteUpdate != null`, rewrite matching visible `replyToJson` snapshots and historical jump references using that safe snapshot, including when `updatedMessage` is absent. Do **not** insert or reveal its hidden original message.
5. **Strict Receipt Handling (`room_delivered` vs `room_peer_seen` vs `room_unread_cleared`):**
   - `room_unread_cleared`: Applies the authoritative `LocalRooms.unreadCount` (zero for a complete read, possibly positive for a bounded read). **NEVER touches the reader's outgoing message ticks or `LocalMessages.seenAt`!** The compact extension below also merges own acknowledgement checkpoints.
   - `room_delivered`:
     `UPDATE local_messages SET delivered_at = COALESCE(delivered_at, :actionTs) WHERE room_id = :roomId AND sender_id = :myUserId AND status = 'sent' AND delivered_at IS NULL AND created_at <= :actionTs`
   - `room_peer_seen`:
     `UPDATE local_messages SET delivered_at = COALESCE(delivered_at, :actionTs), seen_at = COALESCE(seen_at, :actionTs) WHERE room_id = :roomId AND sender_id = :myUserId AND status = 'sent' AND seen_at IS NULL AND created_at <= :actionTs`
   - Local `sending` and `failed` rows never acquire receipts from cumulative boundaries or live events.
6. **If the user currently has `room.roomId` open on the Messages Page:**
   - A contiguous, fully applied live event may advance `messagesSyncedPts` only if the previous message baseline was already verified. A coalesced delta must not certify missing intermediate content/receipt changes merely because the room is open; run latest-page reconciliation first.

---

## 4. UI SCREENS, HOLE-FREE MESSAGE SYNC & 2-TIER REPLY JUMP

### 4.1 Screen 1: Debug User Switcher (`User 1..5`) & Auth

- Development-only one-tap login cards for `User 1..5` plus standard Login/Signup form. Profile/release builds hide demo controls with no runtime override.
- On startup, recover interrupted `sending` rows as `queued` with an unknown server outcome. Drain them through the durable FIFO dispatcher; preserve historical failed rows for explicit Retry. See [outbox and health recovery](OUTBOX_QUEUE_AND_HEALTH_SPEC.md).
- Restore a saved session, attach local room streams and sweep interrupted sends before waiting for any HTTP request. Cached conversations remain usable when the API is unavailable. Mandatory inbox reconciliation, user discovery, presence and realtime setup recover in the background; retry unfinished recovery automatically and through **Sync now**, resume and reconnect without duplicating subscriptions or reviving a retired session. Treat debug-user discovery as optional and independently retryable.
- Genuine 401 during a running session pauses remote work and presents **Sign in again**, retaining cached conversations, pending/failed sends and upload bytes. Same-account reauthentication preserves this work; changing accounts or explicit logout follows the cleanup contract. Retryable 503 infrastructure failures preserve the session. User discovery reads bounded API pages rather than downloading an unlimited directory.

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
- A first optimistic draft send persists a local room summary with the peer metadata and latest pending preview. Merely opening an unsent draft creates no inbox entry or server room. Restore interrupted draft sends and their inbox entries locally; atomically remove the draft summary when messages remap to a real server room.
- **Load More Pagination Cursor:**
  - Persist the server's `nextCursor`, epoch and known/exhausted state in `SyncMetadata`, scoped by its account. A full sync stores that boundary atomically with inbox state after reconciling bounded pinned pages. Load More advances it only after the returned page applies successfully.
  - Pass the retained `beforeSortTimestamp` and `beforeRoomId` back to the API. Deltas, message activity and preferences never move this boundary. This remains valid when every currently loaded room is pinned.
  - Unknown or stale-epoch pagination state bootstraps from a fresh first page. Never derive the boundary from local room order. Draft entries never become server cursors.

### 4.3 Screen 3: Telegram-Style Messages Page (`VBubbleStyle.telegram` + `VMessageInputWidget`)

- **Windowed Reactive Stream:** Watch a bounded query ordered by `created_at DESC, id DESC` (50 visible rows plus one availability row initially, increasing by 30 visible rows when expanded). Use lazy sliver rendering so only the viewport is materialized. Opening a room, testing overlap and local reply navigation must not decode the entire retained history.
- **Offline Availability:** Attach the message stream and show cached sent, sending and failed rows immediately on opening a conversation. Network reconciliation must never gate cached rendering, local history expansion, cached reply jumps, Return to Latest or the composer. Opening a known direct peer uses its cached room or local draft immediately. A failed request preserves local rows and retry keys; it does not certify the cache as current. Data never cached locally still requires the server.
- **Message Viewport:** Fill the available chat height and use reversed scrolling with the latest message at the bottom, including short conversations. Older messages appear above it. Keep historical targets clear of the floating Return to Latest button.
- **Send Context:** Capture the original account, session generation and conversation before awaiting Return to Latest, file uploads, or any item in an image batch. Keep that context for the entire operation, or cancel it when navigation/session changes invalidate it. Never send old text or subsequent selected images to a newly selected recipient/account. Existing core callers default to the current context at their own entry point.
- **Lazy Batch Remapping:** After the first item creates a real direct room, resolve later optimistic rows through the initiating session's mapping for that same draft/peer. Later sending/failed items remain visible in the real conversation; Retry reuses the failed item's idempotency key without uploading the image again.
- **Interrupted Uploads:** Persist the whole selected batch in its original account/conversation before the first upload. Retain bytes and filename for interrupted pre-upload rows, with a 5 MiB/file, 20 pending-file and 20 MiB total local quota. Upload serially within the session; Retry keeps the same send identity, skips a previously acknowledged upload, and clears retained bytes once the server URL is durable locally. Quota/storage failures must be visible without rebinding work to another conversation.
- **Private Media:** Fetch recognized server upload paths with the current bearer through the API client and render returned bytes. Do not put bearer credentials in URLs. Authorization denial shows a safe unavailable state; server revocation cannot recall bytes already downloaded by a client.
- **Composer Identity:** A direct conversation uses a stable account/peer identity across `draft_<peerUserId>` to server-room remapping. Preserve text typed for the next message while the first send is awaiting acknowledgement. Actual account/conversation changes clear the previous input and reply context.
- **Composer Lifecycle:** Connection warnings and upload progress must not recreate the composer or discard typed text, the first input, or keyboard focus. Keep the focused text field's accessibility identity stable when the Send button appears or disappears so Web input is not interrupted.
- **Zero-Bandwidth & Hole-Free Sync on Room Open / Reconnect:**
  - Render from SQLite first. In background recovery, wait for `syncInboxDelta()` to finish before treating `localRoom.msgPts` as up to date.
  - After successful inbox reconciliation, check: `if (localRoom.msgPts == localRoom.messagesSyncedPts && localMessagesCount > 0)` -> reuse the verified cache with **0 HTTP message requests**.
  - Otherwise (`msgPts != messagesSyncedPts`):
    1. Call `GET /rooms/:roomId/messages?limit=30`.
    2. **Hole & History-Edit Check (Inside 1 Drift Transaction):**
       - Check if `oldestReturnedMsg.id` already exists in `LocalMessages` AND `localRoom.lastHistoryEditPts <= localRoom.messagesSyncedPts`.
       - **If YES (Overlap & No Old Edits):** Preserve older sent history only when its receipts can also be verified. Upsert the 30 messages and prune any local sent message with `createdAt >= oldestReturnedMsg.createdAt` that is missing from the 30 returned messages.
       - For a direct room, apply the latest response's cumulative `receipts.deliveredThrough` and `receipts.seenThrough` to all retained **sent outgoing** rows at or before each boundary, using the current session's user ID. Never mark pending/failed optimistics received or read from these boundaries. If `receipts.hasGaps == true` or a legacy response has no receipt summary, do not certify older cached ticks from overlap alone: reset uncertifiable older sent history and keep the exact fresh rows.
       - **If NO (>30 messages arrived while offline, an older message was edited/deleted while offline, or older receipt state is uncertifiable):** Delete cached **sent** rows for this room and insert the fresh 30 messages so SQLite has no pagination hole or stale historical state. Preserve local sending/failed rows and their retry keys.
    3. Apply content, receipt reconciliation and `LocalRooms.messagesSyncedPts = localRoom.msgPts` in the same transaction.
- **2-Tier Reply Jump (`VReplyData` Tap):**
  - **Tier 1:** Query a bounded 31-row local slice centered around a retained `replyTo.messageId`, with Return to Latest and the 1.5s target highlight. Do not scan/decode all cached messages to find it.
  - **Tier 2 (500+ Messages Back):** Call `GET /rooms/:roomId/messages/around/:targetMessageId?limit=30`, switch to in-memory `isJumpMode = true` centered on `targetMessageId` with a floating **`⬇ Return to Latest Messages`** button, and listen to `roomEventsStream` to apply live edits/deletes to the in-memory slice while open.
  - Remember the jump target and verified history revision. If recovery/full sync advances `lastHistoryEditPts` without enough explicit mutation data to update the slice, invalidate/refetch its context. A deleted/invisible target must show a safe notice or return to the latest view, never retain its old visible body indefinitely. Fence refreshes by the initiating session, conversation and jump request so a late result cannot replace a newer selection. Normal new tail messages alone preserve the historical viewport.

### 4.4 Presence Lifecycle

- Refresh authorized peer statuses every 30 seconds while the lifecycle permits it, using `PRESENCE_REFRESH_SECONDS`, batching status reads into at most 100 user IDs. Do not send presence heartbeats. Preserve the session-generation fence around every await so old results cannot update a new account.
- Logout and account switching first invalidate asynchronous work and cancel the timer, then best-effort call `POST /presence/offline` using the old bearer before clearing it. Bound that request to three seconds; failure must not prevent local logout, credential removal or account cleanup.
- Another connected authentication session keeps the user online. Centrifugo inbox presence supplies the snapshots; an open background socket still counts as online. Pause snapshot polling while hidden/paused/detached and refresh on resume/reconnect/startup/manual sync. No application presence lease expiry or five-second grace exists. A separate backend snapshot observer persists approximate `lastSeenAt` after the final connection disappears; it does not replace provider presence. Retired credentials cannot obtain a new connection; a new login creates a new session. Legacy inbox presence hints may trigger snapshot reads but are no longer produced by this backend.
- Direct-chat headers and the people picker show **Online** for a confirmed connected peer and **Last seen <local date> at <local time>** for a confirmed offline peer with an authorized `lastSeenAt` timestamp. A confirmed offline peer without a valid timestamp shows **Offline**; omitted/unknown peers keep the existing conversation hint. Presence timestamps remain scoped to the current session in memory and are cleared on logout/account switch. Failed chunks preserve their last known state/times, and a timestamp-only change notifies the UI without extra polling.
- Seen is emitted only for the selected foreground conversation. Background delivery remains independent. A failed presence snapshot preserves the last known set and exposes separate presence degradation instead of changing a healthy messaging transport to Offline. An unchanged regular presence poll does not notify application state; lifecycle/manual recovery can still notify for other state changes.

### 4.5 Debug Traffic Inspection

- Debug HTTP records include the initiating user's ID captured before awaits, UTC timestamp, method/route, response request ID, status and duration. Ignore OPTIONS. Explicitly install/clear the logger's user identity with session installation/logout; never decode an unverified token for logging identity.
- Debug app launches enable inspector Capture, Share with local logs and Full debug traffic logging before initialization. Use `--dart-define=DEBUG_TRAFFIC_LOGGING_ENABLED=false` for metadata-only startup, or the **Full debug traffic logging** switch in Sync diagnostics at runtime. Include complete application JSON and received realtime publications in one bounded 60-record history, with per-user HTTP/realtime counts for that window. Runtime disable clears full history and prevents old in-flight payloads from being retained later. Release builds cannot enable capture.
- For received realtime data, identify the receiving session and channel. Keep unknown actor/request IDs null; the originating backend HTTP/publish records provide that causal association without adding fields to the event protocol. Recursively redact credentials and represent binary media through metadata. Inspection must not change sync or mutation behavior.

## Sequence receipt extension

Drift schema version 5 adds nullable `LocalMessages.messageSeq`, separate `deliveredByCursor` / `seenByCursor` status flags, room content revision, own/peer receipt cursors and verified received coverage. A `ReceiptTasks` table inside the same database preserves captured acknowledgement targets/confirmations across restart and room-summary pruning. Migrations preserve existing messages, exact dates, pending uploads, draft mappings and inbox cursors; account cleanup also clears receipt tasks.

`ChatMessage.isDelivered` / `isSeen` combine real dates with confirmed cursor-derived status. Cursor acknowledgement must not manufacture a historical date. Reapply stored peer cursors when loading older outgoing messages, to room previews and historical jump objects. Pending/failed rows and incoming direction remain unaffected. Unsequenced history retains the legacy summary/gap fallback; timestamp-only bulk status applies only to legacy rows.

The inbox queue accepts hydrated rooms, compact `receipt` envelopes and compact `unread` envelopes. Apply each patch and inbox progress in one Drift transaction. Unknown rooms, epoch changes and account revision gaps use authoritative recovery. A receipt patch cannot certify a previously incomplete message baseline; `contentPts` distinguishes receipt-only progress from unknown content changes. Hydrated snapshots retain cumulative receipt state after event coalescing.

An `unread` patch carries `room_unread_cleared`, `roomId`, the authoritative `unreadCount` (possibly nonzero), `ownDeliveredSeq` and `ownSeenSeq`. Update the badge and `roomPts` only when the room revision is current, and merge own sequence cursors monotonically. Confirm covered durable sequence tasks while preserving legacy timestamp tasks. Preserve `msgPts`, `contentPts`, message certification, history revisions, room ordering, preview and message rows, including this account's outgoing ticks. Do not schedule a receipt or message fetch solely because this event arrived. The existing SQLite schema supports this patch without a migration; offline clients recover the complete state through ordinary inbox reconciliation.

Receipt-only events do not schedule another delivery, Seen call or ordinary message recovery unless a genuine content gap or legacy exact-state recovery is required. A session-scoped coalescing queue sends only new progress, prefers Seen over covered Delivery, retries persisted targets and fences account changes. Background Delivery advances only through verified message coverage. Seen requires the selected foreground room and captures its intended boundary before asynchronous work; later messages remain unread. Clients use sequence requests only when the room advertises `receiptProtocol: sequence`. Legacy requests retain their captured timestamp rather than substituting server-now on retry.

These rules extend the earlier timestamp-only description; account revisions, history-edit and REST-cursor ownership rules remain in force. See [sequence receipt validation](RECEIPT_SEQUENCE_VALIDATION.md).

## Debug observability

Debug builds provide an optional, controller-local Flutter inspector, disabled by default. It records bounded metadata for controller actions, HTTP/realtime activity, the inbox queue, Drift query/transaction/watch activity, state notifications and principal screen builds. Identity and causal context are captured across asynchronous work; inspector refreshes do not notify application state. Resource gauges, build counts and native frame summaries are diagnostic hints, not heap-leak proof or release benchmarks. Capture is disabled in profile/release builds. The existing full traffic switch additionally enables bounded, credential-redacted SQLite statement/binding/result details within captured query spans. Ordinary inspector capture remains metadata-only; the SQLite row viewer remains separate. See [Flutter debugging](FLUTTER_DEBUGGING.md) for controls, bounds and profiling tools.

## Sequential outbound recovery

The approved [outbox and health specification](OUTBOX_QUEUE_AND_HEALTH_SPEC.md) extends message storage to schema 6, adds automatic sequential sending and typed retry rules, and supersedes earlier manual-only interrupted-send descriptions. Inbox cursor ownership, session fences, logout cleanup, receipt processing and existing upload URLs remain unchanged.
