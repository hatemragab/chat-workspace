# Drift query trace

This document separates a source audit of `mobile_and_web/` from measured Flutter inspector results. The audit below describes the call paths reviewed before the three safe changes in [DRIFT_QUERY_IMPROVEMENTS.md](DRIFT_QUERY_IMPROVEMENTS.md). It is not a fresh benchmark or proof of a UI hang. A long inspector list alone does not establish query duration, an infinite loop, or a network request per SQL statement.

## How to count

- Count one completed executor span for each `SELECT`, `INSERT`, `UPDATE`, or `DELETE`. Do not count its begin and end records twice.
- Report action SQL and watcher/follow-up SQL separately, or state explicitly when both are included. A persistent watch can keep an older trace ID; its trace ID alone does not bound an action.
- Keep HTTP requests, transactions, stream emissions, UI builds, and SQL statements as separate categories.
- Record capture coverage, time boundaries, instance/session identity, archive coverage, and pagination. Static call counts are conditional estimates, not measured totals.
- Identical watched SQL and bound variables can share Drift's active cached stream. Three subscriptions do not establish three SQL executions.

The installed Drift version is 2.35.2. Its `TableUpdate` carries a table name and optional `UpdateKind`; it has no primary key or room ID. A filtered `WHERE room_id = ?` does not make its normal table invalidation room-scoped.

## Recorded scrolling evidence

The existing 19 October 2026 capture in `.runtime/scroll-pagination-upsert-fix/fresh-scroll-summary.json` covers 16:20:50–16:23:30 Cairo. It predates this document correction and the three safe changes; it is not a new capture for those changes.

| Recorded action | Completed SELECTs | Message upserts | Total SQL, including watcher refreshes |
| --- | ---: | ---: | ---: |
| Earlier per-message server page, 30 messages | 99 | 30 | 129 |
| First server page after the scrolling fix, 30 messages | 11 | 1 | 12 |
| Second server page after the scrolling fix, 30 messages | 11 | 1 | 12 |
| Each of two cached window expansions | 1 | 0 | 1 |

Each fetched page made one successful history HTTP request. Each cached expansion made no HTTP request or write. The two fetched pages used one 30-row, 900-parameter message upsert each. These are scenario-specific measurements, not budgets for every room or receipt state.

`local_messages` currently has 30 inserted columns. `_writeMessageRows` bounds a statement to 900 parameters, so 30 full rows fit in one `INSERT ... VALUES (...), (...) ON CONFLICT ... DO UPDATE`. Drift `batch` alone would not prove a multi-row SQL statement; the emitted SQL does.

## Watch dependencies in the audited baseline

| Watch | Data read | Tables that invalidate the SQL |
| --- | --- | --- |
| `watchRooms()` | Non-deleted room summaries plus the newest queued/sending/failed message per room. The pending subquery ranks messages and originally selected every message column, including upload bytes. | `local_rooms`, `local_messages`, `sync_metadata` |
| `watchMessages(roomId, limit)` | Full rows for the selected room and bounded window. | `local_messages`, including writes in other rooms |
| `watchOutboundSnapshot(senderId)` | Pending/failed counts and the oldest eligible queued/sending head. | `local_messages` |

The room stream is session-long; the message stream exists for the selected conversation. The outbox detaches its own subscription while draining a nonempty head and reattaches afterward. It therefore is not a third continuously active watcher during every send write.

Only writes to a watch's declared tables can invalidate it. Queueing a delivery/Seen target writes `receipt_tasks`, which none of these three watches read. That operation does not itself cause three watch queries. Confirming a receipt can also update `local_rooms`, which can refresh the room query. Real message writes can refresh the message and room watches, plus an attached outbox watch. Transaction grouping and Drift stream reuse affect the actual number of executions.

In the baseline room query, the current user came from a `sync_metadata` subquery. This made inbox cursor updates and outbound order allocation invalidate the room query even when its displayed data was unchanged. Narrowing pending preview columns and binding the session user remove that dependency without a new table or schema migration.

The controller also calls `watchRooms().first` during startup. Those subscriptions may reuse the active stream; their call count is not an executor count. Room/message emissions still map models and notify the UI, which is a separate cost from SQL execution.

## Call paths in the audited baseline

### Open a room

Opening displays the bounded cached message watch immediately, then reconciles inbox state before checking cache certification. A certified cache can skip the history request. An uncertified cache may fetch and reconcile the latest page, coverage, and receipts. Optional sent-count reads depend on whether pagination state is already known.

