> Latest authentication and last-seen verification: see **Session expiry, logout retries and last seen — 2026-10-18** at the end of this document. Earlier sections remain historical evidence.

> Historical validation below predates the Centrifugo-only presence change. Current presence behavior and verification are recorded in [PRESENCE_VALIDATION.md](PRESENCE_VALIDATION.md).

# Local Centrifugo validation — 2026-10-17

This follow-up applies the requested local security/diagnostics settings to the installed **Centrifugo OSS v6.9.7**, keeping NestJS, MongoDB, application Redis deltas, Flutter/Drift and the single per-user inbox architecture. The existing unrelated working changes and private backend environment were preserved. No commit, push, deployment, data deletion, container or replacement device was used.

The user selected a NestJS connect proxy with verified JWTs and immediate login revocation. This is an explicit change from the preferred direct Centrifugo JWT admission: signed JWTs travel in connection data, NestJS returns their verified inbox as a server-side subscription, and direct-token admission is disabled to prevent bypass. The proxy renews the same connection server-side; it does not require Flutter to recreate a socket for renewal.

## Automated checks actually run

| Check                                                                                                                                            | Result                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| Installed binary `version`                                                                                                                       | Centrifugo v6.9.7 (Go 1.26.8)                                                                                       |
| `node scripts/centrifugo-local.mjs check`                                                                                                        | Passed; invokes installed `centrifugo checkconfig --config=.../centrifugo/config.json` with the private environment |
| `node --test scripts/centrifugo-local.test.mjs`                                                                                                  | 3 passed; every config key checked against installed defaults, launcher security and bounded native-log redaction   |
| Backend `npm run format:check`                                                                                                                   | Passed                                                                                                              |
| Backend `npm run typecheck`                                                                                                                      | Passed                                                                                                              |
| Backend `npm run build`                                                                                                                          | Passed                                                                                                              |
| Backend `npm test`                                                                                                                               | 54 passed                                                                                                           |
| Backend `npm run test:integration`                                                                                                               | 43 passed, including 9 isolated Centrifugo security/Redis/presence tests                                            |
| `node --check scripts/e2e.mjs`                                                                                                                   | Passed                                                                                                              |
| `node --test scripts/e2e.mjs`                                                                                                                    | 17 passed against the running local API/Centrifugo                                                                  |
| `dart format lib/core/chat_controller.dart`                                                                                                      | Passed                                                                                                              |
| `flutter analyze`                                                                                                                                | No issues                                                                                                           |
| `flutter test`                                                                                                                                   | 247 passed, including presence/session/lifecycle regressions                                                        |
| Targeted presence/session Flutter tests                                                                                                          | Passed separately; also included in full suite                                                                      |
| `flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`       | Passed                                                                                                              |
| `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket` | Passed; Flutter emitted plugin migration guidance about Built-in Kotlin                                             |
| `git diff --check`                                                                                                                               | Passed                                                                                                              |

The integration fixtures have unique MongoDB database names and Redis prefixes; short timing/limit overrides affect only test processes. Existing data is never dropped or flushed. The running service retains 90-second application leases, five-second offline grace, 60-second server refresh and the requested 8/1,000/50 connection limits.

The isolated suite proves valid JWT admission, wrong signature/issuer/audience/expiry/anonymous rejection, direct-JWT bypass rejection, exact server subscriptions with client subscriptions disabled, denied client publish/presence/history/RPC, malformed/oversized command rejection, independent live fanout to eight connections and rejection of a ninth, reconnect without eviction, and larger legitimate outbound event delivery. It verifies socket identity survives repeated server refresh and retirement is enforced on refresh, token issuance, REST and reconnect. It exercises transition-only multi-device online/offline behavior, quick-reconnect grace, autonomous TTL cleanup, contact privacy, bounded queries, HTTP 429 limits, absence of history replay and recovery through the existing Redis delta projection.

A race test accepts a heartbeat completing before logout or being rejected with 401 after retirement; both paths must leave the lease retired and prevent resurrection. This replaces its older expectation that retired authentication remained valid.

## Running local service and diagnostics

