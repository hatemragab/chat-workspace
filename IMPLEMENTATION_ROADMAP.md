# AI AGENT IMPLEMENTATION ROADMAP (IMPLEMENTATION_ROADMAP.md)

Follow these 5 sequential phases. Verify the acceptance criteria at the end of each phase before moving to the next phase.

---

## PHASE 1: Initialize Workspace & NestJS Foundation + 5 Debug Users

**Prompt for AI Agent:**

> Read `CONTEXT.md` and `BACKEND_SPEC.md` (Sections 1, 2, 4.1, and 4.2).
>
> 1. Set up the parent workspace `.gitignore` covering `backend/` and `mobile_and_web/`.
> 2. Create the NestJS app inside `backend/` with `@nestjs/mongoose`, `@nestjs/config`, `@nestjs/jwt`, `ioredis`, `bcrypt`, `uuid`, `multer`, and `sharp`. Enable CORS. Uploaded bytes remain in `./public/uploads`, but `/public/uploads/:filename` is an authenticated controller with current-reference authorization; never expose that directory through a public static-file bypass.
> 3. Create the 5 Mongoose schemas (`User`, `Room`, `RoomMember`, `Message`, `Upload`) with the exact fields and indexes in `BACKEND_SPEC.md` (making sure `directPairKey` is omitted on group rooms and uses the partial unique index). Upload metadata has no TTL deletion index; orphan eligibility controls explicit cleanup only, and pending-owner read/attach retries remain available while retained.
> 4. Implement `AuthModule` and `UsersModule`: seed `User 1..5` in development, implement `/auth/debug-users`, `/auth/debug-login`, `/auth/signup`, `/auth/login`, `/auth/centrifugo-token` (signed connection-data JWT for the protected NestJS connect proxy), and `GET /users`. Debug routes stay unavailable outside development. Distinguish invalid/retired credentials (401) from authentication dependency failure (503), and normalize ObjectId boundaries. Keep legacy complete user arrays within the explicit 10,000-user budget; support opt-in `limit`/`afterUserId` pages without silently truncating legacy responses.
> 5. Verify: Multiple group rooms can be inserted without `directPairKey` index collisions, and `/auth/debug-login` returns valid tokens.

---

## PHASE 2: MongoDB Transactions, Redis Lua `pts` Engine & Rooms/Messages REST APIs

**Prompt for AI Agent:**

> Read `CONTEXT.md` and `BACKEND_SPEC.md` (Sections 3, 4.3, 4.4, and 4.5).
>
> 1. Implement `CentrifugoService` publishing to channel **`inbox:user#${userId}`** with up to 3 attempts (immediate, then 300ms/1000ms delays). Bound post-commit recipient work to 8 active/1,000 waiting jobs per process and a shared 10-second per-mutation deadline; provider attempts use at most 2,500ms and the remaining deadline. Committed mutations remain successful when advisory work expires or fails.
> 2. Implement `RedisSyncService` using the atomic Lua script (`upsertUserRoomDeltaLua`) from `BACKEND_SPEC.md` Section 3.2, plus delta/full-sync recovery. Redis response timers default to 1,500ms, and post-commit Lua upsert/invalidation must reject work after the absolute deadline using Redis server time. Keep backend/Redis clocks synchronized and retain MongoDB revision fences for ambiguous responses. Presence belongs to the separate Centrifugo-backed presence module: `/presence/status` reads authorized provider snapshots, and `/presence/heartbeat` is a deprecated compatibility no-op. `/presence/offline` retires the login before independent logout provider-work quotas (30/user, 120/IP per minute); skipped/failed disconnect work remains retryable. Redis retains room deltas, rate limits and session retirement, not application presence leases.
> 3. Implement `RoomsController` backed by `ChatService` with strict membership guards:
>    - `GET /rooms/delta?sincePts=&epoch=`
>    - `GET /rooms?limit=25&beforeSortTimestamp=&beforeRoomId=` (legacy Page 1 returns all pinned within the explicit 1,000-room budget + 25 unpinned; Page 2+ paginates unpinned rooms tied on `roomId`). Optional `pinnedLimit=1..100`/`pinnedNextCursor` and `pinnedOnly=true` pages bound pinned reconciliation independently of the authoritative unpinned cursor. Exhaust pinned pages before certifying a full inbox; never silently truncate legacy responses.
>    - `GET /rooms/direct-peer/:peerUserId`, `POST /rooms/group`, and `PATCH /rooms/:roomId/preferences` (updating `roomPts` without changing `msgPts` or `sortTimestamp`).
> 4. Implement `MessagesController` backed by `ChatService` using MongoDB transactions (`session.withTransaction`), and the upload/media controllers backed by `UploadsService`:
>    - `POST /uploads/image` (5 MiB maximum; admit rate/concurrency quotas before Multer reads the body: 30/user and 120/IP per minute, 4 active requests/process, 2/user, 30-second deadline). Fully decode accepted JPEG/PNG/GIF/WebP frames with Sharp; bound each dimension to 8,192, frames to 60 and total decoded pixels to 16,000,000. Hold decode permits through completion even if the client cancels.
>    - `GET /public/uploads/:filename` (bearer header, private/no-store, current visible message/quote membership or authorized avatar reference after attachment; pending owner-only access while retained). Track attachment in the mutation transaction, preserve legacy referenced media, revoke new reads when no authorized reference survives, and close cancelled streams. Cleanup inventories by default; never run explicit apply without separate authorization.
>    - `POST /messages` (handling `idempotencyKey` + `11000` duplicate-key catch, lazy direct room creation, same-room `replyTo` validation, and updating `roomPts` + `msgPts`).
>    - `GET /rooms/:roomId/messages` (compound `(createdAt, _id)` cursor) and `GET /rooms/:roomId/messages/around/:targetMessageId` (explicitly including `targetMsg`, with membership, target and both context sides in one MongoDB snapshot).
>    - `PATCH /messages/:id`, `DELETE /messages/:id/for-all` (clearing `replyTo.imageUrl = null` on quotes), and `DELETE /messages/:id/for-me` (updating `lastHistoryEditPts = newPts`).
>    - `POST /rooms/:roomId/delivered`, `POST /rooms/delivered-batch`, and `POST /rooms/:roomId/seen` (emitting `room_unread_cleared` to reader and `room_peer_seen` to sender).

