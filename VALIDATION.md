> Historical validation below predates the Centrifugo-only presence change. Current presence behavior and verification are recorded in [PRESENCE_VALIDATION.md](PRESENCE_VALIDATION.md).

> Current sequence-receipt and compact unread verification (2026-10-17): [RECEIPT_SEQUENCE_VALIDATION.md](RECEIPT_SEQUENCE_VALIDATION.md). Backend 80 unit / 67 integration tests, Flutter 323 tests, both builds and 20 live REST/WebSocket checks passed. Two Web sessions verified Delivered → Seen, live unread clearing and recovery of a partial unread count from persisted SQLite after missed events and preference coalescing. Earlier receipt counts/contracts below are historical.

# Validation history

The first follow-up below is historical evidence. A second source review reproduced four remaining client defects despite its passing suites: delayed delete-for-me across accounts, logout blocked by pending startup, invisible later failed images in lazy batches, and inherited incorrect cache certification. The current follow-up at the end of this document records their fixes and fresh checks; earlier counts and screenshots do not by themselves close those cases.

Recorded 2026-10-16 after fixing all nine source/spec audit findings and the subsequent logout-presence defect. These results supersede the initial implementation's passing counts, which did not cover the nine reproduced cases. The approved architecture remains REST commands/recovery, MongoDB transactions, latest-room Redis projections, protected Centrifugo inbox channels, and Flutter/Drift; no message event log or outbox was added.

## First follow-up commands actually run

| Scope                           | Command                                                                                                                                          | Result                                                             |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| Backend formatting              | `npm run format:check`                                                                                                                           | Pass                                                               |
| Backend TypeScript              | `npm run typecheck`                                                                                                                              | Pass                                                               |
| Backend production compilation  | `npm run build`                                                                                                                                  | Pass                                                               |
| Backend unit checks             | `npm test`                                                                                                                                       | 12 passed                                                          |
| Backend live integration        | `npm run test:integration`                                                                                                                       | 30 passed                                                          |
| Independent REST/two-socket E2E | `node --check scripts/e2e.mjs` and `node --test scripts/e2e.mjs`                                                                                 | 17 passed against the updated running API                          |
| Dart formatting                 | `dart format --output=none --set-exit-if-changed lib test`                                                                                       | 23 files, zero changes                                             |
| Flutter analysis                | `flutter analyze`                                                                                                                                | No issues                                                          |
| Flutter unit/widget checks      | `flutter test`                                                                                                                                   | 89 passed: 67 core, 22 UI/widget                                   |
| Release Web                     | `flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`       | Pass, `mobile_and_web/build/web/`                                  |
| Debug Android                   | `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket` | Pass, `mobile_and_web/build/app/outputs/flutter-apk/app-debug.apk` |

Backend integration uses fresh synthetic MongoDB databases and Redis namespaces against the existing local replica set, Redis and secure Centrifugo. The independent Node suite uses the separately running API and two actual protected WebSocket clients. Flutter regressions use real controllers, the serialized inbox service, native in-memory SQLite and widgets with controlled HTTP delays. These are distinct proof layers; unit tests do not substitute for browser or service checks.

## Closure of the nine findings

| Finding                                        | Final behavior and permanent evidence                                                                                                                                                                                                                                                                                                                                                                                   |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Send target changes across awaits           | Immutable initiating account/session/room/peer context covers text recovery and the entire image batch. `test/ui/send_context_test.dart` delays latest-history recovery and uploads across room/account changes and lazy room creation.                                                                                                                                                                                 |
| 2. UUID-only local identity                    | Drift schema 2 and acknowledgement lookup use `(senderId, idempotencyKey)`. `test/core/schema_migration_test.dart` opens an actual version-1 database, preserves rows/status/metadata/indexes and verifies two senders can share a UUID. Core, integration and live E2E checks verify sender scope.                                                                                                                     |
| 3. Late direct lookup crosses accounts         | Original generation/navigation guards enclose reconciliation and draft remapping in one transaction. `test/core/review_regressions_test.dart` pauses remapping across account switching and delays lookup across navigation.                                                                                                                                                                                            |
| 4. Historical jump misses coalesced mutations  | The target and verified history revision drive guarded context refresh/invalidation; invisible targets return safely to latest. Regressions cover delta/full reset without `updatedMessage`, normal tails, hidden targets and delayed competing jumps.                                                                                                                                                                  |
| 5. Hidden originals leave visible quotes stale | Safe `quoteUpdate` snapshots reach only recipients with visible matching replies. SQLite and in-memory slices rewrite quotes without inserting hidden originals. Backend regressions cover hidden text/image edits/deletion and no-quote confidentiality; core, live socket and browser checks cover cleanup.                                                                                                           |
| 6. Older cached receipt ticks stay stale       | Latest direct pages return snapshot-consistent outgoing receipt boundaries plus `hasGaps`. Reconciliation updates retained sent history, or resets uncertifiable older sent rows while preserving failed/pending sends. Tests cover 60 cached rows, overlap, timestamp ties/backdating, legacy responses, sender direction, coherent reads and unchanged reopen. Live receipt events also exclude failed/pending sends. |
| 7. Lazy room creation loses the next draft     | Stable account/session/direct-peer composer identity survives draft-to-room remapping. Real-controller widget regressions verify the same composer state, exact next draft and focus, plus clearing on actual conversation/account/session changes.                                                                                                                                                                     |
| 8. Optional debug discovery blocks startup     | Required startup and optional discovery have independent deduplicated futures. Tests cover 503, unresolved discovery, interrupted-send sweep, visible Sync now recovery while discovery remains pending, asynchronous directory updates, and retry without duplicate session setup.                                                                                                                                     |
| 9. Null preference booleans mutate state       | Omitted values remain optional; explicit null/non-boolean values fail validation before mutation. Unit/integration/live E2E checks verify 400 and unchanged Mongo state, revisions and Redis state.                                                                                                                                                                                                                     |

The contracts in `CONTEXT.md`, `BACKEND_SPEC.md`, `FLUTTER_SPEC.md` and `IMPLEMENTATION_ROADMAP.md` now agree on sender scope, migration, quote-only disclosure, receipt summaries/gaps, retryable startup and presence lifecycle. OpenAPI and runbooks match the implemented additions. Independent source reviews closed the backend and Flutter fixes; follow-up findings about live optimistic receipts, visible startup retry and optional-directory deduplication were corrected and covered before final validation.

## Logout presence

The old implementation stopped the client timer but left a single user-wide Redis lease active for up to 45 seconds. The stale online state was reproduced in the two browsers before changing presence.

The final implementation uses a per-authentication-session lease identified only by a SHA-256 bearer digest. Newly issued tokens have unique JWT IDs. Logout/account switching calls authenticated `POST /presence/offline` with old credentials, removes only that lease and atomically retires it for 24 hours. Delayed heartbeats cannot revive it; other active sessions keep the user online. Local logout completes even on 401, network failure or a three-second timeout. A stopping-session fence blocks sends, uploads, navigation and recovery during cleanup.

Backend tests verify separate same-user logins, one versus final logout, repeated release, concurrent/late heartbeats, expired-score pruning, legacy compatibility, authentication, unchanged counters and no late `lastSeenAt` renewal. Eight client regressions verify old credentials, account switching, 401/503, a real timeout, late heartbeat results, anonymous logout and operations during delayed release. The independent live suite verifies two same-user sessions and immediate server offline state after the final logout.

On the final build, logout was exercised in both directions between the two Web instances. The departing account returned to authentication; its peer lost the green dot and Online label. Immediately after User 1 logged out, a separate authenticated status read returned `User 1: false` and `User 2: true`. Both accounts could log in again with fresh sessions. The documented boundary is immediate server release when reachable, peer observation on the next normal 20-second refresh, and a 45-second expiry after abrupt termination or failed release. Legacy user-wide leases can persist for their existing expiry during an upgrade. Presence retirement does not revoke authorization for other API routes.

## Two-browser computer-use evidence

The existing Flutter web-server processes at `http://localhost:5173` and `http://localhost:5174` were reused, hot restarted and reloaded. This run used User 2 in the first instance and User 1 in the second.

Verified on the updated application:

- The persisted account restored after reload and existing history remained available. The dedicated migration regression separately verifies exact version-1 row/status preservation in schema version 2.
- Fresh bidirectional text and a quoted reply reached both instances with delivery/read ticks.
- A recipient hid a newly created original, kept a visible reply, and received an edit plus global deletion after a newer tail displaced that reply from the room preview. Its quote changed to the edited preview and then deletion text; the hidden original never reappeared.
- Native Chrome file selection uploaded the synthetic PNG; both clients rendered it and the sender received read ticks.
- The existing 525-message fixture loaded its latest page, jumped to the explicit distant anchor/context, and returned to latest.
- Reopening already verified direct and group caches left `messageRequests` at 5. Browser network tracing confirmed zero message-history GETs, while normal inbox delta and seen requests continued. The selected group remained `msgPts == messagesSyncedPts == 540` with 38 total cached message rows across the two rooms.
- Centrifugo admin showed OSS 6.9.7, one node, two clients, two users, two subscriptions and two channels. The live suite rejected a foreign inbox subscription.

- While the first instance was navigated away, the second sent a fresh message and showed it as sent. Restoring the saved first account recovered an unread inbox preview; opening the chat recovered the body and changed the sender's ticks through delivered to seen.
- Explicit logout was verified in both directions: the departing account returned to the login screen and the peer removed its online dot/label. Fresh login after each release worked. Both instances were reconnected after the checks.

Ignored local screenshots retain the actual browser views: `.runtime/hidden-quote-edited-final.jpg`, `hidden-quote-deleted-final.jpg`, `chat-instance-a-image-final.jpg`, `chat-instance-b-image-final.jpg`, `history-remote-jump-final.jpg`, `cache-before-reopen-final.jpg`, `cache-after-reopen-final.jpg`, `missed-message-recovered-final.jpg`, `logout-peer-offline-final.jpg`, `logged-out-final.jpg`, `reverse-logout-peer-offline-final.jpg`, `reverse-logged-out-final.jpg`, and `centrifugo-followup-final.jpg`. The native file dialog avoids the previously observed detached picker-input automation limitation; no dependency patch or product workaround was added. A development hot restart timed out while its tab was deliberately disconnected; the terminated listener was restarted on port 5173 before the final recovery/presence checks.

## Boundaries

- Verified against local MongoDB replica set, Redis, Centrifugo and API. `/health` returned 200 with MongoDB and Redis both healthy. These results do not establish deployment, production capacity, provider acceptance or native-device behavior.
- No Android/iOS simulator or device UI test was run. Only the explicitly requested two Web instances were used. The current project targets Android and Web.
- Existing transitive media plugins warn about future Flutter built-in Kotlin compatibility. The current debug APK compiles successfully.
- Synthetic test data and uploads are retained. No existing database was dropped, Redis flushed, existing upload removed, or unrelated user data edited. Browser deletion checks only tombstoned newly created synthetic messages through the application's normal actions.
- No commit, push, external publication, deployment, store submission, signing change, or destructive infrastructure action was performed.

