# Implementation Tasks

Sequence receipts and compact unread follow-up (2026-10-17): implemented transactional message sequences, compact peer/own unread pushes, compatible legacy handling, durable SQLite acknowledgement targets, coverage-safe recovery and receipt request coalescing. Two Web sessions verified missed partial-read recovery after preference coalescing and live unread clearing. Checks/builds and evidence are recorded in [RECEIPT_SEQUENCE_VALIDATION.md](RECEIPT_SEQUENCE_VALIDATION.md).

The user has authorized the full backend, Flutter Android/Web application, tests, and two independent web sessions. This supersedes the earlier documentation-only boundary and permits the requested web UI verification. Approved product specifications remain the implementation baseline.

- [x] Read approved guides and inspect available tools/services.
- [x] Implement NestJS foundation, schemas/indexes, authentication, debug users, users listing, configuration and health diagnostics.
- [x] Implement MongoDB transactional messaging, rooms/preferences, atomic Redis room deltas, Centrifugo publishing, uploads and presence.
- [x] Implement and run backend unit/integration/E2E tests including authorization, retries, pagination, receipts and recovery.
- [x] Implement Flutter packages, Drift database, session lifecycle, persistent optimistic sends and serialized synchronization.
- [x] Implement responsive auth, rooms, messages, group/direct entry, images, actions, receipts, pagination and reply jumps.
- [x] Add safe logs, developer diagnostics and local database inspection support/documentation.
- [x] Run Dart format, Flutter analysis/unit/widget tests, Android/Web builds as applicable, backend checks and complete E2E.
- [x] Run two separate Flutter Web instances and test bidirectional chat and important workflows using computer use.
- [x] Inspect Centrifugo admin and runtime/socket evidence; fix observed issues.
- [x] Audit every specification and requested deliverable against code/test/runtime evidence; document run commands and limitations.

Final results and evidence boundaries are recorded in [VALIDATION.md](VALIDATION.md). Local run and debugging commands are in [README.md](README.md).

## Follow-up: nine audit fixes and logout presence

The user authorized all nine fixes, conflict resolution in the specifications, regression coverage, all checks, repeat two-Web-instance chat testing, and then investigation/fix of logout presence.

- [x] Recheck current source, guides, Git state and service listeners; read current official API guidelines.
- [x] Resolve the sender-scoped identity and receipt-recovery contract conflicts in the specifications.
- [x] Fix initiating send context for text recovery and complete image batches; add regression tests.
- [x] Migrate Drift to sender-scoped idempotency and acknowledgement matching; test version-1 migration and duplicate UUID senders.
- [x] Fence late direct-room opening/remapping across account switching; add regression tests.
- [x] Refresh/invalidate historical jump slices after coalesced recovery; add regression tests.
- [x] Deliver safe quote-only updates for hidden originals; test server and client cleanup without resurfacing originals.
- [x] Recover older cached receipts using latest-page summaries; test overlap, gaps/ties, sender direction and safe legacy fallback.
- [x] Preserve composer input across lazy-room remapping; add regression tests.
- [x] Isolate optional debug discovery failures from saved-session startup; add regression tests.
- [x] Reject null preference booleans without state/revision changes; add regression tests.
- [x] Audit the nine fixes against the revised specifications and their permanent regressions.
- [x] Investigate and fix logout online/offline behavior after the nine fixes; document lifecycle and add regressions.
- [x] Run all backend/Flutter/script checks and Web/Android builds; review the final diff.
- [x] Repeat real bidirectional chat, recovery, mutations, uploads and presence testing in the two Web instances; inspect Centrifugo.
- [x] Record actual results, screenshots and remaining proof boundaries in the runbooks and validation report.

No commit, push, external publication, deployment, or destructive changes to existing data are authorized.

## Second review: four remaining fixes and manual API logging

- [x] Stop the agent-started backend and confirm port 3000 is free; provide the manual command with visible request logs.
- [x] Fence delayed delete-for-me database/UI continuations across account switching; add a permanent regression.
- [x] Make logout immediately invalidate unfinished startup and complete cleanup without draining pending network requests; add delayed-result/failure regressions.
- [x] Keep later lazy-batch pending/failed images visible in the real room and retry with their existing identity; add regressions.
- [x] Upgrade versions 1/2 to schema version 3 with one-time baseline invalidation and preserved data/cursors; test receipt/quote repair and subsequent cache reuse.
- [x] Add safe debug client API traces with server request IDs, multipart coverage and bounded diagnostics; test redaction and failure paths.
- [x] Align contracts/runbooks, run all checks/builds and independent service tests, review the final diff, and record current results.

## Offline cached conversations

- [x] Restore saved sessions and render cached sent/sending/failed messages before waiting for HTTP.
- [x] Keep cached history, reply navigation, Return to Latest, contacts and the composer available while recovery is pending or failing.
- [x] Persist pending draft inbox entries across restart/full sync and remap all pending rows atomically on REST or socket acknowledgement.
- [x] Preserve confirmed sends when their REST response is lost, late navigation/session fences, and the current historical viewport.
- [x] Retry unfinished network recovery automatically and through Sync now/resume without accumulating pending requests.
- [x] Exclude local drafts from server room-pagination counts and cursors.
- [x] Verify both existing Web clients with the API stopped, including a failed send surviving reload and cached contact selection.
- [x] Complete the final formatter, analyzer, full Flutter suite and builds, and record the evidence boundaries.

## Full debug traffic logging