Marking Seen reads the current room, derives its verified sequence or captured legacy timestamp boundary, and queues a durable receipt target. The baseline helper could read the same room again while deriving the sequence target. A later flush reads pending tasks, sends the appropriate API requests, and confirms them locally. These paths are conditional; there is no unconditional “three watcher queries” charge for receipt-task writes.

### Scroll to older messages

`loadOlderMessages` expands by 30 while preserving navigation/session guards:

- If the existing watch proves more cached rows exist, a widened watch supplies the new window without a separate pre-read.
- The fallback cache probe may discover additional rows; its following watch can reuse the same SQL stream when applicable. Count actual executions when evaluating this uncommon path.
- A server page reads the oldest sent cursor, fetches one older page, and passes the whole result to `upsertMessages`. Duplicate and room context reads are shared across the page. Coverage/receipt state is applied in the same transaction, then the visible watch widens.

The bounded bulk writer can skip unchanged rows. A fetched page may therefore write fewer rows than it returns. Cached expansion still rereads/maps a growing bounded window; changing that representation is a separate design task, not part of the three safe fixes.

### Send a text or image

Enqueue allocates a durable FIFO order in `sync_metadata` and stores the pending message atomically. Message status changes and acknowledgement reconciliation can invalidate attached watches. Image sends also validate persisted upload-byte quota and retain bytes needed for offline previews/retry.

A REST acknowledgement and its socket echo do not guarantee two message inserts. The merge helpers skip unchanged message/room values, and a publication already covered by the inbox cursor is skipped. REST still must not advance `localPts`; a fresh socket publication must follow normal inbox reconciliation even if its message was already acknowledged.

Draft-room creation/remapping and upload acknowledgement add their own conditional work. A single fixed statement budget would hide those differences.

### Live publications, delta, and full recovery

`InboxSyncQueue` serializes inbox cursor application. The publication drain takes up to 64 publications that are already queued. This is a cap, not a promise that 20 network arrivals become one batch. Contiguous publications can apply in one transaction; gaps, epoch changes, and missing compact rooms recover through the delta path.

The audited baseline then called `_emitRoomEvent` per payload and reread the room to decide whether message recovery was needed. Controller listeners scheduled delivery/foreground Seen follow-up per event. Repeated events for a room could repeat room/receipt-context reads even when the durable target was unchanged.

`queueReceipt` already compares the target with stored targets and confirmed cursors and avoids unchanged task writes. A task-only commit does not invalidate room/message/outbox watches. Therefore the earlier estimate of “120 room-list queries for 20 messages” was unsupported and has been removed. The same applies to fixed 20-message and 25-room totals inferred without recording branches and batching.

Delta/full recovery applies authoritative room state, message content, receipt boundaries, and cursor changes transactionally. Full-sync helper reuse may offer further savings, but this document does not treat a larger full-sync rewrite as implemented or required for the safe fixes.

### Delivered and Seen receipts

Peer receipts change ticks on this account's outgoing messages. Sequence cursors and legacy timestamps remain separate from this account's durable acknowledgement tasks. Seen never means “mark my outgoing messages Seen.”

In the audited baseline, sequence tick updates and a legacy receipt update declared `updates: {localMessages}` even when SQLite affected zero rows. That could invalidate message-dependent watches without changing a message. The existing watermark helper already issued `notifyUpdates` only when the affected-row count was positive. The safe change applies that pattern consistently; real tick changes must continue notifying.

Delivery requires contiguous persisted coverage; foreground Seen can use the exact verified head/captured timestamp boundary. A newer outgoing room preview does not prove there is no unacknowledged incoming coverage. Skipping all outgoing echoes based only on the preview sender would be unsafe.

### Offline outbox

The queue remains in Drift, with sender-scoped idempotency, global FIFO order, persisted retry counts, delayed/paused head blocking, and interrupted-send recovery. The outbox observer is detached during a drain, avoiding its own write feedback.

The post-health-await eligibility read is necessary: an inbox acknowledgement can mark the message sent while readiness is being checked without changing the session. Removing that read based only on session identity can replay retired work. Physical retry attempts must remain durably counted; postponing all retry persistence until a burst finishes loses the budget on a crash/restart.

External writes and explicit Retry/resume wakes must still cause a fresh read where required. These correctness reads are not removed by the three safe fixes.

## Other observations and boundaries

