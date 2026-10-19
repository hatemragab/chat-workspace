# Compare the same logs in Grafana and Logdy

The local comparison reads Vector's existing private output. The original collector, Logdy, MCP, API and databases keep their current configuration.

```text
Existing inputs → existing Vector → .runtime/observability/events.jsonl
                                      ├─ Logdy :8082
                                      ├─ existing read-only MCP
                                      └─ Grafana Alloy → Loki :3100 → Grafana :3001
```

Alloy also imports retained `observability/archives/events.*.jsonl` files. It preserves each original JSON line and its event timestamp, adds low-cardinality `job`, `source`, `level` and `origin` labels, and puts available request/trace/span/test-run identifiers in structured metadata. Message bodies remain in the original JSON. No extra instrumentation or database access is added. See the [official Alloy file source](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.file/) and [processing stages](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.process/).

## Open the comparison

- [Grafana dashboard](http://127.0.0.1:3001/d/chat-logs/chat-workspace-logs)
- [Existing Logdy viewer](http://127.0.0.1:8082/)

The Grafana dashboard defaults to the last 12 hours and refreshes every five seconds. Select a source and level, enter a search regex or request ID, and expand a log row for details. Clear the search box and press Enter to show all records. The chart shows rates by source, and the counter shows warnings/errors across the selected sources and time range. That counter deliberately includes both warning and error levels regardless of the log table's level filter. Both views use Cairo time; raw timestamps remain unchanged. Use Grafana's time picker to revisit older records. Logdy's browser window remains limited to its current buffer.

The log panel initially retrieves at most 1,000 entries. This display limit does not limit stored history. Narrow the time range/search when investigating dense periods. The dashboard links back to Logdy and to Grafana Explore for LogQL queries.

## Verified comparison on 2026-10-17

The read-only check matched **80,249 records** across the active capture and one retained archive: backend 5,799; Flutter 30,962; Redis 7,247; MongoDB 27,961; Centrifugo 8,280. Exact original JSON samples matched for all five sources, Grafana's data-source health returned `OK`, and Alloy reported zero dropped entries. Counts continue increasing as the existing services log activity.

A new correlated `GET /health` appeared in Loki and the shared capture within 544 ms in one local observation. Browser verification found its same three backend/Redis/MongoDB records in both viewers, exercised Grafana's Redis source filter and expanded log details, and confirmed Cairo time. This single observation is not a latency benchmark. Stop/start preserved the stored history and file positions; record-count verification passed afterward.

Validation ran `node --test scripts/loki-grafana.test.mjs scripts/backend-logs.test.mjs scripts/local-logs.test.mjs`: 29 passed, one existing optional bridge test skipped, zero failed. The new four tests include native Loki/Alloy configuration validation and preservation/link checks. Prettier and `git diff --check` also passed. No backend or Flutter application code changed.

For this workspace, compare Logdy's immediate table/facets and compact summaries with Grafana's retained time-range search and charts. The latter now has the same underlying records; selecting one is primarily a workflow and operating-cost decision. CPU, memory, compression, load and production behavior have not been benchmarked.

## Install and manage

From the workspace root, install the native macOS packages once:

```sh
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install grafana loki grafana-alloy
node scripts/loki-grafana.mjs install
```

The second command installs the official signed Loki data-source plugin, pinned to `13.2.2`, into this workspace's private plugin directory. The Homebrew Grafana `13.2.4` package used in this comparison did not include that plugin. Automatic plugin installation/update is disabled; Grafana verifies its signature normally. No unsigned-plugin exception is configured. See [Grafana's Loki plugin](https://grafana.com/grafana/plugins/loki/installation/).

```sh
node scripts/loki-grafana.mjs start
node scripts/loki-grafana.mjs status
node scripts/loki-grafana.mjs stop
```

Start detaches an owned supervisor; it survives closing the invoking terminal. It validates native configuration, refuses occupied ports, waits for readiness and checks the Grafana data source. Stop signals only the verified supervisor and drains Alloy before stopping Loki. It preserves stored logs, credentials and checkpoints. No login service, Docker container, cloud account or application restart is installed. Start the existing collector separately when necessary using [the observability runbook](LOCAL_OBSERVABILITY.md).

Native versions installed for the initial comparison: Grafana `13.2.4`, Loki `3.7.8`, Alloy `1.20.1`. Homebrew formula versions can change; the launcher uses the installed native tools.

## Verify delivery

```sh
node --test scripts/loki-grafana.test.mjs
node scripts/loki-grafana-verify.mjs
```

The read-only verifier compares per-source file record counts with Loki over the captured time range, checks an exact original JSON sample from every source, checks Grafana's Loki connection and checks Alloy's dropped-entry counters. During initial import, wait for the files to drain before expecting count parity. Run against a quiet capture: concurrent appends, rotation, archive expiration, partial lines or old imported files no longer present in the retained capture can invalidate the comparison. It is a bounded diagnostic check, not an exactly-once guarantee.

Useful LogQL queries in Grafana Explore or the data-source query interface:

```logql
{job="chat-workspace"}
{job="chat-workspace",source="redis"}
{job="chat-workspace",level=~"warn|error"}
{job="chat-workspace"} |= "YOUR_REQUEST_ID"
{job="chat-workspace",source="backend"} | json | status >= 500
sum by (source) (count_over_time({job="chat-workspace"}[1h]))
```

IDs are query-time JSON fields or structured metadata, never indexed labels. See [Loki label guidance](https://grafana.com/docs/loki/latest/get-started/labels/).

## Privacy and limits

All listeners bind to `127.0.0.1`: Grafana `3001`, Loki HTTP `3100`, Loki gRPC `9096`, Alloy diagnostics `12345`. Grafana permits local anonymous read-only viewing; a generated random admin password and encryption key are stored privately. Loki and Alloy diagnostics have no authentication and rely on loopback isolation. Do not expose or forward these ports. This is a local development comparison.

All generated configuration, secrets, checkpoints, plugin files, databases, chunks and bounded process logs are under ignored `.runtime/loki-grafana/`. The supervisor sets an owner-only umask and reuses the existing private process-log writer. Usage reporting/update checks are disabled, and Alloy sends logs only to local Loki. Neither tool can restore events that the original producers never captured.

Loki uses single-node filesystem storage with a write-ahead log. Automatic Loki log expiration is disabled for this trial, so stored data grows until a separately authorized retention/cleanup decision. Existing Vector/Logdy retention is unchanged. The 14-day Loki out-of-order acceptance span accommodates the current seven-day retained capture during concurrent backfill; substantially older archives need a deliberate configuration change. Historical event timestamps can place new arrivals outside a short dashboard time window.

Alloy persists file positions and retries transient delivery failures. This trial uses its stable memory-backed delivery path; a sudden Alloy/process failure can lose an in-flight batch or replay records, and archive discovery after rotation can reread an archive. Identical timestamp/line entries may be deduplicated by Loki. It is not a durable exactly-once ledger. See [Alloy delivery/retry behavior](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.write/). No changes are made to the existing collector's pinned minimal Vector build.

This verifies local ingestion, history queries and browser usability. It does not establish production capacity, distributed durability, alert delivery or a CPU/compression benchmark. Existing MCP still queries the JSONL capture; a Loki MCP integration is outside this comparison.
