import assert from "node:assert/strict";
import http from "node:http";
import {
  link,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  inspectorBatch,
  inspectorDeliveryPolicy,
  localLogOrigins,
  startLocalLogIngress,
} from "./local-logs-ingress.mjs";
import { RotatingJsonlWriter } from "./log-retention.mjs";
import { httpDetailLimit } from "./http-log-details.mjs";
import { realtimeDetailLimit } from "./realtime-log-details.mjs";

function event(overrides = {}) {
  return {
    source: "flutter",
    event: "flutter_inspector",
    level: "info",
    seq: 1,
    timestamp: "2026-10-17T12:30:00+03:00",
    category: "realtime",
    name: "inbox.publication",
    phase: "end",
    traceId: "t19",
    spanId: "s21",
    parentSpanId: "s20",
    userId: "user-one",
    roomId: "room-two",
    sessionGeneration: 3,
    durationMicros: 265300,
    requestId: "request-three",
    data: { pts: 42, count: 2 },
    ...overrides,
  };
}
function batch(events = [event()]) {
  return { instanceId: "flutter-tab-one", events };
}

function socketEvent(direction, operation, payload, overrides = {}) {
  return event({
    category: "realtime",
    name: `socket.${direction}.${operation}`,
    phase: "instant",
    data: {
      direction,
      operation,
      protocolId: 1,
      connectionId: "socket-connection-one",
      packetBytes: 128,
      channel: "inbox:user#user-one",
      stage: direction === "send" ? "encoded_for_send" : "decoded_receive",
      realtime: { policy: "full_debug", direction, operation, payload },
    },
    ...overrides,
  });
}

test("realtime socket send and receive rows retain independently redacted protocol JSON", () => {
  for (const [direction, operation, payload] of [
    [
      "send",
      "connect",
      {
        id: 1,
        connect: {
          data: {
            token: "private-connection-token",
            label: "connection input",
          },
          headers: { Authorization: "Bearer private-token" },
        },
      },
    ],
    [
      "receive",
      "publication",
      {
        push: {
          channel: "inbox:user#user-one",
          pub: {
            data: {
              pts: 42,
              epoch: "epoch",
              room: {
                eventType: "message_new",
                text: "Incoming text",
                nested: { apiKey: "private-key" },
              },
            },
          },
        },
      },
    ],
    ["receive", "error", { id: 1, error: { code: 403, message: "Rejected" } }],
    ["send", "pong", {}],
    ["receive", "ping", {}],
  ]) {
    const input = socketEvent(direction, operation, payload);
    const [record] = inspectorBatch(batch([input]), "capture-one");
    assert.equal(record.direction, direction);
    assert.equal(record.operation, operation);
    assert.equal(record.connectionId, "socket-connection-one");
    assert.equal(record.protocolId, 1);
    assert.equal(
      record.result,
      direction === "send" ? "send_attempt" : "received",
    );
    assert.equal(record.data.realtime.policy, "full_debug");
    assert.ok(!JSON.stringify(record).includes("private-"));
    assert.match(
      record.summary,
      new RegExp(`Realtime ${direction} ${operation.toUpperCase()}`),
    );
    if (operation === "publication")
      assert.equal(
        record.data.realtime.payload.push.pub.data.room.text,
        "Incoming text",
      );
  }
});

test("realtime full details require compatible policy, matching direction/operation and socket event scope", () => {
  const valid = socketEvent("receive", "publication", {
    text: "Full realtime body",
  });
  for (const input of [
    { ...valid, category: "http" },
    { ...valid, phase: "end" },
    { ...valid, name: "inbox.publication" },
    { ...valid, data: { ...valid.data, direction: "send" } },
    {
      ...valid,
      data: {
        ...valid.data,
        realtime: { ...valid.data.realtime, policy: "metadata" },
      },
    },
    {
      ...valid,
      data: {
        ...valid.data,
        realtime: { ...valid.data.realtime, direction: "send" },
      },
    },
    {
      ...valid,
      data: {
        ...valid.data,
        realtime: { ...valid.data.realtime, operation: "connect" },
      },
    },
  ]) {
    const [record] = inspectorBatch(batch([input]), "capture-one");
    assert.equal(record.data.realtime, undefined);
    assert.ok(!JSON.stringify(record).includes("Full realtime body"));
  }
  const [legacy] = inspectorBatch(
    batch([
      { ...valid, data: { direction: "receive", operation: "publication" } },
    ]),
    "capture-one",
  );
  assert.equal(legacy.data.realtime, undefined);
});

test("realtime bounds, JSON credential strings and protocol bytes metadata preserve the containing row", () => {
  for (const payload of [
    { text: "x".repeat(40000) },
    Array.from({ length: 100 }, () => ({ text: "x".repeat(1000) })),
    { data: '{"accessToken":"private-string-token","text":"Visible text"}' },
    { push: { pub: { data: { type: "binary", length: 3 } } } },
  ]) {
    const [record] = inspectorBatch(
      batch([socketEvent("receive", "publication", payload)]),
      "capture-one",
    );
    assert.ok(
      Buffer.byteLength(JSON.stringify(record.data.realtime)) <=
        realtimeDetailLimit,
    );
    assert.equal(record.data.packetBytes, 128);
    assert.ok(!JSON.stringify(record).includes("private-"));
  }
});

test("collector decodes protocol base64 before credential redaction without interpreting nested application strings", () => {
  const encoded = Buffer.from(
    JSON.stringify({
      token: "private-encoded-token",
      label: "connection input",
    }),
  ).toString("base64");
  const [record] = inspectorBatch(
    batch([socketEvent("send", "connect", { connect: { data: encoded } })]),
    "capture-one",
  );
  assert.deepEqual(record.data.realtime.payload.connect.data, {
    token: "[REDACTED]",
    label: "connection input",
  });
  assert.ok(!JSON.stringify(record).includes(encoded));
  assert.ok(!JSON.stringify(record).includes("private-encoded-token"));
  const [publication] = inspectorBatch(
    batch([
      socketEvent("receive", "publication", {
        push: { pub: { data: { text: "aGVsbG8=", data: "aGVsbG8=" } } },
      }),
    ]),
    "capture-one",
  );
  assert.deepEqual(publication.data.realtime.payload.push.pub.data, {
    text: "aGVsbG8=",
    data: "aGVsbG8=",
  });
});

