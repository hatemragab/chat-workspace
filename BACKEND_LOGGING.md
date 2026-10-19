# Backend logs: compact terminal and expandable viewer

The backend keeps its existing structured HTTP and realtime records. Development terminals now show two compact lines per event instead of printing entire JSON bodies. The full UTC timestamp, status, route, duration, user ID and request ID stay visible. Realtime summaries also identify the actor, recipient, publication and retry attempt. TTYs use color; `NO_COLOR` disables it.

For expandable JSON, search, filters and export, the workspace uses [Logdy](https://github.com/logdyhq/logdy-core), an Apache-2.0 open-source log viewer. There is no hosted collector, Docker container or application database involved.

## Start

From `backend/`, install the viewer once:

```sh
npm run logs:install
```

In one terminal, start the viewer:

```sh
npm run logs
```

Open [the local log viewer](http://127.0.0.1:8082/). In another terminal, start the API yourself:

```sh
npm run start:debug
```

`start:dev` and `start:debug` use the existing `ts-node` backend entrypoint. It defaults to compact terminal output, HTTP/full-debug capture and the ignored private file `.runtime/backend-logs/traffic.jsonl`. Explicit settings from the shell take precedence over `backend/.env`, then these defaults apply. The viewer waits for appended lines and does not start, stop or restart the API. Existing application data is untouched.

Normal `npm run start:dev` remains available: development console output is pretty, but file capture is off unless configured. Start/restart a running API manually to load these changes.

## Inspect a request

The initial table exposes Cairo time, severity, event, method, route, status, duration and actor user ID. Cairo time displays in 12-hour format as `DD hh:mm:ss AM/PM` (for example, `18 09:42:01 PM`) using `Africa/Cairo`, including daylight-saving changes; raw records retain their complete UTC timestamps and sorting keeps millisecond precision. Filter facets distinguish HTTP completions from realtime publication attempts, users, recipients and request IDs. Customize visible columns or widths as needed.

Select a row to open its detail drawer. Show the raw message to see the full structured record; click JSON brackets to expand or collapse nested objects and arrays. Request/response bodies and headers are captured with credentials redacted when full capture is enabled and the record fits the bounded envelope; oversized content has explicit omission metadata. Binary data uses metadata. Follow/pause controls let you stop the moving list while examining a request.

Use the same `requestId` to follow an HTTP completion and the publications it caused. `recipientUserId`, `publicationId` and `attempt` distinguish recipient fanout and retries. Provider success means the provider accepted the publication; client receipt is a separate event. OPTIONS preflights remain excluded.

Use Logdy's **Export** controls to download the selected table values. Its JSON option produces JSONL in a `.json` download; **Full row** includes hidden configured columns, not the original nested record. Use the private `traffic.jsonl` file for retained original structured records, including records that have rolled out of the viewer's bounded buffers. Capture flags, omissions, queue losses and archive retention still bound that evidence. CSV is also available for table columns, but the pinned upstream version has limited quote escaping; prefer JSON for custom values containing quotation marks. Existing captures can be viewed from the workspace root:

```sh
node scripts/backend-logs.mjs start --file /absolute/path/to/private-capture.jsonl
```

The viewer displays existing input as well as new lines. Input must be JSONL from a trusted, already-redacted capture; Logdy itself does not redact arbitrary imported files.

## Live outbound queue and recovery

Enable **Capture Flutter events** and **Share inspector with local logs** in the
Flutter inspector. Full traffic logging is not required for queue diagnostics.
In Logdy's search field, enter the following expression and press Enter:

```text
data.category in ("outbox", "health")
```

The **Result** and **What happened** columns show saved, sending, HTTP attempt,
waiting for backend readiness, scheduled retry, rejected, needs attention,
acknowledged and empty states. State records include current queued, failed and
attention counts automatically. A genuine failed-readiness-to-ready transition
shows **recovered**; an ordinary initial success shows **ready**. Operation IDs,
attempts, reasons, retry deadlines and counts are available as facets and in the
row drawer. **Session HTTP attempts** is cumulative for that queue instance;
**Attempt** and **Retry count** describe the current operation's bounded attempt
budget. Existing older records retain their original metadata and may have
fewer fields.

Keep one Logdy page open per origin. Upstream pages share browser storage and
warn repeatedly if another page is active; closing duplicate viewers does not
delete the persistent capture. A full page reload starts paused, so use
**Resume incoming messages, starting with the latest** to follow fresh activity,
or **Resume incoming messages where paused** for retained backlog. Reconnecting
an already-following page now preserves following automatically; an explicit
Pause remains paused. This compatibility fix verifies and rewrites only the
pinned v0.17.1 browser asset at the local proxy boundary. Updating Logdy requires
reviewing that verified asset; its module cache is unchanged. Reconnection is a
bounded live view, not a replacement for retained JSONL/MCP history.

The browser's persisted log cache has a separate 2 MiB budget (UTF-16 keys and
JSON values). It evicts oldest cached log rows before settings initialize and
uses an in-memory fallback if storage is full or unavailable. This prevents
quota errors from stopping live intake or saving filters. Layout and application
settings are preserved; the 10,000-row live-view and server-ring upper bounds and
the persistent JSONL capture are unchanged. Reloaded browser history can contain
fewer rows than the live view.

## Choose console and file output independently

| Setting                                         | Behavior                                                                                                       |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `TRAFFIC_LOG_FORMAT=pretty`                     | Compact two-line summaries; default in development, including IDE terminals.                                   |
| `TRAFFIC_LOG_FORMAT=json`                       | Original one-line structured JSON for pipes and collectors; default outside development.                       |
| `TRAFFIC_LOG_FORMAT=silent`                     | Suppress traffic console output; configured file capture continues.                                            |
| `TRAFFIC_LOG_FILE=/absolute/path/traffic.jsonl` | Append structured records asynchronously. Relative paths resolve from the backend process's working directory. |
| `TRAFFIC_LOG_FILE=off` or unset                 | Disable file capture. `start:dev` and `start:debug` supply the workspace default when unset.                                 |
| `HTTP_LOGGING_ENABLED=false`                    | Suppress HTTP completion traffic logs; request correlation still works.                                        |
| `DEBUG_TRAFFIC_LOGGING_ENABLED=true`            | Request complete redacted HTTP JSON and realtime publish attempts; effective in development only by default.   |
| `ALLOW_PRODUCTION_DEBUG_TRAFFIC_LOGGING=true`   | Explicit production operational override, also requiring the debug flag; startup records expose the policy.    |

For example, keep a quiet terminal while capturing full traffic:

```sh
TRAFFIC_LOG_FORMAT=silent npm run start:debug
```

Or use normal startup with a chosen file:

```sh
TRAFFIC_LOG_FORMAT=pretty \
TRAFFIC_LOG_FILE=../.runtime/backend-logs/traffic.jsonl \
HTTP_LOGGING_ENABLED=true DEBUG_TRAFFIC_LOGGING_ENABLED=true \
npm run start:dev
```

Settings are read by the backend process; changing file output requires a restart. Console output, disk failures and capture overload cannot change HTTP results or publication retries. Logging does not add any field to chat API/event payloads.

## Files, bounds and privacy

New log files use mode `0600` and new log directories use `0700`. Active captures append records; bounded rotation moves owned files into private archives and expires eligible archives under the configured retention policy. Unread input archives are preserved until acknowledged checkpoints reach their stable end. Symlinks, hard-linked targets and non-regular files are rejected. See [retention and ownership](LOCAL_OBSERVABILITY.md#rotation-archive-queries-and-diagnostic-totals); a log-only reset is a separate explicitly authorized operation.

One record must fit the shared 1 MiB envelope; oversized records produce explicit omission metadata. Private `*.status.json` sidecars expose sink queue, written/drop/failure/omission counts, last success/failure and recovery state. The protected collector health endpoint samples this metadata and observed output freshness. A healthy API or live Vector process alone does not establish a healthy capture sink.

File output admits 4 MiB of ordinary pending writes plus a 1 MiB important-only reserve. Warnings/errors, HTTP failures and failed operations can evict queued ordinary records, while the in-flight write is protected. Admitted important records retry a recoverable append failure for at most 30 seconds / 32 append attempts. Safe stable identities and delivery-attempt/previous-outcome metadata mark ambiguous replay; a reopened writer fences a torn JSONL tail before later records. The same bounded policy applies to owned native/process wrappers. Shared MongoDB/Redis files remain under their service owners.

Private sidecars and `fileStats()` separately report important pending/written/dropped/failed/uncertain records, ordinary evictions and retries. Mongo command tracking also reports bounded omission summaries and unmatched failures without inventing request identity. Important-only saturation, retry-budget exhaustion, process/OS crash and storage failure can still lose records; these paths are explicit rather than a durable audit guarantee. Oversized originals retain safe omission metadata. A fixed warning appears on stderr and shutdown drains accepted work within the retry budget. Successful app requests do not certify logging health.

The viewer retains at most 10,000 records on the server and 10,000 in its browser buffer; these are record-count limits, not byte limits. Logdy may retain local UI state and records in browser storage. Files and exports include message/application data even though credentials are redacted. Keep them private. Pausing or clearing a viewer buffer does not delete the JSONL file.

## AI access through MCP

The [Vector local collector](LOCAL_OBSERVABILITY.md) combines Flutter inspector and backend/service/native diagnostics in `.runtime/observability/events.jsonl`. Start the collector before Logdy/MCP; both select this unified file when it exists and otherwise retain the backend-file fallback. Reconnect an existing MCP session after its first creation. Logdy's Source facet separates services; `trace_events` adds explicit source/instance-scoped inspector timelines alongside the original tools below. The unified capture contains private data under the same file controls.

The local read-only server in [tools/backend-logs-mcp](tools/backend-logs-mcp/README.md) exposes five tools: `search_logs`, `trace_request`, `error_summary`, `trace_events` and `list_log_archives` over stdio. The AI host launches it without another network listener. It reads the same JSONL capture as Logdy, with validated metadata/time filters, opt-in bounded payloads, explicit scan coverage and cursors for older records. It never starts the API/viewer, modifies captures or accepts arbitrary file paths in tool arguments; archives use exact listed IDs. See the tool's README for installation, host connection instructions, examples and privacy/coverage limits. Only trusted captures already sanitized by their local producers/ingress and configured native-log transformations are supported.

## Local viewer runtime

The installer pins Logdy `v0.17.1` and builds a small adapter from the upstream Go library. Its private Unix socket has no directly exposed TCP listener. A loopback-only Node front end checks Host/Origin and cross-site requests, blocks ingestion and server-side configuration writes, and applies a local-only content policy. Layout download and browser controls remain available; upstream **Save config to server** is intentionally unavailable. Analytics and update checks are disabled.

The existing system Go installation is preserved. The current installer supports this Mac's ARM64 architecture and downloads the pinned official Go `1.27.2` archive with SHA-256 verification, then uses pinned upstream modules with Go checksum verification. Toolchains, module/build caches, compiled binaries, layouts and diagnostics live under ignored `.runtime/backend-log-viewer/`; application dependencies do not change. Stop the foreground viewer with Ctrl-C. It closes its own proxy, adapter and socket.

This local development boundary is separate from production authentication. The logging integration itself changes no chat API routes, schemas or authorization rules; application changes are documented in [the backend specification](BACKEND_SPEC.md). The [Zalando guideline preflight](https://opensource.zalando.com/restful-api-guidelines/) on 2026-10-16 informed endpoint protection (104), compatibility (106), standard status/header behavior and keeping stack traces/private settings out of errors (177); it is not production compliance evidence.

Sources: [Logdy CLI and embedding](https://logdy.dev/docs/reference/cli), [export](https://logdy.dev/docs/explanation/features/miscellaneous), [pinned upstream library](https://github.com/logdyhq/logdy-core/tree/v0.17.1/logdy), [Go downloads](https://go.dev/dl/).