## Second-review follow-up: fixes and API tracing

Recorded 2026-10-16 after the input/bottom-layout fixes and the four remaining review findings. The current results supersede the earlier Flutter count; the original nine regression paths remain in the full suite.

| Check                           | Actual command                                                               | Result                 |
| ------------------------------- | ---------------------------------------------------------------------------- | ---------------------- |
| Backend format/type/build       | `npm run format:check`, `npm run typecheck`, `npm run build`                 | Pass                   |
| Backend unit                    | `npm test`                                                                   | 12 passed              |
| Backend integration             | `npm run test:integration`                                                   | 30 passed              |
| Script syntax                   | `node --check scripts/e2e.mjs`, `node --check scripts/history-fixture.mjs`   | Pass                   |
| Independent REST/two-socket E2E | `node --test scripts/e2e.mjs` with a temporary isolated API                  | 17 passed              |
| Dart format                     | `dart format --output=none --set-exit-if-changed lib test`                   | 28 files, zero changes |
| Flutter analysis                | `flutter analyze`                                                            | No issues              |
| Flutter tests                   | `flutter test --reporter expanded`                                           | 130 passed             |
| Web release                     | `flutter build web` with the documented localhost API/Centrifugo definitions | Pass                   |
| Android debug                   | `flutter build apk --debug` with the documented host-loopback definitions    | Pass                   |
| Whitespace/conflicts            | `git diff --check`                                                           | Pass                   |

The independent E2E script was launched by a one-shot harness that loaded the existing private local configuration without printing it, selected a fresh synthetic MongoDB database and Redis namespace, listened on an ephemeral localhost port, passed that URL through `API_BASE_URL`, and closed the test API in `finally`. It used the existing Centrifugo service. The manual API on port 3000 was not started or restarted for these checks. Synthetic test data/uploads were retained.

| Remaining finding                            | Implemented behavior and permanent regression                                                                                                                                                                                                                                                                                                                                                                                                                            |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Delayed delete-for-me crosses accounts       | Recheck the original session after resource reconciliation, inside the local delete transaction, and before filtering the visible list. `remaining_controller_regressions_test.dart` pauses both reconciliation and local transaction acquisition across a complete account switch and preserves the next account's shared row/view.                                                                                                                                     |
| Logout waits for pending startup             | Invalidate synchronously; keep local install/cleanup serialized while mandatory network startup runs outside that lane. Retire old sync without draining HTTP or waiting for a paused event consumer. Regressions delay delta/users/heartbeat with late success/failure across logout and the next login, fence metadata-to-HTTP, cover paused consumers and expired saved credentials, and verify a pending delta cannot extend the three-second offline-release bound. |
| Later lazy-batch images become invisible     | Resolve the initiating draft's original peer to its known real room inside the optimistic-write transaction. Tests verify later sending/failed rows remain in that room, Retry uses the same idempotency key, navigation does not redirect the send, and an account change cancels old context. The existing UI batch regression now verifies the first peer-targeted request and later real-room request retain the same original recipient.                            |
| Old upgraded caches remain falsely certified | Schema version 3 invalidates only `messagesSyncedPts` once for versions 1/2 while retaining rows, receipts, drafts, sender keys and inbox cursor. Actual legacy-database regressions verify unchanged-inbox receipt/quote repair, no hidden-original resurrection, preserved retry state, unchanged reopen with zero extra requests, and persistence of a newly verified baseline across database reopening.                                                             |

The input/scroll regressions still pass: Web text-field semantics identity survives Send toggling; connection/upload banners preserve composer state, text and focus; short chats anchor at the bottom; chronological order, history scrolling and local/remote reply jumps remain correct.

Ten adapter-based API logging regressions verify safe route templates and server response correlation, unchanged outbound headers, HTTP/network errors, multipart success/failure, malformed IDs, disabled logging, immutable history capped at 60 records and logger failure isolation. Debug traces include operational metadata only; release builds gate them off. `recentApiRequests` appears in Sync diagnostics alongside the existing operational events.

The agent-started persistent backend was stopped first and port 3000 was confirmed free. A separately started backend subsequently answered `/health` with 200 and a response request ID; that process remains under the user's control. Start it manually with `HTTP_LOGGING_ENABLED=true npm run start:dev` from `backend/`. Client `[api]` console records and Sync diagnostics carry the response request ID for matching the API terminal's JSON completion log. Request bodies, credentials, raw paths/queries and upload filenames are excluded from these traces.

The refreshed Web client visibly exposed the new bounded request history in Sync diagnostics and emitted `[api]` console records. The manually controlled API became unreachable during that check, so those records correctly showed `status: null`, `requestId: null` and `connectionError` rather than fabricated server correlation. The local screenshot is `.runtime/api-traces-current.jpg`. A successful browser reconnect/correlation was not claimed for that unavailable service; successful correlation, HTTP errors and uploads passed the adapter suite, and actual server response correlation passed integration/E2E. The manual service was not restarted by the agent.

These are local source, SQLite/widget and real-service checks. No native device/simulator UI run or deployment was performed. Existing transitive media plugins still emit the previously recorded future Kotlin compatibility warning; the current APK builds successfully. All changes remain uncommitted.

## Current follow-up: cached conversations without the API

Recorded 2026-10-16 for the request to keep Drift messages and pending sends available offline. Local session installation and message subscriptions no longer wait for inbox/latest HTTP. Saved rooms, sent/sending/failed messages, local history expansion, cached reply navigation, Return to Latest, cached contacts and the composer remain usable while requests fail or never complete. Background recovery coalesces pending work and retries automatically every 20 seconds while needed, as well as on Sync now, resume and reconnect. Offline rendering never advances the inbox cursor or certifies an unverified message baseline.

| Check                | Actual command                                                                                                                                   | Result                 |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------- |
| Dart format          | `dart format --output=none --set-exit-if-changed lib test`                                                                                       | 32 files, zero changes |
| Flutter analysis     | `flutter analyze`                                                                                                                                | No issues              |
| Full Flutter suite   | `flutter test --timeout 30s --reporter expanded`                                                                                                 | 155 passed             |
| Web release          | `flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`       | Pass                   |
| Android debug        | `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket` | Pass                   |
| Whitespace/conflicts | `git diff --check`                                                                                                                               | Pass                   |

The 25 new regressions comprise 11 controller cases, nine draft-storage cases, two server-pagination cases and three real-controller/Drift widget workflows. They cover unresolved delta/latest/context/direct requests; local navigation and window expansion; failed rows and same-key Retry; persisted draft metadata and startup recovery; real-room discovery and atomic remapping; socket acknowledgement before a lost REST response; sender-scoped UUID isolation and transaction rollback; cached contacts; preserved composer state/focus; and recovery after initial and later outages. The automatic recovery test waits for both initial failures and the actual 20-second timer without invoking manual sync/resume. Existing receipt, historical deletion, migration, logout and account-switch checks retain their assertions with explicit awaits for background network reconciliation. The lazy-composer widget harness now pumps frames with a bounded wait and releases pending gates in teardown; its composer identity, exact text and focus assertions remain unchanged.

Before the controller changes, all three new offline widget workflows reproduced the blocked startup through an unresolved delta and a three-second timeout. Their final versions pass. Initial uncached reply context keeps the saved tail visible while waiting/failing; known stale historical contexts still invalidate safely. Local draft summaries appear only after a real optimistic send, survive restart/full sync while pending, and are excluded from server inbox page counts/cursors. Both REST and socket acknowledgement remove the draft summary and remap all pending rows atomically. A server-confirmed send stays sent if the HTTP response subsequently fails.

Actual computer-use checks used the two existing independent Web origins on ports 5173 and 5174 with port 3000 unavailable. Both restored saved accounts and opened cached direct histories. On the first client, typing and sending a synthetic offline message produced a visible failed row with Retry and a failed inbox preview; reloading and reopening preserved it alongside the earlier sent history. The cached-contact picker remained selectable and reopened that conversation without waiting for `/users`. Screenshots are retained locally as `.runtime/offline-cache-and-retry.jpg` and `.runtime/offline-second-client.jpg`. The manually controlled API was not started or restarted. Browser recovery against a restarted API was not claimed; controlled HTTP tests prove that path, including automatic retry.

This verifies cached chat behavior with the API unavailable. New authentication, uncached history, new image uploads and server mutations still require the API. Stored image URLs do not guarantee persistent offline image bytes on Web, and no offline Web app-shell service worker was added for a browser reload with all network resources unavailable. No backend contract/schema/dependency change, native device/simulator run, deployment or publication was needed for this follow-up. All existing data and unrelated changes were preserved; changes remain uncommitted.

## Current follow-up: full debug traffic inspection

Recorded 2026-10-16 for the request to inspect user IDs, timestamps, complete HTTP responses and realtime data, exclude OPTIONS, count traffic and switch the custom logger on/off. Backend `DebugTrafficLogger` shares JSON output and request context across HTTP completion and each Centrifugo publication attempt. Full capture is opt-in with `DEBUG_TRAFFIC_LOGGING_ENABLED=true`; HTTP metadata has its independent `HTTP_LOGGING_ENABLED` flag. Debug Flutter builds have a runtime switch, immutable full records capped at 60 and counts grouped by receiving/initiating user for that retained window. Release builds gate capture off. No API/event wire fields or dependencies were added.

| Check                            | Actual command                                                                                                                                   | Result                 |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------- |
| Backend format                   | `npm run format:check`                                                                                                                           | Pass                   |
| Backend types/build              | `npm run typecheck`; `npm run build`                                                                                                             | Pass                   |
| Backend unit suite               | `npm test`                                                                                                                                       | 25 passed              |
| Backend real-service integration | `npm run test:integration`                                                                                                                       | 34 passed              |
| Independent REST/WebSocket E2E   | `node --test scripts/e2e.mjs` through an isolated ephemeral test API                                                                             | 17 passed              |
| Dart format                      | `dart format --output=none --set-exit-if-changed lib test`                                                                                       | 36 files, zero changes |
| Flutter analysis                 | `flutter analyze`                                                                                                                                | No issues              |
| Full Flutter suite               | `flutter test --timeout 30s --reporter expanded`                                                                                                 | 178 passed             |
| Web release                      | `flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`       | Pass                   |
| Android debug                    | `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket` | Pass                   |
| Scripts/whitespace               | `node --check scripts/e2e.mjs`; `node --check scripts/history-fixture.mjs`; `git diff --check`                                                   | Pass                   |

The 13 added backend unit cases and four added integration cases cover full nested HTTP JSON and error bodies, headers/parameters/queries, trusted auth identities, OPTIONS exclusion, binary/multipart metadata, disabled logging, concurrent async request context, exact publication payloads, stable retry IDs, provider failures and output failure isolation. Integration uses real local MongoDB, Redis and Centrifugo: the first publish attempt is deliberately rejected, subsequent attempts reach the real provider, both recipients retain the originating actor/request ID, and exhausted advisory retries still leave the committed REST mutation successful.