test("actual ingress persists sent and received realtime envelopes without changing acknowledgement", async (t) => {
  const h = await fixture(t);
  const response = await request(h.url, {
    method: "POST",
    headers: { ...jsonHeaders, origin: "http://localhost:5173" },
    body: JSON.stringify(
      batch([
        socketEvent("send", "connect", {
          connect: { data: { token: "private-token" } },
        }),
        socketEvent(
          "receive",
          "publication",
          { push: { pub: { data: { text: "received through ingress" } } } },
          { seq: 2 },
        ),
      ]),
    ),
  });
  assert.equal(response.status, 202);
  const records = (await readFile(h.file, "utf8"))
    .trim()
    .split("\n")
    .map(JSON.parse);
  assert.equal(
    records[0].data.realtime.payload.connect.data.token,
    "[REDACTED]",
  );
  assert.equal(
    records[1].data.realtime.payload.push.pub.data.text,
    "received through ingress",
  );
  assert.equal(records[1].requestId, "request-three");
});

function httpEvent(http, overrides = {}) {
  return event({
    category: "http",
    name: "GET:/presence/status",
    data: {
      method: "GET",
      route: "/presence/status",
      status: 200,
      outcome: "response",
      http,
    },
    ...overrides,
  });
}

test("HTTP completion retains request and response JSON with independent credential redaction", () => {
  const input = httpEvent({
    policy: "full_debug",
    params: {},
    query: { userIds: "peer-one,peer-two", apiKey: "private-query-key" },
    requestBody: null,
    requestHeaders: {
      Authorization: "Bearer private-bearer",
      Cookie: "private-cookie",
    },
    responseBody: {
      statuses: { "peer-one": true, "peer-two": false },
      nested: { accessToken: "private-token" },
    },
    responseHeaders: {
      "Set-Cookie": "private-cookie",
      "Content-Type": "application/json",
    },
    unapproved: "private-unknown-field",
  });
  const [record] = inspectorBatch(batch([input]), "capture-one");
  assert.deepEqual(record.data.http.query, {
    userIds: "peer-one,peer-two",
    apiKey: "[REDACTED]",
  });
  assert.deepEqual(record.data.http.responseBody.statuses, {
    "peer-one": true,
    "peer-two": false,
  });
  assert.equal(record.data.http.requestBody, null);
  assert.equal(record.data.http.requestHeaders.Authorization, "[REDACTED]");
  assert.equal(record.data.http.responseHeaders["Set-Cookie"], "[REDACTED]");
  assert.ok(!JSON.stringify(record).includes("private-"));
  assert.equal(record.requestId, input.requestId);
  assert.equal(record.method, "GET");
  assert.equal(record.status, 200);
  assert.equal(record.summary, "GET /presence/status: 200.");
  assert.equal(input.data.http.query.apiKey, "private-query-key");
});

test("HTTP payloads require explicit full-debug policy and an HTTP completion", () => {
  const details = {
    policy: "full_debug",
    requestBody: { text: "debug business text" },
  };
  for (const input of [
    httpEvent({ ...details, policy: "metadata" }),
    httpEvent(details, { category: "action" }),
    httpEvent(details, { phase: "begin" }),
    httpEvent(details, { name: "OPTIONS:/presence/status" }),
    httpEvent(details, { name: "unrecognized" }),
  ]) {
    const [record] = inspectorBatch(batch([input]), "capture-one");
    assert.equal(record.data.http, undefined);
    assert.ok(!JSON.stringify(record).includes("debug business text"));
  }
  const [legacy] = inspectorBatch(batch([httpEvent(undefined)]), "capture-one");
  assert.equal(legacy.data.http, undefined);
});

test("HTTP detail bounds keep metadata and mark oversized or deeply nested values", () => {
  let deep = { password: "private-deep-password" };
  for (let i = 0; i < 24; i++) deep = { nested: deep };
  for (const responseBody of [
    { text: "x".repeat(40000) },
    Array.from({ length: 100 }, () => ({ text: "x".repeat(1000) })),
    deep,
    '{"token":"private-string-token","text":"visible"}',
  ]) {
    const [record] = inspectorBatch(
      batch([
        httpEvent({
          policy: "full_debug",
          query: { userIds: "peer-one" },
          responseBody,
        }),
      ]),
      "capture-one",
    );
    assert.ok(
      Buffer.byteLength(JSON.stringify(record.data.http)) <= httpDetailLimit,
    );
    assert.deepEqual(record.data.http.query, { userIds: "peer-one" });
    assert.equal(record.status, 200);
    assert.ok(!JSON.stringify(record).includes("private-"));
    if (typeof responseBody !== "string")
      assert.match(JSON.stringify(record), /payloadOmitted/);
  }
});

test("HTTP full-debug details survive actual ingress writes", async (t) => {
  const h = await fixture(t);
  const response = await request(h.url, {
    method: "POST",
    headers: { ...jsonHeaders, origin: "http://localhost:5173" },
    body: JSON.stringify(
      batch([
        httpEvent({
          policy: "full_debug",
          query: { userIds: "peer-one" },
          responseBody: {
            statuses: { "peer-one": true },
            accessToken: "private-token",
          },
        }),
      ]),
    ),
  });
  assert.equal(response.status, 202);
  const record = JSON.parse((await readFile(h.file, "utf8")).trim());
  assert.deepEqual(record.data.http.responseBody, {
    statuses: { "peer-one": true },
    accessToken: "[REDACTED]",
  });
  assert.ok(!JSON.stringify(record).includes("private-token"));
});