The active Centrifugo process uses `centrifugo/config.json` through `scripts/centrifugo-local.mjs`. The obsolete insecure process was replaced. The launcher filters native debug output before stdout and the shared private observability log. Raw v6.9.7 debug commands were observed to contain a rejected JWT; redaction was implemented and verified with token/secret/message canaries. The final audit found one historical token-bearing native record from the superseded process; only its credential bytes were masked in place, preserving the record and metadata. Active native, backend, Vector, service and Flutter captures then passed the JWT scan. Application full-payload capture is disabled for the running backend; metadata diagnostics remain enabled. Existing full-traffic tools remain separately opt-in.

Verified URLs:

- WebSocket: `ws://localhost:8000/connection/websocket`
- Admin: `http://localhost:9000`
- pprof: `http://localhost:9000/debug/pprof/`
- Metrics: `http://localhost:9000/metrics`
- Swagger: `http://localhost:9000/swagger`
- Health: `http://localhost:9000/health`
- Authenticated internal API: `http://localhost:9000/api`

Admin login returned 400 for a wrong password and 200 with an authentication token for the configured password, without recording either credential. Internal `info`, `presence` and `presence_stats` succeeded with the API key. The same diagnostic paths returned 404 on the external listener. Socket inspection confirmed loopback-only bindings; probing port 9000 through the Mac's LAN address failed. Startup/config checks reported no unknown options. Metric output included client/channel counts, CPU seconds and heap allocations.

## Flutter browser evidence

Two independent existing Flutter Web listeners on ports 5173 and 5174 were hot-restarted and reloaded through computer use. User 1 and User 2 both displayed **Connected**. A synthetic message, “Centrifugo v6.9.7 secure local verification”, sent from the first session appeared live in the second inbox, and the authorized peer displayed **Online**. The sender received delivery/read receipts. After User 2 logged out, its session returned to sign-in and User 1 lost the peer's online badge while retaining its own connection and cached messages. Browser storage remained isolated by origin; the running Redis/REST synchronization path was retained.

A private [verification screenshot](.runtime/centrifugo-flutter-verification.jpg) shows the delivered/read message after the peer logged out. This UI evidence is separate from the eight-device protocol test. No simulator, physical mobile device or native UI test was run. APK compilation is build evidence only. No production benchmark, multi-node failover or deployment was performed. An internal-API outage can delay socket disconnection until server refresh/expiration; retired sessions cannot reconnect or obtain tokens through NestJS. A connect already in flight at logout is also targeted by a second disconnect pass.

See [the local runbook](centrifugo/README.md) for credentials, startup, settings, privacy semantics and inspection steps.

## Session expiry, logout retries and last seen — 2026-10-18

This follow-up supersedes earlier descriptions of minute-by-minute server refresh and unchanged last-seen values. It preserves the single private inbox, native Centrifugo presence, existing durable inbox recovery and all unrelated local data.

- Disabled `client.proxy.refresh.enabled` and forced it off in the local launcher. Connect admission now returns the access session's actual expiry. The protected legacy refresh callback is terminal rather than renewing a connection.
- Redis atomically retains login revocation and disconnect work. Bounded workers use visibility leases, fenced completion, capped backoff, provider-presence confirmation and a delayed final pass for in-flight connects. API restarts and logout quotas cannot discard pending work; another login remains connected. Redis persistence remains the durability boundary.
- Last-seen observations track authenticated connection activity and provider snapshots in batches of up to 100. Once the final socket disappears, monotonic MongoDB updates retain `users.lastSeenAt`. Versions fence reconnect races; dependency failures retain observations. The default interval is 30 seconds (`LAST_SEEN_CHECK_SECONDS`); this is an approximate last-observed timestamp, with additional uncertainty during provider/network outages. Native session expiry retains Centrifugo's configured expiration grace (25 seconds in the running configuration; isolated tests use one second).
- GET/POST `/presence/status` add `lastSeenAt` only for authorized offline users. Self/shared-room restrictions apply to both maps. Unrelated users remain omitted, the general user directory remains unchanged, and no Flutter last-seen display was added.

