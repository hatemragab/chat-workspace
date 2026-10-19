import http from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { ensureLogFile } from "./backend-logs.mjs";
import { RotatingJsonlWriter, retentionPolicy } from "./log-retention.mjs";
import { sqliteLogDetails } from "./sqlite-log-details.mjs";
import { httpLogDetails } from "./http-log-details.mjs";
import { realtimeLogDetails } from "./realtime-log-details.mjs";

const maximumBody = 256 * 1024;
const batchIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const inspectorDeliveryPolicy = Object.freeze({
  deduplicationWindowMs: 2 * 60 * 1000,
  deduplicationLimit: 16384,
});
const labelPattern = /^[a-zA-Z0-9_./:#<>\[\]-]+$/;
const metadataKeys = new Set(
  `stage correlationKey channel method path route status statusCode errorType reason source eventType requestId pts roomPts msgPts localPts messagesSyncedPts lastHistoryEditPts sincePts targetPts epoch count rows roomCount messageCount cached cacheHit operation table transactionId connectionState attempt operationId enqueueOrder retryCount nextRetryAt physicalAttempts sessionPhysicalAttempts outcomeUnknown queued failed paused queuedCount failedCount pausedCount running queuePaused healthStatus previousStatus queueDepth pendingCount historyEdited recovered fullSync widget bytes microseconds durationMs outcome busy initialized isJumpMode hasMoreMessages selectedRoomId userChanged changed notificationId changedFields socketSubscriptions roomsSubscription messagesSubscription roomEventsSubscription presenceTimer highlightTimer lifecycleObserver roomRecoveries draftAdoptions directLookups sessionStopping roomId userId sessionGeneration argumentCount rowCount affectedRows statementCount executionCount watch limit generation pending invalidated fromPts toPts mode epochMatches hasRoom hasMessage`.split(
    " ",
  ),
);
for (const key of ["direction", "protocolId", "connectionId", "packetBytes"])
  metadataKeys.add(key);
const topKeys = new Set(
  `seq timestamp category name phase traceId spanId parentSpanId userId sessionGeneration roomId durationMicros data source event level requestId metricName metricValue metricGroup`.split(
    " ",
  ),
);
export const localLogOrigins = [
  "http://localhost:5173",
  "http://localhost:5174",
  "http://127.0.0.1:5173",
  "http://127.0.0.1:5174",
];

function label(value, { nullable = false, maximum = 128 } = {}) {
  if (nullable && value == null) return null;
  if (
    typeof value !== "string" ||
    !value ||
    value.length > maximum ||
    !labelPattern.test(value) ||
    /\beyJ[\w-]+\.eyJ[\w-]+\.[\w-]+\b/.test(value)
  )
    throw new Error("Invalid metadata.");
  return value;
}

function metadata(value, depth = 0, budget = { remaining: 80 }) {
  if (!value || typeof value !== "object" || Array.isArray(value) || depth >= 3)
    return {};
  const result = {};
  for (const [key, item] of Object.entries(value)) {
    if (budget.remaining-- <= 0) break;
    if (!metadataKeys.has(key)) continue;
    if (
      item === null ||
      typeof item === "boolean" ||
      (typeof item === "number" && Number.isFinite(item))
    )
      result[key] = item;
    else if (typeof item === "string") {
      try {
        result[key] = label(item, { maximum: 120 });
      } catch {
        /* Free-form values are deliberately excluded. */
      }
    } else if (Array.isArray(item)) {
      result[key] = item.slice(0, 24).flatMap((entry) => {
        if (budget.remaining-- <= 0) return [];
        if (typeof entry === "string") {
          try {
            return [label(entry, { maximum: 120 })];
          } catch {
            return [];
          }
        }
        return (typeof entry === "number" && Number.isFinite(entry)) ||
          typeof entry === "boolean"
          ? [entry]
          : [];
      });
    } else if (typeof item === "object")
      result[key] = metadata(item, depth + 1, budget);
  }
  return result;
}

/** Fixed presentation over sanitized identifiers and counts, never payloads. */
function outboundPresentation(record) {
  if (!["outbox", "health"].includes(record.category)) return;
  const data = record.data;
  for (const key of [
    "operationId",
    "reason",
    "healthStatus",
    "previousStatus",
  ]) {
    if (typeof data[key] === "string") record[key] = data[key];
  }
  for (const key of [
    "attempt",
    "enqueueOrder",
    "retryCount",
    "sessionPhysicalAttempts",
    "queuedCount",
    "failedCount",
    "pausedCount",
  ]) {
    if (Number.isSafeInteger(data[key]) && data[key] >= 0)
      record[key] = data[key];
  }
  for (const key of ["outcomeUnknown", "recovered", "running", "queuePaused"]) {
    if (typeof data[key] === "boolean") record[key] = data[key];
  }
  if (
    typeof data.nextRetryAt === "string" &&
    /^\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)$/.test(data.nextRetryAt) &&
    Number.isFinite(Date.parse(data.nextRetryAt))
  ) {
    record.nextRetryAt = new Date(data.nextRetryAt).toISOString();
  }
  if (record.category === "health") {
    const states = {
      checking: ["checking", "Checking backend /health"],
      unavailable: ["offline", "Backend unavailable; waiting for /health"],
      ready:
        record.recovered === true
          ? ["recovered", "Backend recovered; queued sends can resume"]
          : ["ready", "Backend ready"],
    };
    const [result, summary] = Object.hasOwn(states, record.name)
      ? states[record.name]
      : ["changed", "Backend readiness changed"];
    record.result = result;
    record.summary = `${summary}.`;
    return;
  }
  const states = {
    enqueued: ["queued", "Outbox message saved"],
    attempt: ["sending", "Outbox sending"],
    http_attempt: ["sending", "Outbox HTTP attempt"],
    acknowledged: ["sent", "Outbox server acknowledgment saved"],
    rejected: [
      "failed",
      "Outbox request rejected; continuing with next message",
    ],
    needs_attention: [
      "needs_attention",
      "Outbox needs attention; automatic retries stopped",
    ],
    head_paused: [
      "needs_attention",
      "Outbox head paused; waiting for acknowledgment or manual retry",
    ],
    waiting_for_server: [
      "offline",
      "Outbox waiting for backend /health recovery",
    ],
    waiting: ["waiting", "Outbox retry scheduled"],
    paused: ["paused", "Outbox paused"],
    empty: ["idle", "Outbox empty"],
    attempt_finished: ["finished", "Outbox attempt finished"],
    send:
      record.level === "error" || data.errorType
        ? ["attempt_failed", "Outbox send attempt failed"]
        : [
            record.phase === "begin" ? "sending" : "finished",
            "Outbox send attempt",
          ],
  };
  const [result, description] = Object.hasOwn(states, record.name)
    ? states[record.name]
    : ["changed", "Outbox state changed"];
  const details = [];
  if (record.queuedCount != null) details.push(`queued ${record.queuedCount}`);
  if (record.failedCount != null) details.push(`failed ${record.failedCount}`);
  if (record.pausedCount != null)
    details.push(`attention ${record.pausedCount}`);
  if (record.attempt > 0) details.push(`attempt ${record.attempt}`);
  if (record.reason) details.push(`reason ${record.reason}`);
  if (record.nextRetryAt) details.push(`retry at ${record.nextRetryAt}`);
  record.result = result;
  record.summary = `${description}${details.length ? "; " + details.join(", ") : ""}.`;
}