test("named metric metadata is searchable without copying arbitrary inspector payload fields", () => {
  const named = event({
    category: "inspector",
    name: "metric.gauges.queue.pending",
    metricName: "queue.pending",
    metricGroup: "gauges",
    metricValue: 2,
  });
  const [record] = inspectorBatch(batch([named]), "capture-one");
  assert.equal(record.metricName, "queue.pending");
  assert.equal(record.metricGroup, "gauges");
  assert.equal(record.metricValue, 2);
  for (const invalid of [
    event({ metricName: "forged", metricGroup: "gauges", metricValue: 1 }),
    { ...named, metricValue: Infinity },
    { ...named, metricName: "free form credential text" },
  ])
    assert.throws(() => inspectorBatch(batch([invalid]), "capture-one"));
});
async function temporaryRoot(t) {
  const root = await mkdtemp(
    join(await realpath(tmpdir()), "chat-local-ingress-test-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}
async function fixture(t, options = {}) {
  const root = await temporaryRoot(t);
  const file = join(root, "private", "flutter.jsonl");
  const ingress = await startLocalLogIngress({
    file,
    port: 0,
    captureId: "capture-one",
    ...options,
  });
  t.after(() => ingress.close());
  return { ...ingress, file, root };
}
function request(
  url,
  { method = "GET", path = "/events", headers = {}, body, chunks } = {},
) {
  const target = new URL(url);
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: target.hostname,
        port: target.port,
        path,
        method,
        headers,
        agent: false,
      },
      (res) => {
        const received = [];
        res.on("data", (value) => received.push(value));
        res.once("error", reject);
        res.once("end", () =>
          resolve({
            status: res.statusCode,
            headers: res.headers,
            body: Buffer.concat(received).toString("utf8"),
          }),
        );
      },
    );
    req.setTimeout(4000, () =>
      req.destroy(new Error("Synthetic ingress test timed out")),
    );
    req.once("error", reject);
    if (chunks) for (const chunk of chunks) req.write(chunk);
    req.end(body);
  });
}
const jsonHeaders = { "content-type": "application/json" };

test("inspector batches preserve screenshot metadata, causal IDs and durations with server-owned capture identity", () => {
  const input = batch();
  const value = inspectorBatch(input, "capture-server")[0];
  assert.equal(value.source, "flutter");
  assert.equal(value.origin, "inspector");
  assert.equal(value.instanceId, "flutter-tab-one");
  assert.equal(value.captureId, "capture-server");
  assert.equal(value.timestamp, "2026-10-17T09:30:00.000Z");
  assert.ok(Number.isFinite(Date.parse(value.receivedAt)));
  for (const field of [
    "category",
    "name",
    "phase",
    "seq",
    "traceId",
    "spanId",
    "parentSpanId",
    "userId",
    "roomId",
    "sessionGeneration",
    "durationMicros",
    "requestId",
  ])
    assert.equal(value[field], input.events[0][field], field);
  assert.equal(value.durationMs, 265.3);
  assert.deepEqual(value.data, { pts: 42, count: 2 });
  assert.equal(
    input.events[0].timestamp,
    "2026-10-17T12:30:00+03:00",
    "Normalization does not modify producer records",
  );
  const anonymous = inspectorBatch(
    batch([
      event({
        requestId: undefined,
        roomId: undefined,
        userId: undefined,
        traceId: undefined,
        spanId: undefined,
        parentSpanId: undefined,
        durationMicros: undefined,
        sessionGeneration: undefined,
      }),
    ]),
    "capture-two",
  )[0];
  for (const field of [
    "requestId",
    "roomId",
    "userId",
    "traceId",
    "spanId",
    "parentSpanId",
    "durationMicros",
    "sessionGeneration",
  ])
    assert.equal(anonymous[field], null);
  assert.equal("durationMs" in anonymous, false);
});

test("inspector ingestion removes payloads, credentials and free-form strings while bounding nested metadata", () => {
  const jwt = "eyJheader.eyJpayload.signature";
  const value = inspectorBatch(
    batch([
      event({
        data: {
          password: "private-password",
          authorization: "Bearer private-bearer",
          body: { text: "private-message" },
          headers: { cookie: "private-cookie" },
          sql: "SELECT private",
          errorType: "TypeError",
          reason: "private free form error text",
          path: "/rooms?token=private-query",
          requestId: jwt,
          count: Infinity,
          rows: NaN,
          cached: true,
          status: null,
          changedFields: [
            "roomPts",
            "private words",
            jwt,
            2,
            true,
            { password: "private-nested" },
          ],
          operation: { operation: { operation: { count: 1 } } },
          table: "x".repeat(121),
        },
      }),
    ]),
    "capture",
  )[0];
  assert.deepEqual(value.data.changedFields, ["roomPts", 2, true]);
  assert.equal(value.data.errorType, "TypeError");
  assert.equal(value.data.cached, true);
  assert.equal(value.data.status, null);
  assert.deepEqual(value.data.operation, { operation: { operation: {} } });
  assert.doesNotMatch(
    JSON.stringify(value),
    /private-|private words|private free form|SELECT|eyJheader|Infinity|NaN/,
  );
  assert.equal(value.data.table, undefined);
  const bounded = inspectorBatch(
    batch([
      event({
        data: {
          changedFields: Array.from({ length: 1000 }, (_, i) => `field-${i}`),
        },
      }),
    ]),
    "capture",
  )[0];
  assert.equal(bounded.data.changedFields.length, 24);
});

test("outbox retry correlation survives ingestion without admitting message content or credentials", () => {
  const data = {
    operationId: "45562e37-4dd7-4ef6-beb7-9d922dc3bd28",
    enqueueOrder: 7,
    status: "queued",
    reason: "server_unavailable",
    retryCount: 2,
    nextRetryAt: "2026-10-18T12:00:05.000Z",
    physicalAttempts: 3,
    sessionPhysicalAttempts: 8,
    outcomeUnknown: true,
    queued: 2,
    failed: 1,
    paused: 1,
    queuedCount: 2,
    failedCount: 1,
    pausedCount: 1,
  };
  const [record] = inspectorBatch(
    batch([
      event({
        category: "outbox",
        name: "waiting_for_server",
        phase: "instant",
        data: {
          ...data,
          text: "private-message-body",
          imageUrl: "/private-image",
          uploadBytes: [1, 2, 3],
          token: "private-token",
          password: "private-password",
          body: { text: "private-nested-body" },
          lastErrorText: "private free form server response",
        },
      }),
    ]),
    "capture-one",
  );
  assert.deepEqual(record.data, data);
  assert.equal(record.result, "offline");
  assert.equal(record.operationId, data.operationId);
  assert.equal(record.reason, data.reason);
  assert.equal(record.nextRetryAt, data.nextRetryAt);
  assert.equal(record.sessionPhysicalAttempts, 8);
  assert.equal(record.queuedCount, 2);
  assert.match(record.summary, /Outbox waiting for backend \/health recovery/);
  assert.match(record.summary, /queued 2, failed 1, attention 1/);
  assert.match(record.summary, /reason server_unavailable/);
  assert.doesNotMatch(
    JSON.stringify(record),
    /private-|uploadBytes|lastErrorText/,
  );
  const [untrusted] = inspectorBatch(
    batch([
      event({
        category: "outbox",
        name: "waiting",
        phase: "instant",
        data: {
          operationId: "eyJheader.eyJpayload.signature",
          nextRetryAt: "private free form value",
          reason: "private response text",
          physicalAttempts: Infinity,
          retryCount: NaN,
        },
      }),
    ]),
    "capture-one",
  );
  assert.deepEqual(untrusted.data, {});
  assert.equal(untrusted.operationId, undefined);
  assert.equal(untrusted.reason, undefined);
  assert.equal(untrusted.nextRetryAt, undefined);
  assert.equal(untrusted.result, "waiting");
  assert.equal(untrusted.summary, "Outbox retry scheduled.");
});

