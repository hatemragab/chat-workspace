# Sequential outbox and health recovery

The Flutter client persists sends in the existing `chat_app_db` and runs one
`Queue(parallel: 1)` execution lane. Drift owns durability; the package queue is
only an in-memory executor. There is no new server message-event queue.

## Persistence and ordering

Drift schema 6 extends `LocalMessages` with `enqueueOrder`, `retryCount`,
`nextAttemptAt`, `lastErrorCode`, `lastErrorText`, `outcomeUnknown` and
`outboxPaused`. `SyncMetadata.lastOutboundOrder` allocates monotonically
increasing local order values in the same transaction as the optimistic insert.
All older schemas migrate without deleting messages, upload bytes, drafts,
receipts or inbox cursors.

New text, images and complete image batches are saved as `queued` before network
work. Existing image URLs and upload bytes are reused; no duplicate upload-token
column or filesystem promotion is introduced. Requests retain the current
`POST /uploads/image` and `POST /messages` routes.

The oldest unresolved operation owns the global FIFO lane. A confirmed send or
a known permanent rejection permits the next operation. Connectivity,
authentication, a future retry deadline or an uncertain paused head stops newer
sends from overtaking it. Restart recovers interrupted `sending` rows as queued
with an unknown outcome. Historical failed rows remain available for explicit
Retry because their original error classification is unavailable.

## Recovery and retries

`ServerHealthMonitor` probes only this API's public `/health`, with public
internet checks disabled. The selected checker uses HEAD. GET and HEAD run the
same bounded MongoDB-primary and Redis checks; responses preserve the existing
JSON shape for GET and no-store behavior. Readiness is a hint, not proof that a
particular message committed. Centrifugo availability does not gate REST sends.

Unknown initial readiness permits a send attempt. Failed readiness starts one
bounded recovery timer. Healthy idle sessions do not poll. Startup, resume,
manual recovery and newly queued work wake the same dispatcher; a wakeup during
an active drain is remembered. Retry deadlines survive restart and health
success does not bypass a cooldown.

Only owned message requests receive up to two short Dio retries. The durable
worker counts actual requests toward its three-attempt healthy-server budget;
three worker cycles cannot conceal nine HTTP attempts. Upload bodies have a
30-second send bound and the owned upload/send burst has a 75-second active
cancellation deadline. A queue timeout is deliberately not used because that
would permit the next closure while the previous operation still runs.

| Failure                                                           | Action                                                                                                       |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Offline or failed readiness                                       | Retain queued head, preserve its identity and resume automatically; do not consume the poison-message budget |
| New operation rejected with invalid data or permissions           | Retain visible failed row; no automatic retry; continue FIFO                                                 |
| Rejection after an earlier ambiguous attempt                      | Pause the unresolved head visibly; the new rejection cannot disprove earlier acceptance                      |
| Authentication required                                           | Pause account sending and preserve pending work for same-account reauthentication                            |
| Rate limited                                                      | Persist `Retry-After` and schedule a nonzero bounded-delay wakeup                                            |
| Repeated healthy-server errors                                    | Stop automatic attempts at the budget and retain a visible paused head                                       |
| Lost response or interrupted execution                            | Preserve uncertainty; replay the original operation rather than create a new identity                        |
| Malformed/mismatched acknowledgement or local persistence failure | Pause visibly; never certify a send or redirect its conversation                                             |

An acknowledgement must match sender, send key and conversation before local
mutation. Upload checkpoints reread the current row to preserve remapping,
claimed status and retry metadata. REST and realtime acknowledgements converge
inside existing Drift transactions. A late failure cannot downgrade an already
sent row. REST reconciliation never advances the serialized inbox cursor.

Explicit logout/account switching retain the existing local-cleanup policy.
Same-account reauthentication preserves the queue. Browser storage ownership
remains enforced before opening the database; a second tab does not gain another
writer. Background suspension defers execution until resume, and browser data
clearing/uninstall cannot be recovered by this local queue.

## Status tracking

Sync diagnostics includes an `outbox` snapshot: running/paused state, health,
queue counts, retry deadline, last reason and physical attempts. Queued bubbles
show that sending is automatic; rejected and paused messages expose explicit
Retry and a safe reason.

The Flutter inspector emits `outbox` and `health` events through the existing
opt-in local exporter, Vector, Logdy and read-only logs MCP. Events include a
stable `operationId`, captured account/conversation context,
attempt number, status/reason and retry deadline. They contain no message text,
image bytes, credentials or raw response bodies. Rejection, server-unavailable
and attention-required events use the exporter's reserved diagnostic priority.

To inspect a run, enable **Flutter inspector → Capture → Share with local logs**,
send a test message and filter Logdy by source `flutter` and category `outbox` or
`health`. Follow one operation by its operation ID and trace. The local JSONL/MCP
capture is authoritative for retained diagnostics; Logdy has a bounded window.
Successful GET/HEAD health completion records are suppressed; failed or aborted
health probes and bad-request completions remain visible. Problem responses add
stable `code`, `retryable` and rate-limit hints without removing existing fields.

## Verification

Focused regressions cover migration, FIFO, automatic offline recovery,
interrupted startup, lost acknowledgements, bad-request non-repetition,
authentication, rate-limit deadlines, healthy-server retry budgets, late echoes,
account changes, upload checkpoint reuse and log metadata. Current executed
commands and live evidence belong in `VALIDATION.md`; this specification alone
does not establish device, production or suspended-background execution proof.