- Existing indexes support room history, reply targets, sender/status/order outbox access, and unique sender/idempotency identity. An additional preview index needs a query-plan measurement before changing schema.
- `inspect()` performs a deliberate diagnostic snapshot; it is not a room-open/scroll hot-path operation.
- Full message watches still include upload bytes because pending image rendering and the outbox use them. Removing bytes from a room-list preview is safe; removing them everywhere requires a separate lazy-loading design.
- Room-scoped invalidation would require application-owned signaling and complete coverage of writers, rollback, deletion, recovery, and account cleanup. Drift's built-in `TableUpdate` alone cannot provide it.

## Current implementation and fresh validation

The three safe fixes are implemented. The baseline analysis above is retained as the explanation of the original work; the current behavior is:

| Safe fix | Current implementation |
| --- | --- |
| Narrow room previews and remove metadata invalidation | `watchRooms({String? userId})` accepts a captured account ID; controller and sync callers bind it. The pending projection selects 19 display/state columns, retaining `outboxPaused` and `outcomeUnknown` for the UI while omitting blobs, reply snapshots, and retry/error details. Its watched tables are now only `local_rooms` and `local_messages`. Compatibility callers read metadata once before starting that parameterized stream. |
| Guard no-op receipt notifications | Sequence and legacy peer-tick updates notify `local_messages` only when SQLite changes a row. Real tick updates retain transaction-scoped notifications. |
| Reuse per-room state and merge follow-up | Typed `InboxRoomEvent` retains every mutation but reads the final committed room once per distinct room in the emitted batch. Receipt work runs for that room's final event, with earlier incoming/legacy acknowledgement information retained. `receipts.room.queue` combines delivery/Seen targets through one receipt-context read. Pure `receiptTargetFromRoom` avoids rereading coverage; explicit Seen reads a fresh room once and reuses it. |

Each event still reaches historical mutation handling. Session/navigation/foreground fences and captured Seen boundaries remain enforced. Outbox retry/eligibility policy, schema, API contracts, and full message/upload reads are unchanged.

Static/unit validation completed with `flutter analyze`, `flutter test --concurrency=2` (490 passed), and `flutter build web` (passed). Six new database regressions, three service-batch regressions, and three real-WebSocket controller burst regressions cover query behavior, retained events, and foreground/hidden/navigated Seen behavior. A full test run concurrent with a build hit an existing exporter timing assertion; its 24 isolated tests and the quieter full 490-test rerun passed.

### Fresh Flutter Web verification

The [fresh summary](.runtime/drift-safe-fixes/fresh-verification-summary.json) covers **19 October 2026, 16:46:30–16:52:23 Cairo**: 2,484 Flutter records across three instances, each continuous from sequence 1 (950, 796, and 738 records). [MCP coverage](.runtime/drift-safe-fixes/mcp-coverage.json) contains 26 pages (10 + 8 + 8); both retained older archives had zero matching records and zero invalid lines. [Raw Flutter records](.runtime/drift-safe-fixes/fresh-verification-flutter.jsonl), the [collection script](.runtime/drift-safe-fixes/collect_evidence.py), and [evidence checks](.runtime/drift-safe-fixes/evidence-validation.log) retain the supporting local evidence.

| Scenario | Fresh result |
| --- | --- |
| Quiet home, 16:46:50–16:47:20 | Both clients executed zero SQL statements. |
| Room previews | Emitted SQL binds the user and selects 19 pending columns without `sync_metadata`, upload bytes, or reply snapshots. |
| Live direct-room exchange | Both directions rendered Seen; all five Seen HTTP requests in the window returned 200. |
| Offline/reload/FIFO recovery | A deliberate API block left two messages queued across a reload. Removing the block automatically sent them in order, as sequences 96 then 97, retaining their original idempotency keys. Each had one successful message POST; blocked failed attempts were separate. Recovered rows rendered Seen. |
| Resume at 16:51:15 | Inbox delta and presence requests both returned 200. |
| Fetched older page | 30 messages used one 900-parameter upsert: 14 SQL statements, comprising 11 SELECTs, one INSERT, and two coverage UPDATEs; one history HTTP request. |
| Two cached expansions | Each executed one SELECT with zero HTTP requests and writes. |

The 14-statement fetched page used a different account/cache/coverage state from the earlier 12-statement scrolling capture, so those totals are not a controlled before/after comparison. No broad post-fix statement budget is inferred from them.

All 29 warning/error records occurred during the deliberate API outage, 16:48:54–16:49:58; none occurred after 16:50:00 and none were unexpected. The temporary API block and focus/network test settings were removed/restored.