test("health presentation distinguishes first readiness from outage recovery", () => {
  for (const [recovered, result, summary] of [
    [false, "ready", "Backend ready."],
    [true, "recovered", "Backend recovered; queued sends can resume."],
  ]) {
    const [record] = inspectorBatch(
      batch([
        event({
          category: "health",
          name: "ready",
          phase: "instant",
          data: {
            healthStatus: "ready",
            previousStatus: "checking",
            recovered,
          },
        }),
      ]),
      "capture-one",
    );
    assert.equal(record.result, result);
    assert.equal(record.summary, summary);
    assert.equal(record.recovered, recovered);
    assert.equal(record.healthStatus, "ready");
  }
});

test("offline summaries omit attempt zero while retaining the retry budget metadata", () => {
  const [record] = inspectorBatch(
    batch([
      event({
        category: "outbox",
        name: "waiting_for_server",
        phase: "instant",
        data: {
          queuedCount: 2,
          attempt: 0,
          retryCount: 0,
          reason: "server_unavailable",
        },
      }),
    ]),
    "capture-one",
  );
  assert.equal(record.retryCount, 0);
  assert.equal(record.data.retryCount, 0);
  assert.equal(record.attempt, 0);
  assert.match(record.summary, /queued 2/);
  assert.doesNotMatch(record.summary, /attempt 0/);
});

test("outbox presentation promotes only safe primitive queue fields", () => {
  const [record] = inspectorBatch(
    batch([
      event({
        category: "outbox",
        name: "waiting",
        data: {
          queuedCount: -1,
          failedCount: { count: 10 },
          pausedCount: 1.5,
          attempt: "forged_attempt",
          operationId: { operationId: "nested-id" },
          nextRetryAt: "not_a_date",
          reason: { reason: "nested-reason" },
          sessionPhysicalAttempts: Number.MAX_SAFE_INTEGER + 1,
          recovered: "true",
        },
      }),
    ]),
    "capture-one",
  );
  for (const key of [
    "queuedCount",
    "failedCount",
    "pausedCount",
    "attempt",
    "operationId",
    "nextRetryAt",
    "reason",
    "sessionPhysicalAttempts",
    "recovered",
  ])
    assert.equal(record[key], undefined, key);
  assert.equal(record.summary, "Outbox retry scheduled.");
});

test("failed send spans describe the attempt without declaring permanent message failure", () => {
  for (const overrides of [
    { level: "error" },
    { data: { errorType: "ChatApiException" } },
  ]) {
    const [record] = inspectorBatch(
      batch([
        event({
          category: "outbox",
          name: "send",
          phase: "end",
          ...overrides,
        }),
      ]),
      "capture-one",
    );
    assert.equal(record.result, "attempt_failed");
    assert.equal(record.summary, "Outbox send attempt failed.");
  }
});

test("unknown diagnostic names cannot resolve inherited presentation properties", () => {
  for (const category of ["outbox", "health"]) {
    for (const name of ["constructor", "__proto__", "toString"]) {
      const [record] = inspectorBatch(
        batch([event({ category, name })]),
        "capture-one",
      );
      assert.equal(record.result, "changed");
      assert.equal(
        record.summary,
        category === "outbox"
          ? "Outbox state changed."
          : "Backend readiness changed.",
      );
    }
  }
});

test("outbox operation identity remains in persisted records across client restarts", async (t) => {
  const ingress = await fixture(t);
  const operationId = "45562e37-4dd7-4ef6-beb7-9d922dc3bd28";
  for (const [instanceId, name, data] of [
    [
      "flutter-before-restart",
      "waiting",
      {
        operationId,
        retryCount: 1,
        nextRetryAt: "2026-10-18T12:00:05.000Z",
        outcomeUnknown: true,
      },
    ],
    ["flutter-after-restart", "acknowledged", { operationId }],
  ]) {
    const response = await request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        instanceId,
        events: [
          event({
            category: "outbox",
            name,
            phase: "instant",
            data,
          }),
        ],
      }),
    });
    assert.equal(response.status, 202);
  }
  const records = (await readFile(ingress.file, "utf8"))
    .trim()
    .split("\n")
    .map(JSON.parse);
  assert.deepEqual(
    records.map((record) => record.instanceId),
    ["flutter-before-restart", "flutter-after-restart"],
  );
  assert.ok(records.every((record) => record.data.operationId === operationId));
  assert.equal(records[0].data.retryCount, 1);
  assert.equal(records[0].data.nextRetryAt, "2026-10-18T12:00:05.000Z");
  assert.equal(records[0].data.outcomeUnknown, true);
  assert.equal(records[1].name, "acknowledged");
});

