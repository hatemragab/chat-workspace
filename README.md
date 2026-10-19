# Chat Workspace

NestJS and Flutter Android/Web implementation of the approved [workspace contract](CONTEXT.md), [backend specification](BACKEND_SPEC.md), [Flutter specification](FLUTTER_SPEC.md), and [five implementation phases](IMPLEMENTATION_ROADMAP.md).

REST performs mutations and recovery. MongoDB replica-set transactions persist messages and revisions; Redis Lua retains the latest hydrated room per account; Centrifugo publishes to protected `inbox:user#<userId>` channels. Flutter uses Riverpod, one Drift `chat_app_db` database, and a serialized inbox queue. There is no server message event log. Flutter has a durable sequential send queue in its existing database; see [outbox and health recovery](OUTBOX_QUEUE_AND_HEALTH_SPEC.md).

Cached conversations open from Drift immediately while network recovery runs in the background. Saved sessions, cached history and reply navigation, the composer, and sending/failed messages remain available without the API. Failed first sends retain a local draft inbox entry across restart and can be retried with the same identity. New sign-in, uncached history and image uploads require connectivity; see [client behavior and limits](mobile_and_web/README.md) and [current validation](VALIDATION.md).

Message acknowledgements use `(senderId, idempotencyKey)` on both server and client. Drift schema version 6 adds persistent outbound queue state while preserving existing rows and inbox cursors, retains the one-time baseline repair for versions 1/2, and adds persistent server page boundaries, indexed reply targets and bounded pending-upload bytes. Version-1 UUID-only constraints are replaced without discarding local work. Latest direct-message pages provide receipt watermarks and a gap flag so recovery can update retained older ticks safely; uncertain or gapped history falls back to a fresh page while preserving pending and failed sends. Hidden originals use quote-only updates without resurfacing the original message.

Presence follows Centrifugo inbox connections. Foreground clients refresh authorized peer snapshots every 30 seconds; there are no application presence leases, heartbeats or offline sweeper. Logout revokes only that login; other connected logins remain online. A hidden open socket still counts as online; Seen requires the selected conversation to be foreground. Presence degradation is separate from messaging transport status. See the [secured local Centrifugo runbook](centrifugo/README.md).

New messages use transactional per-room sequences. Flutter persists cumulative receipt status and pending acknowledgement boundaries in SQLite; compact peer receipt and own unread pushes avoid resending message content. Partial reads preserve newer unread messages, and missed events recover through hydrated Redis/REST snapshots. Legacy history keeps exact receipt dates. `RECEIPT_PUSH_MODE=legacy` preserves older clients; enable `compact` only with rebuilt clients that support both compact envelope types. See [sequence receipt validation](RECEIPT_SEQUENCE_VALIDATION.md) for checks and rollout details.

## Run locally

Use the existing MongoDB replica set on port 27017, Redis on 6379, and Centrifugo v6 on 8000. Do not use Docker. The API's private `backend/.env` must contain local database URLs and matching Centrifugo credentials; use [backend/.env.example](backend/.env.example) as the configuration reference. Never copy credentials into logs or documentation.

In `backend/`:

```sh
npm install
RECEIPT_PUSH_MODE=compact npm run start:debug
```

