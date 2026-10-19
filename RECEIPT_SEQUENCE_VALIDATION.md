# Sequence receipts implementation and validation

Date: 2026-10-17 (Africa/Cairo).

Status: implementation and validation complete.

## Scope

Add transactional, immutable per-room message sequences and durable cumulative receipt state. Keep REST mutations, the existing personal inbox, account revision ordering, hydrated Redis recovery and SQLite session fences. Preserve legacy message receipt dates and existing data; do not renumber history or reset databases.

New sequence receipts use explicit captured boundaries. A highest observed message alone is not proof of complete received coverage. Foreground room-read acknowledgement stays separate from background delivery and from the caller's outgoing ticks. Receipt patches must not certify missing content.

## API preflight

Read the current [official Zalando RESTful API and Event Guidelines](https://opensource.zalando.com/restful-api-guidelines/) on 2026-10-17 before API changes. Applicable rules: 101 (OpenAPI), 104 (authentication/authorization), 171 (integer formats), 155 (bandwidth), 106/107 (compatible extensions), 214 (duplicate-safe consumption), and 242 (event ordering). Existing camelCase fields, routes, personal channels and synchronization counters remain the compatibility contract; Zalando-specific event infrastructure and registries do not apply.

## Compact unread follow-up

The authorized follow-up adds `{epoch, pts, unread: {eventType, roomId, unreadCount, ownDeliveredSeq, ownSeenSeq}}` under the existing `compact` rollout mode. Legacy mode still publishes hydrated rooms. Both zero and nonzero counts are authoritative. No database migration, additional progress-only publication or content revision change was added.

Flutter applies the unread patch and inbox cursor atomically, keeps own sequence progress monotonic and confirms only covered sequence acknowledgement tasks. It preserves message rows, preview, peer ticks, ordering, `msgPts`, `contentPts`, history revisions and cache certification. Missing rooms, gaps, epoch changes and disconnected clients use normal hydrated recovery. A separate peer Seen event still updates the sender's outgoing ticks.

Fresh validation on 2026-10-17:

- Backend `npm run format:check`, `npm run typecheck`, `npm run build`, `npm test` (**80 passed**) and `npm run test:integration` (**67 passed**). Tests include real Centrifugo direct/group unread counts, partial reads, duplicate suppression, preserved content revisions and hydrated delta recovery.
- Flutter `dart format --output=none --set-exit-if-changed lib test` passed (67 files, zero changes), `flutter analyze` found no issues and `flutter test` passed **323 tests** after the final logging fix. The database/service and actual protobuf WebSocket regressions cover zero/nonzero patches, stale REST-ahead state, atomic rollback, persisted SQLite reopen, pending task confirmation, failed-send preservation, missing rooms, gaps, epochs and missed unread/peer Seen recovery.
- Both final artifact builds passed: `flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket` and `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket`. Existing transitive plugin Kotlin Gradle compatibility warnings remain. No native-device or simulator test was performed.
- `node --test scripts/e2e.mjs`: **19 passed**. The compatible timestamp path still works with the new unread envelope.
- `node --test scripts/receipt-sequence-e2e.mjs`: **1 passed**. Two reader sockets received the same compact partial unread event; duplicate/older boundaries emitted no new unread event. Offline reader and sender recovered counts/cursors from hydrated deltas after preference coalescing.
- The live synthetic unread publication was **188 bytes** of minified application JSON. The existing browser accounts produced **191 bytes**, compared with **1,156 bytes** in the supplied hydrated unread example: about **83.5% smaller**. Transport framing, compression and the separate debug log wrapper are excluded.
- The backend and both Web servers were restarted through their verified existing private log launchers, retaining MongoDB, Redis, Centrifugo, saved accounts and SQLite history. The API still runs process-only `RECEIPT_PUSH_MODE=compact`; private environment files were not changed.
- Two existing Web origins observed REST-generated synthetic messages `UNREAD-LIVE-001` and `UNREAD-LIVE-002`. Both became Delivered with the recipient conversation closed, with unread **2**. The recipient then navigated away, preserving its SQLite database. A second authenticated session read only sequence **5**, followed by a preference update with its existing value. The returning client recovered unread **1** from the coalesced hydrated delta; the first outgoing message was Seen and the second remained Delivered. This verifies disconnected-browser persistence/recovery, rather than a native-device network outage.
- While the recipient was connected with its conversation closed, another session read sequence **6**. The actual compact unread publication cleared its badge to **0** and the separate peer receipt changed the second sender tick to Seen. Browser HTTP traces showed no receipt command or message fetch caused by this unread event. Opening the conversation later performed the ordinary message-window verification for the previously incomplete background cache. Local partial-read evidence: `.runtime/compact-unread-recovered.png`.
- After the final logging fix, both Web servers were rebuilt/restarted and the saved accounts/history restored again. `UNREAD-LIVE-003` became Delivered with the recipient conversation closed. Opening it in the real Flutter UI sent Seen, removed unread **1** and changed the sender tick to Seen. The recipient's browser log now classified the received envelope as `room_unread_cleared` (191 bytes), and both final browser consoles had no warnings/errors. Local final evidence: `.runtime/compact-unread-final.png`. The sender's original unsent composer text was restored.
- Fresh MCP capture beginning **16:05:05 UTC** through the inspected final **16:11 UTC** UI window reported complete scanned coverage (6,085 records, no malformed records), zero warnings, zero errors and zero failed operations. Earlier live negative tests intentionally generated 4xx responses; concurrent idempotency checks generated retryable MongoDB transaction warnings. A traced warned request completed HTTP 200 after retry, and the suite verified one persisted message. No 5xx or failed publication was reported in that test window.

Review corrected two related defects: the controller's realtime tracing decoder previously assumed `room` or `receipt` and could reject an `unread` envelope before SQLite; the debug traffic logger also needed both compact envelopes to retain their event type. Regression tests exercise the actual SDK ingress and all three logging envelope forms.

Main follow-up files: `backend/src/infrastructure/centrifugo.service.ts`, `backend/src/openapi.ts`, backend contract/integration tests; Flutter `app_database.dart`, `inbox_sync_service.dart`, `chat_controller.dart`, `debug_traffic_logger.dart` and their focused regressions; `scripts/receipt-sequence-e2e.mjs`, the compatible live harness and contract/runbook updates. No database schema or generated binding was changed by this unread follow-up.

## Initial sequence validation

- Existing local MongoDB, Redis, Centrifugo, backend, collector, Logdy and two Flutter Web servers were healthy before implementation.
- Backend: `npm run format:check`, `npm run typecheck`, `npm run build`, `npm test` passed; 79 unit tests. Final `npm run test:integration` passed 66 tests, including real Centrifugo sockets, duplicate/no-op handling, partial unread boundaries, conservative legacy receipt gaps, group legacy history and atomic batch validation.
- Flutter: `dart run build_runner build`, `dart format --output=none --set-exit-if-changed lib test` (65 files, zero changes), `flutter analyze` (no issues), and `flutter test` (306 tests) passed. Focused coverage includes schema upgrades, durable targets across restart/summary pruning, sent-only statuses, receipt-only certification, unknown room recovery, captured offline boundaries and account-switch fences.
- Final Web build passed: `flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`.
- Final Android debug build passed: `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket`. No Android device or simulator test was performed. Existing transitive plugins emit a future Kotlin Gradle compatibility warning; the current build succeeds.
- `node --test scripts/e2e.mjs`: 19 live REST/WebSocket checks passed against the running API.
- `node --test scripts/receipt-sequence-e2e.mjs`: passed. A real compact receipt measured 185 minified application JSON bytes. Verified transactional sequences/idempotency, exact first dates retained, partial Seen leaves newer unread, duplicate requests do not allocate revisions, invalid future/foreign boundaries fail, and REST delta retains receipts after a coalescing preference event.
- Real UI Delivered publications measured 191 bytes with the existing accounts' four-digit revision counters, about 81% smaller than the user's original 984-byte minified application payload (transport framing/compression excluded).
- Browser sessions on the two documented Web origins preserved their saved accounts and old SQLite history after migration. `SEQ-LIVE-001` was Delivered with the recipient conversation closed and became Seen when opened. For `SEQ-LIVE-002`, the sender navigated away before the peer read; the sender recovered Seen from REST/SQLite on return, despite missing that realtime publication.
- After the final audited source rebuild and a second Flutter-server restart, both accounts/history restored again. The reverse-direction `SEQ-LIVE-003` reply reached the other client and showed Seen. Both final browser consoles had no warning/error records. Local screenshot: `.runtime/receipt-sequence-final.png` (ignored runtime evidence).
- Fresh MCP capture from 14:54 UTC through the inspected 14:57 UTC window had complete reported coverage, zero warnings, zero errors and zero failed operations. Both browser consoles had no warning/error records during that verification. These are local observations, not production or multi-instance capacity evidence.
- `node --check scripts/receipt-sequence-e2e.mjs`, changed-document/script Prettier checks and `git diff --check` passed.

## Runtime and compatibility

The API and both Flutter Web servers were explicitly restarted through their existing bounded private-log launchers. MongoDB, Redis, Centrifugo, collector and Logdy were reused. The running API uses process-only `RECEIPT_PUSH_MODE=compact`; no private environment file was edited. To preserve compact mode on a later manual API restart, run `RECEIPT_PUSH_MODE=compact npm run start:debug` from `backend/`. The default `legacy` mode advertises legacy capability and rejects sequence commands; clients fall back to captured timestamps.

The complete hydrated room stays in Redis. Compact patches never replace recovery snapshots. Existing MongoDB messages remain unnumbered and retain exact dates; new messages use the additive unique sequence index. SQLite v5 retains pending sends, uploads, message IDs, drafts and account cursors.

Strict background Delivery waits when received coverage has an earlier hole. Loading older pages can close that gap; explicit foreground room-read acknowledgement may advance Seen through the verified latest head under the existing room-level read policy. No automatic full-history download was added. Receipt flags prove status; exact historical dates remain available only from actual per-message data.

## Defects found and corrected during review

- Timestamp receipt logic could colour new sequenced messages in SQLite and historical jump views; compatibility bulk status now applies only to legacy rows.
- A later snapshot could certify retained history using an earlier captured edit revision; overlap certification now uses snapshot coverage revisions.
- Older pagination could incorrectly promote an unseen latest room head; only latest-page verification certifies that head.
- A full inbox refresh could discard queued acknowledgements with room summaries; the dedicated SQLite receipt-task table survives summary pruning.
- Queue/confirmation writes needed a session check inside their transaction to prevent late writes after account cleanup.
- Mixed legacy history and partial reads needed explicit unread accounting, and mixed-version publication required a protocol capability gate.

## Main files

- Backend schemas/DTOs and transactional receipts: `backend/src/models.ts`, `backend/src/chat/chat.service.ts`, `backend/src/chat/dto.ts`, `backend/src/chat/chat.controller.ts`.
- Publication and API contract: `backend/src/infrastructure/centrifugo.service.ts`, `backend/src/openapi.ts`, backend receipt regressions and runbook/configuration example.
- Flutter models/SQLite/migration/inbox: `mobile_and_web/lib/core/models.dart`, `app_database.dart`, generated `app_database.g.dart`, `inbox_sync_service.dart`.
- Flutter scheduling/UI: `chat_controller.dart`, `chat_api.dart`, `lib/ui/chat_shell.dart`, `lib/ui/messages_pane.dart`; sequence, migration, scheduling and widget receipt regressions.
- Live regression: `scripts/receipt-sequence-e2e.mjs`; updated workspace specifications/runbooks and validation links.

No commit, push, publication, deployment, database reset or media cleanup is authorized by this task.
