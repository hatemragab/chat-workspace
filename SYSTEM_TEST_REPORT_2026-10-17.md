# Chat system test and improvement report

Date: 17 October 2026, Africa/Cairo. Tested the current working tree without committing or changing application implementation.

The local chat system is running, the requested Flutter Web rebuild succeeded, and both independent browser sessions remain open. Fresh Flutter, NestJS, MongoDB, Redis and Centrifugo records reached the shared capture and were visible together in Logdy. Core chat flows and the existing automated suites passed. Targeted probes nevertheless reproduced correctness and diagnostic problems that need follow-up.

The most important correction is authentication error handling: a temporary database/revocation-store failure becomes HTTP 401, which Flutter can interpret as a reason to clear its saved session and offline database. The other immediate priorities are logout availability, ObjectId normalization, inbox pagination, and reliable diagnostic export during bursts.

## 1. Runtime work completed

- Gracefully stopped the positively identified workspace NestJS and two Flutter Web processes, then relaunched them through the existing up-logger workflow.
- Reused the healthy MongoDB replica set, Redis, Centrifugo, Vector collector and Logdy processes. Preserved their configuration, credentials, data, captures and checkpoints.
- Built the Flutter Web release output separately. Browser tests used the rebuilt debug web servers so inspector capture/export could run.
- Opened independent Chrome sessions at [localhost:5173](http://localhost:5173/) and [localhost:5174](http://localhost:5174/), using User 1 and User 2. The different ports isolate their browser storage.
- Enabled Capture and Share with local logs in both sessions. Re-enabled them in session A after its deliberate navigation/reload because these options reset on a new application instance.
- Reused [Logdy](http://127.0.0.1:8082/), refreshed it, enabled live following and requested its retained backlog.
- Restored session B's temporary offline emulation and disabled temporary browser protocol observation before finishing.
- Left both chat pages and Logdy open.

| Component | Address | Verified result |
| --- | --- | --- |
| NestJS | localhost:3000 | /health reports MongoDB ok and Redis ok after restart |
| MongoDB replica set | localhost:27017 | Backend access and real transaction tests pass |
| Redis | localhost:6379 | Readiness and real atomic/recovery tests pass |
| Centrifugo | loopback 8000 / protected 9000 | Authenticated info succeeds; API authentication enforced; native log configured; browser sockets/publications work |
| Vector collector / Flutter ingress | 127.0.0.1:8083 | health ok, Vector child alive |
| Logdy | 127.0.0.1:8082 | Assets/status work; live five-source view verified |
| Flutter A / B | localhost:5173 / 5174 | Both connected; direct messaging and recovery exercised |

Private runtime read-back: [.runtime/chat-system-audit/stack-after.json](.runtime/chat-system-audit/stack-after.json).

## 2. Automated validation actually run

| Area | Commands | Result |
| --- | --- | --- |
| Backend formatting | cd backend && npm run format:check | Passed |
| Backend types / build | npm run typecheck; npm run build | Passed |
| Backend unit | npm test | 55 passed |
| Real MongoDB / Redis / Centrifugo integration | npm run test:integration | 45 passed: 34 backend and 11 realtime cases |
| Running API and two WebSocket clients | node --check scripts/e2e.mjs; node --test scripts/e2e.mjs | 17 passed |
| Flutter formatting | dart format --output=none --set-exit-if-changed lib test | 50 files, zero changes |
| Flutter analysis | flutter analyze --no-pub | No issues |
| Flutter unit/widget suite | flutter test --no-pub | 246 passed |
| Flutter Web release build | flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket | Passed; build/web generated |
| Logs MCP types/tests | npm --prefix tools/backend-logs-mcp run typecheck; npm --prefix tools/backend-logs-mcp test | Types passed; 54 tests passed |
| Logger/collector/retention/Redis/Centrifugo tooling | node --test over the ten tooling test files listed below | 78 passed, one installed-bridge test initially skipped |
| Actual installed Logdy bridge | BACKEND_LOG_VIEWER_INTEGRATION=1 node --test scripts/backend-logs.test.mjs | 16 passed; closes the earlier skip, repeating 15 already counted cases |
| Additional Flutter diagnostic probes | flutter test --no-pub over three private audit harnesses | Five passed, reproducing pagination, theme and cancellation behavior |
| Additional backend probes | node .runtime/chat-system-audit/backend-edge-probes.mjs | Four probes completed and reproduced the defects below |
| Diff whitespace | git diff --check | Passed |

There are **496 distinct passing cases in the existing suites**, including **133 distinct MCP/tooling cases**, plus five additional Flutter reproduction assertions. A reproduction assertion can pass while demonstrating defective application behavior; these counts do not close the findings.

Tooling command:

```sh
node --test scripts/backend-debug.test.mjs scripts/backend-logs.test.mjs \
  scripts/centrifugo-local.test.mjs scripts/input-log-retention.test.mjs \
  scripts/local-logs-ingress.test.mjs scripts/local-logs.test.mjs \
  scripts/log-retention.test.mjs scripts/log-retention-integration.test.mjs \
  scripts/redis-debug.test.mjs scripts/vector-tool.test.mjs
```

Additional Flutter harnesses are in .runtime/chat-system-audit/:

- flutter-edge-probes_test.dart: two pagination cases.
- flutter-rebuild-probe_test.dart: theme equality and bounded rebuild behavior.
- flutter-cancellation-probe_test.dart: actual remote Drift watch cancellation, with no injected exception.

One integration run printed “Traffic log file capture dropped records or could not write. Console logging continues.” All assertions passed. Its exact sink/retention/shutdown cause remains unresolved. It is an integration diagnostic limitation; it is neither proof of main-server capture failure nor something this report dismisses as an intentional assertion.

## 3. Browser/UI evidence

| Scenario | Observed behavior |
| --- | --- |
| Saved session / independent login | Session A restored User 1; session B signed into User 2 |
| Unicode and multiline text | Arabic, emoji and line breaks composed and delivered |
| Inbox notification | Peer received the message and unread badge 1 while the conversation was closed |
| Delivered versus seen | Sender first showed delivered; opening the peer conversation cleared unread and produced read ticks |
| Bidirectional reply | User 2 sent a quote of User 1's message; User 1 received it |
| Live edit | Editing the original updated the peer's original bubble and visible reply preview |
| Pin/mute | Both preferences changed and were restored to their original unpinned/unmuted state |
| Offline send | A scoped browser offline test retained the cached conversation and displayed a failed message with Retry |
| Retry | Restored connectivity and retried; exactly one successful message appeared in each conversation |
| Group creation | Created synthetic AUDIT-20261017 recovery with the two demo users |
| Missed-message recovery | Navigated A away; retained 67 new synthetic group messages: anchor, 65 later messages, reply |
| Reconnect/reload | Restored A; recovered the group's 67-message unread state and latest 30-message page |
| Uncached reply jump | Tapped the latest quote; /messages/around returned the missing anchor and nearby context |
| Return to latest | Returned from historical context to the latest message page |
| Verified-cache reopen | Message request counter stayed 1 before and after reopening the unchanged group: zero additional history requests |
| Final causal check | AUDIT-104 arrived in the other browser; sender showed seen |

The browser history case exercises a target outside the cached latest page across 65 intervening messages. It is not a new 500+ message browser stress run. Existing unit/widget tests cover additional long-history and jump recovery rules.

Other existing live/integration coverage includes duplicate/concurrent first sends; sender-scoped identical UUIDs; member/sender authorization; foreign replies; empty/invalid/null fields; compound pagination and ties; bounded and coalesced receipts; hidden-original quote redaction; per-user/global deletion of synthetic test messages; multiple groups; image upload/retrieval, MIME spoofing and size limits; cache lag/full recovery; authenticated channels; multiple logins; logout revocation; provider outage as 503; socket-close/crash presence; refresh; connection limits; and retry exhaustion preserving committed writes.

![Bidirectional reply and live edit](.runtime/chat-system-audit/chat-reply-edit.jpg)

![Offline failed send with Retry](.runtime/chat-system-audit/offline-retry.jpg)

![Remote historical context](.runtime/chat-system-audit/history-remote-jump.jpg)

## 4. Logdy and MCP coverage

All five MCP tools were available in this chat: search_logs, trace_request, trace_events, error_summary and list_log_archives. This used the host's actual provided MCP connection.

I read the entire available active capture through **search_logs with limit: 50**, following cursors to byte zero, then read a supplementary snapshot back to the already reviewed boundary. Both archive listings returned no retained archives.

The bulk pass reviewed metadata for every retained record. Focused follow-up queries read bounded redacted payloads for all 150 warning/error records and selected request/recipient timelines. This is complete retained-record metadata coverage, not a claim that every private HTTP body was opened.

- Primary pass: **31,774 records, 636 pages**, fixed 19,244,966-byte snapshot.
- Supplement: 13 pages returned 650 records, of which 624 were new and 26 overlapped the primary pass.
- Combined: **32,398 unique records across 649 fifty-record query pages**, covering the active file through **19,659,086 bytes**.
- Record-timestamp range: 16 October 22:51:42.999 UTC through 17 October 01:06:49.293 UTC. Native records can use collection-time fallback; this range does not imply every record has an independent service timestamp.
- Last collection timestamp in that reviewed snapshot: 17 October 01:06:54.875 UTC, or 04:06:54.875 Cairo.
- No malformed, invalid or oversized lines, incomplete trailing line, or truncated metadata was reported in these scan pages.
- Intermediate partial/older-record warnings represented normal pagination; the primary pass reached byte zero and the supplement overlapped its reviewed boundary.
- Logging continues after that fixed review snapshot. These are all available retained records at the stated boundary, not a claim that future records or never-exported events were read.

| Source | Entire reviewed capture | Records timestamped during this audit |
| --- | ---: | ---: |
| Flutter inspector | 8,005 | 7,150 |
| NestJS | 1,425 | 616 |
| MongoDB | 10,543 | 3,318 |
| Redis | 8,783 | 711 |
| Centrifugo | 3,642 | 954 |
| Total | **32,398** | **12,749** |

The audit window begins at 00:57:14 UTC on 17 October. Native and client observations are separate: the whole capture contained 4,813 native MongoDB records plus 5,730 MongoDB client operations, 50 native Redis records plus 8,733 Redis client operations, and 3,113 native Centrifugo records plus 529 backend-to-provider operations. Native Redis can remain quiet between its own diagnostics; quiet intervals are not capture failure.

The collector baseline reported 237 accepted Flutter events. A later read-back reported 7,051, with zero rejected/failed/pending ingress batches and a live Vector child. Those ingress counters are separate from Flutter exporter failures and from persisted output consumption.

![Logdy with Flutter, backend, MongoDB, Redis and Centrifugo source facets](.runtime/chat-system-audit/logdy-five-sources.jpg)

### Causal proof for one successful send

Request **2e387728-f388-4164-b259-cdbd837298ff** has 23 correlated records:

- Flutter: one HTTP completion.
- NestJS: HTTP completion and two publication records.
- MongoDB: 14 operation records.
- Redis: three operation records.
- Centrifugo: two provider operations.

POST /messages completed HTTP 200 in 33.29 ms on the backend. Both per-user publications were accepted on attempt 1. A separate recipient Flutter trace, scoped by exact instance, capture, generation and trace t1726, observed message_new at pts 92, applied it, and advanced its local cursor 91 → 92. The peer browser visibly rendered AUDIT-104. The later unread-cleared trace advanced 92 → 93.

The request-trace tool correctly reports clientReceiptObserved=false because it cannot infer client delivery from provider acceptance. The separately scoped peer trace and UI provide the additional evidence; this report does not turn temporal proximity alone into receipt proof.

Private evidence: final-correlation.json and peer-message-correlation.json in the audit directory.

### Warning/error analysis

Across the full reviewed capture: **144 warning records and six error records**. During this audit: **33 warnings and four errors**.

For the tested run, the MCP summary counted:

- 14 HTTP 4xx responses, all matching the live E2E negative authentication/authorization/validation checks.
- Zero HTTP 5xx, aborted HTTP requests, or failed realtime publication attempts in the shared running-server capture.
- Five failed MongoDB inserts and nine failed abortTransaction operations during concurrent lazy/idempotent sends. Their four causative requests all finished HTTP 200; the concurrency E2E assertions passed. Failed attempts are not four lost messages.
- Five native MongoDB “Failed to check socket connectivity” warnings. The sanitized capture excludes native attributes, so the exact peer/cause is unresolved. Database health and transaction tests passed afterward; do not infer corruption or a persistent outage from these lines.
- Four Flutter query.select errors, all CancellationException in two local_rooms/local_messages pairs. The additional remote-executor probe reproduced ordinary watcher invalidation causing this diagnostic classification while fresh watch results and stored data remained correct. See finding 8.

The summary's warningRecords/errorRecords/failedOperations overlap. Its 32 deduplicated error-or-failure observations are not 32 independent broken user operations.

Historical records before this run also contained a Centrifugo ListenAndServe error, a refresh-proxy error, earlier unknown-environment/debug/insecure-admin warnings, and four failed publish attempts for two logical publications. Both publications succeeded on attempt 3. Those historical lines are retained evidence, not current readiness claims. Current authenticated/loopback/protected-provider checks passed. The sanitized historical error text does not establish its complete original cause.

## 5. Confirmed problems, ranked

### 1. P1 — Temporary infrastructure failure can be mistaken for an invalid session

**Reproduced in an isolated Nest instance:** a valid bearer plus a deliberately failing Redis retirement check returned HTTP 401 “Invalid or expired access token.”

backend/src/auth/auth.guard.ts:42-65 wraps token verification, MongoDB lookup and Redis revocation lookup in one catch and converts every failure into UnauthorizedException. Flutter startup/recovery treats 401 as session invalidation at chat_controller.dart:673-678; its clear path removes Drift/session data at 826-829.

**Impact:** a temporary dependency outage can cause loss of cached history and unsent local work during recovery. The backend 401 is reproduced; destructive browser cache loss was traced from source and was not induced in the user's sessions.

**Correction:** distinguish invalid/expired/retired credentials from dependency unavailability. Keep authorization fail-closed, return a retryable service error for unavailable dependencies, and preserve offline work. Add backend outage and Flutter draft-retention regressions.

### 2. P2 — Heartbeat rate limiting can prevent logout revocation

**Reproduced:** in an isolated low-limit configuration, two compatibility heartbeats exhausted the shared bucket; /presence/offline returned 429, and the old bearer still called /users with 200.

presence.controller.ts:60-61 consumes the heartbeat bucket before session retirement. Flutter completes local logout after an offline-request failure.

**Correction:** allow idempotent session retirement independently of heartbeat exhaustion; separately bound expensive provider-disconnect work. Verify only the intended login is retired while another stays valid.

### 3. P2 — Valid mixed-case ObjectIds produce inconsistent identity behavior

**Reproduced:** lowercase own peerUserId returns the intended 400; the same uppercase ObjectId causes a 500 after duplicate membership retries. With the isolated Centrifugo provider method stubbed to deterministic results, lowercase self presence returns one status; uppercase self presence silently returns no status. The presence probe isolates normalization/authorization; it is not a provider-availability test.

Sources: chat.service.ts:456-457; dto.ts:39-40,79-86; presence.service.ts:14-30. URL ObjectIdPipe normalization already establishes a useful existing pattern.

**Correction:** canonicalize validated JSON/query IDs before equality, authorization, deduplication and key construction. Test self, peer, participants and presence in mixed case.

### 4. P2 — An old room arriving through delta can skip unloaded inbox pages

**Reproduced with real in-memory Drift:** load rooms 1–25, introduce old room 100 through a delta, then Load More chooses room 100 as its boundary and can skip 26–99.

Source: inbox_sync_service.dart:324-338 derives the cursor from current local rows. A receipt/preference delta can add a very old uncached room without changing its sort time.

**Correction:** retain the server's authoritative pagination boundary per account/epoch; move it only when loading/replacing pages. This requires a narrow specification refinement because the approved Flutter document currently mandates the local-oldest rule.

### 5. P2 — Pinning all loaded rooms makes Load More do nothing

**Reproduced:** when all loaded server rooms become pinned, no local unpinned row remains. loadMoreRooms returns without a request even while hasMoreRooms is true.

Source: inbox_sync_service.dart:325-330.

**Correction:** reuse the retained page boundary from finding 4, including after preference changes. Add a pinned-all pagination regression.

### 6. P2 — Flutter diagnostics are lost under burst load

**Observed in session B:** sentEvents=3,752, droppedEvents=2,248, failedBatches=2, queuedEvents=119 at the saved snapshot. The scope included a deliberate offline interval and the 67-message group burst. The counters do not establish how many drops came from each cause, and the earlier A instance was reloaded before exporting its final counters; 2,248 is not a system-wide loss total.

The exporter sends at most 50 events, waits 500 ms, and permits one request in flight. Its sustained drain ceiling is below 100 events/sec, with a 500-event/1 MiB pending queue. It intentionally does not retry ambiguous failed batches.

**Correction:** drain bounded follow-up batches promptly while backlog exists, sample high-volume categories, and expose loss/uncertain/failure counters alongside the capture. Preserve bounded memory and diagnostic best-effort behavior. The current system cannot honestly promise that every Flutter event reaches Logdy.

### 7. P2 performance — A moderate burst creates a long serialized client backlog

During the 67-message group fixture, the retained session-B inbox.publication span reached **25,155.5 ms**. The run's retained publication spans had p95 approximately 8.71 seconds. Individual apply-publication work had p95 approximately 484 ms. Backend POST /messages p95 was 36.89 ms.

This is observed debug/browser behavior with inspector sharing enabled and potential background-tab scheduling. Outer spans include queue waiting; they are not 25 seconds of SQL CPU, nor a release-performance benchmark. Export loss means these samples are incomplete.

**Correction:** profile with inspector off/on and in a representative release browser; measure queue wait separately from execution; reduce redundant database/watch/receipt work. Preserve the single serialized cursor lane and atomic cursor/data rules.

### 8. P2 diagnostics — Ordinary Drift cancellations inflate error counts

The interceptor at app_database.dart:690-696 classifies every query exception as error. Drift intentionally cancels and restarts in-flight watched reads when their tables change or their last listener closes.

**Reproduced using the actual remote executor:** two cancellation error records, zero subscriber errors, fresh watch emissions, and the newly written message retained. The four live cancellation records are consistent with this mechanism; their exact cancelling updates are not independently identified.

**Correction:** give recognized cancellation a distinct outcome without incrementing failure aggregates. Preserve real database/watch errors and avoid suppressing arbitrary error strings.

### 9. P2 performance — Unchanged themes trigger redundant animation and builds

**Reproduced:** a single controller notification creates unequal same-brightness ThemeData because VInputTheme has identity equality. MaterialApp starts its 200 ms theme transition. ChatShell and MessagesPane each rebuilt five times before settling through 1,000 ms.

Sources: chat_app.dart:28,37-38; theme.dart:40-101. Repeated records with the same trace are bounded theme animation plus reused state context, not demonstrated infinite recursion.

**Correction:** cache stable light/dark themes and narrow controller subscriptions. Measure actual frame/CPU impact before claiming release jank.

## 6. Further improvements and policies to validate

These are source-backed limits or design opportunities, not additional demonstrated user failures. They are ranked for follow-up without changing the approved architecture during this audit.

| Priority | Improvement | Evidence / next step |
| --- | --- | --- |
| P2 | Align producer/consumer log record limits | Backend sink can accept records approaching 4 MiB; Vector/MCP line limits are 1 MiB. Bound one shared envelope or emit an explicit omission record. traffic-log-output.ts:178-220; local-logs.mjs:31-48; log-store.ts:441-443 |
| P2 | Surface backend sink health | Written/dropped/failed sink stats have no normal health consumer. Permanent sink failure can coexist with healthy API/collector. debug-traffic-logger.ts:132-134; local-service-diagnostics.ts:95-97; traffic-log-output.ts:325-333 |
| P2 | Measure end-to-end capture freshness | vectorAlive and ingress 202 prove different stages. Add per-source last-ingest/output time, lag/backlog and drop counters; distinguish idle sources from stalled delivery |
| P2 | Rotate native/process output under owner policy | JSONL retention excludes process stdout/stderr and native files; define bounded service-owned retention without deleting unread evidence |
| P2 | Make MCP fifty-record scans more efficient | Each page can eagerly reread up to 32 MiB before scanning backward for 50 matches. Use bounded backward chunks while preserving signed cursors, privacy and exact coverage |
| P2 | Bound long-history client work | app_database.dart:270-279 reads all cached messages on several paths; messages_pane.dart:539-575 materializes an expanding Column. Measure large histories and use bounded SQL/lazy rendering |
| P2 | Reduce receipt/quote SQL work | Receipts issue per-row updates and quote edits decode room reply JSON. app_database.dart:459-510,584-613. Use measured bulk/indexable operations while preserving transactions |
| P2 | Define same-origin tab ownership | One shared chat_app_db and per-controller mutex do not establish safe two-account use in two tabs at one origin. Test/define coordination or a clear single-tab policy; different-port testing does not cover this |
| P2 | Define hidden-chat Seen semantics | Open-room receipts lack a foreground visibility gate. Decide whether a hidden tab can mark messages seen, then add real visibility tests |
| P2 | Verify running-session expiry/revocation UX | Startup 401 and later mutation errors take different paths; define reauthentication while protecting pending local work |
| P2 | Upload memory/concurrency and image budgets | 5 MiB in-memory files have no upload-specific concurrency quota; signature checks do not prove full decoding/dimension safety. Measure bounded concurrent uploads and decide limits |
| P2 | Media privacy/lifecycle | Uploaded URLs are public static files; global message deletion clears database URLs but does not revoke the original file. Define access, orphan and retention policy before production |
| P2 | Measure large-group/provider slowdown | Per-member transactional updates and concurrent post-commit fanout need realistic member/count/pool/retry measurements. Keep committed sends successful and REST recovery authoritative |
| P2 | Measure receipt-history query plans | Inspect explain plans for acknowledged boundaries/gaps at realistic history size before adding indexes |
| P2 | Bound directory/pinned-list growth | /users and all pinned rooms are intentionally unbounded by current contracts; set dataset and response budgets before proposing API pagination |
| P2 | Test concurrent historical-context changes | Around-target reads lack a single MongoDB snapshot. Test concurrent edit/delete and existing client revision fences before changing the implementation |
| P3 | Separate presence degradation from transport status | A presence snapshot failure can set global connectionStatus Offline while messaging still works. chat_controller.dart:1015-1020 |
| P3 | Persist failed upload work if desired | Upload happens before an optimistic image row exists; upload failure has a banner but no durable Retry row. chat_controller.dart:1578-1592 |
| P3 | Suppress unchanged presence rebuilds | Poll completion notifies even when the online set is unchanged; narrow selected state and preserve existing lifecycle behavior |
| P3 | Hide unsupported production demo controls | Auth UI renders demo buttons even when backend debug routes are unavailable; backend authorization remains enforced. auth_screen.dart:234-265 |
| P3 | Clarify full backend payload-capture policy | Its explicit flag has no environment gate; local debug bodies intentionally contain private chat data after credential redaction. Define production operational policy/startup visibility |
| P3 | Repair current documentation drift | README.md:11 describes removed heartbeat leases; BACKEND_LOGGING.md:78 contradicts controlled archive expiry; LOCAL_OBSERVABILITY.md says four tools where five exist; old roadmap phase text assigns presence to Redis |

## 7. Suggested correction order and acceptance

1. Fix dependency/auth classification and logout retirement availability. Verify retryable outages preserve saved sessions/drafts and actual revoked credentials remain rejected.
2. Normalize IDs consistently and add the four mixed-case self/peer/member/presence cases.
3. Refine the page-cursor contract and fix both inbox pagination cases with persisted authoritative boundaries.
4. Improve capture drain/loss visibility, cancellation outcome classification, record-size consistency and sink/freshness health.
5. Stabilize themes and profile serialized recovery, receipt updates and long-history rendering under representative load.
6. Resolve the explicit product/production policies in section 6, then align the overview/runbooks.

Keep REST mutations, MongoDB durability, latest-room Redis state, Centrifugo inbox routing, the single Drift database and serialized inbox cursor. These findings do not require adding an outbox or replacing the approved stack.

## 8. Limits, preserved state and artifacts

- No application implementation was changed or fixed during this test/report task.
- Existing extensive dirty work was preserved. No commit, push, publication, deployment, original-data deletion, Redis flush, database drop, secret overwrite or credential change occurred.
- Live E2E deletion checks targeted only messages that the test itself created. Synthetic accounts, random integration databases/namespaces, test groups/messages and uploaded fixtures remain retained.
- No simulator/device UI test or Android/native build was run. No substitute device was used.
- The successful release Web build was not separately browser-tested as a production deployment; the two instrumented browser sessions are debug builds.
- No production capacity, prolonged token-expiry, same-origin tab concurrency, browser-quota/eviction, full OS crash, 500+ fresh-message browser stress, heap leak or representative release-frame claim is made.
- Four isolated backend defect probes intentionally disabled full/service logging and used their own application instance. Their evidence is in the private probe output, not falsely attributed to the shared main-server MCP log window.
- The dropped Flutter diagnostics and unresolved integration sink warning prevent a claim of lossless capture. Reading every retained byte cannot recover events that were never exported.

Main deliverable: this report. Supporting files are private/ignored under [.runtime/chat-system-audit/](.runtime/chat-system-audit/):

- backend-audit.md, flutter-audit.md, observability-audit.md: detailed source reviews and command evidence.
- backend-edge-probes.mjs / .log and three Flutter harnesses: reproducible findings.
- e2e.tap: actual live E2E output.
- mcp-scan-ledger.json and mcp-supplement-ledger.json: every page's byte/record coverage.
- log-analysis-summary.json and log-exceptions.json: counts, timing samples and bounded redacted diagnostic details.
- final-correlation.json and peer-message-correlation.json: server and separately scoped recipient timelines.
- inspector-A.json and inspector-B-after-burst.json: actual exporter status snapshots.
- cache-before.json / cache-after.json: zero-additional-message-request evidence.
- collector-before.json / collector-after.json and stack-after.json: runtime read-back.
- history-gap.mjs / history-gap-evidence.json and screenshots: retained fixture and browser evidence.

Application source files changed by this audit: **none**.
