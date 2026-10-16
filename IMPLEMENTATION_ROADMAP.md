# AI AGENT IMPLEMENTATION ROADMAP (IMPLEMENTATION_ROADMAP.md)

Follow these 5 sequential phases. Verify the acceptance criteria at the end of each phase before moving to the next phase.

---

## PHASE 1: Initialize Workspace & NestJS Foundation + 5 Debug Users
**Prompt for AI Agent:**
> Read `CONTEXT.md` and `BACKEND_SPEC.md` (Sections 1, 2, 4.1, and 4.2).
> 1. Set up the parent workspace `.gitignore` covering `backend/` and `mobile_and_web/`.
> 2. Create the NestJS app inside `backend/` with `@nestjs/mongoose`, `@nestjs/config`, `@nestjs/jwt`, `@nestjs/serve-static` (serving `./public/uploads` at `/public/uploads`), `ioredis`, `bcrypt`, `uuid`, and `multer`. Enable CORS.
> 3. Create the 4 Mongoose schemas (`User`, `Room`, `RoomMember`, `Message`) with the exact fields and indexes in `BACKEND_SPEC.md` (making sure `directPairKey` is omitted on group rooms and uses the partial unique index).
> 4. Implement `AuthModule` and `UsersModule`: seed `User 1..5` on startup, implement `/auth/debug-users`, `/auth/debug-login`, `/auth/signup`, `/auth/login`, `/auth/centrifugo-token` (signing JWT for `sub: userId`), and `GET /users`.
> 5. Verify: Multiple group rooms can be inserted without `directPairKey` index collisions, and `/auth/debug-login` returns valid tokens.

---

## PHASE 2: MongoDB Transactions, Redis Lua `pts` Engine & Rooms/Messages REST APIs
**Prompt for AI Agent:**
> Read `CONTEXT.md` and `BACKEND_SPEC.md` (Sections 3, 4.3, 4.4, and 4.5).
> 1. Implement `CentrifugoService` publishing to channel **`inbox:user#${userId}`** with 3-attempt retry backoff.
> 2. Implement `RedisSyncService` using the atomic Lua script (`upsertUserRoomDeltaLua`) from `BACKEND_SPEC.md` Section 3.2, plus `getDeltaOrRequireFullSync()` and `/presence/heartbeat` + `/presence/status`.
> 3. Implement `RoomsController` and `RoomsService` with strict membership guards:
>    - `GET /rooms/delta?sincePts=&epoch=`
>    - `GET /rooms?limit=25&beforeSortTimestamp=&beforeRoomId=` (Page 1 returns all pinned + 25 unpinned; Page 2+ paginates unpinned rooms tied on `roomId`).
>    - `GET /rooms/direct-peer/:peerUserId`, `POST /rooms/group`, and `PATCH /rooms/:roomId/preferences` (updating `roomPts` without changing `msgPts` or `sortTimestamp`).
> 4. Implement `MessagesController` and `MessagesService` using MongoDB transactions (`session.withTransaction`):
>    - `POST /uploads/image` (Multer 5MB limit + MIME check).
>    - `POST /messages` (handling `idempotencyKey` + `11000` duplicate-key catch, lazy direct room creation, same-room `replyTo` validation, and updating `roomPts` + `msgPts`).
>    - `GET /rooms/:roomId/messages` (compound `(createdAt, _id)` cursor) and `GET /rooms/:roomId/messages/around/:targetMessageId` (explicitly including `targetMsg`).
>    - `PATCH /messages/:id`, `DELETE /messages/:id/for-all` (clearing `replyTo.imageUrl = null` on quotes), and `DELETE /messages/:id/for-me` (updating `lastHistoryEditPts = newPts`).
>    - `POST /rooms/:roomId/delivered`, `POST /rooms/delivered-batch`, and `POST /rooms/:roomId/seen` (emitting `room_unread_cleared` to reader and `room_peer_seen` to sender).

---

## PHASE 3: Flutter Scaffold (Android + Web), Drift SQLite & Debug User Switcher
**Prompt for AI Agent:**
> Read `CONTEXT.md` and `FLUTTER_SPEC.md` (Sections 1, 2, and 4.1).
> 1. Create the Flutter project inside `mobile_and_web/` for Android and Web.
> 2. Configure `drift`, `drift_flutter`, `centrifuge: ^0.20.1`, `dio`, `v_platform`, `v_chat_bubbles`, `v_chat_input_ui`, `flutter_riverpod`, `shared_preferences`, and `uuid`. Set up `sqlite3.wasm` and `drift_worker.js` in `web/`.
> 3. Implement the Drift database (`SyncMetadata`, `LocalRooms` with `roomPts`, `msgPts`, `lastHistoryEditPts`, `messagesSyncedPts`, and `LocalMessages` with startup sweep marking interrupted `'sending'` rows as `'failed'`).
> 4. Build the Debug User Switcher & Auth Screen (`User 1..5` one-tap login + Login/Signup) with safe logout/switch table clearing.

---

## PHASE 4: Serialized `InboxSyncQueue`, Centrifugo `inbox:user#<id>` & Main Rooms Tab
**Prompt for AI Agent:**
> Read `FLUTTER_SPEC.md` (Sections 3 and 4.2).
> 1. Implement `RealtimeSyncService` subscribing to **`inbox:user#${userId}`** with automatic token refresh via `POST /auth/centrifugo-token`.
> 2. Implement the serialized `InboxSyncQueue` so live socket publications, reconnect `SubscribedEvent` triggers, app `resumed` triggers, and `syncInboxDelta()` execute sequentially without interleaving.
> 3. Ensure `applyRoomPayloadInTx()` distinguishes `room_unread_cleared` (reader unread reset) from `room_peer_seen` (sender blue ticks) and `room_delivered`.
> 4. Build the Telegram-style **Main Rooms Tab** watching Drift's sorted rooms stream, showing Green Online Dots (`PresenceService`), Pin/Mute icons, Unread badges, `lastMessage` previews, and `🕒/✓/✓✓` ticks, plus unpinned cursor pagination (`beforeSortTimestamp`, `beforeRoomId`), New Direct Chat picker, and New Group dialog.

---

## PHASE 5: Telegram-Style Messages Page (`v_chat_bubbles` + `v_chat_input_ui`), Hole-Free Sync & Reply Jump
**Prompt for AI Agent:**
> Read `FLUTTER_SPEC.md` (Section 4.3).
> 1. Build the **Messages Page** using `VBubbleStyle.telegram`, `VTextBubble`, `VImageBubble`, `VDeletedBubble`, `VReplyData`, and `VMessageInputWidget`, supporting both existing rooms and lazy direct draft rooms (`roomId == null, peerUser != null`).
> 2. Implement the `msgPts == messagesSyncedPts` check and the **Hole-Free Message Sync** transaction (preserving history when the 30-message batch overlaps local SQLite, and resetting stale history when >30 messages arrived offline or `lastHistoryEditPts > messagesSyncedPts`).
> 3. Implement optimistic sending with `idempotencyKey`, failed message Retry, scroll-up Load More pagination, and context menu actions (**Reply**, **Edit**, **Delete for Me**, **Delete for Everyone**).
> 4. Implement the **2-Tier Reply Jump**: local scroll + 1.5s highlight if cached in `LocalMessages`, or `GET /rooms/:id/messages/around/:targetMessageId` in-memory `isJumpMode` with live edit/delete listener and floating **`⬇ Return to Latest Messages`** button.