---

## PHASE 3: Flutter Scaffold (Android + Web), Drift SQLite & Debug User Switcher

**Prompt for AI Agent:**

> Read `CONTEXT.md` and `FLUTTER_SPEC.md` (Sections 1, 2, and 4.1).
>
> 1. Create the Flutter project inside `mobile_and_web/` for Android and Web.
> 2. Configure `drift`, `drift_flutter`, `centrifuge: ^0.20.1`, `dio`, `v_platform`, `v_chat_bubbles`, `v_chat_input_ui`, `flutter_riverpod`, `shared_preferences`, and `uuid`. Set up `sqlite3.wasm` and `drift_worker.js` in `web/`.
> 3. Implement the Drift database (`SyncMetadata`, `LocalRooms` with `roomPts`, `msgPts`, `lastHistoryEditPts`, `messagesSyncedPts`, and `LocalMessages` with startup recovery returning interrupted `'sending'` rows to the durable FIFO queue with an unknown server outcome).
> 4. Build the Debug User Switcher & Auth Screen (`User 1..5` one-tap login + Login/Signup) with safe logout/switch table clearing.

---

## PHASE 4: Serialized `InboxSyncQueue`, Centrifugo `inbox:user#<id>` & Main Rooms Tab

**Prompt for AI Agent:**

> Read `FLUTTER_SPEC.md` (Sections 3 and 4.2).
>
> 1. Implement `RealtimeSyncService` subscribing to **`inbox:user#${userId}`** with fresh connection-data JWTs via `getData` and `POST /auth/centrifugo-token` on every connect/reconnect. Use the access session's actual socket expiry, disable periodic refresh proxies, and persist backend-driven logout disconnect retries.
> 2. Implement the serialized `InboxSyncQueue` so live socket publications, reconnect `SubscribedEvent` triggers, app `resumed` triggers, and `syncInboxDelta()` execute sequentially without interleaving.
> 3. Ensure `applyRoomPayloadInTx()` distinguishes `room_unread_cleared` (reader unread reset) from `room_peer_seen` (sender blue ticks) and `room_delivered`.
> 4. Build the Telegram-style **Main Rooms Tab** watching Drift's sorted rooms stream, showing Green Online Dots (`PresenceService`), Pin/Mute icons, Unread badges, `lastMessage` previews, and `🕒/✓/✓✓` ticks, plus unpinned cursor pagination (`beforeSortTimestamp`, `beforeRoomId`), New Direct Chat picker, and New Group dialog.