The live capture contains 13 single-item publication batches. **Twenty-item coalescing is verified by automated tests, not by this live capture.** Offline image bytes, compact/legacy edge cases, and navigation/foreground races have regression-test coverage rather than a claim of fresh live coverage for every combination. The earlier scrolling evidence remains historical and is not reused as proof of these changes.

## Scrolling follow-up: remove repeated page reads

The 14-statement page above contained **11 SELECTs, one 30-row upsert and two receipt/coverage UPDATEs**. Its 11 reads were: a cache probe; the oldest sent cursor; account, room and duplicate-message context for the upsert; another room and account read for coverage; room-preview, narrow message-window and outbox watcher refreshes; and the final wider message window. Watcher traces were included even where their trace IDs differed from the scroll action.

The current scroll path removes five of those reads:

- Capture the session account and pass it into `storeOlderMessagePage`, avoiding both metadata lookups.
- Reuse the upsert's transaction-local room for receipt state and coverage, avoiding the second room read.
- Start one retained wider message watch in the inbox lane. When that snapshot contains the entire cache, its oldest **sent** row supplies the compound cursor without another SELECT. Pending/failed sends cannot supply that cursor.
- Keep that wider watch for the commit, avoiding the obsolete narrow-window refresh. A failed HTTP/store operation restores the old window bound and watch; repeated failures cannot inflate it.

Page persistence uses two shared reads with a captured account: room context and sender-scoped duplicate identities. The ordinary fetched-page path adds two message-window reads (initial snapshot and committed page) and, when attached, room-preview and outbox watcher reads. These remaining observers are kept for correctness; no custom notification or outbox-policy redesign is included. Actual totals still depend on changed rows, coverage, receipts and observer scheduling. Cached expansion continues to use one SELECT with no history HTTP or writes.

### Fresh follow-up verification, 19 October 2026

[The follow-up summary](.runtime/scroll-read-fix/fresh-summary.json) covers **17:07:47–17:10:19 Cairo**: 2,511 Flutter records, retrieved through [27 MCP pages](.runtime/scroll-read-fix/mcp-coverage.json). All three instances are continuous from sequence 1 (899, 1,001 and 611 records). Both retained archives were separately checked with zero matches; a complete local-file scan agreed with the MCP counts and found no invalid lines. [Raw records](.runtime/scroll-read-fix/fresh-flutter.jsonl), [verification script](.runtime/scroll-read-fix/verify_capture.py) and [assertion results](.runtime/scroll-read-fix/evidence-checks.log) retain the proof.

The fetched 30-message page at 17:08:17 used **seven SQL statements: six SELECTs and one 30-row/900-parameter upsert**, plus one history HTTP request. Counts include all watcher completions through one second after action end: three completed a few milliseconds after the action, including watchers with different trace IDs.

| Remaining SELECTs | Count | Purpose |
| --- | ---: | --- |
| Wider message window | 2 | Initial complete cache/cursor snapshot and the same watch's post-commit refresh. |
| Room context | 1 | Current receipt cursors and verified coverage for the whole transaction. |
| Sender-scoped duplicate identities | 1 | Preserve optimistic acknowledgement, exact receipt state and pending-send reconciliation. |
| Room-preview observer | 1 | Keep inbox display current after real message writes. |
| Outbox observer | 1 | Keep durable queue/head/count state current. |

The previous page's 11 SELECTs fall to six by removing the five identified reads. The new page needed neither of the old page's two receipt/coverage UPDATEs because its state was already current; **the seven-versus-fourteen total also reflects this state difference**, not seven removed reads. No universal seven-statement budget or latency improvement is claimed. A cached expansion at 17:08:06 used one SELECT, zero writes and zero HTTP.

Both live directions rendered Seen; all six Seen requests returned 200. Two API-blocked offline sends survived a reload, rendered queued from cache, then recovered automatically in FIFO order as sequences 100 and 101 with their original idempotency keys and one successful message POST each. Both rendered Seen. Resume at 17:10:11 triggered successful delta and presence requests. All 24 warning/error records fell within deliberate API blocking (17:09:04–17:09:47); there were no unexpected warnings/errors or failures after recovery. The API block was removed and focus settings restored. These are local Flutter Web checks, with broader image/legacy/concurrency combinations covered by tests.