Checks actually completed:

| Command                                                       | Result                                                                     |
| ------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Backend `npm run typecheck`                                   | Passed                                                                     |
| Backend `npm run build`                                       | Passed                                                                     |
| Backend `npm run format:check`                                | Passed                                                                     |
| Backend `npm test`                                            | 95 passed                                                                  |
| Backend `npm run test:integration`                            | 81 passed against local replica-set MongoDB, Redis and isolated Centrifugo |
| `node --test scripts/centrifugo-local.test.mjs`               | 4 passed against the installed v6.9.7 schema                               |
| `node scripts/centrifugo-local.mjs check`                     | Passed                                                                     |
| `node --check scripts/centrifugo-local.mjs` and its test file | Passed                                                                     |
| `git diff --check` and relative document-file link check      | Passed                                                                     |

Live integration assertions include an unchanged socket across 62 seconds with zero refresh callbacks, native login expiry and rejected expired reconnects, failed disconnect retry after a complete API restart while provider sockets stay open, a connect/logout race caught by the persisted final pass, multiple-device isolation, last-seen persistence after socket closure without REST logout, authorized API visibility, provider/MongoDB outage handling, and stale worker completion fencing. Synthetic databases/keys/uploads remain retained; no cleanup was executed.

The official [Centrifugo FAQ](https://centrifugal.dev/docs/faq#why-centrifugo-does-not-have-disconnect-hooks) confirms OSS has no disconnect webhook. `join_leave` sends channel events to connected subscribers; [PRO channel-state webhooks](https://centrifugal.dev/docs/pro/channel_state_events) provide first/last-subscriber notifications. This implementation stays OSS and does not add private inbox cross-subscriptions or event history.

Running-service readback on 2026-10-18: restarted only the two identified existing local NestJS/Centrifugo launcher processes, preserving configuration, credentials, data, external listener addresses and loopback-only diagnostics. A separate live probe selected an unused debug user, connected to the actual ports 3000/8000, confirmed the socket TTL matched the access-session expiry, and remained connected for 65 seconds. The active backend capture observed its connect request and **zero** refresh requests in that window. Closing that socket without REST logout was followed by an automatically persisted last-seen timestamp, read back through authorized `/presence/status`. The probe then retired its own synthetic login. No browser/device UI, multi-node cluster, Redis process restart or production-capacity acceptance is claimed.

API preflight re-read the [official Zalando guidelines](https://opensource.zalando.com/restful-api-guidelines/) on 2026-10-18. Applied security (104), additive compatibility (106), idempotent operation behavior (181) and schema documentation (101); provider callbacks continue using Centrifugo's protocol.

## Flutter last-seen display — 2026-10-18

Direct-chat headers and the people picker now show **Online** for a confirmed connected peer, **Last seen <local date> at <local time>** for a confirmed offline peer with an authorized timestamp, and **Offline** when that offline timestamp is missing/invalid. Unknown or unauthorized peers retain the existing conversation hint. Group headers are unchanged. Formatting uses the device's local timezone and 12/24-hour setting without adding a dependency or UI timer.

Flutter keeps the online/offline sets and last-seen map in session memory, applies each presence refresh together, ignores unrelated/malformed timestamps, preserves failed chunks, and rejects stale session/lifecycle completions. Logout/account switching clears the presence data. A timestamp-only update notifies listeners; an unchanged snapshot does not. No schema migration or extra HTTP polling was added.

Validation completed: `dart format` on all six changed Dart files, `flutter analyze` (no issues), focused presence/controller/widget tests (18 passed), the complete `flutter test` suite (334 passed), release `flutter build web` with local API/Centrifugo defines, and `git diff --check`. Two existing Flutter Web development instances were hot-restarted and their existing Chrome tabs reloaded. The actual User 1 header showed **Online** for connected User 2; navigating User 2's tab temporarily to `about:blank` disconnected its socket without clearing local data, and User 1's header displayed **Last seen Oct 18, 2026 at 2:22 AM** after a presence refresh. The peer tab was restored afterward, and User 1's header returned to Online. Screenshots are retained privately under `.runtime/last-seen-online.jpg` and `.runtime/last-seen-offline.jpg`. No messages were sent or deleted and no native-device acceptance is claimed.

## Browser and retained-log audit — 2026-10-18

Computer use in the two existing Chrome sessions verified automatic peer updates without manual synchronization: navigating User 2's page to `about:blank` changed the people picker and direct-chat header to **Last seen Oct 18, 2026 at 2:26 AM**; restoring that page returned the header to **Online**. The **Switch account** logout returned User 2 to sign-in and updated User 1's header to **Last seen Oct 18, 2026 at 2:27 AM**. Signing in again restored both sessions to Connected and the peer to Online. Logdy showed the corresponding successful Centrifugo disconnect and `POST /presence/offline` HTTP 200. No messages were sent or deleted during this verification.

Flutter inspector capture and local sharing were temporarily enabled for a traced **Sync now**. All 102 delivered Flutter events were informational; the inspector reported zero queued, dropped, uncertain or failed deliveries. Both toggles were restored to their original off state. Private screenshots are `.runtime/presence-audit-picker-offline.jpg`, `.runtime/presence-audit-after-logout.jpg`, `.runtime/presence-audit-final-online.jpg` and `.runtime/presence-audit-flutter-delivery.jpg`.

The complete retained unified capture and its one archive were read from fixed byte snapshots in batches of 100, followed by a separate append-only post-test audit: **107,996 valid records in 1,082 batches**, through **2026-10-17 23:30:29.388 UTC** (18 October 02:30:29 Cairo). Only each snapshot's final batch was partial. No malformed records or incomplete trailing bytes were found. This covers retained Logdy/MCP history, not unretained history or every separate process-output file. The browser's separate rolling window of 1,000 rows was also inspected as ten batches of 100.

No backend HTTP 5xx or failed publication was present. All 386 failed MongoDB command records correlated to successful final HTTP responses across 89 request IDs. Historical refresh-proxy failures, prior-restart connection errors, synthetic severity probes and unrelated endpoint probes were distinguished from current behavior. The final 1,271-record tail had zero refresh requests, error-severity records, HTTP 4xx/5xx, aborted requests or failed operations. It contained two native MongoDB socket-connectivity warnings during isolated test teardown, with no failed application request. Batch manifests, byte limits, hashes, source counts and classifications are private under `.runtime/log-audit-20261018/`; the UI batch manifest is `.runtime/logdy-ui-audit-batches.json`. Existing logs were preserved.

Fresh validation in this audit:

| Command                                                                                             | Result                                                                                                                                                                                       |
| --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Backend `npm test`                                                                                  | 95 passed                                                                                                                                                                                    |
| Backend `npm run build`                                                                             | Passed                                                                                                                                                                                       |
| Backend `tsx --test test/integration/session-disconnect.test.ts test/integration/last-seen.test.ts` | 9 passed against local Redis                                                                                                                                                                 |
| Backend selected realtime integration cases                                                         | 5 passed against isolated NestJS/Centrifugo services and local MongoDB/Redis; 62-second idle interval, native expiry, outage/restart retries, logout/connect race and final-device last seen |
| Flutter `flutter test test/core/presence_session_test.dart test/ui/presence_label_test.dart`        | 18 passed                                                                                                                                                                                    |
| Flutter `flutter analyze`                                                                           | No issues                                                                                                                                                                                    |
| Flutter `dart format --output=none --set-exit-if-changed lib/core/chat_controller.dart`             | Passed; no formatting changes                                                                                                                                                                |
| `git diff --check`                                                                                  | Passed                                                                                                                                                                                       |

The five realtime cases were selected from the backend directory with:

```sh
./node_modules/.bin/tsx --test --test-name-pattern='idle sockets|access-session expiry|provider outage at logout|logout racing|last seen persists' test/integration/realtime.test.ts
```

No runtime defect was reproduced. Two obsolete refresh descriptions were corrected in `backend/README.md` and the Flutter realtime connection comment. This remains local browser/service evidence; no native-device, multi-node or production acceptance is claimed.