/** The browser may submit inspector metadata, never forge another service. */
export function inspectorBatch(value, captureId) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).some(
      (key) => !["instanceId", "batchId", "events"].includes(key),
    )
  )
    throw new Error("Invalid batch.");
  const instanceId = label(value.instanceId);
  if (
    Object.hasOwn(value, "batchId") &&
    (typeof value.batchId !== "string" || !batchIdPattern.test(value.batchId))
  )
    throw new Error("Invalid batch identity.");
  if (
    !Array.isArray(value.events) ||
    !value.events.length ||
    value.events.length > 50
  )
    throw new Error("Invalid batch size.");
  return value.events.map((event) => {
    if (
      !event ||
      typeof event !== "object" ||
      Array.isArray(event) ||
      Object.keys(event).some((key) => !topKeys.has(key))
    )
      throw new Error("Invalid event.");
    if (
      event.source !== "flutter" ||
      event.event !== "flutter_inspector" ||
      !["info", "warn", "error"].includes(event.level)
    )
      throw new Error("Invalid event source.");
    if (
      typeof event.timestamp !== "string" ||
      !/^\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)$/.test(event.timestamp) ||
      !Number.isFinite(Date.parse(event.timestamp))
    )
      throw new Error("Invalid event time.");
    if (
      !Number.isSafeInteger(event.seq) ||
      event.seq < 1 ||
      !["begin", "end", "instant"].includes(event.phase)
    )
      throw new Error("Invalid event sequence.");
    for (const key of ["durationMicros", "sessionGeneration"])
      if (
        event[key] != null &&
        (!Number.isSafeInteger(event[key]) || event[key] < 0)
      )
        throw new Error("Invalid numeric metadata.");
    const record = {
      source: "flutter",
      event: "flutter_inspector",
      level: event.level,
      timestamp: new Date(event.timestamp).toISOString(),
      receivedAt: new Date().toISOString(),
      origin: "inspector",
      instanceId,
      ...(value.batchId ? { batchId: value.batchId.toLowerCase() } : {}),
      captureId,
      seq: event.seq,
      category: label(event.category),
      name: label(event.name),
      phase: event.phase,
      requestId: label(event.requestId, { nullable: true }),
      userId: label(event.userId, { nullable: true }),
      roomId: label(event.roomId, { nullable: true }),
      traceId: label(event.traceId, { nullable: true }),
      spanId: label(event.spanId, { nullable: true }),
      parentSpanId: label(event.parentSpanId, { nullable: true }),
      sessionGeneration: event.sessionGeneration ?? null,
      durationMicros: event.durationMicros ?? null,
      data: metadata(event.data),
    };
    const deliveryStages = {
      "publication.received": "client_received",
      "publication.applied": "inbox_applied",
      "publication.covered": "already_covered",
    };
    if (
      record.category === "realtime" &&
      deliveryStages[record.name] &&
      typeof record.data.epoch === "string" &&
      Number.isSafeInteger(record.data.pts) &&
      record.data.pts >= 0 &&
      record.userId
    ) {
      record.stage = deliveryStages[record.name];
      record.epoch = record.data.epoch;
      record.pts = record.data.pts;
      record.channel = `inbox:user#${record.userId}`;
      record.recipientUserId = record.userId;
      record.correlationKey = `inbox:${record.userId}:${record.epoch}:${record.pts}`;
      record.eventType = record.data.eventType;
      if (typeof record.data.roomId === "string")
        record.roomId = record.data.roomId;
      record.result =
        record.stage === "already_covered" ? "covered" : "success";
      record.summary = `${record.stage}: ${record.eventType ?? "inbox publication"} at pts ${record.pts}.`;
    }
    const socket =
      /^socket\.(send|receive)\.(connect|subscribe|unsubscribe|publish|presence|presence_stats|history|rpc|refresh|sub_refresh|send|ping|pong|error|publication|join|leave|disconnect|message|push|reply)$/.exec(
        record.name,
      );
    if (
      record.category === "realtime" &&
      record.phase === "instant" &&
      socket &&
      record.data.direction === socket[1] &&
      record.data.operation === socket[2]
    ) {
      const [, direction, operation] = socket;
      const details = realtimeLogDetails(
        event.data?.realtime,
        direction,
        operation,
      );
      if (details) record.data.realtime = details;
      record.direction = direction;
      record.operation = operation;
      record.connectionId = record.data.connectionId;
      record.protocolId = record.data.protocolId;
      record.channel = record.data.channel;
      record.result = direction === "send" ? "send_attempt" : "received";
      record.summary = `Realtime ${direction} ${operation.toUpperCase()}${record.channel ? ` on ${record.channel}` : ""}${record.protocolId > 0 ? ` (command ${record.protocolId})` : ""}.`;
    }
    outboundPresentation(record);
    if (event.durationMicros != null)
      record.durationMs = event.durationMicros / 1000;
    if (
      record.category === "http" &&
      record.phase === "end" &&
      /^(GET|POST|PUT|PATCH|DELETE|HEAD|CONNECT|TRACE):\//.test(record.name)
    ) {
      const details = httpLogDetails(event.data?.http);
      if (details) record.data.http = details;
      record.method = record.data.method;
      record.route = record.data.route;
      record.status = record.data.status;
      record.result = record.data.errorType
        ? "failure"
        : record.data.outcome === "cancel"
          ? "cancelled"
          : "success";
      record.summary = `${record.method ?? "HTTP"} ${record.route ?? record.name}: ${record.status ?? record.data.outcome ?? "completed"}.`;
    }
    if (
      record.category === "drift" &&
      /^query\.(select|insert|update|delete|custom|batch)$/.test(record.name)
    ) {
      const operation = record.name.slice("query.".length);
      const details = sqliteLogDetails(event.data?.sqlite, operation);
      if (details) record.data.sqlite = details;
      record.databaseName = "chat_app_db";
      record.collection =
        typeof record.data.table === "string" ? record.data.table : undefined;
      record.result = record.data.errorType
        ? "failure"
        : record.data.outcome === "cancelled"
          ? "cancelled"
          : record.phase === "end"
            ? "success"
            : "started";
      record.summary = `SQLite ${operation.toUpperCase()}${record.collection ? ` ${record.collection}` : ""}: ${record.result}${typeof record.data.rowCount === "number" ? `, ${record.data.rowCount} rows` : ""}${typeof record.data.affectedRows === "number" ? `, ${record.data.affectedRows} affected` : ""}.`;
    }
    if (
      ["metricName", "metricValue", "metricGroup"].some(
        (key) => event[key] != null,
      )
    ) {
      if (
        record.category !== "inspector" ||
        !record.name.startsWith("metric.") ||
        typeof event.metricValue !== "number" ||
        !Number.isFinite(event.metricValue)
      )
        throw new Error("Invalid metric metadata.");
      record.metricName = label(event.metricName);
      record.metricGroup = label(event.metricGroup);
      record.metricValue = event.metricValue;
    }
    return record;
  });
}