The 23 added Flutter controller/logger/widget cases cover full HTTP/realtime data, credential redaction, immutable history and bounds, failure isolation, runtime enable/disable including in-flight responses, session installation/logout identity, file metadata and the actual diagnostics toggle/count display. Additional audit regressions capture identity synchronously before Dio's asynchronous interceptor: immediate A-to-B, A-to-logout, anonymous-to-B and upload/account switches preserve the identity matching the copied outbound bearer. Credential regression coverage includes nested JSON-encoded strings, bearer/JWT/header/query material and URL userinfo while preserving ordinary JSON formatting and business URLs. The ordinary-header assertions compare HTTP names case-insensitively.

The manually controlled API on port 3000 was not started or restarted. Integration and E2E used fresh synthetic MongoDB databases/Redis prefixes and test-only ephemeral listeners, closed afterward; no existing data was deleted. The independent E2E run preceded the final credential-pattern refinement, which was subsequently covered by the final unit, integration and client suites. Backend provider acceptance and client receipt remain distinct records. OpenObserve and Loki are documented as optional self-hosted search tools; neither was installed and no logs were uploaded to an external service. No native device/simulator run, commit, push or deployment was performed. Existing transitive media plugins retain the recorded future Kotlin compatibility warning; the APK builds successfully.

Actual browser verification refreshed the existing first Web client, restored its saved account and opened Sync diagnostics. The new switch visibly changed off/on/off/on. Sync now emitted full JSON console records with the initiating user ID, UTC timestamp, route, query and redacted authorization header. With the manual API unavailable, these records correctly showed a connection error and null status/response/request ID. Successful browser HTTP/realtime receipt was not claimed during that outage; full successful response/publication checks are covered above. The enabled control is saved in ignored `.runtime/debug-traffic-current.png`. Both existing Web sessions remain available.

## Current follow-up: inspect internal Redis data

Recorded 2026-10-16 for the request to install an open-source tool for the app's internal Redis debugging. Redis Commander `0.9.0` (MIT) is installed in ignored `.runtime/redis-inspector/` and running at `http://127.0.0.1:8081/`. `scripts/redis-debug.mjs` supplies isolated, in-memory connection settings from private `backend/.env`, pins the tool version, binds the UI to loopback, enables server-side read-only checks and SCAN, disables connection saving/value logging and retains verified TLS for local `rediss` URLs. It refuses nonlocal/malformed targets and unrelated legacy saved connections. The key tree follows `REDIS_KEY_PREFIX`; the current unprefixed database also contains other local services and retained synthetic test namespaces.

| Check                      | Actual command / observation                                                                                                               | Result                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------- |
| Reproducible install       | `node scripts/redis-debug.mjs install`                                                                                                     | Pass, exact `0.9.0`                     |
| Foreground lifecycle       | `node scripts/redis-debug.mjs start`; Ctrl+C; start again                                                                                  | Pass; port 8081 was free after shutdown |
| Syntax                     | `node --check scripts/redis-debug.mjs`; `node --check scripts/redis-debug.test.mjs`                                                        | Pass                                    |
| Launcher regressions       | `node --test scripts/redis-debug.test.mjs`                                                                                                 | 12 passed                               |
| Formatter                  | `backend/node_modules/.bin/prettier --check scripts/redis-debug.mjs scripts/redis-debug.test.mjs REDIS_DEBUGGING.md`; backend README check | Pass                                    |
| Diff whitespace            | `git diff --check`                                                                                                                         | Pass                                    |
| HTTP binding               | `lsof -nP -iTCP:8081 -sTCP:LISTEN`                                                                                                         | Only `127.0.0.1:8081`                   |
| Live Redis/inspector probe | Real configured connection, meta hash/TTL, full room JSON, sorted set, rejected form/CLI mutation and unchanged sampled Redis data         | Eight checks passed                     |
| JSON viewer assets         | Both `/json-viewer/jquery.json-viewer.js` and `.css`                                                                                       | HTTP 200                                |
| Browser UI                 | Open actual user's `meta`, `dirty_rooms`, `rooms_data` and nested JSON tree                                                                | Pass                                    |

The live read-only probe received HTTP 403 for a mutation form and `ERROR: Command not read-only` for a CLI `EXPIRE` targeting a verified nonexistent random key. It did not send any destructive command. The nonexistent probe key remained absent, and before/after comparisons of the sampled user's meta hash, room hash and sorted-set members/scores matched. Live data showed account `current_pts` and direct-room revision score 569 with corresponding room JSON, plus the older group score 540. TTLs were positive. Discovery found 31 unprefixed chat meta/dirty-room/room-data groups; presence keys naturally expire and are not a fixed count.

Initial browser verification exposed an upstream packaging issue: Redis Commander serves its JSON viewer from a nested dependency path while npm hoists that package. Both asset requests returned 404, so valid JSON fell back to quoted text. The launcher now links the existing dependency into the missing expected path after install and before start, without changing vendor source or overwriting unexpected files. Four filesystem regressions cover the repair, repetition, existing nested dependencies and missing/partial assets. The actual browser then rendered expandable nested JSON with message/reply data and revisions. Screenshot: ignored `.runtime/redis-inspector-current.png`.

`REDIS_DEBUGGING.md` maps every current app key family, types, TTLs, read-only commands and HTTP/realtime correlation. Redis retains latest room projections rather than full history; MongoDB and Drift remain their existing durable/cache authorities. The inspector is a current-state view with manual refresh, not a historical audit journal. The app source, API contracts, Redis ACL/server settings, existing data and application dependencies were unchanged. The manually controlled API on port 3000 was not started or restarted, and Redis/MongoDB/Centrifugo were not restarted. No native device run, container, commit, push, external upload or deployment was needed.

## Flutter event, state and Drift inspector follow-up

Recorded 2026-10-16 for the requested internal Flutter debugging and performance visibility. Debug builds now expose **Flutter inspector** in the Workspace menu and Sync diagnostics, with recording off by default. The controller-local recorder retains at most 500 events, 64 active spans, 100 aggregate operation keys, 64 gauge/build keys and 120 native frame samples. Clear/off/pause invalidate unfinished spans; independent timers/socket/watch callbacks start with a fresh capture epoch and installed session identity. HTTP spans capture the initiating bearer identity synchronously and retire even on request setup failure. No new package, service, database schema or API/event wire field was added.

The timeline covers controller actions, HTTP/realtime, inbox queue and reconciliation, actual Drift query/transaction/watch activity, state notifications and four principal screen builds. Query text/parameters, returned cell values, credentials and message/network bodies are excluded. Full traffic logging and SQLite row inspection remain separate opt-in/debugging views. State-to-build records include notification IDs. Persistent stream emissions retain subscription identity; their exact causative SQLite write is not always recoverable from Drift invalidation and is not invented.

| Check               | Command                                                                                  | Result                         |
| ------------------- | ---------------------------------------------------------------------------------------- | ------------------------------ |
| Dart formatting     | `dart format --output=none --set-exit-if-changed mobile_and_web/lib mobile_and_web/test` | 44 files, 0 changed            |
| Flutter analysis    | `flutter analyze`                                                                        | No issues                      |
| Full Flutter suite  | `flutter test --timeout 30s --reporter expanded`                                         | 221 passed                     |
| Web release build   | `flutter build web --release`                                                            | Passed, including Wasm dry run |
| Android debug build | `flutter build apk --debug`                                                              | Passed                         |
| Patch whitespace    | `git diff --check`                                                                       | Passed                         |

The 43 added regressions cover bounded stores/active spans, immutable metadata/redaction, async parent/session identity, clear/pause/off during work, long-lived callback reuse, HTTP setup cleanup and target-room attribution, action error reporting, real SQLite query errors/rollback/stream cancellation, full/delta/live inbox processing and cursor authority, queue invalidation/retirement, resource sampling across pause/enable, inspector controls/export/filters, no state-notifier feedback, accessible capture toggle actions/state and responsive 320/390px layouts. Existing 178 regressions remain in the same full suite. SDK commands ran sequentially to avoid shared Web asset staging races.

Native frame timing uses a labelled 60 Hz heuristic and is unavailable on Web. Resource gauges count only instrumented timers/subscriptions/queues/views; no heap leak has been proven or ruled out by those counts. The inspector is unavailable in profile/release builds; use Chrome Performance/Memory for Web or Flutter DevTools with a native profile build for representative measurements. No native device/simulator test or heap-profile acceptance run was performed. The existing transitive media-plugin warning about future built-in Kotlin support remains; the APK build succeeded. No backend changes, persistent API startup, commit, push or deployment occurred in this follow-up.

Both existing Flutter Web processes were hot restarted sequentially and their original tabs reloaded. The first instance restored its saved account, exposed the inspector through the Workspace menu, and exported real captures containing action/state/Drift/widget/queue/sync/HTTP/controller categories. The accessible **Capture Flutter events** switch toggled through its semantic action; Pause, Clear and Resume worked in the actual browser. Opening the existing cached room showed its retained messages and failed sends while capture recorded query timings, watch/state updates and build notification IDs. Exported state notification IDs matched subsequent widget records; live gauges showed one room watch, one message watch and zero pending/running queue work after reconciliation failed. Web native frame timings were explicitly labelled unavailable with Chrome profiling guidance.

The manual API remained stopped. Captured `/rooms/delta` failures therefore correctly had `status: null`, `requestId: null`, `connectionError` and captured user/session/room/parent-span IDs; this run does not claim successful live HTTP or realtime delivery. The first inspector is left paused with 69 retained events and a correlated nine-event inbox trace visible. The second instance independently showed capture off with an empty timeline. Both chat tabs and the existing Redis Commander tab remain available. The final screenshot is ignored `.runtime/flutter-inspector-current.png`. No messages were sent or deleted during this browser check.

## Backend log presentation and exports follow-up

Recorded 2026-10-16 for the request to replace enormous terminal JSON lines with compact summaries and expandable inspection. Development traffic output now uses two lines with full UTC timestamps, status, method/route, duration, actor and request IDs. JSON stdout remains the default outside development; explicit `pretty`, `json` and `silent` modes are supported. Private append-only JSONL capture is optional and independent of the terminal. Full redacted HTTP/realtime payload capture retains its existing flag. The file sink bounds pending writes at 4 MiB, rejects linked/special files, isolates errors and drains accepted writes on shutdown. No application API, database schema or dependency changed.

Logdy `v0.17.1` is installed in ignored `.runtime/backend-log-viewer/` using the pinned, checksum-verified official macOS ARM64 Go SDK. The adapter follows a single file stream from offset zero, serves the upstream UI over a private Unix socket and retains 2,000 server records. The loopback Node front end checks Host/Origin, blocks cross-site access, ingestion and server-side configuration writes, strips CORS, and supplies a content policy with an exact hash for the pinned inline bootstrap. Analytics/update checks are disabled. The browser buffer holds 1,000 records. `npm run logs` starts only this viewer; `npm run start:debug` starts the API manually and honors shell settings, then private `.env` logging choices, then debug defaults.