- [x] Add one backend traffic service with independent full-payload and HTTP switches, UTC timestamps, trusted user IDs and request correlation.
- [x] Capture complete HTTP JSON, parameters, queries and headers while excluding OPTIONS, credentials and binary bytes.
- [x] Record exact realtime publication data, actor/recipient IDs, stable publication IDs, retry attempts and provider outcomes without changing delivery behavior.
- [x] Add a debug-only Flutter runtime switch, full HTTP/realtime records and per-user counts over an immutable 60-record window.
- [x] Preserve initiating session identity across account switches, and clear/invalidate full capture when disabled.
- [x] Document manual startup, filtering/counting commands and optional self-hosted open-source log search.
- [x] Complete final formatting, analysis/type checks, regression/service tests, builds, browser toggle verification and evidence review.

## Redis debugging inspector

- [x] Select and install a pinned open-source Redis browser without adding application dependencies or Docker.
- [x] Provide a reusable local launcher with read-only commands/forms, loopback binding, private in-memory connection settings and clean foreground shutdown.
- [x] Document user room JSON, sync counters, presence/session digests, TTLs and the relationship to HTTP/realtime logs.
- [x] Repair the upstream npm-hoisted JSON viewer assets without editing vendor source, and cover repeated setup/preservation of existing files.
- [x] Verify the actual browser JSON tree, meta hashes and sorted-set scores; reject mutations and confirm sampled application data is unchanged.
- [x] Run syntax/format checks, all 12 launcher tests, actual install/start/stop/restart and final scope review.

## Flutter event/state/Drift inspector

- [x] Add opt-in, debug-only bounded metadata traces with captured user/session/room identity, causal spans and safe immutable export.
- [x] Instrument controller actions, HTTP/realtime, inbox serialization, Drift queries/transactions/watch emissions, state notifications and principal screen builds.
- [x] Preserve independent callback identity across login, Clear and off/on without resurrecting cleared asynchronous operations.
- [x] Add responsive timeline filters/details, slow-operation summaries, live resource sampling, widget counters and native frame summaries.
- [x] Cover failures, bounds, privacy, causal attribution, queue/subscription cleanup, manual sampling, notification loops and narrow layouts.
- [x] Document Chrome/Flutter DevTools heap and representative performance profiling, and distinguish resource counts from leak proof.
- [x] Run formatting, analysis, all 221 Flutter tests and Web/debug-APK builds.
- [x] Verify the actual accessible capture controls, filtered/exported causal records and resource/frame panels in the existing Web sessions; preserve API manual control and capture a preview.

## Backend log presentation and exports

- [x] Preserve structured/redacted HTTP and realtime capture while adding compact UTC/user/request terminal summaries.
- [x] Provide independent pretty/JSON/silent console modes and private append-only JSONL output with bounded asynchronous writes and safe shutdown.
- [x] Add a manual debug startup command without taking control of the persistent API.
- [x] Install the pinned open-source viewer, secure its local access boundary and configure useful traffic columns.
- [x] Verify collapsible JSON, request correlation, JSON table export and pause/resume with live file following in the actual browser; record upstream export limitations.
- [x] Run all relevant backend/tool checks and record validation and privacy/retention limits.

## Local read-only backend logs MCP

- [x] Add an isolated typed MCP package with the official SDK and host-owned stdio lifecycle.
- [x] Expose only `search_logs`, `trace_request` and `error_summary`, with strict schemas and read-only annotations.
- [x] Restrict queries to one configured capture, preserve files/permissions and handle missing or unsafe files without creating them.
- [x] Bound scans, records, responses and concurrency; report skipped/incomplete coverage and support older-snapshot cursors.
- [x] Test actual legacy/current stdio clients, metadata/payload selection, correlation/retry semantics and error classification.
- [x] Complete pagination/size-limit review, full tool checks and read-only calls against the existing capture.
- [x] Register the verified local server for the AI host and document connection/coverage/privacy limits.

## Unified local observability

- [x] Install checksum-pinned native Vector and provide local file fan-in, checkpoints, transforms and bounded output buffering.
- [x] Preserve the existing Logdy and MCP launch commands, selecting the shared capture when available.
- [x] Export original debug Flutter inspector events through an opt-in bounded browser transport, including explicit metric snapshots and delivery counters.
- [x] Add independent metadata-only Redis/MongoDB/Centrifugo client diagnostics without changing commands, publication retries or HTTP results.
- [x] Tail available native Redis/MongoDB logs with credential filtering and support an explicit Centrifugo file without restarting existing services.
- [x] Extend MCP source filters, generic failure summaries and source/instance-scoped causal traces while retaining fixed-file/read-only bounds.
- [x] Verify actual Vector normalization/redaction, backend live-service integration, both Flutter Web exporters, Logdy details and real stdio MCP queries.
- [x] Record startup, manual API restart/MCP reconnect requirements, native Centrifugo coverage gap and best-effort/privacy limits.

## Activate and verify the shared local capture

- [x] Restart the persistent backend with the user's explicit authorization and verify live MongoDB/Redis health and new diagnostics.
- [x] Attach native Centrifugo file logging, preserve its private configuration and verify JWT/WebSocket own-channel authorization after restart.
- [x] Discover the workspace Centrifugo log by default on future collector starts and add a regression covering missing/default/override/off cases.
- [x] Verify fresh records from all five sources without replay, including two real Flutter Sync now flows correlated with backend/Redis/MongoDB operations.
- [x] Verify all five sources, native Centrifugo and causal traces through a fresh AI host's provided MCP tools.
- [x] Refresh this chat's pre-existing MCP connection after the user's desktop restart; verify all four tools and complete five-source browser mutation traces through this chat's own provided tools.
- [x] Add searchable service operation names and command/connection categories; distinguish the displayed operation from the raw event kind in Logdy.
- [x] Preserve explicit native log severity over message keywords; verify the live Centrifugo rejection probe remains informational through Vector and this chat's MCP.
- [x] Verify the installed Logdy bridge delivers new records beyond its bounded ring capacity; document browser pause/backfill and viewport limits.
