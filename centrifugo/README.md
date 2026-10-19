# Local Centrifugo v6.9.7

This configuration targets the installed **Centrifugo OSS v6.9.7**, verified with its `version`, `defaultconfig`, `configdoc`, `checkconfig`, startup logs and live protocol tests. It uses the existing local Redis; no containers or deployment infrastructure are involved. The newer settings here supersede older examples describing insecure admin, client subscriptions or 45-second presence.

## Start and configure

From the workspace root:

```sh
# Once only. Creates a private, ignored centrifugo/.env with independent random
# realtime JWT, HTTP API, proxy and admin credentials; preserves existing files.
node scripts/centrifugo-local.mjs init
node scripts/centrifugo-local.mjs check
node scripts/centrifugo-local.mjs start
```

In another terminal:

```sh
cd backend
DEBUG_TRAFFIC_LOGGING_ENABLED=false npm run start:debug
```

Existing MongoDB replica-set and Redis services must already be available. Do not start competing listeners on the same ports. `init` refuses to replace an existing private file. Both NestJS and the launcher load `centrifugo/.env`; its realtime settings take precedence over `backend/.env`. Process environment overrides files. The existing backend environment and old external Centrifugo configuration remain intact; use this launcher for the secured service.

The binary path is configurable with `CENTRIFUGO_BIN`. The launcher checks for v6.9.7 and runs `centrifugo checkconfig --config=config.json` with the repository configuration's absolute path and its private environment. Centrifugo itself does not automatically load dotenv files. No secrets belong in `config.json`. See [.env.example](.env.example) and [backend environment reference](../backend/.env.example).

Native `CENTRIFUGO_CLIENT_USER_CONNECTION_LIMIT`, `CENTRIFUGO_CLIENT_CONNECTION_LIMIT`, `CENTRIFUGO_CLIENT_CONNECTION_RATE_LIMIT`, `CENTRIFUGO_WEBSOCKET_MESSAGE_SIZE_LIMIT` and related environment options allow local limit experiments. Defaults: eight connections per user per node, 1,000 connections per node and 50 new connections/second. These are development limits, without a production capacity claim. A ninth connection is rejected without evicting the existing eight. Limits are per node; the Redis engine supports shared routing/presence for future nodes without implementing deployment.

The external WebSocket listener binds to `0.0.0.0:8000` for the authorized Android Wi-Fi connection. Set `CENTRIFUGO_HTTP_SERVER_ADDRESS=127.0.0.1` to restore loopback-only access. NestJS defaults to `0.0.0.0:3000` in development and loopback outside development; an explicit `HOST` overrides this. Configure API CORS and Centrifugo allowed origins together if browser origins change; native Android does not require adding a browser origin. The launcher always keeps internal endpoints on `127.0.0.1:9000` and enforces authenticated admin/API and disabled insecure modes. Internal endpoints must remain on loopback. A future container setup needs separate reviewed bindings; this task uses native local processes.

## Authentication and one inbox

Each app instance manages one connection. All of a user's devices receive independent publications on exactly `inbox:user#<userId>`. No room/presence channels are created. Client subscribe, publish, RPC, presence enumeration and history commands are unauthorized; join/leave broadcasts, history, positioning, recovery and delta compression are disabled.

**User-approved OSS tradeoff:** admission uses the NestJS connect proxy to enforce login revocation immediately. A 30-minute connection JWT is carried in `connect.data.token`, rather than `connect.token`. NestJS verifies HS256 signature, `sub`, `iss=chat-api`, `aud=chat-realtime`, `iat`, `exp`, the exact single `channels` claim and the authenticated login's SHA-256 session identity. It derives the server subscription from these verified claims. Centrifugo's own JWT verifier intentionally has no signing key, preventing direct-token admission from bypassing revocation. Issuer/audience settings remain explicit in the config; NestJS performs the JWT verification in this selected flow.

Only the loopback server with the dedicated `CENTRIFUGO_PROXY_SECRET` can call `/internal/realtime/connect` and `/internal/realtime/refresh`. The launcher maps this secret into Centrifugo's static `X-API-Key` proxy header. These are provider callbacks, excluded from public Swagger. They use the documented Centrifugo response protocol rather than application REST error semantics. Calls without a valid proxy key return 403.