/** Minimal browser transport into Vector's file source; no collection/query logic. */
export async function startLocalLogIngress({
  file,
  port = 8083,
  origins = localLogOrigins,
  captureId = randomUUID(),
  retention = retentionPolicy(),
  healthDetails = () => ({}),
  now = Date.now,
  deduplicationWindowMs = inspectorDeliveryPolicy.deduplicationWindowMs,
  deduplicationLimit = inspectorDeliveryPolicy.deduplicationLimit,
}) {
  if (
    !Number.isSafeInteger(deduplicationWindowMs) ||
    deduplicationWindowMs < 1 ||
    !Number.isSafeInteger(deduplicationLimit) ||
    deduplicationLimit < 1 ||
    deduplicationLimit > inspectorDeliveryPolicy.deduplicationLimit
  )
    throw new Error("Invalid delivery budget.");
  await ensureLogFile(file);
  const handle = await new RotatingJsonlWriter(file, retention).open();
  let host;
  let pendingBytes = 0;
  let pendingBatches = 0;
  let chain = Promise.resolve();
  let closing = false;
  const counters = {
    acceptedEvents: 0,
    rejectedBatches: 0,
    failedBatches: 0,
    deduplicatedBatches: 0,
    deduplicatedEvents: 0,
    idempotencyConflicts: 0,
    idempotencyBusy: 0,
    retriedBatches: 0,
    uncertainWriteBatches: 0,
  };
  // A receipt becomes reusable only after its complete input-file write. Keep
  // pending receipts too, so concurrent retries share the same write. Never
  // evict an unexpired receipt to admit another: reject with retryable 503.
  const receipts = new Map();
  const pruneReceipts = () => {
    const time = now();
    for (const [key, receipt] of receipts)
      if (receipt.expiresAt <= time) receipts.delete(key);
  };
  const connections = new Set();
  const server = http.createServer(async (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    const finish = (status, value) => {
      if (response.destroyed || response.writableEnded) return;
      response.writeHead(status, {
        "Content-Type":
          status >= 400 ? "application/problem+json" : "application/json",
      });
      response.end(
        JSON.stringify(
          status >= 400 ? { type: "about:blank", title: value, status } : value,
        ),
      );
    };
    if (request.headers.host !== host) return finish(403, "Local access only");
    const origin = request.headers.origin;
    if (origin && !origins.includes(origin))
      return finish(403, "Origin not allowed");
    if (
      !origin &&
      request.headers["sec-fetch-site"] &&
      request.headers["sec-fetch-site"] !== "none"
    )
      return finish(403, "Origin required");
    if (origin) {
      response.setHeader("Access-Control-Allow-Origin", origin);
      response.setHeader("Vary", "Origin");
    }
    if (request.url === "/health" && request.method === "GET") {
      pruneReceipts();
      return finish(200, {
        status: "ok",
        captureId,
        ...counters,
        pendingBatches,
        pendingBytes,
        idempotencyEntries: receipts.size,
        deduplicationWindowMs,
        deduplicationLimit,
        ...healthDetails(),
      });
    }
    if (request.url !== "/events") return finish(404, "Resource not found");
    if (request.method === "OPTIONS") {
      if (
        !origin ||
        request.headers["access-control-request-method"] !== "POST" ||
        (request.headers["access-control-request-headers"] ?? "")
          .split(",")
          .some(
            (key) => key.trim() && key.trim().toLowerCase() !== "content-type",
          )
      )
        return finish(403, "Preflight not allowed");
      response.setHeader("Access-Control-Allow-Methods", "POST");
      response.setHeader("Access-Control-Allow-Headers", "Content-Type");
      response.writeHead(204);
      response.end();
      return;
    }
    if (request.method !== "POST") {
      response.setHeader("Allow", "POST, OPTIONS");
      return finish(405, "Method not allowed");
    }
    if (
      !/^application\/json(?:\s*;|$)/i.test(
        request.headers["content-type"] ?? "",
      )
    )
      return finish(415, "JSON required");
    if (closing || pendingBatches >= 8 || pendingBytes >= 1024 * 1024) {
      response.setHeader("Retry-After", "1");
      return finish(503, "Capture busy");
    }
    const chunks = [];
    let bytes = 0;
    try {
      if (Number(request.headers["content-length"] ?? 0) > maximumBody)
        return finish(413, "Batch too large");
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > maximumBody) return finish(413, "Batch too large");
        chunks.push(chunk);
      }
      const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const records = inspectorBatch(input, captureId);
      const receiptKey = input.batchId
        ? `${input.instanceId}:${input.batchId.toLowerCase()}`
        : null;
      // receivedAt is an observation of this attempt, not part of its identity.
      const fingerprint = receiptKey
        ? createHash("sha256")
            .update(
              JSON.stringify(
                records.map(({ receivedAt: _receivedAt, ...record }) => record),
              ),
            )
            .digest("hex")
        : null;
      pruneReceipts();
      const existing = receiptKey && receipts.get(receiptKey);
      if (existing) {
        if (existing.fingerprint !== fingerprint) {
          counters.idempotencyConflicts++;
          return finish(409, "Batch identity already used");
        }
        if (existing.state !== "failed") {
          try {
            await existing.write;
            counters.deduplicatedBatches++;
            counters.deduplicatedEvents += records.length;
            return finish(202, { accepted: records.length });
          } catch {
            return finish(503, "Capture unavailable");
          }
        }
      }
      if (receiptKey && !existing && receipts.size >= deduplicationLimit) {
        counters.idempotencyBusy++;
        response.setHeader("Retry-After", "1");
        return finish(503, "Capture receipts busy");
      }
      const attempt = (existing?.attempt ?? 0) + 1;
      if (receiptKey) {
        for (const record of records) {
          record.logDeliveryAttempt = attempt;
          if (existing?.outcome)
            record.logPreviousWriteOutcome = existing.outcome;
          record.data = {
            ...record.data,
            logDelivery: {
              batchId: record.batchId,
              logDeliveryAttempt: attempt,
              logPreviousWriteOutcome: existing?.outcome ?? "not_attempted",
            },
          };
        }
      }
      const encoded =
        records.map((record) => JSON.stringify(record)).join("\n") + "\n";
      const size = Buffer.byteLength(encoded);
      if (closing || pendingBatches >= 8 || pendingBytes + size > 1024 * 1024)
        return finish(503, "Capture busy");
      pendingBatches++;
      pendingBytes += size;
      const write = chain.then(() => handle.write(encoded));
      chain = write.catch(() => {});
      const receipt = {
        fingerprint,
        write,
        expiresAt: Infinity,
        attempt,
        state: "pending",
      };
      if (receiptKey) receipts.set(receiptKey, receipt);
      if (existing) counters.retriedBatches++;
      try {
        await write;
        receipt.expiresAt = now() + deduplicationWindowMs;
        receipt.state = "accepted";
        counters.acceptedEvents += records.length;
        finish(202, { accepted: records.length });
      } catch (error) {
        receipt.state = "failed";
        receipt.expiresAt = now() + deduplicationWindowMs;
        receipt.outcome =
          error?.logWriteOutcome === "not_written"
            ? "not_written"
            : "uncertain";
        if (receipt.outcome === "uncertain") counters.uncertainWriteBatches++;
        counters.failedBatches++;
        finish(503, "Capture unavailable");
      } finally {
        pendingBatches--;
        pendingBytes -= size;
      }
    } catch {
      counters.rejectedBatches++;
      finish(400, "Invalid inspector batch");
    }
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  server.maxHeadersCount = 32;
  server.maxConnections = 16;
  server.on("connection", (socket) => {
    connections.add(socket);
    socket.once("close", () => connections.delete(socket));
  });
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, "127.0.0.1", resolve);
    });
  } catch {
    await handle.close();
    throw new Error("Could not bind local ingestion port.");
  }
  host = `127.0.0.1:${server.address().port}`;
  let closed;
  return {
    url: `http://${host}/events`,
    server,
    captureId,
    close() {
      return (closed ??= (async () => {
        closing = true;
        for (const socket of connections) socket.destroy();
        await new Promise((resolve) => server.close(resolve));
        await chain;
        await handle.close();
      })());
    },
  };
}