| Check                                | Command / observation                                                                                                                         | Result                                                                      |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Backend formatting                   | `npm run format:check`                                                                                                                        | Passed                                                                      |
| Backend types/build                  | `npm run typecheck`; `npm run build`                                                                                                          | Passed                                                                      |
| Backend unit suite                   | `npm test`                                                                                                                                    | 41 passed                                                                   |
| Real-service capture and live append | `TRAFFIC_LOG_FILE=../.runtime/backend-logs/traffic.jsonl npm run test:integration`                                                            | 34 passed; repeated while the viewer was open                               |
| Tool regression/integration suite    | `BACKEND_LOG_VIEWER_INTEGRATION=1 node --test scripts/backend-logs.test.mjs scripts/backend-debug.test.mjs`                                   | 19 passed                                                                   |
| Script formatting/syntax             | Prettier checks for the five new JS files and logging docs; `node --check` for launcher/proxy/debug files; `gofmt -l scripts/logdy-bridge.go` | Passed                                                                      |
| Whitespace                           | `git diff --check`                                                                                                                            | Passed                                                                      |
| Runtime boundary                     | Listener read-back and actual bridge tests                                                                                                    | Only `127.0.0.1:8082`; private socket `0600`, parent `0700`; port 3000 free |
| Browser inspection                   | Real integration capture, JSON tree, correlation, pause/resume                                                                                | Passed; resumed from 19 retained rows to all 38 appended records            |
| Browser JSON download                | Actual `logdy-messages.json` in Downloads, parsed as JSONL                                                                                    | 19 records, 12 configured column values per record                          |

Sixteen new backend cases cover summaries, ANSI/control characters, production JSON compatibility, silent/file-only capture, independent sink failure isolation, private file permissions, append order, linked/special targets, queue bounds and flush/disposal. Viewer tests cover exact Host/Origin and WebSocket checks, encoded path bypasses, restricted routes/headers, body/status bounds, lifecycle cleanup and file preservation. Installed integration reads existing and newly appended JSONL through the actual bridge and fetches WebAssembly/worker/font assets. Browser verification found and fixed missing static assets and the pinned UI's requirement for an exact `application/json` status header; both now have regression coverage.

The screenshot is ignored `.runtime/backend-logs-current.png`. The viewer remains open with real synthetic integration requests and nested payload details. These records came from isolated test MongoDB databases/Redis prefixes and ephemeral API listeners, which closed afterward; the persistent API on port 3000 was never started or restarted. Existing MongoDB/Redis/Centrifugo and the two Flutter Web processes were preserved. No native simulator/device test, external log upload, commit, push or deployment was performed.

Export limitations are explicit: upstream **Full row** exports all configured table columns, including hidden columns, rather than the original nested record; JSON export is JSONL despite its `.json` suffix. The private capture file is the complete payload export. The CSV control was exercised, but a downloaded CSV artifact was not verified; the pinned upstream implementation also has limited quote escaping, so JSON is preferred for custom values containing quotes. Log files grow until the developer archives/removes them, file capture is best-effort, and the viewer's record-count bounds are not byte limits. The installer currently supports macOS ARM64. See [Backend logging](BACKEND_LOGGING.md) for commands, privacy, retention and guideline notes.

## Local read-only backend logs MCP follow-up

Recorded 2026-10-16 for the authorized MCP implementation. The isolated TypeScript package `tools/backend-logs-mcp/` uses the official MCP server/client SDK `2.3.1` and Zod `4.6.7`; backend application dependencies are unchanged. The host-owned stdio server exposes exactly `search_logs`, `trace_request` and `error_summary`, with strict input/output schemas, read-only annotations and explicit instructions treating all log content as untrusted data. It reads one configured, already-redacted JSONL capture. No HTTP listener, database connection, file mutation or service-control tool was added.

| Check                              | Actual command / observation                                                                                                         | Result                                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| Isolated dependency install        | `npm install --ignore-scripts --no-fund --no-audit` in the MCP package                                                               | 17 packages installed; application manifests/lockfiles unchanged                                       |
| Type checking                      | `npm --prefix tools/backend-logs-mcp run typecheck`                                                                                  | Passed                                                                                                 |
| Build and full package suite       | `npm --prefix tools/backend-logs-mcp test`                                                                                           | Build passed; 38 tests passed                                                                          |
| Source/document formatting         | Backend Prettier against MCP source/tests/manifests/README and changed logging entry docs                                            | Passed                                                                                                 |
| Runtime dependency audit           | `npm audit --omit=dev` in the MCP package                                                                                            | Zero reported vulnerabilities                                                                          |
| Patch whitespace                   | `git diff --check`                                                                                                                   | Passed                                                                                                 |
| Actual stdio SDK clients           | Legacy handshake and protocol `2026-07-28` through the compiled entrypoint                                                           | Discovery and all three tools passed                                                                   |
| Existing local capture through MCP | Real client search, trace and summary against the default file from a different cwd                                                  | Five search rows; seven correlated records across two recipient publications; 38 total scanned records |
| Capture preservation               | Before/after SHA-256, permissions and modification time for those real MCP queries                                                   | Identical; mode `0600`                                                                                 |
| Codex registration read-back       | `codex mcp add chat-backend-logs -- /opt/homebrew/bin/node <absolute-compiled-entrypoint>`; `codex mcp get chat-backend-logs --json` | Enabled stdio entry with the intended executable/entrypoint; no environment credentials configured     |

The suite comprises 22 store cases, ten actual-SDK server cases, four CLI cases and two real stdio client cases. It covers fixed-file access, missing captures without creation, preserved bytes/inode/mode/mtime, symlink/hard-link/special-file rejection, exact/literal/time filtering, metadata/payload selection, malformed/invalid UTF-8/oversized/incomplete lines, signed cursor scope and append-stable snapshots, rotation/truncation rejection, bounded byte windows and full trace outputs, chronological retry/fanout identity, failure/abort classification, strict schemas, safe errors, concurrency bounds and clean EOF. A separate source audit found and fixed a leading-blank-line loop and metadata escaping/grouping edges; regressions now cover each. Additional independent in-memory probes checked 40 UTF-8/window pagination scenarios and 200 adversarial metadata records without missing/duplicated rows or unchanged cursors.

The existing capture contained synthetic integration requests: its complete summary reported six HTTP 4xx records, no HTTP 5xx records and 16 failed realtime attempts. These expected test failures are not current production incidents. The real MCP check requested metadata only and printed counts, not message bodies, credentials or private configuration. No API was started/restarted, no MongoDB/Redis/Centrifugo data was touched and no capture bytes or permissions were changed. No native/browser app test, commit, push, publication or deployment was needed.

Codex registration used its supported CLI and the resulting private config remains mode `0600`. A guard comparing parsed global settings before/after, excluding the new server, detected a semantic difference. The original settings were not retained or printed, so the cause could not be classified as CLI normalization or a concurrent edit. No unrelated settings were manually changed or reverted; the new server's targeted registration and connectivity are verified, but preservation of every pre-existing global setting is not claimed.

Default bounds are 32 MiB per scan window, 1 MiB per record, 256 KiB per result and two concurrent queries. Coverage/warnings/cursors distinguish a partial page from a whole capture. Payloads require explicit opt-in; the producer's credential redaction is the trust boundary, not a sanitizer for arbitrary imported files. Snapshot fencing assumes append-only producer output and checks identity, size and boundary fingerprints rather than whole-file integrity against arbitrary in-place edits. Cursors expire across server restarts. The current chat's tool catalog was not hot-reloaded; reconnect the MCP server or open a new local AI session to discover the registered tools. See [MCP usage and contract](tools/backend-logs-mcp/README.md).

## Vector, Logdy and multi-source MCP follow-up

Recorded 2026-10-17 for the authorized local collector implementation. Native Vector v0.59.0 is installed under ignored `.runtime/vector/` from its official ARM64 macOS archive with fixed size/SHA-256 verification and binary-manifest validation. The collector writes `.runtime/observability/events.jsonl`, which the existing Logdy/MCP launchers now select. The loopback browser ingress accepts only bounded Flutter inspector metadata; Vector performs file tailing/checkpoints/transforms/fan-in. Backend diagnostics observe Redis/MongoDB/Centrifugo client operation names, duration, result and error class without arguments/documents/replies. Native Redis/MongoDB files are attached from the existing local service paths. All application services remain separate processes under their existing owners.

| Check                                        | Actual command / observation                                                                                                                                                               | Result                                                                                                                             |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Backend static checks                        | `npm run format:check`; `npm run typecheck`; `npm run build` in `backend/`                                                                                                                 | Passed                                                                                                                             |
| Backend unit suite                           | `npm test`                                                                                                                                                                                 | 49 passed                                                                                                                          |
| Existing-service integration                 | `TRAFFIC_LOG_FILE=../.runtime/backend-logs/traffic.jsonl LOCAL_SERVICE_LOG_FILE=../.runtime/observability/inputs/services.jsonl npm run test:integration`                                  | 35 passed; ephemeral test API only                                                                                                 |
| MCP checks                                   | `npm --prefix tools/backend-logs-mcp run typecheck`; `npm --prefix tools/backend-logs-mcp test`                                                                                            | Build/typecheck passed; 44 tests passed                                                                                            |
| Existing viewer/debug/Vector installer tests | `node --test scripts/backend-debug.test.mjs scripts/backend-logs.test.mjs scripts/vector-tool.test.mjs`, then `BACKEND_LOG_VIEWER_INTEGRATION=1 node --test scripts/backend-logs.test.mjs` | 27 unique checks passed, including actual bridge streaming                                                                         |
| New ingress/collector tests                  | `node --test scripts/local-logs.test.mjs scripts/local-logs-ingress.test.mjs`                                                                                                              | 17 passed, zero skips, including actual installed Vector with isolated synthetic inputs                                            |
| Flutter static/full suite                    | `flutter analyze`; `flutter test`                                                                                                                                                          | Clean analysis; 242 tests passed                                                                                                   |
| Flutter builds                               | `flutter build web` with localhost API/Centrifugo defines; `flutter build apk --debug` with existing Android host-bridge defines                                                           | Both passed; Web Wasm dry run passed                                                                                               |
| Formatting/whitespace                        | Dart formatter for changed files; Prettier for changed scripts/MCP/docs; `git diff --check`                                                                                                | Passed                                                                                                                             |
| Actual collector startup                     | Generated configuration validated by installed Vector before binding ingress; process/listener read-back                                                                                   | `127.0.0.1:8083`, private JSONL/state, no Vector admin API or remote sink                                                          |
| Browser export                               | Existing Web listeners hot restarted and original tabs reloaded; capture/sharing and explicit metric refresh enabled in each                                                               | Two distinct exporter instance IDs, original begin/end/instant metadata, all ten observed inspector categories                     |
| Logdy browser inspection                     | Source/phase columns, exact `inbox.publication` event facet, row details and original JSON                                                                                                 | Realtime duration/IDs/room/session/metadata preserved; existing paused viewer resumed                                              |
| Live stdio MCP against shared capture        | Actual SDK client launched the compiled server with no file override from cwd `/`; all four tools called                                                                                   | All five sources found; 51-record Flutter trace included original publication begin/end and duration, with complete trace coverage |