Flutter obtains fresh connection data through `getData` on every reconnect. The connect proxy authorizes the socket until the access session's actual expiry (`expire_at = sessionExpiresAt`); the 30-minute connection-data JWT only authorizes admission. `client.proxy.refresh.enabled` is false, enforced by the local launcher even if an inherited environment enables it. There are no periodic `/internal/realtime/refresh` calls. Centrifugo closes an expired connection using its native expiration timer and configured expiration grace (25 seconds by default); the SDK has no token-refresh callback, and direct JWT verification remains disabled, so a client cannot extend the session. The protected legacy refresh route only returns `expired: true` during a rolling local restart. Flutter retains automatic jittered reconnect backoff (500ms–20s), and every reconnect revalidates session revocation.

Logout atomically writes the 24-hour login revocation and a persistent Redis disconnect job. NestJS immediately attempts to disconnect matching client IDs using authenticated server presence/API calls; other logins remain connected. Provider failure, request quotas or an API restart leave the job pending without requiring another logout request. A bounded worker checks the retry queue once per second, attempts at most four jobs concurrently per process, and retries failures after 1/2/4/8/16/30 seconds (then every 30 seconds). No provider calls occur for an empty queue. Redis server time, 60-second visibility leases and fenced completion prevent concurrent workers or delayed acknowledgements from losing work. Successful early attempts retain a final pass at least 15 seconds after retirement to cover an in-flight connect (the local proxy timeout is 2 seconds and stale connection timeout is 10 seconds). Jobs/tombstones expire after 24 hours plus 60 seconds, covering the maximum session lifetime and expiration grace. Redis data must be retained for revocations/retries to survive a Redis restart; this does not add disk durability beyond the configured Redis persistence. An unavailable provider API can delay forced logout until a retry succeeds or native session expiry closes the socket. No PRO token revocation, analytics or connection tracing is assumed.

Token issuance uses atomic Redis minute limits: 30/user and 120/IP by default. Heartbeat/offline defaults are 120/user and 600/IP; status queries 300/user and 1,200/IP. See the backend example for overrides. Limits return 429 problem JSON with `Retry-After: 60`. The API trusts the actual socket address, without accepting a caller's forwarded IP as an identity. Realtime credentials never come from arbitrary user IDs in a request body.

## Application online/offline presence

Centrifugo owns online/offline status: one or more connections subscribed to `inbox:user#<userId>` mean online; zero means offline. The namespace already enables provider presence. NestJS checks self/shared-room contact authorization, then uses one bounded server `batch` of `presence_stats` commands for up to 100 unique IDs. Provider failures and malformed/partial replies return 503, never a fabricated offline snapshot. Keys and API credentials remain server-side. No new client subscriptions or presence channels are introduced.

There is no application Redis heartbeat/session lease, application online-state hash, `presence:due` index, 500ms presence reconciliation worker or application `presence_changed` publisher. Centrifugo still manages its own Redis-engine presence under its separate `chat_centrifugo_local` prefix. Redis room deltas, rate limits and login revocation remain unchanged in responsibility. Auth revocations now use `auth-session:<userId>:retired:<sessionHash>`; old revocation keys under `presence:<userId>:retired:<sessionHash>` are read until their existing 24-hour TTL expires, never renewed as presence leases.

Flutter refreshes peer status snapshots every 30 seconds by default (`PRESENCE_REFRESH_SECONDS`), and on startup/reconnect/resume/manual sync. Hidden/paused/detached clients pause snapshot polling; their open socket still counts as online. One ongoing request per foreground client bounds polling, and session/lifecycle fences reject late results. Legacy presence hints are accepted as invalidations for compatibility but this backend no longer emits them. Snapshot refresh timing plus Centrifugo failure detection determines peer UI updates; there is no application five-second grace or 90-second lease.