test("invalid schemas, forged services, injected labels, timestamps and unbounded batches are rejected atomically", () => {
  for (const invalid of [
    null,
    [],
    {},
    { ...batch(), captureId: "forged" },
    batch([]),
    batch(Array.from({ length: 51 }, () => event())),
    { ...batch(), instanceId: "bad\ninstance" },
    { ...batch(), instanceId: "x".repeat(129) },
    ...[null, "", "not-a-uuid", "secret\nvalue", 42].map((batchId) => ({
      ...batch(),
      batchId,
    })),
  ])
    assert.throws(() => inspectorBatch(invalid, "server-capture"));
  for (const override of [
    { source: "backend" },
    { event: "service_log" },
    { level: "debug" },
    { name: "private message text" },
    { name: "\u001b[31mwarning" },
    { userId: "eyJheader.eyJpayload.signature" },
    { timestamp: "not-a-date" },
    { timestamp: "2026-10-17T12:00:00" },
    { seq: 0 },
    { seq: 1.5 },
    { seq: Number.MAX_SAFE_INTEGER + 1 },
    { phase: "finish" },
    { durationMicros: -1 },
    { durationMicros: 0.5 },
    { sessionGeneration: -1 },
    { requestHeaders: { authorization: "private" } },
    { captureId: "forged" },
  ])
    assert.throws(
      () => inspectorBatch(batch([event(), event(override)]), "server-capture"),
      JSON.stringify(override),
    );
});

test("loopback ingress persists complete batches privately in order and reports counters without payloads", async (t) => {
  const ingress = await fixture(t);
  assert.equal(ingress.server.address().address, "127.0.0.1");
  for (let seq = 1; seq <= 3; seq++) {
    const response = await request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify(batch([event({ seq })])),
    });
    assert.equal(response.status, 202);
    assert.deepEqual(JSON.parse(response.body), { accepted: 1 });
    assert.equal(response.headers["cache-control"], "no-store");
    assert.equal(response.headers["x-content-type-options"], "nosniff");
  }
  const records = (await readFile(ingress.file, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.deepEqual(
    records.map((value) => value.seq),
    [1, 2, 3],
  );
  assert.ok(records.every((value) => value.captureId === "capture-one"));
  assert.equal((await stat(ingress.file)).mode & 0o777, 0o600);
  assert.equal((await stat(join(ingress.root, "private"))).mode & 0o777, 0o700);
  const health = await request(ingress.url, { path: "/health" });
  assert.equal(health.status, 200);
  assert.equal(JSON.parse(health.body).acceptedEvents, 3);
  assert.doesNotMatch(health.body, /inbox\.publication|user-one|room-two/);
  const closing = ingress.close();
  assert.equal(ingress.close(), closing);
  await closing;
  await assert.rejects(request(ingress.url, { path: "/health" }));
});

test("stable batch identity deduplicates retries while preserving legacy batches and instance isolation", async (t) => {
  const ingress = await fixture(t);
  const input = { ...batch(), batchId: "3cd51921-c236-408a-82f0-bc9a25f30d71" };
  const post = (value) =>
    request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify(value),
    });
  for (const value of [
    input,
    input,
    { ...input, batchId: input.batchId.toUpperCase() },
  ]) {
    const response = await post(value);
    assert.equal(response.status, 202);
    assert.deepEqual(JSON.parse(response.body), { accepted: 1 });
  }
  assert.equal(
    (await post({ ...input, events: [event({ seq: 2 })] })).status,
    409,
  );
  assert.equal(
    (await post({ ...input, instanceId: "flutter-tab-two" })).status,
    202,
  );
  assert.equal((await post(batch())).status, 202);
  assert.equal((await post(batch())).status, 202);
  const records = (await readFile(ingress.file, "utf8"))
    .trim()
    .split("\n")
    .map(JSON.parse);
  assert.equal(records.length, 4);
  assert.equal(records[0].batchId, input.batchId);
  assert.equal(records[1].instanceId, "flutter-tab-two");
  const health = JSON.parse(
    (await request(ingress.url, { path: "/health" })).body,
  );
  assert.equal(health.acceptedEvents, 4);
  assert.equal(health.deduplicatedBatches, 2);
  assert.equal(health.deduplicatedEvents, 2);
  assert.equal(health.idempotencyConflicts, 1);
  assert.equal(health.idempotencyEntries, 2);
  assert.doesNotMatch(
    JSON.stringify(health),
    /flutter-tab|3cd51921|inbox\.publication/,
  );
});

test("concurrent retries wait for the original write and never acknowledge a failed write", async (t) => {
  const ingress = await fixture(t);
  const originalWrite = RotatingJsonlWriter.prototype.write;
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  let began;
  const started = new Promise((resolve) => {
    began = resolve;
  });
  let writes = 0;
  t.mock.method(RotatingJsonlWriter.prototype, "write", async function (text) {
    writes++;
    began();
    await gate;
    return originalWrite.call(this, text);
  });
  const input = { ...batch(), batchId: "a17007a4-1292-4946-bb37-43d93785384e" };
  const post = () =>
    request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify(input),
    });
  const first = post();
  await started;
  const second = post();
  release();
  assert.deepEqual(
    (await Promise.all([first, second])).map((r) => r.status),
    [202, 202],
  );
  assert.equal(writes, 1);
  assert.equal(
    (await readFile(ingress.file, "utf8")).trim().split("\n").length,
    1,
  );

  let fail = true;
  t.mock.method(RotatingJsonlWriter.prototype, "write", async function (text) {
    if (fail) {
      fail = false;
      throw new Error("Synthetic input unavailable");
    }
    return originalWrite.call(this, text);
  });
  input.batchId = "972aa31e-5df1-4b2f-ad5d-ae126beed129";
  assert.equal((await post()).status, 503);
  assert.equal((await post()).status, 202);
  const health = JSON.parse(
    (await request(ingress.url, { path: "/health" })).body,
  );
  assert.equal(health.failedBatches, 1);
  assert.equal(health.acceptedEvents, 2);
});

