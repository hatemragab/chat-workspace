# Chat backend

NestJS REST commands and recovery, MongoDB replica-set transactions, latest-room Redis deltas, and user-restricted Centrifugo publications implement the approved root specifications. There is no per-message event log or outbox.

Requires Node.js 22 or newer, local MongoDB configured as replica set `rs0`, Redis, and Centrifugo v6. No Docker is used. Install dependencies with `npm install`, copy `.env.example` to a private `.env`, and fill in fresh JWT credentials plus the secrets already configured in your local Centrifugo. Never include `.env` in source control.

Run `npm run build` then `npm start`, or use `npm run start:dev` to execute the TypeScript entrypoint. The default API address is `http://localhost:3000`. `GET /health` checks MongoDB and Redis. Swagger UI is available at `/docs`, with the self-contained OpenAPI description at `/docs-json`.

In development, startup seeds five debug users and `/auth/debug-users` plus `/auth/debug-login` allow switching accounts. Those routes return 404 outside `NODE_ENV=development`; normal signup/login remain available. Authenticated endpoints require `Authorization: Bearer <accessToken>`. Debug accounts have random unusable passwords. Startup creates missing approved indexes and never drops existing indexes or application data.

Centrifugo must configure namespace `inbox` with `allow_user_limited_channels: true` and `history_size: 0`. Its client token HMAC key must match the API's configuration. Do not launch Centrifugo with `--client.insecure`: that disables the user boundary even for restricted inbox channels. Add each browser origin to both Centrifugo `client.allowed_origins` and API `CORS_ORIGINS`; local defaults are ports 5173 and 5174. Only the API uses the Centrifugo HTTP API key.

Each user subscribes to exactly `inbox:user#<userId>`. Publications have `{pts,epoch,room}` with the full room and optional updated message. REST responses reconcile resources but clients must advance their local inbox cursor only through serialized socket/delta reconciliation. Message writes and account/room revisions commit together; Redis Lua prevents older requests overwriting newer snapshots. Delta consistency checks force a full snapshot during cache lag or missing room states. Publication failures exhaust three retry attempts, retain REST recovery, and never turn a committed mutation into a failed send. A process interruption between MongoDB commit and Redis update is recovered through the MongoDB revision fence and a full sync.

`POST /messages` accepts exactly one of `roomId` and `peerUserId`; a direct room is created only on its first send. Idempotency is scoped to the sender. Preferences preserve message revision and room order. Reader badge clearing and sender delivery/seen events remain separate. When clients supply a receipt boundary, the publication `actionTimestamp` is that boundary, preventing later cached messages from receiving premature ticks; persisted receipt dates record the actual server action time.

Users and debug-user lists are JSON arrays. Auth returns `{user,accessToken,centrifugoToken}`; send/edit/delete return `{message,room}`; group creation/preferences return `{room}`. Presence supports `GET /presence/status?userIds=id,id` and the compatible `POST /presence/status` body `{userIds: [...]}`; it returns `{statuses: {userId: boolean}}`. Heartbeats renew a 45-second lease. Image uploads use multipart field `file`, enforce 5 MiB and supported MIME/signature checks, and return `{imageUrl}`. Generated files live in ignored `public/uploads/`.

## Request logs and correlation

Every HTTP request receives `X-Request-ID`. A caller may send a correlation ID containing 1-64 letters, digits, dots, underscores or hyphens; invalid or oversized values are replaced with a generated UUID. Problem JSON includes the same `requestId`, and browser clients can read the exposed response header. A JSON completion record on stdout contains only `timestamp`, `level`, `event`, `requestId`, `method`, matched route template, `status`, `durationMs`, and `aborted`. Raw paths, queries, message bodies, user IDs, IPs, headers, credentials and raw exceptions are excluded. Unmatched paths use `[unmatched]`. Responses with status 400+ log at `warn`, and 500+ or aborted responses log at `error`. Internal failure logs use the same request ID without exposing exception data.

To capture local logs, run `npm start 2>&1 | tee /tmp/chat-backend.log`. In another terminal, use `tail -f /tmp/chat-backend.log` or `rg '"level":"(warn|error)"' /tmp/chat-backend.log`. Find one request with `rg '"requestId":"YOUR_REQUEST_ID"' /tmp/chat-backend.log`, using the ID from the response header or problem body. Set `HTTP_LOGGING_ENABLED=false` to disable completion logs while keeping response correlation and internal error logging. These logs contain operational metadata; keep captured files private.

Only text messages may be edited. Image edit attempts return 400 without changing message content or account revisions; sender and membership checks still apply.

## Validation

- `npm run typecheck` checks application and test TypeScript.
- `npm run build` compiles the production server.
- `npm test` checks cursor behavior, schema indexes, upload signatures, debug isolation and OpenAPI coverage.
- `npm run test:integration` uses existing local MongoDB, Redis and secure Centrifugo. It creates a fresh `chat_app_test_<random>` database and Redis namespace for each run; it does not mutate or delete existing user data. Synthetic databases and uploaded test images are retained. It reads private local secrets from `.env` without printing them. Build before running integration tests.
- `npm run format` formats maintained sources; `npm run format:check` verifies formatting.

Validation recorded on 2026-10-16: `npm run typecheck`, `npm run build`, `npm run format:check`, `npm test` (10/10 passed), and `npm run test:integration` (21/21 passed), including actual MongoDB replica-set transactions, Redis Lua and secure Centrifugo WebSocket checks. These are local service checks; they do not establish production capacity or native-device acceptance.

Integration coverage includes concurrent idempotent sends, sender UUID scope, strict membership/sender authorization, revision separation, badge versus tick behavior, bounded receipts, reply editing/deletion/image cleanup, tied room/message cursors, explicit around targets, Lua ordering/TTL, recovery after injected cache failures, CORS, spoofed/oversized uploads, presence, secure live WebSocket subscriptions and publications, and authentication throttling.

API guideline preflight on 2026-10-16 read the [official Zalando RESTful API and Event Guidelines](https://opensource.zalando.com/restful-api-guidelines/). Portable requirements applied include security (104), OpenAPI (101), standard date formats (169), method/status semantics (148, 243), problem JSON (176), no exposed stack traces (177), cursor pagination (160), compatibility (106), idempotent secondary keys (231), and ordered duplicate-tolerant advisory data changes (242, 214, 212). The approved camelCase fields, explicit action routes, array user lists, and atomic batch response take precedence over incompatible external conventions. The OpenAPI file documents this local contract; this preflight does not establish production compliance.