Final checks passed: `dart format --output=none --set-exit-if-changed lib test` (97 files unchanged), `flutter analyze`, `flutter test --concurrency=2` (**504 passed**), `flutter build web` with the documented local API/WebSocket defines, and `git diff --check`. Nine new database cases cover shared context, receipts, coverage, pending uploads/FIFO, rollback, identity adoption and absent contexts. Five new controller cases cover cursor ordering, pending/failed exclusion, queued recovery, account fencing, and bounded failed retries with live-watch continuity.

## Older-history projection notifications

The subsequent authorized change separates inbox/outbox watch dependencies from ordinary table-wide message notifications. It uses two in-memory Drift update names, `__inbox_projection` and `__outbound_projection`, without adding SQL tables, schema changes, generated bindings or a second database. Ordinary database writes still notify the physical table and the affected projection dependencies through `AppDatabase.notifyUpdates`. Message upserts notify explicitly through that method because Drift's automatic custom-write notification otherwise goes through the transaction child engine.

For a pure older sent-message page, the bulk writer notifies `local_messages` for conversation watches but omits the inbox/outbox projection names. The three internal coverage fields (`receivedThroughSeq`, `receivedRangesJson`, `verifiedHeadSeq`) likewise notify raw room observers without refreshing the inbox, because none is mapped by `roomModel`. Conversation windows retain their existing table-wide notification behavior; this is projection-specific, not room-specific invalidation.

There are correctness exceptions: a page that acknowledges a queued/sending/failed duplicate still wakes both projections, including same-ID acknowledgements and draft remapping. A receipt snapshot that changes visible room cursors or preview ticks still wakes the inbox; its sent-row receipt changes do not refresh the outbox. Ordinary sends, mutations, Retry/recovery, deletion and account cleanup keep their existing notifications. Actual/synthetic updates accumulate in the same Drift transaction, so a quiet history operation cannot swallow an ordinary write in a mixed transaction.

Seven new retained-listener regressions verify physical SQL executions, coverage-only changes, visible receipt advances, pending identity adoption, ordinary state changes, mixed transactions and rollback/recovery. Pure 30-row history persistence refreshes the conversation once with zero inbox/outbox SQL, even with a pending queue head retained. Final formatting (98 unchanged files), analysis, **511 Flutter tests**, Web build and diff checks passed.

### Fresh projection verification

The [new summary](.runtime/history-watch-fix/fresh-summary.json) covers **19 October 2026, 17:21:38–17:25:03 Cairo**: 2,304 Flutter records, with complete per-instance sequences (850, 795 and 659 records) matched against [24 MCP pages](.runtime/history-watch-fix/mcp-coverage.json). Both retained archives were separately inspected and had zero matches; full local-file scanning agreed with the MCP counts and found no invalid lines. [Raw records](.runtime/history-watch-fix/fresh-flutter.jsonl), [verification script](.runtime/history-watch-fix/verify_capture.py), and [assertions](.runtime/history-watch-fix/evidence-checks.log) retain the evidence.

| Fresh action | SELECTs | Message upserts | Inbox/outbox watcher SELECTs | History HTTP |
| --- | ---: | ---: | ---: | ---: |
| Each of two cached expansions | 1 | 0 | 0 / 0 | 0 |
| Final uncached page, **23 remaining messages** | 4 | 1 (23 rows, 690 parameters) | **0 / 0** | 1 |

The four fetched-page reads are the widened cache snapshot, shared room context, duplicate identities and the retained conversation watch's post-commit refresh. Its SQL scope includes one second after action completion so observer work is not hidden by the action's end. Consecutive cached actions use their individual completed spans. The initial progress update described the page as 30 messages before inspecting the response; the actual response had 23 and `hasMore: false`. **The 30-row case is automated-test evidence; the fresh UI page has 23 rows.** Row count and state differ from earlier captures, so no fixed latency or total-statement percentage is inferred.

Both live directions reached Seen. Two blocked offline sends survived reload and rendered queued from cache, then recovered automatically with their original keys and one successful message POST each, in FIFO order as sequences 104 and 105. While the peer was hidden, Delivery succeeded and it sent zero Seen requests; after resume at 17:24:51, delta, presence and Seen returned 200 and both messages rendered Seen. All four Seen requests in the window returned 200. Normal inbox/outbox queries resumed for real send/recovery changes, proving the watches were retained rather than disabled.

All 26 warnings/errors occurred during deliberate API blocking, 17:23:25–17:24:13. No unexpected warnings/errors or post-recovery failures were observed. Temporary network/focus controls were restored. This is local Flutter Web proof; broader sequence/legacy, image, rollback and concurrency combinations are covered by the full regression suite.