test("a lost acknowledgement retries the committed batch without duplicating its records", async (t) => {
  const ingress = await fixture(t);
  const originalWrite = RotatingJsonlWriter.prototype.write;
  let firstSocket;
  ingress.server.prependListener("request", (incoming) => {
    if (incoming.method === "POST" && !firstSocket)
      firstSocket = incoming.socket;
  });
  let loseAck = true;
  t.mock.method(RotatingJsonlWriter.prototype, "write", async function (text) {
    await originalWrite.call(this, text);
    if (loseAck) {
      loseAck = false;
      firstSocket.destroy();
    }
  });
  const input = {
    ...batch([
      event({ level: "error", data: { errorType: "SyntheticFailure" } }),
    ]),
    batchId: "23451c79-3c0d-42be-a7e7-087e5ef996cd",
  };
  const post = () =>
    request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify(input),
    });
  await assert.rejects(post(), /socket hang up|ECONNRESET/);
  assert.equal((await post()).status, 202);
  const records = (await readFile(ingress.file, "utf8"))
    .trim()
    .split("\n")
    .map(JSON.parse);
  assert.equal(records.length, 1);
  assert.equal(records[0].level, "error");
  const health = JSON.parse(
    (await request(ingress.url, { path: "/health" })).body,
  );
  assert.equal(health.acceptedEvents, 1);
  assert.equal(health.deduplicatedEvents, 1);
});

test("an uncertain partial batch retries every important record with explicit duplicate identity and attempt metadata", async (t) => {
  const ingress = await fixture(t);
  const originalWrite = RotatingJsonlWriter.prototype.write;
  let partial = true;
  t.mock.method(RotatingJsonlWriter.prototype, "write", async function (text) {
    if (partial) {
      partial = false;
      const prefix = text.slice(0, text.indexOf("\n") + 1);
      await originalWrite.call(this, prefix);
      throw Object.assign(new Error("Synthetic partial append"), {
        logWriteOutcome: "uncertain",
        logBytesWritten: Buffer.byteLength(prefix),
      });
    }
    return originalWrite.call(this, text);
  });
  const input = {
    ...batch([
      event({ seq: 1, level: "error" }),
      event({ seq: 2, level: "warn" }),
      event({ seq: 3, name: "cursor.advance" }),
    ]),
    batchId: "e99c5d11-9c7a-4ef4-9064-7ed4f57931ce",
  };
  const post = (value = input) =>
    request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify(value),
    });
  assert.equal((await post()).status, 503);
  assert.equal(
    (await post({ ...input, events: [event({ seq: 4 })] })).status,
    409,
  );
  assert.equal((await post()).status, 202);
  assert.equal((await post()).status, 202);
  const records = (await readFile(ingress.file, "utf8"))
    .trim()
    .split("\n")
    .map(JSON.parse);
  assert.equal(records.length, 4);
  assert.deepEqual(
    [...new Set(records.map((record) => record.seq))],
    [1, 2, 3],
  );
  assert.ok(records.every((record) => record.batchId === input.batchId));
  assert.equal(records[0].logDeliveryAttempt, 1);
  assert.deepEqual(records[0].data.logDelivery, {
    batchId: input.batchId,
    logDeliveryAttempt: 1,
    logPreviousWriteOutcome: "not_attempted",
  });
  assert.ok(
    records
      .slice(1)
      .every(
        (record) =>
          record.logDeliveryAttempt === 2 &&
          record.logPreviousWriteOutcome === "uncertain" &&
          record.data.logDelivery.logDeliveryAttempt === 2 &&
          record.data.logDelivery.logPreviousWriteOutcome === "uncertain",
      ),
  );
  const health = JSON.parse(
    (await request(ingress.url, { path: "/health" })).body,
  );
  assert.equal(health.failedBatches, 1);
  assert.equal(health.uncertainWriteBatches, 1);
  assert.equal(health.retriedBatches, 1);
  assert.equal(health.idempotencyConflicts, 1);
  assert.equal(health.acceptedEvents, 3);
  assert.equal(health.deduplicatedEvents, 3);
});

test("receipt cache is bounded and rejects new identities until expiry without evicting accepted receipts", async (t) => {
  let time = 1000;
  const ingress = await fixture(t, {
    now: () => time,
    deduplicationLimit: 2,
    deduplicationWindowMs: 100,
  });
  const ids = [
    "b2bdb764-b629-4c03-8a24-6c897fba7aff",
    "5d2ab6b6-d45c-42af-a29b-1783f4c97d63",
    "fce3e0cb-a018-487a-9f93-57a52cc242ce",
  ];
  const post = (batchId) =>
    request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({ ...batch(), batchId }),
    });
  assert.equal((await post(ids[0])).status, 202);
  assert.equal((await post(ids[1])).status, 202);
  const busy = await post(ids[2]);
  assert.equal(busy.status, 503);
  assert.equal(busy.headers["retry-after"], "1");
  assert.equal((await post(ids[0])).status, 202);
  time += 101;
  assert.equal((await post(ids[2])).status, 202);
  const health = JSON.parse(
    (await request(ingress.url, { path: "/health" })).body,
  );
  assert.equal(health.idempotencyEntries, 1);
  assert.equal(health.idempotencyBusy, 1);
  assert.equal(health.deduplicatedBatches, 1);
  assert.equal(health.acceptedEvents, 3);
  assert.equal(inspectorDeliveryPolicy.deduplicationLimit, 16384);
  assert.equal(inspectorDeliveryPolicy.deduplicationWindowMs, 120000);
  await assert.rejects(
    startLocalLogIngress({
      file: ingress.file,
      port: 0,
      deduplicationLimit: inspectorDeliveryPolicy.deduplicationLimit + 1,
    }),
    /Invalid delivery budget/,
  );
});

test("two 100ms exporters sustain six minutes of important batches without receipt-cache backpressure", async (t) => {
  let time = 1000;
  const ingress = await fixture(t, { now: () => time });
  for (let i = 0; i < 7200; i++) {
    time = 1000 + Math.floor(i / 2) * 100;
    const response = await request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        instanceId: `flutter-tab-${i % 2}`,
        batchId: `00000000-0000-4000-8000-${i.toString(16).padStart(12, "0")}`,
        events: [event({ seq: Math.floor(i / 2) + 1, level: "error" })],
      }),
    });
    assert.equal(response.status, 202, `Important batch ${i}`);
  }
  const health = JSON.parse(
    (await request(ingress.url, { path: "/health" })).body,
  );
  assert.equal(health.acceptedEvents, 7200);
  assert.equal(health.failedBatches, 0);
  assert.equal(health.idempotencyBusy, 0);
  assert.ok(health.idempotencyEntries <= 2400);
  assert.equal(
    (await readFile(ingress.file, "utf8")).trim().split("\n").length,
    7200,
  );
});