The new Node tests cover Host/Origin/CORS, strict inspector schema/privacy, atomic batch rejection, fixed/chunked body limits, file/link safety including native parent links, cleanup/port conflicts, unique Vector component IDs and the actual VRL fan-in. Native fixtures verify quoted passwords, cookie fragments, JWTs, Bearer strings and URI userinfo are removed while MongoDB attributes/query documents are omitted. That live test found and fixed a VRL null-to-empty-string fallback affecting MongoDB severity and Centrifugo `message` fields. Flutter regressions cover delivery bounds, snapshots, immutable metadata, capture/pause/off/clear generations, no retained replay, metric sampling and UI controls. Web Fetch rejects redirects and omits credentials; its standalone Dart-to-JavaScript compilation also passed.

The integration suite intentionally overrides its diagnostics file to a private temporary capture and includes deliberate failure cases. Its final restored-provider real-service success flow produced 18 metadata records (MongoDB 14, Redis 2, Centrifugo 2). Only those successful `local-services-` records were explicitly replayed through the collector's service input for live unified/MCP verification, marked `verificationReplay: true` while preserving original timestamps/IDs. They are not evidence that the persistent API already loaded the new code. Integration teardown emitted one bounded file-capture warning; test assertions passed, but complete audit capture is not claimed.

The user's persistent API and existing Redis/MongoDB/Centrifugo processes were not started, stopped or restarted. The API is healthy but requires its owner's manual restart using `npm run start:debug` to load new service diagnostics. Native Centrifugo stdout/stderr currently use pipes, so native server-log coverage remains unavailable until an explicit log file is configured. Client publish diagnostics were verified against real Centrifugo in the isolated integration flow; Flutter realtime receipt was observed independently. No exact cross-service client receipt is inferred from timestamp proximity.

Ignored evidence: `.runtime/local-observability-flutter.png`, `.runtime/local-observability-logdy.png` and metadata-only `.runtime/local-observability-mcp-verification.json`. The collector and unified Logdy viewer remain running locally. Reconnect the existing MCP host to discover the new tool and select the unified file. Selected AI hosts still receive requested tool results; there is no hosted log-upload service. Best-effort queues, bounded query/display windows, manual file archival, collection-time native timestamps and device loopback/port-forwarding limits remain documented in [local observability](LOCAL_OBSERVABILITY.md). No native device/simulator test, heap profile, commit, push or deployment occurred. Existing transitive media-plugin Kotlin compatibility warnings did not prevent the APK build.

## Authorized service restart and native Centrifugo activation

Recorded 2026-10-17 after the user explicitly requested backend restart, MCP reconnect, native Centrifugo logging and fresh five-source verification. The verification window begins at `2026-10-16T21:43:25.537Z` (UTC). Existing captures were preserved; no integration-record replay was used for this window.

| Check                       | Actual action / result                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Persistent backend          | Graceful stop of the existing listener, then `npm run start:debug`; new process served `GET /health` with MongoDB and Redis both `ok`, and wrote fresh traffic/service diagnostics.                                                                                                                                                                                                                                                                                                    |
| Collector                   | Restarted the existing Vector launcher after preparing the native Centrifugo file. Generated configuration validated and reported native Redis, MongoDB and Centrifugo sources. Ingress remains on `127.0.0.1:8083`; Logdy remains on `127.0.0.1:8082`.                                                                                                                                                                                                                                |
| Native Centrifugo           | Existing v6.9.7 executable/configuration/arguments/environment preserved; added supported `--log.file` and `--log.level info`, then gracefully restarted. Private native file is `.runtime/observability/inputs/centrifugo-server.log` (0600); real native records reached the shared capture.                                                                                                                                                                                         |
| Centrifugo safety/readiness | Existing configuration hash unchanged and configuration validation passed. Before/after authenticated API info and JWT WebSocket handshake succeeded; own-user inbox subscription was accepted and another user's inbox was rejected. JWT and user-limited namespace/history settings stayed unchanged.                                                                                                                                                                                |
| Future collector startup    | `discoverNativeLogs` now finds the workspace Centrifugo file by default when present; explicit override and `off` remain supported. `node --test scripts/local-logs.test.mjs scripts/local-logs-ingress.test.mjs` passed 18 tests, zero skips, including actual isolated Vector normalization.                                                                                                                                                                                         |
| Flutter 5173                | Actual browser **Sync now**, HTTP 200 with request `8bf539c6-b1d2-44b9-89b3-a99b35f23e09`; original inspector trace/span/duration retained. Exact request ID matched fresh Flutter, backend, Redis and MongoDB records.                                                                                                                                                                                                                                                                |
| Flutter 5174                | Independent actual browser **Sync now**, HTTP 200 with request `00f5cd95-e76d-4cff-8e28-cbfd91ecb6a4`; original inspector trace/span/duration retained. Exact request ID matched the same four sources. Both clients stayed Connected with capture/sharing on.                                                                                                                                                                                                                         |
| Five-source shared capture  | A read-only snapshot contained 1,174 fresh records: Flutter 923, backend 34, Redis 39, MongoDB 157 and Centrifugo 21. Later snapshots continued to grow. These are diagnostic record counts at one point, not complete operation/audit totals.                                                                                                                                                                                                                                         |
| Actual fresh AI-host MCP    | The verification worker's provided MCP tools queried all five sources after the cutoff from the same unified capture, with no malformed/invalid records. Native Centrifugo `service_log` records had `origin: server_log`. Request tracing returned six correlated records (MongoDB 3, Redis 1, backend 1, Flutter 1) with complete coverage; scoped Flutter `trace_events` returned 74 chronological events. A raw read-only cross-check found zero replay flags in the fresh window. |
| Format and whitespace       | Prettier for changed scripts/docs and `git diff --check` passed. No backend/Flutter source changed in this activation follow-up; their preceding full suites/builds remain the implementation evidence.                                                                                                                                                                                                                                                                                |

The fresh worker-host MCP connection is not the root chat's pre-existing MCP connection. A direct root tool call still read the smaller legacy backend capture and exposed only the old three tools. The supported `config/mcpServer/reload` request was accepted by the separately running shared daemon, but that daemon did not own the desktop app-server's root connection. Read-only process inspection found that the actual desktop host uses private stdio with no supported external reload listener; its MCP children contain no thread/session identity for responsible targeted process selection. Registration/configuration were not edited and unrelated MCP processes were not killed.

