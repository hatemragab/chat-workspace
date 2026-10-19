# Drift query improvements

This plan follows the corrected [source trace and evidence rules](DRIFT_QUERY_TRACE.md). It distinguishes the three authorized safe fixes from larger deferred designs. Exact statement savings depend on cache state, pending receipts, publication scheduling, attached watches, and acknowledgement order; measure them instead of treating static estimates as benchmarks.

Keep one Drift database and one serialized inbox cursor writer. REST reconciliation must not advance `localPts`. Preserve delivery/Seen separation, verified receipt boundaries, sender-scoped idempotency, durable FIFO/retry state, session/navigation fences, and offline pending images.

## 1. Narrow the room preview query and bind its user

In `app_database.dart`, replace the `sync_metadata` user subquery with the captured session user as a bound parameter. The room stream then reads `local_rooms` and `local_messages`, without declaring `sync_metadata` as a dependency. Cursor-only updates and outbound order allocation must not refresh it.

Select only the pending-message fields used to render the room preview. Omit `upload_bytes`, reply snapshots, and outbox retry counters/error details from that projection; retain `outboxPaused` and `outcomeUnknown` because the room-preview UI uses them. Preserve the newest pending message per room, account filtering, failed/sending/queued status, timestamp comparison with the server preview, room sorting, and draft-room behavior. Keep upload bytes in full message reads and the outbox, where pending image rendering and retry require them.

Do not add a preview table or limit the loaded inbox. The current UI displays every locally loaded room; an arbitrary SQL limit would hide data. Message-table writes can still invalidate the room query after this change. The improvement is a narrower read and removal of metadata-only invalidations, not room-scoped message notifications.

Verification: pending text/image previews, draft remap, sender filtering/account switch, and ordering remain correct. A cursor-only write produces no new room-query execution/emission; real preview changes remain observable.

## 2. Suppress zero-row peer-receipt notifications

Use the existing `_applyReceiptWatermarks` pattern for the sequence and legacy peer-tick updates: execute the guarded `UPDATE` without automatic `local_messages` notification, inspect the affected-row count, and notify `TableUpdate.onTable(localMessages, kind: UpdateKind.update)` only when it is positive. Keep notifications inside the existing transaction so rollback cannot expose a false change.

Keep all monotonic cursor/timestamp predicates, sender/room scoping, sent-only filtering, and Seen-implies-delivered behavior. A zero-row SQL `UPDATE` may still appear in the inspector; this fix removes its unnecessary watcher refreshes, not necessarily that executor call. A real tick change must still reach both the visible message and room-preview models.

Verification: no-match/replayed receipts do not emit message-dependent streams, a changed receipt does emit and updates ticks, and transaction rollback retains the prior data/observer state. Exercise sequence and legacy receipts.

## 3. Reuse room state and coalesce receipt follow-up per room

In `inbox_sync_service.dart` and `chat_controller.dart`, avoid rereading the same just-applied room for every event and avoid scheduling duplicate receipt-target work for that room while a shared follow-up is pending.

- Reuse the room state already produced/read during authoritative application where it remains valid. Preserve the post-apply `needsMessageRecovery` decision. Any fallback read must reflect the committed transaction and retain session guards.
- Preserve individual event payloads needed for historical edits, deletions, quotes, and recovery. Coalescing receipt work must not discard message mutations or inbox cursor progression.
- Collect distinct rooms for delivery and foreground Seen target calculation and process the pending set through the inbox queue. Reuse a room snapshot within that transaction rather than reading it again in nested helpers.
- Merge sequence/timestamp targets monotonically and queue the combined task once where applicable. `queueReceipt` already avoids unchanged writes; the added saving is shared reads/follow-up scheduling.
- Recheck account, selected room, lifecycle/foreground state, and authentication after asynchronous boundaries. Seen must retain the exact eligible read boundary. A room switch or background transition must not mark a later room read.
- Keep the existing durable receipt tasks and delayed HTTP flush/retry path, including a wake arriving during an in-flight flush. Delivery still follows contiguous received coverage; Seen still uses the verified visible boundary. Do not skip coverage only because the newest preview belongs to this sender.

Coalescing applies to work actually pending together. The publication drain accepts at most 64 already queued items, so a 20-message network burst may span multiple transactions/follow-ups. Do not promise one apply transaction or one flush for an arbitrary burst.

Verification: repeated events for one room share follow-up reads; distinct rooms retain their own targets. Sequence gaps, compact unread/receipts, legacy boundaries, historical mutations, background state, navigation, logout/account switch, and flush wake races must retain their behavior. Confirm real delivered/Seen acknowledgements through fresh Flutter logs.

## Deferred work and rejected shortcuts

These are not included in the three safe fixes:

| Idea | Required caution before implementation |
| --- | --- |
| A separate pending-preview table | Requires schema/migration and atomic maintenance for every writer, recovery, remap, and cleanup path. Measure the narrower query first. |
| Room-scoped message invalidation | Drift 2.35.2 `TableUpdate` contains table/kind only. A custom application channel must cover every write, rollback, deletion, full recovery, and account change. Adding `roomId` to the current notification is not supported. |
| Full-sync read elimination | Can reuse metadata and room rows, but must preserve baseline reset/certification, draft/pending messages, receipts, and cursor atomicity. Current safe changes do not claim a full-sync rewrite. |
| In-place message-window growth | Cached scrolling already uses one SELECT in the recorded path. Diffing only IDs would miss edits, deletions, content changes, send status, and receipt ticks; any future diff must compare visible state and preserve jump/navigation behavior. |
| Additional preview index | Check `EXPLAIN QUERY PLAN` and a representative workload before a schema change. Existing room/history and outbox indexes remain in use. |
| Removing blobs from all message watches | Requires a replacement loader/cache for pending images and the outbox. Only the room-preview projection is narrowed here. |
| Outbox claim/retry redesign | Preserve the post-health-await eligibility check, durable per-physical-attempt retry counts, same-key uncertain replay, FIFO head blocking, and explicit fresh-read wakes. Deferring retry persistence to burst completion is unsafe across crashes. |

The outbox already detaches its observer during draining. Do not count it as an attached third watch on every write. Receipt-task-only writes do not invalidate room/message/outbox streams, and unchanged REST/socket echoes do not necessarily write message rows. These facts invalidate the earlier fixed estimates of 120 room-list queries for 20 messages and an unconditional second message insert per socket echo.

## Validation and evidence

Run the formatter, `flutter analyze`, relevant regression tests, the full Flutter suite, an applicable Web build, and `git diff --check`. Record commands actually run and their results separately from source inspection.

Fresh Flutter Web verification should cover:

1. Startup/resume inbox reconciliation and a quiet home page.
2. Open a direct room, send/receive a message, and observe delivered/Seen ticks and cursor application.
3. A fetched older page and a cached expansion, retaining the existing multi-row upsert and pagination behavior.
4. Offline enqueue/retry/recovery, preserving the same idempotency key, upload bytes where applicable, durable attempt state, and FIFO order.

Record completed SQL spans once, HTTP operations separately, watcher/follow-up scope, time boundaries, instance/session identity, archive/live coverage, and warnings/errors. Compare equivalent actions and state where possible. A missed message, repeated send, stale tick, or incorrect read boundary is a regression even if statement counts fall.

Prior scrolling measurements are documented in [DRIFT_QUERY_TRACE.md](DRIFT_QUERY_TRACE.md). They are not a benchmark for these three changes; no exact post-fix query budget is promised here.

## Implementation status

All three safe changes are implemented in `app_database.dart`, `inbox_sync_service.dart`, and `chat_controller.dart`. The room preview now binds the session account and selects 19 pending-message columns without metadata invalidation. Sequence/legacy receipt notifications are conditional on changed rows. Typed `InboxRoomEvent` preserves every content mutation, reuses one final committed room read per distinct room, and schedules one combined receipt-context operation for that room's batch follow-up. Earlier incoming or legacy acknowledgement work remains represented when the final event is an outgoing echo or compact receipt.

`receiptTargetFromRoom` is pure; explicit Seen obtains one fresh room snapshot and reuses its coverage. Durable task merging, foreground/navigation checks, exact captured boundaries, flush races, and the offline outbox policy remain intact. No deferred schema, scoped-notification, full-sync, or outbox redesign was included.

Formatting, `flutter analyze`, the full `flutter test --concurrency=2` run (490 tests), `flutter build web`, and `git diff --check` passed. The regression additions include six database tests, three service-batch tests, and three controller tests using real WebSocket bursts. An earlier full test run competing with a build hit an exporter timing assertion; 24 isolated exporter tests and the quieter full rerun passed.

Fresh Web verification on **19 October 2026, 16:46:30–16:52:23 Cairo** is complete: [summary](.runtime/drift-safe-fixes/fresh-verification-summary.json), [raw Flutter records](.runtime/drift-safe-fixes/fresh-verification-flutter.jsonl), and [MCP coverage](.runtime/drift-safe-fixes/mcp-coverage.json). Both home clients had zero SQL during a 30-second quiet interval. Live messages and the two FIFO offline messages recovered across reload with their original idempotency keys and rendered Seen. Resume delta/presence returned 200. A 30-message history page retained one 900-parameter upsert; cached expansions retained one SELECT and no HTTP/writes. All 29 warning/error records belonged to the deliberate API block; there were no unexpected records or warnings/errors after recovery.