test("ingress enforces exact Host, browser origins and missing-origin fetch restrictions", async (t) => {
  const ingress = await fixture(t);
  const port = new URL(ingress.url).port;
  for (const headers of [
    { host: "attacker.test" },
    { host: `localhost:${port}` },
    { origin: "https://attacker.test" },
    { origin: "null" },
    { origin: "http://localhost:5175" },
    { origin: "http://localhost:5173.attacker.test" },
    { "sec-fetch-site": "cross-site" },
    { "sec-fetch-site": "same-site" },
  ]) {
    const response = await request(ingress.url, { path: "/health", headers });
    assert.equal(response.status, 403);
    assert.equal(response.headers["access-control-allow-origin"], undefined);
  }
  for (const origin of localLogOrigins) {
    const response = await request(ingress.url, {
      path: "/health",
      headers: { origin },
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers["access-control-allow-origin"], origin);
    assert.equal(response.headers.vary, "Origin");
  }
  const local = await request(ingress.url, {
    path: "/health",
    headers: { "sec-fetch-site": "none" },
  });
  assert.equal(local.status, 200);
});

test("CORS accepts only allowed JSON POST preflights and keeps invalid methods and routes explicit", async (t) => {
  const ingress = await fixture(t);
  const allowed = {
    origin: localLogOrigins[0],
    "access-control-request-method": "POST",
    "access-control-request-headers": "Content-Type",
  };
  const preflight = await request(ingress.url, {
    method: "OPTIONS",
    headers: allowed,
  });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers["access-control-allow-methods"], "POST");
  assert.equal(
    preflight.headers["access-control-allow-headers"],
    "Content-Type",
  );
  assert.equal(preflight.body, "");
  for (const headers of [
    { ...allowed, origin: undefined },
    { ...allowed, "access-control-request-method": "DELETE" },
    {
      ...allowed,
      "access-control-request-headers": "content-type,authorization",
    },
  ]) {
    const filtered = Object.fromEntries(
      Object.entries(headers).filter(([, value]) => value !== undefined),
    );
    assert.equal(
      (await request(ingress.url, { method: "OPTIONS", headers: filtered }))
        .status,
      403,
    );
  }
  const method = await request(ingress.url, { method: "DELETE" });
  assert.equal(method.status, 405);
  assert.equal(method.headers.allow, "POST, OPTIONS");
  assert.equal((await request(ingress.url, { path: "/other" })).status, 404);
});

test("invalid content types, JSON, forbidden payload fields and oversized bodies never persist records", async (t) => {
  const ingress = await fixture(t);
  for (const type of [
    undefined,
    "text/plain",
    "application/x-www-form-urlencoded",
    "application/json-invalid",
  ]) {
    const response = await request(ingress.url, {
      method: "POST",
      headers: type ? { "content-type": type } : {},
      body: "{}",
    });
    assert.equal(response.status, 415);
  }
  for (const body of [
    "{malformed-json",
    JSON.stringify(batch([event({ content: "private-message" })])),
    JSON.stringify(batch([event({ source: "redis" })])),
  ]) {
    const response = await request(ingress.url, {
      method: "POST",
      headers: jsonHeaders,
      body,
    });
    assert.equal(response.status, 400);
    assert.equal(response.headers["content-type"], "application/problem+json");
    assert.deepEqual(JSON.parse(response.body), {
      type: "about:blank",
      title: "Invalid inspector batch",
      status: 400,
    });
    assert.doesNotMatch(response.body, /private-message|malformed|redis|stack/);
  }
  const huge = "x".repeat(256 * 1024 + 1);
  const oversized = await request(ingress.url, {
    method: "POST",
    headers: { ...jsonHeaders, "content-length": Buffer.byteLength(huge) },
    body: huge,
  });
  assert.equal(oversized.status, 413);
  const chunked = await request(ingress.url, {
    method: "POST",
    headers: jsonHeaders,
    chunks: ["x".repeat(128 * 1024), "x".repeat(128 * 1024 + 1)],
  });
  assert.equal(chunked.status, 413);
  assert.equal(await readFile(ingress.file, "utf8"), "");
  const health = JSON.parse(
    (await request(ingress.url, { path: "/health" })).body,
  );
  assert.equal(health.acceptedEvents, 0);
  assert.equal(health.rejectedBatches, 3);
});

test("ingress rejects symlinked files, linked files and symlinked ancestors while preserving targets", async (t) => {
  const root = await temporaryRoot(t);
  const target = join(root, "original.jsonl");
  await writeFile(target, "existing private data", { mode: 0o644 });
  const symlinkPath = join(root, "symlink.jsonl");
  await symlink(target, symlinkPath);
  const linkedPath = join(root, "hardlink.jsonl");
  await link(target, linkedPath);
  for (const file of [symlinkPath, linkedPath])
    await assert.rejects(startLocalLogIngress({ file, port: 0 }));
  const destination = join(root, "original-directory");
  await mkdir(destination);
  const alias = join(root, "alias-directory");
  await symlink(destination, alias);
  await assert.rejects(
    startLocalLogIngress({ file: join(alias, "events.jsonl"), port: 0 }),
  );
  assert.equal(await readFile(target, "utf8"), "existing private data");
  assert.equal((await stat(target)).mode & 0o777, 0o644);
  await assert.rejects(stat(join(destination, "events.jsonl")), {
    code: "ENOENT",
  });
});

test("an occupied ingestion port fails cleanly without replacing captures or disturbing the existing server", async (t) => {
  const ingress = await fixture(t);
  const root = await temporaryRoot(t);
  const file = join(root, "other.jsonl");
  await writeFile(file, "preserved capture\n", { mode: 0o600 });
  await assert.rejects(
    startLocalLogIngress({ file, port: Number(new URL(ingress.url).port) }),
    /Could not bind local ingestion port/,
  );
  assert.equal(await readFile(file, "utf8"), "preserved capture\n");
  assert.equal((await request(ingress.url, { path: "/health" })).status, 200);
});