---

## PHASE 5: Telegram-Style Messages Page (`v_chat_bubbles` + `v_chat_input_ui`), Hole-Free Sync & Reply Jump

**Prompt for AI Agent:**

> Read `FLUTTER_SPEC.md` (Section 4.3).
>
> 1. Build the **Messages Page** using `VBubbleStyle.telegram`, `VTextBubble`, `VImageBubble`, `VDeletedBubble`, `VReplyData`, and `VMessageInputWidget`, supporting both existing rooms and lazy direct draft rooms (`roomId == null, peerUser != null`).
> 2. Implement the `msgPts == messagesSyncedPts` check and the **Hole-Free Message Sync** transaction (preserving history when the 30-message batch overlaps local SQLite, and resetting stale history when >30 messages arrived offline or `lastHistoryEditPts > messagesSyncedPts`).
> 3. Implement optimistic sending with `idempotencyKey`, failed message Retry, scroll-up Load More pagination, and context menu actions (**Reply**, **Edit**, **Delete for Me**, **Delete for Everyone**).
> 4. Implement the **2-Tier Reply Jump**: local scroll + 1.5s highlight if cached in `LocalMessages`, or `GET /rooms/:id/messages/around/:targetMessageId` in-memory `isJumpMode` with live edit/delete listener and floating **`⬇ Return to Latest Messages`** button.

## Regression acceptance after the source/spec audit

The nine reported defects require permanent regression coverage before closure; the original green suites did not cover these cases:

1. Capture a send's original room/session across awaited history recovery and the complete multi-image batch; navigation never redirects it.
2. Store and acknowledge same-UUID messages from different senders independently, including upgrades from Drift versions 1/2 to version 3 without data loss. Invalidate old message certification once, repair stale receipts/quotes on an unchanged inbox, and preserve the zero-message-request path after a newly verified reopen.
3. Cancel a direct-open continuation paused in local reconciliation/remapping across an account switch; preserve the new account's draft and room selection.
4. Recover an open historical jump after a missed deletion/edit followed by a newer coalesced event, including deleted-target handling and late-response fences.
5. Update visible quote snapshots when their original is hidden for that participant, without revealing or reinserting it.
6. Recover receipts throughout retained history after a coalesced seen/delivered event; verify safe behavior for timestamp gaps/ties, sender direction, optimistic rows, missing legacy summaries, and unchanged-room zero-request behavior.
7. Preserve the next unsent composer draft when the first lazy direct send receives its real room ID; still clear input on actual conversation/account changes.
8. Restore saved-session startup and interrupted sends when optional debug discovery fails; initialization remains retryable.
9. Reject explicit null preference booleans without changing state/revision counters; omitted fields remain unchanged.

After these code/documentation fixes and regressions pass, investigate logout online/offline behavior, define its lifecycle contract, add its regressions, run the complete checks/builds, and repeat real bidirectional chat and presence verification in the two explicitly authorized Web instances. Record current results in `VALIDATION.md`; earlier test counts are historical evidence.

Presence acceptance: Centrifugo connections alone determine online/offline; heartbeat calls cannot fabricate presence. Logout/account switching revokes only the outgoing login, another connected session preserves online status, and API failure cannot block local logout. Verify connection close without a REST offline request, privacy, bounded provider batches, provider failure as 503, no application Redis presence keys/500ms polling, and unchanged room revisions/delta recovery. Foreground clients refresh peer snapshots every 30 seconds without heartbeats. See [local realtime acceptance](CENTRIFUGO_VALIDATION.md).

The second review adds four required regressions: a delayed delete-for-me cannot remove a later account's shared row; logout during pending startup immediately fences work and completes cleanup without draining network requests; later lazy-batch pending/failed images remain in the real room with working Retry; and versions 1/2 repair old cache certification once through the version-3 migration, retained in current schema version 4. Preserve the input/scroll regressions and run all checks again. Keep the persistent API under the user's manual control and provide safe client/server request correlation for debugging.

The offline follow-up requires cached Drift conversations and pending/failed sends to render before any server response. Saved-session startup, cached history expansion, local reply jumps and Return to Latest must stay usable while HTTP fails or never resolves. Recovery remains serialized and retryable in the background, retaining all session/navigation fences and verified-baseline rules. Draft-only failed conversations must remain reachable after restart without creating a server room before a successful send.
