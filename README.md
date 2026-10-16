# Chat Workspace

NestJS and Flutter Android/Web implementation of the approved [workspace contract](CONTEXT.md), [backend specification](BACKEND_SPEC.md), [Flutter specification](FLUTTER_SPEC.md), and [five implementation phases](IMPLEMENTATION_ROADMAP.md).

REST performs mutations and recovery. MongoDB replica-set transactions persist messages and revisions; Redis Lua retains the latest hydrated room per account; Centrifugo publishes to protected `inbox:user#<userId>` channels. Flutter uses Riverpod, one Drift `chat_app_db` database, and a serialized inbox queue. There is no message event log or outbox.

## Run locally

Use the existing MongoDB replica set on port 27017, Redis on 6379, and Centrifugo v6 on 8000. Do not use Docker. The API's private `backend/.env` must contain local database URLs and matching Centrifugo credentials; use [backend/.env.example](backend/.env.example) as the configuration reference. Never copy credentials into logs or documentation.

In `backend/`:

```sh
npm install
npm run build
npm start
```

The API is at [localhost:3000](http://localhost:3000/health), with [Swagger UI](http://localhost:3000/docs). See the [backend runbook](backend/README.md) for authentication, API contracts, correlation IDs and log filtering.

Centrifugo requires namespace `inbox`, `allow_user_limited_channels: true`, and `history_size: 0`. Configure both API CORS and Centrifugo allowed origins for `http://localhost:5173` and `http://localhost:5174`. Explicit local origins are sufficient; a wildcard is unnecessary. Client JWT validation must remain enabled. The local admin UI is at [localhost:8000](http://localhost:8000/); its current insecure admin setting is for this existing local environment only.

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

Open [User 1's instance](http://localhost:5173/) and [User 2's instance](http://localhost:5174/). Different ports isolate browser storage. Development startup provides five one-tap debug accounts; regular signup/login also work. Debug authentication endpoints return 404 outside development. Opening a direct conversation creates a draft; the first message creates the room.

Both web instances and the API were left running after verification. Reuse those processes instead of starting competing listeners. See the [Flutter runbook](mobile_and_web/README.md) for builds and configuration.

## Inspect and debug

Use **Sync diagnostics** in the workspace menu or account footer. It displays connection status, session generation, local/server revision counters, request counts and bounded recent events. Scroll down and expand **SQLite database rows** to inspect a read-only snapshot of `SyncMetadata`, `LocalRooms`, and `LocalMessages`. No additional inspector service or database is needed. Tokens are excluded; message contents remain private local data.

**Sync now** runs normal serialized recovery and refreshes the snapshot. When a room is current, reopening it should not increase `messageRequests`. `msgPts` and `messagesSyncedPts` should converge after recovery. Clearing an unread badge must not mark the reader's outgoing messages seen. REST mutation responses never directly advance the inbox cursor.

The API emits compact JSON request completion records with an `X-Request-ID` also present in problem responses. Logs omit request bodies, raw paths/queries, credentials and personal identifiers. Capture and filter them using the [backend logging instructions](backend/README.md#request-logs-and-correlation). Flutter's debug console reports bounded operational events; its diagnostics panel is the structured inspection surface.

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

See [VALIDATION.md](VALIDATION.md) for actual results and evidence boundaries. [TASKS.md](TASKS.md) records the completed implementation work.