`GET /presence/status?userIds=...` and compatible `POST /presence/status` return `{statuses:{userId:boolean}}`, restricted to self and existing direct/group co-members; unrelated IDs are silently omitted. No-body `/presence/heartbeat` remains a deprecated authenticated/rate-limited no-op for old clients. No-body `/presence/offline` revokes only the initiating login and disconnects its provider clients, preserving other logins. REST/realtime admission continues to reject retired sessions. Presence never advances inbox/message counters. Empty/unauthorized-only status batches never call Centrifugo.

### Last seen and disconnect notifications

Centrifugo OSS has no disconnect/unsubscribe webhook to NestJS ([official FAQ](https://centrifugal.dev/docs/faq#why-centrifugo-does-not-have-disconnect-hooks)). Namespace `join_leave` and `force_push_join_leave` send events to connected channel subscribers; they do not create backend callbacks. Private inboxes keep these disabled. [PRO channel-state events](https://centrifugal.dev/docs/pro/channel_state_events) can notify the backend when the first subscriber arrives or the last leaves, but this workspace remains OSS.

To retain last seen with OSS, `LastSeenService` tracks users after verified connect admission, then batches up to 100 due users into one provider presence request. `LAST_SEEN_CHECK_SECONDS` defaults to 30 (range 1–300); an idle queue creates no provider requests. The backend maintains `last-seen:due` and `last-seen:observations` as observation metadata, never as authoritative online leases. Online snapshots advance the remembered activity timestamp. Once no sockets remain, a monotonic MongoDB `$max` stores `users.lastSeenAt` and the observation is removed. Other connected logins prevent offline persistence. Logout schedules an early check after successful disconnection. Neither client heartbeat nor a client-reported disconnect time is trusted.

This timestamp is approximate: it is the last authenticated connection admission or confirmed online observation, usually within one observation interval before disappearance, plus Centrifugo failure-detection time. Provider or MongoDB outages can increase that gap. Failed snapshots never fabricate offline status. Redis state retains unfinished observations across API restart; per-connect versions and 60-second visibility leases protect reconnection/worker races. `GET`/`POST /presence/status` add `lastSeenAt: {userId: ISO timestamp or null}` for permitted offline users only. Self/shared-room authorization applies to both maps; online and unrelated users have no last-seen entry. The general user directory remains unchanged. Flutter displays these authorized offline timestamps in direct-chat headers and the people picker, and shows Online for connected peers. No user history, messages or uploaded files are removed.

## Local tools

| Purpose                      | URL                                      |
| ---------------------------- | ---------------------------------------- |
| Client WebSocket             | ws://localhost:8000/connection/websocket |
| Password-protected OSS Admin | http://localhost:9000                    |
| Go profiling                 | http://localhost:9000/debug/pprof/       |
| Prometheus                   | http://localhost:9000/metrics            |
| Server API Swagger           | http://localhost:9000/swagger            |
| Health                       | http://localhost:9000/health             |
| Authenticated server API     | http://localhost:9000/api                |
| NestJS Swagger               | http://localhost:3000/docs               |

Read the admin password from the private `centrifugo/.env`; do not paste it into chat, URLs or shell arguments. Wrong passwords are rejected; the correct configured password was verified using the HTTP login endpoint without recording credentials. The OSS dashboard shows nodes and current counters. Use authenticated `/api/info` for node/client/user/subscription counts, `/api/channels` for active channels, `/api/presence` for client/session info in one user's inbox, and `/api/presence_stats` for counts. Presence statistics count connections and unique users separately: multiple devices in one inbox give multiple clients and one user. Swagger documents the request objects. Always send `X-API-Key` with the server API key; never embed it in Flutter.

Metrics include `centrifugo_node_num_clients`, `centrifugo_node_num_channels`, `process_cpu_seconds_total` and `go_memstats_heap_alloc_bytes`. Compare CPU counter rates and heap allocation over time. The pprof index exposes heap, allocs, goroutine and CPU profiles; a short CPU capture is available at `/debug/pprof/profile?seconds=10`. These powerful diagnostic routes have network isolation rather than their own login and must remain loopback-only.

Debug logging stays enabled. Native v6.9.7 debug logs can include rejected tokens inside protobuf command strings. **Always use the launcher:** its bounded filter removes native commands, replies, payloads, credentials and JWT strings before writing stdout or the private `.runtime/observability/inputs/centrifugo-server.log`. The existing Vector/Logdy pipeline reads this same filtered file. `CENTRIFUGO_LOG_LEVEL=trace node scripts/centrifugo-local.mjs start` enables temporary trace diagnostics with the same filter; restart with the default debug level afterward. Do not use native `--log.file` for unfiltered debug/trace capture. The startup command above keeps application full-payload capture disabled too; metadata diagnostics remain available. The existing full-traffic feature stays opt-in according to its runbook and must not be enabled when message contents must stay out of logs.

When diagnosing subscriptions, check the connect proxy response's server `subs`, inspect authenticated server presence and Flutter Sync diagnostics, and verify reconnect invokes `/rooms/delta`. Do not attempt a client subscription or enable recovery to repair delivery. Centrifugo does not retain missed publications. REST/MongoDB plus the existing Redis latest-room projection remain recovery authority.

## Validation

```sh
node scripts/centrifugo-local.mjs check
node --test scripts/centrifugo-local.test.mjs
cd backend
npm run format:check
npm run typecheck
npm run build
npm test
npm run test:integration
cd ..
node --test scripts/e2e.mjs
cd mobile_and_web
dart format --output=none --set-exit-if-changed lib/core/chat_controller.dart
flutter analyze
flutter test
flutter build web --dart-define=API_BASE_URL=http://localhost:3000 \
  --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket
```

`backend/test/integration/realtime.test.ts` starts the installed binary on temporary loopback ports with a synthetic MongoDB database and isolated application/engine Redis prefixes. It checks all config keys against installed defaults, valid/invalid/expired JWTs, issuer/audience, anonymous rejection, direct-token bypass, cross-user and client commands, eight-device fanout and ninth rejection, malformed/oversized frames, connection presence/privacy/provider failures/absence of application polling, device logout and replay denial, missed-publication delta recovery, diagnostics, configurable rate limits and redacted logs. It retains synthetic test data and never flushes Redis or drops a database. Short test socket ping/pong timings are process-local; the running service retains its configured 25s/10s defaults. There are no application 90s/5s presence leases.

The local run also verified every documented diagnostic URL, password authentication, authenticated `info`/`presence`/`presence_stats`, loopback socket bindings and refusal of a connection through the Mac's LAN interface. Browser verification and exact command results are recorded in [local validation](../CENTRIFUGO_VALIDATION.md). These are local checks; no production sizing, physical-device, multi-node or VPS deployment claim is made.

## Sources and API conventions

Official references reviewed 2026-10-17: [configuration](https://centrifugal.dev/docs/server/configuration), [channels](https://centrifugal.dev/docs/server/channels), [presence](https://centrifugal.dev/docs/server/presence), [server subscriptions](https://centrifugal.dev/docs/server/server_subs), [admin](https://centrifugal.dev/docs/server/admin_web), [engines](https://centrifugal.dev/docs/server/engines), [FAQ](https://centrifugal.dev/docs/faq), [proxies](https://centrifugal.dev/docs/server/proxy) and [server API](https://centrifugal.dev/docs/server/server_api).

The [Zalando guidelines](https://opensource.zalando.com/restful-api-guidelines/) informed authenticated boundaries (104), OpenAPI (101), 429/Retry-After (153), compatibility (106) and duplicate-tolerant events (214). Existing camelCase fields and action routes are preserved for compatibility; Centrifugo callbacks follow its protocol rather than REST resource conventions. No Zalando infrastructure or event registry is introduced.

Authentication/last-seen API preflight on 2026-10-18 re-read the current [Zalando guidelines](https://opensource.zalando.com/restful-api-guidelines/): authenticated endpoints (104), additive compatibility (106), idempotent operation behavior (181) and schema documentation (101). Public REST response compatibility and self/contact authorization are preserved; provider callbacks retain Centrifugo protocol semantics.