The [trace](DRIFT_QUERY_TRACE.md) records exact scope and SQL counts. Live publications were all single-item batches, so the 20-item coalescing result is automated-test evidence only. The history-page total is not compared directly with the older capture because account/cache/coverage state differed. Broader compact/legacy, offline-image, and navigation race combinations retain regression-test coverage; they were not all recreated in this fresh UI capture.

## Authorized scrolling follow-up

The 14-statement page identified five removable reads. `storeOlderMessagePage` now shares the transaction's room state across upsert, receipts and coverage, and accepts the captured account to avoid rereading metadata. The controller widens and retains its message watch before fetching, derives the pagination cursor from a complete cached snapshot, and lets that same watch observe the commit. It no longer separately queries the oldest sent row or refreshes the obsolete narrow window. Cached expansion remains local and independent of stalled remote recovery. Failed requests restore the previous window bound, with the live watch retained.

Keep the shared duplicate-identity lookup, room-preview observer and outbox observer. They preserve optimistic acknowledgement/draft adoption, exact receipt state, pending images and queue visibility. Page persistence with the captured account now needs two shared SELECTs; this is a source/test result, distinct from the complete UI-action count. No schema, generated bindings, wire protocol, inbox cursor ownership or outbound retry policy changed. The source breakdown and fresh measurements belong in [the scrolling follow-up trace](DRIFT_QUERY_TRACE.md#scrolling-follow-up-remove-repeated-page-reads).

Fresh verification is complete for **19 October 2026, 17:07:47–17:10:19 Cairo**: [summary](.runtime/scroll-read-fix/fresh-summary.json), [2,511 raw Flutter records](.runtime/scroll-read-fix/fresh-flutter.jsonl), [27 MCP pages](.runtime/scroll-read-fix/mcp-coverage.json), and [assertion results](.runtime/scroll-read-fix/evidence-checks.log). The fetched 30-message page used six SELECTs plus one 900-parameter multi-row upsert, including observer completions just after action end; cached expansion used one SELECT and no HTTP/write. Five redundant reads were removed from the prior 11-SELECT path. Its two receipt/coverage writes were also unnecessary under this new capture's already-current state, so seven versus fourteen total statements is not a controlled same-state comparison.

Bidirectional Seen, offline/reload recovery of two sends with original keys/FIFO and one successful POST each, and resume delta/presence all passed. All 24 warnings/errors came from deliberate API blocking and none occurred after recovery. Temporary test controls were restored. Formatting, analysis, the complete **504-test** Flutter suite, Web build and diff check passed. The new nine database and five controller regressions protect shared context, rollback, receipt/coverage rules, pending uploads/idempotency, cursor ordering, account changes and bounded failed retries. Native-device and production performance remain unmeasured.

## Authorized projection-refresh follow-up

The inbox and outbound snapshot now watch explicit projection dependencies. `AppDatabase.notifyUpdates` propagates ordinary message/room writes to them. Pure older sent-page inserts notify only conversation/raw table observers; internal coverage changes do not invalidate inbox SQL. Pending-send acknowledgements still notify both projections, and visible receipt/preview changes still notify the inbox. These conditions are computed from the existing transaction-local duplicate/room context, without another SELECT. No observer is detached and no mutable global suppression flag is used.

The implementation keeps real table notifications, transaction buffering, pending draft remapping, FIFO/retry eligibility, receipt monotonicity, cursor ownership and account cleanup. It changes no schema, generated bindings or wire contract. Seven new retained-watch tests verify pure history, receipt advances, same-ID and draft acknowledgements, ordinary queue mutations, mixed transactions and rollback. Formatting, analysis, the full **511-test** suite, Web build and diff check passed. Per-room conversation invalidation remains a separate deferred design.

Fresh Web verification on **19 October 2026, 17:21:38–17:25:03 Cairo** is complete: [summary](.runtime/history-watch-fix/fresh-summary.json), [2,304 records](.runtime/history-watch-fix/fresh-flutter.jsonl), [24 MCP pages](.runtime/history-watch-fix/mcp-coverage.json), and [assertions](.runtime/history-watch-fix/evidence-checks.log). The final server page contained **23 remaining messages**, persisted by one 690-parameter upsert with four SELECTs and **zero inbox/outbox watcher queries**. Two cached expansions each used one SELECT and no HTTP/write. The 30-row notification behavior is covered by automated tests rather than this 23-row live page.

Live bidirectional Seen, two offline sends surviving reload and recovering with original keys/FIFO, hidden Delivery without Seen, and resume delta/presence/Seen passed. Ordinary watcher queries remained active for sends/recovery. All 26 warnings/errors came from deliberate API blocking; none were unexpected or occurred after recovery. Temporary controls were restored. The [trace](DRIFT_QUERY_TRACE.md#fresh-projection-verification) explains exact measurement boundaries and the corrected page size. Native-device and production performance remain unmeasured.