Computer Use explicitly denied control of the Codex app. No alternative app path, UI automation bypass or injected stdio was attempted. The remaining supported step is for the user to restart `chat-backend-logs` under **Settings → MCP servers**, then verify the root connection reads the unified capture and exposes `trace_events`. The user was asked for this action. This is a concrete incomplete reconnect step, despite successful five-source access through the fresh worker-host connection. See [official MCP settings](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

Private evidence: `.runtime/observability/restart-verification-start.json`, `restart-local-capture-verification.json`, `centrifugo-native-runtime.json`, `centrifugo-native-verification.json`, `restarted-mcp-host-verification.json` and `.runtime/local-observability-restarted.jpg`. Runtime captures/records remain local; the AI host receives requested tool results. No credentials/configuration bytes were published, no application data was deleted, and no commit/push/deployment or native device test occurred.

The user could not find the MCP restart control. Read-only inspection of the installed desktop UI code established that the circular-arrow icon is in the **Servers header beside Add**, hidden until a server setting changes; unchanged Save is disabled. Toggling the existing entry off/back on marks the host pending restart. The control dispatches an app-server restart, so it is broader than one MCP process. No live Codex UI access or restriction bypass was attempted.

To preserve local collection across that authorized host restart, only the previously owned backend/collector/Logdy processes were gracefully stopped and restarted using the existing commands with detached process groups and private redirected stdout/stderr. Before stopping, executable/argument checks confirmed each process's identity; an initial mismatch guard rejected the backend's different executable-path spelling without changing any process, then the verified exact identity was used. After the launch helper exited, all three and the unchanged Centrifugo process had parent PID 1 and no controlling terminal. Backend health reported MongoDB/Redis `ok`; ingress health and Logdy HTTP were healthy. The runtime manifest is `.runtime/observability/independent-services.json`. This is background process detachment, not an installed LaunchAgent or login service. No application source or MCP registration changed. Flutter managed development listeners remain separate and may need to be resumed if the desktop host ends its old run sessions. The root MCP reconnect remains pending the user's supported UI action and actual tool read-back.

## Current chat MCP reconnect and five-service E2E

Recorded 2026-10-17 after the user completed the desktop restart. This resolves the historical root-connection blocker above: this chat now exposes `search_logs`, `trace_request`, `trace_events` and `error_summary`, and its actual provided tools read the unified capture. The two existing Flutter Web listeners were restored on ports 5173/5174 using the documented launch arguments and detached process groups; existing browser sessions and their local databases were preserved.

New Redis/MongoDB/Centrifugo client records now have additive `name: <source>.<operation>` and `category: command|connection` fields. Examples are `redis.eval`, `mongodb.find`, `mongodb.commitTransaction` and `centrifugo.publish`. Unsafe operation labels remain bounded to `unknown`, without exposing arguments. Existing event, operation, request and publication identities remain unchanged; historical capture bytes were not rewritten. Logdy's versioned layout now labels its name/operation projection **Operation / event**, with a separate hidden **Event kind** facet for the original event.

| Check                                       | Actual command / observation                                                                                                                                                                                     | Result                                                                                                                               |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Backend naming checks                       | Targeted Prettier write/check, `npm run typecheck`, `npm run build`, `npm test` in `backend/`                                                                                                                    | Passed; 50 unit tests                                                                                                                |
| Final terminal E2E after backend restart    | `node --check scripts/e2e.mjs`; `node --test scripts/e2e.mjs`                                                                                                                                                    | 17/17 passed; UTC 2026-10-16T22:09:13.646Z–22:09:23.068Z                                                                             |
| Terminal E2E request coverage               | Fresh synthetic run `1792188553733_b3aa64`, protected WebSocket subscriptions, direct/group messaging, idempotency, receipts, edits/deletions of its own data, preferences, pagination, uploads, presence/logout | 123 related HTTP completions; 114 successful publication attempts; zero HTTP 5xx or failed publish attempts                          |
| New service labels during terminal E2E      | Request-linked client diagnostics from the same run                                                                                                                                                              | Redis 141, MongoDB 1,042, Centrifugo 114; all 1,297 records have names and `command` category                                        |
| Two real Flutter Web sessions               | A→B send, B→A quoted reply, edit only the fresh A→B message                                                                                                                                                      | Both directions received and showed seen/read; received bubble and reply quote updated live                                          |
| Flutter exporter counters after those flows | Both inspectors, Capture and Share enabled                                                                                                                                                                       | First 4,922 sent; second 3,128 sent; both zero queued, export drops or failed batches at inspection                                  |
| This chat's actual MCP mutation traces      | First send, reverse reply, edit and a new post-restart send queried using their exact request IDs                                                                                                                | Each trace contains all five sources; complete reported capture coverage, no malformed/invalid/oversized records or omitted metadata |
| Scoped Flutter traces through this chat     | Source + distinct client instance + capture + session + trace ID                                                                                                                                                 | Each send returned 74 events, including action/HTTP/Drift begin/end spans, parent relationships and durations; complete coverage     |
| Exact MCP name/category filters             | `redis.eval`, `mongodb.find`, `centrifugo.publish`, each scoped to its source and `command`                                                                                                                      | Correct new records returned; MongoDB failure groups distinguish `mongodb.insert` from `mongodb.abortTransaction`                    |

The 17-test count includes 16 nested cases and their parent test. The final terminal run's eleven HTTP 4xx records are intentional authorization/validation cases (five 400, three 401, three 403). Twelve MongoDB warnings (four insert, eight abortTransaction) belong to the concurrent send-idempotency case: the related requests returned 200 and the test verified one message identity across five simultaneous requests. Native Centrifugo also recorded the deliberate foreign-inbox subscription rejection (code 103). The earlier collector inferred `error` from its diagnostic text despite native `level: info`; those historical normalized records remain preserved. These expected negative tests are not current service incidents.

For independent verification, the first browser send request ID is `e9a08761-13ef-485c-ac4f-4f5496515a63`; the reply is `c9a6895c-dcfa-41c0-9747-c8a1e2bce5c3`; the edit is `83c9b6fe-5ce8-48cb-b98f-7289cf433be2`. The post-restart send is `81065ae2-1d5f-4e17-8468-21c84f23bc43`, and its actual MCP trace contains MongoDB 14, Redis 2, Centrifugo 2, backend 3 and Flutter 1 records with the new service names. The first terminal-send trace is `9a552fbb-12e7-4de9-9e11-eda62df7a9fb`; it correctly contains four sources because that sender is the terminal E2E client. Provider acceptance remains separate from receipt: the MCP publication summary does not assert receipt from an unlinked Flutter event; actual browser UI reception was verified independently.

Private evidence is under `.runtime/observability/`: `e2e-terminal-2026-10-16T22-09-13-646Z-9cc71bbc-{report,coverage,negative-test-classification}.json`, `e2e-browser-current.jpg`, `e2e-inspector-first.jpg` and `e2e-inspector-current.jpg`. New synthetic test accounts/data are retained. No existing service data was flushed or deleted; no native-device testing, commit, push, publication or deployment occurred. This is local development coverage and bounded best-effort collection, not proof that every internal server operation or all future logs are captured.

The native severity follow-up changes only `scripts/local-logs.mjs` and its tests: recognized structured JSON `level` / MongoDB `s` now takes precedence over message keywords. `node --check scripts/local-logs.mjs`, targeted Prettier and `node --test scripts/local-logs.test.mjs scripts/local-logs-ingress.test.mjs` passed (18/18, including installed Vector). Actual Vector fixtures cover informational/warning messages containing “error,” case/whitespace, debug/MongoDB severity, unclassified/plain error inference and credential redaction. The owned collector was gracefully restarted with unchanged input/checkpoint paths, preserving capture bytes; its new capture ID is `a9bf2022-0972-4f2d-b1f3-67811d0f6099`.

A narrow live probe reused the terminal suite's existing synthetic outsider identity and attempted only a forbidden inbox subscription; its short-lived connection token stayed in memory. No database mutation or publication was needed. UTC 22:14:38.834Z–22:14:48.033Z: Centrifugo still denied the subscription with code 103, and both native informational lines remained `info` in the new capture. This chat's actual MCP returned both native records and zero native failures for that exact scope, with complete coverage and no malformed/invalid records. Proof files are `native-severity-live-2026-10-16T22-14-38-834Z-3d135df5.json` and `-mcp.json`; this chat's own metadata-only query results are also saved in `e2e-mcp-current.json`.

The first Logdy browser check exposed a stale retained viewport at 22:08:54 while the capture continued advancing. An independent read-only WebSocket client received the capture's exact newest timestamp at 22:13:11, proving that ingestion and the file follower were current. Reloading Logdy restored current rows. Its upstream browser client starts paused; plain Play follows new arrivals without backfilling the paused interval, while resume-from-cursor requests only still-retained rows. The display rolls over 1,000 browser rows and the server ring remains bounded at 2,000. No Go bridge change or larger buffer was introduced; the precise trigger of that retained stale browser state was not established. See `e2e-logdy-stale.jpg` for the initial observation.

The installed-bridge regression now loads 2,401 synthetic pre-existing records and appends another 2,401, observes each final sequence marker over the real WebSocket, and asserts the server ring stays at 2,000 records in both batches. `BACKEND_LOG_VIEWER_INTEGRATION=1 node --test scripts/backend-logs.test.mjs` passed all 16 tests with zero skips; syntax and formatting checks also passed. This test uses a private temporary capture and random-port viewer and does not modify the real stream.

The final browser send after the collector fix is request `7943bb06-1a9e-4efb-8f41-b7cecefdd4e6` at 22:15:43Z. Actual peer receipt and sender seen/read passed again. This chat's own MCP returned MongoDB 14, Redis 2, backend 3, Centrifugo 2 and Flutter 1 records for that request, all in the new collector capture; the Flutter HTTP completion retains its original `t1148` / `s1157` identifiers. Its trace has complete coverage with no malformed/invalid records or missing metadata. A complete `error_summary` scoped to that new capture reported zero failures at the final check; the earlier intentional E2E warnings remain in their historical capture.

Final Logdy UI evidence `e2e-logdy-current.jpg` shows `redis.eval`, `mongodb.find/update/commitTransaction/findAndModify` and `centrifugo.publish` (200) together under **Operation / event**, with all five sources listed in the facet. Only the three service sources were selected for that screenshot's readability. UI filters were then reset and live following resumed; browser/server buffer limits were preserved. Health read-back returned 200 for backend, collector and Logdy, MongoDB/Redis `ok`, and zero rejected/failed/pending ingress batches (`e2e-health-current.json`). Final formatting, eight relative documentation links and `git diff --check` passed. The primary changed implementation files in this verification follow-up are `backend/src/infrastructure/local-service-diagnostics.ts`, `scripts/local-logs.mjs` and `scripts/backend-logs.mjs`, with their corresponding tests and this logging documentation; Flutter, MCP schemas and chat business routes were unchanged.

## Local logger review fixes — 2026-10-17

Implemented the five findings from the 830-record review while preserving unrelated concurrent realtime/authentication edits. Flutter presence now coalesces heartbeat/status work independently, cancels ephemeral requests when hidden/paused/detached, fences retired completions, and renews immediately on resume without removing inbox recovery. The concurrently introduced default heartbeat interval remains 30 seconds; arbitrary larger overrides were not changed by this task.

Native records retain validated source and collection times plus safe MongoDB event IDs. Inspector metrics have specific names and validated searchable name/group/value fields. MCP adds explicit warning/error/failed-operation totals without changing legacy warning-inclusive totals, and a fifth read-only archive listing tool with constrained archive IDs. Runtime JSONL retention targets 50 MiB, seven archives and seven days; unread inputs are preserved using acknowledged pinned Vector checksum/EOF checks, with bounded producer backpressure when the unread budget fills. Shared native service files and process stdout/stderr are outside this capture policy.

Validation actually run:

- Flutter: touched files formatted; flutter analyze passed; full flutter test --reporter expanded passed **247 tests**; flutter build web with localhost API/Centrifugo defines passed.
- Backend: typecheck and build passed; npm test passed **54 tests**, including rotation safety, replaced ancestors, private files and bounded unread-backlog regressions. No mutating backend E2E/integration suite was run for this logger change.
- Logger scripts: node --test selected log/retention/ingress/viewer/debug suites passed **55 tests**, with **one optional installed-bridge test skipped**. Actual installed Vector integration preserved all 22 synthetic events across input rollovers and two Vector-only output rollovers while ingress stayed available.
- MCP: typecheck/build and **54 tests** passed, including actual legacy/modern STDIO clients, archive traversal/link rejection, cursor isolation and compatible summaries. A fresh, closed-after-check SDK connection read all five service sources with the new five-tool server.
- Global up-logger helper: **17 tests** passed; current live status reports all eight service/listener checks ready. Current Centrifugo external/internal ports are loopback-only, API authentication is enforced and the workspace admin is protected. The concurrent migration restarted the backend/Centrifugo; this task did not overwrite its configuration or credentials.
- Current collector health confirms live Vector, retention maintenance/checkpoints available, and successful Flutter delivery with zero rejected/failed batches. Browser inspection and this chat's original MCP connection show fresh named Flutter metrics and native MongoDB event names. The latest isolated verification window had no captured failures.
- git diff --check passed. No commit or push.

The existing chat host still exposes the older four-tool connection. The rebuilt five-tool server is verified through actual STDIO, but activating archive listing/new structured fields in this chat requires the user's supported Codex MCP reconnect. This is an activation boundary, not evidence of a broken collector. See ignored .runtime/observability/log-review-fixes-verification.json and log-review-fixes-logdy.png for bounded local evidence.

API preflight: read the current official Zalando guideline source on 2026-10-17; compatible additions, timezone-qualified timestamps, bounded pagination and sensitive-data exclusion informed diagnostic contracts. Chat REST routes were unchanged by this logger task.

## Sequential outbox and health recovery — 2026-10-18

Implemented the newly authorized client outbox using a durable Drift schema 6,
`Queue(parallel: 1)`, the API-only readiness checker and scoped Dio retries.
Existing sender-scoped idempotency, staged image upload routes, inbox
serialization and browser database ownership are reused. Permanent new-request
rejections fail once and release the next message. Uncertain outcomes retain
their original identity and pause visibly after a bounded healthy-server retry
budget. Late canonical acknowledgements release a paused head automatically.

The public GET/HEAD health route now checks MongoDB primary and Redis with
bounded probes. It preserves the existing GET response shape, exposes no
dependency errors and suppresses successful health completion logs. Structured
error hints and exposed `Retry-After` preserve the existing API fields. The
current [Zalando guidelines](https://opensource.zalando.com/restful-api-guidelines/)
were reviewed on 2026-10-18 for compatible extensions, problem responses,
idempotent retries and rate-limit headers.

Actual automated validation:

| Surface       | Commands and result                                                                                                                                                                                                                                                                                                                                               |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Backend       | `npm test`: **102 passed**. `npx tsx --test test/integration/backend.test.ts`: **57 passed** against local MongoDB, Redis and Centrifugo with isolated fixture databases. `npm run format:check`, `npm run typecheck` and `npm run build` passed.                                                                                                                 |
| Flutter       | `flutter test`: **379 passed**, zero skips, including migrations, FIFO, restart recovery, lost responses, late acknowledgements, upload checkpoints, validation rejection, authentication, rate limits, cancellation, account fencing, malformed acknowledgements and local storage failure. `flutter analyze` reported no issues. Dart formatting checks passed. |
| Web rebuild   | `flutter build web --debug --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`: passed after the final source change in 43.5 seconds. Both existing Web servers were explicitly hot restarted, then pages reloaded.                                                                           |
| Android build | `flutter build apk --debug`: passed after the Web build in 19.4 seconds. Existing transitive media-plugin Kotlin migration warnings remain. No device or simulator UI test was run.                                                                                                                                                                               |
| Log pipeline  | `node --test scripts/local-logs-ingress.test.mjs`: **21 passed**. `node --test scripts/local-logs.test.mjs`: **10 passed**, including installed Vector normalization. Syntax checks, scoped Prettier and `git diff --check` passed.                                                                                                                               |

Live browser verification used independent demo-user sessions at ports 5173 and
5174 with Flutter event Capture and Share enabled, while full traffic capture
stayed off. Only the specifically verified local API process was stopped and
restarted; MongoDB, Redis and Centrifugo were left running. No data was cleared.

1. Sent two synthetic messages while the API was unavailable. Both showed
   **Queued · Sends automatically**. Reloaded the sender page while still
   offline and verified both rows survived.
2. Restored the API without pressing Retry or Sync. Readiness changed to ready
   at `15:44:44.856Z`; the two `/messages` completions were HTTP 200 at
   `15:44:45.065Z` and `15:44:45.577Z`. Both appeared in order in the receiving
   browser and the sender showed seen/read.
3. Sent a 10,001-character message. Exactly one HTTP 400 was captured at
   `15:45:35.767Z`; the local row displayed **Not sent · Retry** and the text
   length error. A subsequent valid message succeeded at `15:45:51.602Z` and
   appeared in the receiving session. The final bounded query still contained
   one 400 and no repeated bad-request attempts.
4. Live inspection found the collector's metadata allowlist omitted new outbox
   fields. Added only safe bounded metadata, with credential/body exclusion
   regressions, then gracefully restarted the collector with existing capture
   and checkpoint paths preserved. Repeated an outage/send/recovery. Fresh
   events retained operation ID `cd70817f-14ca-43a1-bdeb-881d193f26a2` from
   enqueue to waiting-for-server to acknowledgement at `15:48:27.498Z`.
5. A read-only MongoDB check found exactly four canonical synthetic test
   messages with consecutive message sequences **25, 26, 27, 28**, in send
   order, and zero records for the invalid text. These test rows were retained.

This chat's actual logs MCP returned complete scanned coverage for the scoped
outbox, health, HTTP and request-trace queries: no malformed, invalid or
truncated records and no coverage warnings. The recovery request
`857772bd-5609-454b-a653-a649180c4658` correlated fresh Flutter, backend,
MongoDB, Redis and Centrifugo records. Its MongoDB commit and both inbox
publications succeeded; receiving-browser evidence independently established
client receipt. The old capture remains preserved; the restarted collector's
capture ID is `b979c1de-d8f1-4009-b12c-051d71af0ef5`.

The error summary contains deliberate offline transport/sync failures, health
warnings and the deliberate 400, with zero backend HTTP 5xx and zero failed
publication attempts in the verification window. One concurrent seen-receipt
transaction logged a transient MongoDB WriteConflict and abort warning. Its
same-request trace then retried, committed, published and returned HTTP 200.
These are attempt diagnostics, not additional failed messages.

Private evidence is under `.runtime/outbox-verification/`: `offline-queued.png`,
`auto-recovered.png`, `peer-received.png`, `bad-request-no-loop.png`, canonical
message readbacks and `mcp-verification.json`. Full Flutter stdout is
`/tmp/chat-outbox-full-tests-head-watch.log`; final build and analysis outputs
use `/tmp/chat-outbox-*-final-build.log` and `/tmp/chat-outbox-final-analyze.log`.
The Logdy tab became unresponsive during the final visual check; a fresh tab
reported its existing multiple-tab limitation. No final live-viewer screenshot
or viewer completeness is claimed. The persistent capture and current MCP
queries verified delivery independently of that display issue.

The logger startup helper also reports the tracked Centrifugo LAN configuration
does not satisfy its loopback-configuration policy. Actual current external and
internal listeners were loopback-only, and the internal API was authenticated;
no private configuration was changed to silence the policy warning.

This is local Web and automated service coverage. Mobile UI, process suspension,
production load, and every possible proxy/network failure were not tested.
Browser/OS suspension resumes work when active; uninstall/storage clearing and
the existing explicit-logout cleanup policy cannot provide permanent local
retention. No commit, push, publication, deployment or data deletion occurred.

## Live Logdy queue and reconnect fixes — 2026-10-18

Fixed the viewer issues observed at the end of the outbox verification above.
The pinned Logdy v0.17.1 browser client omitted `should_follow` on WebSocket
reconnect, so its UI could display following while the server cursor was paused.
The local proxy now verifies the installed main asset's SHA-256 before adding
the reception state to that handshake. Initial and explicit pause are preserved;
unknown or changed main assets fail closed. Module-cache files are unchanged.

Live browser inspection also found repeated `QuotaExceededError` exceptions from
persisting `logdy_logs_*` rows. These stopped intake and prevented filter/layout
settings from being saved. The verified asset transformation now bounds that
cache to 2 MiB of UTF-16 keys/JSON, evicts only oldest cached log rows, and falls
back to memory after bounded storage failures. Application/layout settings,
capture files and checkpoints are preserved. Existing 10,000-row live-view and
server-ring upper bounds remain; reloaded browser history can be smaller.
Only one Logdy page per origin is supported by upstream shared storage.

Queue and health diagnostics now produce safe readable Result/What happened
summaries, automatic queued/failed/attention counts, attempt/retry deadlines,
operation IDs and cumulative queue-session HTTP attempts. The layout includes
searchable metadata with nested-data fallbacks. Initial readiness is distinct
from actual recovery. Enqueueing behind a known-offline head emits an updated
queue snapshot without dispatching another request. Sensitive bodies and
credentials are not promoted into summaries.

Actual validation after the final source changes:

- `BACKEND_LOG_VIEWER_INTEGRATION=1 node --test scripts/backend-logs.test.mjs scripts/backend-logs-proxy.test.mjs scripts/local-logs-ingress.test.mjs scripts/local-logs.test.mjs`: **72 passed, zero skips**. Includes the installed bridge, following/paused handshakes, asset verification, GET/HEAD rewriting, quota/error fallback, cache identity/update/reload consistency, and metadata redaction.
- `flutter test`: **382 passed**, zero skips. Focused diagnostics/health run: **20 passed**. Dart formatting and `flutter analyze` passed.
- `flutter build web --debug --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`: passed in **37.1 seconds**. Both existing Web processes then hot reloaded successfully, preserving their sessions and enabled Capture/Share.
- Scoped JavaScript/Markdown formatting and `git diff --check` passed. No native device or simulator test was run for this logging follow-up.

Live verification used the existing Chrome Logdy page at port 8082 and the two
independent Flutter Web sessions at ports 5173/5174. The search expression is
`data.category in ("outbox", "health")`; plain `outbox` is not a Breser expression.
During an API outage, the stream showed HTTP attempts, waiting-for-server and
health probes. After restoring only the API, actual recovery appeared at
`16:39:50.200Z`; the two queued sends completed at `16:39:50.385Z` and
`16:39:51.247Z`, and the receiving browser showed both in FIFO order. A later
400 validation rejection appeared once at `16:40:50.039Z`, followed by a valid
send at `16:40:53.522Z`; it did not automatically loop.

After loading the final code, only the verified collector and viewer processes
were gracefully restarted. The existing Logdy page was neither reloaded nor
manually resumed. Fresh automatic queue snapshots from both sessions appeared
at `16:48:09.331Z` and `16:49:07.714Z`, confirming live following survived the
reconnect. Browser console inspection found no new quota warnings/errors after
the cache fix. The saved screenshot shows recovery, acknowledgements, the
validation rejection and these fresh snapshots in the live viewer.

The current chat's MCP correlated the first recovery send across Flutter,
backend, MongoDB, Redis and Centrifugo. Scoped queries had complete scanned
coverage, zero malformed/invalid/truncated records and no coverage warnings.
The error summary contained intentional offline/validation failures, zero
backend HTTP 5xx and zero failed publication attempts. Concurrent message and
seen-receipt transactions logged transient MongoDB command/abort failures;
both exact-request traces subsequently committed and returned HTTP 200.
The separate post-reconnect window from `16:46:30Z` had zero warnings, errors,
failed operations, HTTP 4xx/5xx or failed publication attempts, with complete
scanned MCP coverage and no coverage warnings.

Final direct checks returned HTTP 200 for backend readiness, collector, Logdy,
both Web sessions and authenticated Centrifugo info. The collector reported
Vector alive and zero rejected, failed or pending ingress batches. Its current
capture ID is `92e0c9a1-b930-4b45-8a67-f0129c7f9ad5`; earlier captures remain
in the same persistent stream. The startup helper still flags the previously
documented Centrifugo configuration-policy mismatch, despite the actual
loopback-only authenticated listeners. Its dependency-blocked labels are not
reported here as successful startup checks; no credentials/config were changed.

Main files: `scripts/backend-logs-proxy.mjs`, `scripts/backend-logs.mjs`,
`scripts/local-logs-ingress.mjs`, their tests, Flutter outbox/health/inspector
diagnostics and the logging guides. Private live evidence is under
`.runtime/logdy-queue-verification/`, including `logdy-live-queue.png`,
`final-mcp.json`, `final-health.json` and reconnect/reload timestamps. Full test,
build and analysis output is in `/tmp/chat-logdy-queue-node-final.log`,
`/tmp/chat-outbox-logdy-flutter-tests-final.log`,
`/tmp/chat-logdy-queue-web-build-final.log` and
`/tmp/chat-logdy-final-analyze.log`.

This verifies local automated behavior and live Web recovery, not production
capacity, suspended mobile execution or an unbounded viewer history. No commit,
push, publication, deployment or application-data/capture reset occurred.

## Flutter SQLite query reduction — 2026-10-19

Optimized `app_database.dart`, `inbox_sync_service.dart`,
`outbox_send_queue.dart` and the controller's delivery scheduling. Identical
resources, receipt confirmations and coverage ranges avoid writes; bulk message
reconciliation shares context and merges coverage once; real-room remaps do no
work. REST acknowledgements avoid reconciling the same embedded/top-level message
twice. Outbox drains avoid repeated count/head observer reads and unchanged state
notifications. Pending receipt selection uses one filtered join. Room previews
use one pending-message window query constrained by the existing outbox index,
instead of a separate pending scan or a per-room sent-history scan.

Sync cursor ownership, transactional application, sender-scoped identities,
sequence gaps, durable receipt tasks, draft remapping and session fencing remain
covered. There is no schema or API contract change. Executor query logging stays
enabled and observes actual calls; the reductions do not suppress SQL records.

### Live ten-message comparison

Sent ten `DBOPT baseline` messages through the existing Flutter Web UI, rebuilt
the client, then sent ten `DBOPT optimized` messages in the same account/direct
conversation. The recipient was inactive during both measurement windows. The
existing database was retained, so the second run had more cached messages.
Full debug capture was enabled for both runs. Count completed `query.*` spans
once, rather than counting both their begin/end log entries.

| Sender SQL calls for ten sends | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| SELECT | 763 | 432 | 43.4% |
| UPDATE | 171 | 70 | 59.1% |
| INSERT / UPSERT | 70 | 40 | 42.9% |
| DELETE | 10 | 10 | 0% |
| Total | 1,014 | 552 | 45.6% |

Before: `2026-10-19T00:25:16.784Z`–`00:26:20.510Z`, 3,341 Flutter
records over 34 MCP pages. After: `00:31:50.730Z`–`00:32:21.510Z`,
2,236 records over 23 pages. Every request used `source: flutter`, `limit: 100`
and signed pagination with unchanged filters. Both snapshots were scanned to
byte zero, without malformed/invalid/oversized records, payload omissions,
sequence gaps or duplicate sequences. Each window contains ten successful
`POST /messages` completions and no warnings/errors. This compares query counts,
not release CPU time or human-paced wall-clock durations.

### Browser recovery and correctness

The two independent origins on ports 5173 and 5174 restored their existing
accounts. The recipient rendered all ten optimized messages; live messages
worked in both directions and the sender's seen indicators updated. Blocking
only the sender tab's API requests simulated an outage without stopping shared
services. Two sends remained queued, survived a browser reload and appeared
alongside cached history while the API was still blocked. Removing the block
allowed automatic FIFO delivery: message 01 succeeded at `00:34:37.184Z`, then
02 at `00:34:38.164Z`; the recipient displayed exactly one copy of each, and both
clients recovered to Connected. The browser request block was removed.

Read the follow-up Flutter capture in 28 more limit-100 pages (2,698 records).
Eight payloads omitted by individual page budgets were recovered through exact
follow-up queries. SQLite recorded no failures. HTTP, health and recovery
failures were confined to the intentional API block; no warning/error followed
recovery. A further 47.9-second idle window contained 24 Flutter records,
zero SQL calls and zero warnings/errors.

### Automated checks and evidence

- `dart format --output=none --set-exit-if-changed` on the four changed core
  files and five affected/new test files: passed.
- `flutter analyze`: passed, no issues.
- `flutter test --no-pub --reporter compact`: **424 passed**, including 22 new
  efficiency/correctness regressions. A cancellation probe was updated to
  distinguish the room watch from its joined message subquery; its actual
  cancellation/error assertions remain in place.
- `flutter build web --no-pub --dart-define=API_BASE_URL=http://localhost:3000
  --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`: passed.
- `flutter build apk --debug --no-pub
  --dart-define=API_BASE_URL=http://10.0.2.2:3000
  --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket`: passed;
  existing media plugins still warn about future built-in Kotlin migration.
- Scoped `git diff --check`: passed.

The deterministic 30-message reconciliation test uses 39 SQL calls (5 SELECT,
3 UPDATE, 30 INSERT, 1 DELETE). Other regressions cover no-op acknowledgements,
coverage gaps, independent sender keys, pruned receipt retries, SQLite reopening,
REST/socket ordering and outbox wake/acknowledgement races. The actual room
preview statement is checked with `EXPLAIN QUERY PLAN` against 1,000 sent rows;
it uses `local_messages_outbox`, without a sent-history scan or correlated
history lookup.

Private local aggregate evidence and build/test output are in
`.runtime/query-optimization/`: `baseline-summary.json`, `after-summary.json`,
`results.json`, `flutter-tests-final.log`, `web-build-final.log`,
`apk-build-final.log` and `recipient-recovered.jpg`. No commit, push, deployment,
application-data deletion or capture reset occurred. Device execution and
production/load performance were not tested; the live evidence is Flutter Web
debug behavior with detailed logging enabled.

## Further Flutter SQLite reduction — 2026-10-19

The second pass reduces the same ten-send workload from **552 to 271 SQL calls**
(50.9% fewer), or 73.3% fewer than the original 1,014. Query interception and full
debug logging remain enabled. No database schema or wire contract changed.

### Changes and safety boundaries

- `app_database.dart`: share room and duplicate-message proofs inside a
  transaction; use one joined proof for a hydrated resource; identical REST
  acknowledgements after socket application use one SELECT and no writes.
  Receipt confirmations update only when cursors advance, while durable
  confirmations survive room pruning. Thirty-message reconciliation uses
  37 statements: 4 SELECT, 2 UPDATE, 30 INSERT and 1 DELETE.
- `inbox_sync_service.dart`: remove redundant compact-event preflight reads;
  a typed missing-room result rolls the entire batch back before hydrated
  recovery. Reuse the captured account and avoid unchanged cursor updates.
  REST responses still never advance the inbox cursor.
- `outbox_send_queue.dart`: combine indexed head/count reads, reuse watched
  snapshots after durable enqueue and successful sends, and retain the empty
  observer. Explicit Retry/control wakes force a fresh read even if a drain
  is already active; the deterministic stale-observer regression failed before
  this fix and passes afterward.
- `chat_controller.dart`: certified live publications use the Drift watch
  instead of reloading/counting a synchronized message window. A lookahead row
  preserves local pagination. Incoming/unread messages still schedule Seen;
  outgoing echoes with no unread state skip redundant Seen and recovery work.
  Initial healthy outbox readiness no longer causes another startup sync;
  actual outages and unfinished recovery still do.

Tests cover equal-revision repairs, monotonic receipts and quotes, missing-room
rollback, live pagination beyond 50 rows, self versus peer publications, Retry
races, and healthy first-send recovery. Existing sync/offline regressions pass.

### Fresh ten-message UI measurement

Sent `DBOPT verify 01` through `DBOPT verify 10` using the Flutter Web UI on
port 5173, retaining the same account, conversation and local database. As in
the previous 552-query run, the recipient was inactive during the measurement;
its session was opened afterward for receipt and recovery checks. The cached
conversation was warmed before the boundary. Both runs use debug builds and
actual completed `query.*` spans, counted once.

| Sender SQL calls for ten sends | Previous | Current | Reduction |
| --- | ---: | ---: | ---: |
| SELECT | 432 | 180 | 58.3% |
| UPDATE | 70 | 51 | 27.1% |
| INSERT / UPSERT | 40 | 30 | 25.0% |
| DELETE | 10 | 10 | 0% |
| Total | 552 | 271 | 50.9% |

Current window: `2026-10-19T01:08:13.652Z`–`01:08:45.306Z`.
Read 1,394 Flutter records over 16 signed MCP pages, each requested with
`source: flutter`, `limit: 100` and unchanged filters. Coverage reached byte
zero with no malformed/invalid/oversized records, payload omissions, duplicate
sequences or sequence gaps. All ten `POST /messages` calls completed with 200;
there were no Seen requests, delta requests, warnings or errors in this window.
Page result budgets may return fewer than 100 records.

The remaining 180 SELECTs break down as follows:

| Reads across ten sends | Count | Purpose |
| --- | ---: | --- |
| Sender/key lookups | 40 | Validate durable identity and current send state |
| Message watches | 30 | Render queued, sending and confirmed states |
| Room/pending-preview watches | 30 | Update conversation previews across those states |
| Combined outbox snapshots | 20 | Observe FIFO head and queue health |
| Joined room/message proofs | 20 | Reconcile REST/socket ordering without duplicate writes |
| Sync metadata | 20 | Read durable cursor and outbound ordering state |
| Fresh room rows | 10 | Emit applied room state |
| Batched duplicate-key checks | 10 | Guard enqueue reconciliation |

The other 91 calls persist messages, sending claims, room state, contiguous
coverage, message baselines, inbox/outbound cursors and temporary-row remaps,
plus one conditional receipt confirmation. This is a query-count comparison;
human-paced send durations do not establish a CPU or latency speedup.

### Live recovery after the measurement

The independent recipient session on port 5174 rendered all ten messages and
updated the sender's Seen indicators. A recipient reply arrived live. Blocking
only the sender tab's API requests then queued two outgoing messages. Both
survived a browser reload alongside cached history. While disconnected, the
recipient sent another message; it was absent from the offline sender and
recovered automatically after reconnection. The queued sends delivered once
each in FIFO order at `01:09:53.742Z` and `01:09:54.237Z`. Both clients returned
to Connected, and the temporary browser network block was removed.

The recovery window (`01:08:45.965Z`–`01:10:20.245Z`) contains 2,317 Flutter
records. The capture rotated automatically during the test, so coverage combines
25 limit-100 pages from `events.20261019T011006212Z-04afd85e.jsonl` with one live
page. Eleven payloads omitted by page budgets were recovered with exact
follow-up queries; no omissions remained. Archive scanning reached byte zero,
with no malformed/invalid/oversized records. SQLite had zero failures. Expected
HTTP/health/sync failures occurred during the forced outage; the last was at
`01:09:51.538Z`, before successful recovery.

A further 137.7-second idle window contained 56 Flutter records, **zero SQL
calls and zero warnings/errors**, with complete live-capture coverage.

### Final checks and evidence

- `dart format --output=none --set-exit-if-changed` on the four core files and
  five affected test files: passed.
- `flutter analyze`: passed, no issues.
- `flutter test --no-pub --reporter compact`: **444 passed**.
- `flutter build web --no-pub --dart-define=API_BASE_URL=http://localhost:3000
  --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`: passed.
- `flutter build apk --debug --no-pub
  --dart-define=API_BASE_URL=http://10.0.2.2:3000
  --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket`: passed;
  existing media-plugin Kotlin migration warnings remain.
- Scoped `git diff --check`: passed.

Private aggregate evidence is in `.runtime/query-optimization-2/results.json`,
`final-ten-send-summary.json`, `e2e-complete-summary.json`, `idle-summary.json`
and `recipient-final.jpg`. Final test and build logs have the suffix
`delivery-final.log` in that folder. The earlier `e2e-summary.json` is explicitly
marked incomplete because it read only the post-rotation live file.

No commit, push, deployment, data deletion or capture reset occurred. This
verifies local Flutter Web debug behavior and automated regressions; native
device execution, production load and release performance were not measured.