test("full-debug SQLite extension preserves real query parameters, results and causal scope without relaxing ordinary metadata", () => {
  const input = event({
    category: "drift",
    name: "query.select",
    data: {
      operation: "select",
      table: "local_messages",
      rowCount: 1,
      sqlite: {
        policy: "full_debug",
        database: "chat_app_db",
        operation: "select",
        statement: "SELECT * FROM local_messages WHERE room_id = ?",
        parameters: [{ position: 1, storageType: "text", value: "room-two" }],
        parametersOmitted: 0,
        result: {
          rowCount: 1,
          rowsCaptured: 1,
          rowsOmitted: 0,
          rows: [
            {
              text: "result body",
              token: "private-token",
              upload_bytes: [1, 2, 3],
              reply_to_json: '{"text":"quote","password":"private-json"}',
            },
          ],
        },
      },
    },
  });
  const [record] = inspectorBatch(batch([input]), "capture-test");
  assert.equal(record.requestId, input.requestId);
  assert.equal(record.instanceId, "flutter-tab-one");
  assert.equal(record.databaseName, "chat_app_db");
  assert.equal(record.collection, "local_messages");
  assert.equal(record.result, "success");
  assert.match(record.summary, /SELECT.*1 rows/);
  assert.equal(record.data.sqlite.statement, input.data.sqlite.statement);
  assert.equal(record.data.sqlite.parameters[0].value, "room-two");
  assert.equal(record.data.sqlite.result.rows[0].text, "result body");
  assert.deepEqual(record.data.sqlite.result.rows[0].upload_bytes, {
    type: "binary",
    length: 3,
  });
  assert.doesNotMatch(JSON.stringify(record), /private-/);
  const [ordinary] = inspectorBatch(
    batch([event({ data: input.data })]),
    "capture-test",
  );
  assert.equal(ordinary.data.sqlite, undefined);
  const [disabled] = inspectorBatch(
    batch([
      {
        ...input,
        data: {
          ...input.data,
          sqlite: { ...input.data.sqlite, policy: "metadata" },
        },
      },
    ]),
    "capture-test",
  );
  assert.equal(disabled.data.sqlite, undefined);
});

test("SQLite collector independently redacts positional secrets, literal credentials, aliases and blob bindings", () => {
  const [record] = inspectorBatch(
    batch([
      event({
        category: "drift",
        name: "query.select",
        data: {
          sqlite: {
            policy: "full_debug",
            database: "chat_app_db",
            operation: "select",
            statement:
              "SELECT password_hash AS value FROM private_table WHERE id = ? AND pin = 123 -- private-comment",
            parameters: [
              { position: 1, storageType: "text", value: "private-binding" },
            ],
            result: {
              rowCount: 1,
              rowsCaptured: 1,
              rowsOmitted: 0,
              rows: [{ value: "private-alias" }],
            },
          },
        },
      }),
    ]),
    "capture-test",
  );
  assert.doesNotMatch(
    JSON.stringify(record),
    /private-(comment|binding|alias)|123/,
  );
  assert.equal(record.data.sqlite.parameters[0].value, "[REDACTED]");
  assert.equal(record.data.sqlite.result.rowsOmitted, 1);
  const [binary] = inspectorBatch(
    batch([
      event({
        category: "drift",
        name: "query.insert",
        data: {
          sqlite: {
            policy: "full_debug",
            database: "chat_app_db",
            operation: "insert",
            statement:
              "INSERT INTO local_messages (text, upload_bytes) VALUES (?, ?)",
            parameters: [
              {
                position: 1,
                storageType: "text",
                value: '{"password":"private-json"}',
              },
              { position: 2, storageType: "blob", value: [41, 42, 43] },
            ],
            result: { lastInsertRowId: 12 },
          },
        },
      }),
    ]),
    "capture-test",
  );
  assert.deepEqual(binary.data.sqlite.parameters[1].value, {
    type: "binary",
    length: 3,
  });
  assert.equal(binary.data.sqlite.result.lastInsertRowId, 12);
  assert.doesNotMatch(JSON.stringify(binary), /private-json/);
});

test("SQLite detail bounds and invalid extensions remain explicit without losing metadata or changing ingestion acknowledgement", async (t) => {
  const { url, file } = await fixture(t);
  const detailed = event({
    category: "drift",
    name: "query.select",
    data: {
      rowCount: 600,
      sqlite: {
        policy: "full_debug",
        database: "chat_app_db",
        operation: "select",
        statement: "SELECT * FROM local_messages",
        parameters: [],
        result: {
          rowCount: 600,
          rowsCaptured: 600,
          rowsOmitted: 0,
          rows: Array.from({ length: 600 }, (_, id) => ({ id })),
        },
      },
    },
  });
  const response = await request(url, {
    method: "POST",
    headers: { ...jsonHeaders, origin: "http://localhost:5173" },
    body: JSON.stringify(batch([detailed])),
  });
  assert.equal(response.status, 202);
  const record = JSON.parse((await readFile(file, "utf8")).trim());
  assert.equal(record.data.sqlite.result.rowsCaptured, 512);
  assert.equal(record.data.sqlite.result.rowsOmitted, 88);
  assert.match(JSON.stringify(record.data.sqlite), /array_entry_limit/);
  const huge = event({
    category: "drift",
    name: "query.select",
    data: {
      sqlite: {
        policy: "full_debug",
        database: "chat_app_db",
        operation: "select",
        statement: "SELECT ?",
        parameters: [],
        result: {
          rows: Array.from({ length: 40 }, () => ({ text: "x".repeat(2000) })),
        },
      },
    },
  });
  const [omitted] = inspectorBatch(batch([huge]), "capture-test");
  assert.equal(omitted.data.sqlite.payloadOmitted, true);
  assert.equal(omitted.data.sqlite.omissionReason, "detail_byte_limit");
});

test("delivery stages use the emitting account and cannot forge cross-user correlation", () => {
  const [row] = inspectorBatch(
    batch([
      event({
        name: "publication.applied",
        data: {
          stage: "provider_accepted",
          channel: "inbox:user#other",
          correlationKey: "forged",
          epoch: "epoch",
          pts: 42,
          eventType: "message_new",
          text: "private",
        },
      }),
    ]),
    "capture-one",
  );
  assert.equal(row.stage, "inbox_applied");
  assert.equal(row.recipientUserId, "user-one");
  assert.equal(row.channel, "inbox:user#user-one");
  assert.equal(row.correlationKey, "inbox:user-one:epoch:42");
  assert.equal(row.data.text, undefined);
});