Run that API command in your terminal to see request methods, route templates, statuses, durations and request IDs. Successful GET/HEAD health probes and OPTIONS requests are excluded from routine completion logs. Alternatively, run `npm run build` followed by `HTTP_LOGGING_ENABLED=true npm start`. The API is at [localhost:3000](http://localhost:3000/health), with [Swagger UI](http://localhost:3000/docs). See the [backend runbook](backend/README.md) for authentication, API contracts, correlation IDs and log filtering.

Run `node scripts/centrifugo-local.mjs check` and `node scripts/centrifugo-local.mjs start` from the root. The tracked configuration targets installed v6.9.7, uses a Redis engine and enables password-protected admin, pprof, Prometheus, Swagger and health on loopback port 9000. WebSockets stay on 8000. NestJS verifies connection-data JWTs through the OSS connect proxy and assigns the sole inbox server subscription; client subscriptions/history/recovery are disabled. Create the shared private credentials once with `node scripts/centrifugo-local.mjs init`; existing files are preserved. See the [local runbook](centrifugo/README.md) for startup, all URLs and inspection commands.

In `mobile_and_web/`, run these in two separate terminals:

```sh
flutter pub get
flutter run -d web-server --web-hostname=localhost --web-port=5173 \
  --dart-define=API_BASE_URL=http://localhost:3000 \
  --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket
```

```sh
flutter run -d web-server --web-hostname=localhost --web-port=5174 \
  --dart-define=API_BASE_URL=http://localhost:3000 \
  --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket
```

Open the [first instance](http://localhost:5173/) and [second instance](http://localhost:5174/), and choose different demo accounts. Different ports isolate browser storage. Development startup provides five one-tap debug accounts; regular signup/login also work. Debug authentication endpoints return 404 outside development. Opening a direct conversation creates a draft; the first message creates the room.

Reuse existing web listeners instead of starting competing processes. Keep the API under manual control unless an agent restart is explicitly requested. The authorized observability follow-up restarted it with local capture and connected native Centrifugo logs. See the [Flutter runbook](mobile_and_web/README.md) for builds and configuration.

## Inspect and debug

Use [local observability](LOCAL_OBSERVABILITY.md) to collect Flutter inspector, backend, Redis, MongoDB and Centrifugo diagnostics through Vector into the same Logdy/MCP capture. Start `npm run logs:collector` and `npm run logs` in separate `backend/` terminals after their one-time install commands. Debug Flutter app launches automatically enable **Capture**, **Share with local logs** and full traffic logging; **Refresh counters** also sends current metrics. Collection stays on this Mac.

Use **Sync diagnostics** in the workspace menu or account footer. It displays connection status, session generation, local/server revision counters, request counts and bounded recent events. Scroll down and expand **SQLite database rows** to inspect a read-only snapshot of `SyncMetadata`, `LocalRooms`, and `LocalMessages`. No additional inspector service or database is needed. Tokens are excluded; message contents remain private local data.

**Sync now** runs normal serialized recovery and refreshes the snapshot. When a room is current, reopening it should not increase `messageRequests`. `msgPts` and `messagesSyncedPts` should converge after recovery. Clearing an unread badge must not mark the reader's outgoing messages seen. REST mutation responses never directly advance the inbox cursor.

The API records request completions with timestamps, authenticated user IDs and an `X-Request-ID` also present in problem responses; OPTIONS preflights are filtered out. Opt in to full HTTP request/response JSON and correlated realtime publish attempts with `HTTP_LOGGING_ENABLED=true DEBUG_TRAFFIC_LOGGING_ENABLED=true npm run start:dev` in `backend/`. Passwords, tokens, cookies and API keys remain redacted; binary files use metadata. Debug Flutter builds have an independent **Full debug traffic logging** switch in Sync diagnostics, with full HTTP/realtime records and per-user counts for the latest 60 entries. Release Flutter builds do not collect these traces. Match the response request ID with backend fanout records to follow one request between users. Development terminals use compact summaries. Run `npm run logs:install` once and `npm run logs` from `backend/` to open the [expandable local Logdy viewer](http://127.0.0.1:8082/); `npm run start:debug` separately starts the API with private JSONL capture. The [local read-only MCP server](tools/backend-logs-mcp/README.md) lets AI hosts search that capture, trace request fanout and summarize errors without controlling services. See [Backend logging](BACKEND_LOGGING.md) for JSON trees, filters, export and file controls.

Inspect live Redis data with the MIT-licensed Redis Commander at [127.0.0.1:8081](http://127.0.0.1:8081/). From the workspace root, run `node scripts/redis-debug.mjs install` once, then `node scripts/redis-debug.mjs start`. The launcher reads the API's private Redis settings, binds locally, disables writes and connection saving, and displays the configured prefix's key tree. Expand **user** for room projections and **auth-session** for login revocation. Centrifugo manages provider presence under its own prefix. See [Redis debugging](REDIS_DEBUGGING.md) for room JSON, revision counters, TTLs, presence inspection and how to relate them to traffic logs. Redis stores latest room projections; it does not contain the full message history.

Debug Flutter builds also include **Workspace menu → Flutter inspector**: an automatically enabled causal timeline for actions, HTTP/realtime, inbox processing, Drift queries/watch emissions, state notifications and screen builds, with slow-operation summaries, resource gauges and JSON export. See [Flutter debugging](FLUTTER_DEBUGGING.md) for capture controls and Chrome/Flutter DevTools profiling.

Web SQLite falls back to shared IndexedDB when the browser does not provide shared-memory support. Persistence and reload recovery were verified in that configuration. During Flutter development, a hot restart can produce a transient disposed-engine warning; a browser reload loads the rebuilt application.

## Validate

From `backend/`:

```sh
npm run format:check
npm run typecheck
npm run build
npm test
npm run test:integration
```

From `mobile_and_web/`:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build web --dart-define=API_BASE_URL=http://localhost:3000 \
  --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket
flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 \
  --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket
```

From the workspace root, with all local services and the API running:

```sh
node --check scripts/e2e.mjs
node --test scripts/e2e.mjs
```

The independent E2E script creates synthetic accounts, messages, groups and uploads in the configured development database. Integration tests use fresh synthetic MongoDB databases and Redis namespaces. Tests retain their data and never drop existing databases, flush Redis, or remove existing uploads. Run them only against a development environment.

The long-history helper's `node scripts/history-fixture.mjs prepare` command places an anchor in the existing synthetic `E2E history verification` group. Close the first browser's app tab or navigate it away, run `node scripts/history-fixture.mjs fill`, and reopen the app. The helper resumes from ignored `.runtime/history-fixture.json` and adds 525 messages plus a reply to the anchor using debug test accounts. Once completed, rerunning it preserves that fixture instead of adding another batch. It does not remove data. Tap the quote to exercise remote context recovery, then **Return to Latest Messages**. Use a reply to a locally cached direct-chat message to exercise the local jump path.

See [VALIDATION.md](VALIDATION.md) for actual results and evidence boundaries. [TASKS.md](TASKS.md) records implementation and follow-up verification work.
