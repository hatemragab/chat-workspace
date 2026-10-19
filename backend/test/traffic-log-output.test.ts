import "reflect-metadata";
import assert from "node:assert/strict";
import {
  chmod,
  link,
  readdir,
  mkdir,
  rename,
  mkdtemp,
  readFile,
  realpath,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Writable } from "node:stream";
import { test } from "node:test";
import { ConfigService } from "@nestjs/config";
import {
  DebugTrafficLogger,
  type TrafficLogRecord,
} from "../src/infrastructure/debug-traffic-logger";
import {
  AsyncJsonlTrafficSink,
  formatTrafficSummary,
  resolveTrafficLogFormat,
  writeTrafficLine,
} from "../src/infrastructure/traffic-log-output";

test("rotation archives complete records and keeps subsequent writes on the active private path", async () => {
  const directory = await fixture();
  const path = join(directory, "traffic.jsonl");
  const sink = new AsyncJsonlTrafficSink({
    path,
    rotation: { maxBytes: 1, maxArchives: 7, maxAgeMs: 86400000 },
  });
  sink.append(record("first"));
  sink.append(record("second"));
  await sink.close();
  const files = (await readdir(join(directory, "archives"))).filter((name) =>
    name.endsWith(".jsonl"),
  );
  assert.equal(files.length, 1);
  assert.equal(
    JSON.parse(await readFile(join(directory, "archives", files[0]), "utf8"))
      .requestId,
    "first",
  );
  assert.equal(JSON.parse(await readFile(path, "utf8")).requestId, "second");
  assert.equal((await stat(path)).mode & 0o777, 0o600);
  assert.equal(sink.stats().writtenRecords, 2);
});

test("rotation rejects an archive directory link without overwriting its target", async () => {
  const directory = await fixture();
  const path = join(directory, "traffic.jsonl");
  await symlink(directory, join(directory, "archives"));
  const sink = new AsyncJsonlTrafficSink({
    path,
    rotation: { maxBytes: 1, maxArchives: 7, maxAgeMs: 86400000 },
    warn: () => {},
  });
  sink.append(record("first"));
  sink.append(record("second"));
  await sink.close();
  assert.equal(sink.stats().failed, true);
  assert.equal(JSON.parse(await readFile(path, "utf8")).requestId, "first");
});

test("rotation refuses a swapped ancestor without moving or modifying another file", async () => {
  const root = await fixture();
  const logs = join(root, "logs");
  const foreign = join(root, "foreign");
  await mkdir(foreign);
  await writeFile(join(foreign, "traffic.jsonl"), "preserved foreign bytes\n");
  const sink = new AsyncJsonlTrafficSink({
    path: join(logs, "traffic.jsonl"),
    rotation: { maxBytes: 1, maxArchives: 1, maxAgeMs: 86400000 },
    warn: () => {},
  });
  sink.append(record("owned"));
  await sink.flush();
  await rename(logs, join(root, "owned-logs"));
  await symlink(foreign, logs);
  sink.append(record("rejected"));
  await sink.close();
  assert.equal(sink.stats().failed, true);
  assert.equal(
    await readFile(join(foreign, "traffic.jsonl"), "utf8"),
    "preserved foreign bytes\n",
  );
  assert.deepEqual(await readdir(foreign), ["traffic.jsonl"]);
});

test("a full unread input archive budget drops new diagnostics rather than deleting old records", async () => {
  const directory = await fixture();
  const sink = new AsyncJsonlTrafficSink({
    path: join(directory, "traffic.jsonl"),
    rotation: { maxBytes: 1, maxArchives: 1, maxAgeMs: 86400000 },
    warn: () => {},
  });
  for (const id of ["one", "two", "three", "four"]) sink.append(record(id));
  await sink.close();
  assert.equal(sink.stats().writtenRecords, 3);
  assert.equal(sink.stats().droppedRecords, 1);
  assert.equal(sink.stats().failed, false);
  assert.equal((await readdir(join(directory, "archives"))).length, 2);
});

function record(requestId = "request-one"): TrafficLogRecord {
  return {
    timestamp: "2026-10-16T12:34:56.789Z",
    level: "info",
    source: "backend",
    event: "http_request",
    requestId,
    userId: "user-one",
    method: "GET",
    route: "/rooms/delta",
    status: 200,
    durationMs: 53.84,
    aborted: false,
  };
}

async function fixture(): Promise<string> {
  // Resolve OS aliases (e.g. macOS /var) before asking the sink to reject links.
  return mkdtemp(join(await realpath(tmpdir()), "chat-traffic-test-"));
}

test("development defaults to pretty even without a TTY; explicit modes and invalid fallback are safe", () => {
  assert.equal(resolveTrafficLogFormat(undefined, "development"), "pretty");
  assert.equal(resolveTrafficLogFormat(undefined, "production"), "json");
  assert.equal(resolveTrafficLogFormat(undefined, undefined), "json");
  for (const mode of ["pretty", "json", "silent"] as const) {
    assert.equal(resolveTrafficLogFormat(mode, "development"), mode);
    assert.equal(resolveTrafficLogFormat(mode, "production"), mode);
  }
  for (const invalid of ["", "invalid", "JSON", "\u001b[31m", {}, null]) {
    assert.equal(resolveTrafficLogFormat(invalid, "production"), "json");
    assert.equal(resolveTrafficLogFormat(invalid, "development"), "pretty");
  }
});

test("pretty HTTP records have two short lines, identity and UTC without expanding payloads", () => {
  const value = {
    ...record(),
    requestHeaders: { "x-extra": "full-header" },
    responseBody: { content: "business-body".repeat(1000) },
  };
  const pretty = formatTrafficSummary(value);
  assert.equal(
    pretty,
    "2026-10-16T12:34:56.789Z INFO  HTTP 200 GET /rooms/delta 53.8ms\n  user=user-one request=request-one",
  );
  assert.equal(pretty.split("\n").length, 2);
  assert.equal(pretty.includes("business-body"), false);
  assert.equal(pretty.includes("full-header"), false);
  assert.match(
    formatTrafficSummary({ ...record(), status: 503, aborted: true }),
    /HTTP 503 GET \/rooms\/delta 53\.8ms ABORTED/,
  );
});

test("pretty realtime records retain actor, recipient, channel, event, revision, attempt and outcome", () => {
  const pretty = formatTrafficSummary({
    ...record(),
    event: "realtime_publication",
    actorUserId: "actor-one",
    recipientUserId: "recipient-two",
    channel: "inbox:user#recipient-two",
    eventType: "message_new",
    pts: 42,
    publicationId: "publication-one",
    attempt: 2,
    result: "success",
    data: { privateBusinessContent: "full-business-payload" },
  });
  for (const field of [
    "REALTIME success message_new pts=42",
    "actor=actor-one",
    "recipient=recipient-two",
    "channel=inbox:user#recipient-two",
    "attempt=2",
    "status=200",
    "request=request-one",
    "publication=publication-one",
  ])
    assert.equal(pretty.includes(field), true, field);
  assert.equal(pretty.includes("full-business-payload"), false);
  assert.equal(pretty.split("\n").length, 2);
});

test("pretty labels remove terminal escape sequences and control injection and bound long fields", () => {
  const pretty = formatTrafficSummary({
    ...record(),
    method: "\u001b[31mGET\u001b[0m\r\n",
    route:
      "/rooms/\u001b]8;;https://untrusted.test\u0007link\u001b]8;;\u0007\u0000\n\u009b31m",
    requestId: "request\r\n\u0007injected",
    userId: "u".repeat(5000),
  });
  assert.equal(pretty.split("\n").length, 2);
  assert.doesNotMatch(pretty, /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/);
  assert.equal(pretty.includes("untrusted.test"), false);
  assert.equal(pretty.includes("GET"), true);
  assert.equal(pretty.includes("user=" + "u".repeat(95) + "…"), true);
  assert.ok(pretty.length < 400);
  assert.match(formatTrafficSummary(record(), { color: true }), /\u001b\[/);
  assert.doesNotMatch(formatTrafficSummary(record()), /\u001b/);
});

test("default console output honors pretty, JSON and silent without leaking full bodies into pretty", (context) => {
  const chunks: string[] = [];
  context.mock.method(process.stdout, "write", (chunk: unknown) => {
    chunks.push(String(chunk));
    return true;
  });
  const config = new ConfigService({ NODE_ENV: "development" });
  const logger = new DebugTrafficLogger(config);
  const value = { ...record(), responseBody: { text: "complete-message" } };
  logger.write(value);
  assert.match(chunks[0], /HTTP 200 GET/);
  assert.equal(chunks[0].includes("complete-message"), false);
  config.set("TRAFFIC_LOG_FORMAT", "json");
  logger.write(value);
  assert.deepEqual(JSON.parse(chunks[1]), value);
  config.set("TRAFFIC_LOG_FORMAT", "silent");
  logger.write(value);
  assert.equal(chunks.length, 2);
});

test("closed output streams emit no unhandled error and reuse one error listener", async () => {
  const stream = new Writable({
    write(_chunk, _encoding, done) {
      done(new Error("Synthetic output failure with private details"));
    },
  });
  writeTrafficLine(stream, "first\n");
  writeTrafficLine(stream, "second\n");
  await new Promise<void>((resolve) => stream.once("close", resolve));
  assert.equal(stream.listenerCount("error"), 1);
});

test("private JSONL files append old contents, resolve relative paths and preserve asynchronous record order", async () => {
  const directory = await fixture();
  const path = join(directory, "traffic.jsonl");
  await writeFile(path, "existing capture\n", { mode: 0o644 });
  const sink = new AsyncJsonlTrafficSink({
    path: "traffic.jsonl",
    cwd: directory,
    warn: () => undefined,
  });
  for (let index = 0; index < 200; index++)
    assert.equal(sink.append(record(`request-${index}`)), true);
  assert.ok(sink.stats().pendingRecords > 0);
  await sink.flush();
  assert.equal(sink.stats().pendingRecords, 0);
  assert.equal(sink.stats().pendingBytes, 0);
  assert.equal(sink.stats().writtenRecords, 200);
  const lines = (await readFile(path, "utf8")).trimEnd().split("\n");
  assert.equal(lines.shift(), "existing capture");
  assert.deepEqual(
    lines.map((line) => JSON.parse(line).requestId),
    Array.from({ length: 200 }, (_, index) => `request-${index}`),
  );
  assert.equal((await stat(path)).mode & 0o777, 0o600);
  await sink.close();
  assert.equal(sink.stats().closed, true);
  assert.equal(sink.append(record()), false);
  assert.equal(sink.stats().droppedRecords, 1);
  await sink.close();
});

test("new nested log directories and files are private while existing parent permissions are preserved", async () => {
  const directory = await fixture();
  await chmod(directory, 0o755);
  const path = join(directory, "private", "nested", "traffic.jsonl");
  const sink = new AsyncJsonlTrafficSink({ path });
  sink.append(record());
  await sink.close();
  assert.equal((await stat(directory)).mode & 0o777, 0o755);
  assert.equal((await stat(join(directory, "private"))).mode & 0o777, 0o700);
  assert.equal(
    (await stat(join(directory, "private", "nested"))).mode & 0o777,
    0o700,
  );
  assert.equal((await stat(path)).mode & 0o777, 0o600);
});

test("file targets and directory ancestors that are symbolic links are rejected without touching the destination", async () => {
  const directory = await fixture();
  const destination = join(directory, "original.jsonl");
  const alias = join(directory, "alias.jsonl");
  await writeFile(destination, "preserve this existing data\n");
  await symlink(destination, alias);
  const warnings: string[] = [];
  const sink = new AsyncJsonlTrafficSink({
    path: alias,
    warn: (text) => warnings.push(text),
  });
  sink.append(record());
  await sink.close();
  assert.equal(sink.stats().failedRecords, 1);
  assert.equal(sink.stats().failureCount, 1);
  assert.equal(
    await readFile(destination, "utf8"),
    "preserve this existing data\n",
  );
  const directoryAlias = join(directory, "alias-directory");
  await symlink(directory, directoryAlias);
  const nested = new AsyncJsonlTrafficSink({
    path: join(directoryAlias, "must-not-create", "traffic.jsonl"),
    warn: (text) => warnings.push(text),
  });
  nested.append(record());
  await nested.close();
  assert.equal(nested.stats().failedRecords, 1);
  await assert.rejects(stat(join(directory, "must-not-create")), {
    code: "ENOENT",
  });
  assert.equal(warnings.length, 2);
  assert.equal(
    warnings.some((warning) => warning.includes(directory)),
    false,
  );
});

test("bounded byte queue drops excess captures, warns once and flushes accepted data", async () => {
  const directory = await fixture();
  const path = join(directory, "traffic.jsonl");
  const value = record();
  const bytes = Buffer.byteLength(`${JSON.stringify(value)}\n`);
  const warnings: string[] = [];
  const sink = new AsyncJsonlTrafficSink({
    path,
    maxPendingBytes: bytes,
    warn: (message) => warnings.push(message),
  });
  assert.equal(sink.append(value), true);
  assert.equal(sink.append(value), false);
  assert.equal(sink.append(value), false);
  assert.equal(sink.stats().pendingBytes, bytes);
  assert.equal(sink.stats().droppedRecords, 2);
  assert.equal(warnings.length, 1);
  await sink.flush();
  assert.equal(sink.append(value), true);
  await sink.close();
  assert.equal(sink.stats().writtenRecords, 2);
  assert.equal((await readFile(path, "utf8")).trim().split("\n").length, 2);
  assert.equal(warnings.length, 1);
});

test("hard-linked existing files are rejected without appending or changing destination permissions", async () => {
  const directory = await fixture();
  const original = join(directory, "existing.jsonl");
  const alias = join(directory, "linked.jsonl");
  await writeFile(original, "preserved existing contents", { mode: 0o644 });
  await link(original, alias);
  const sink = new AsyncJsonlTrafficSink({
    path: alias,
    warn: () => undefined,
  });
  sink.append(record());
  await sink.close();
  assert.equal(sink.stats().failedRecords, 1);
  assert.equal(await readFile(original, "utf8"), "preserved existing contents");
  assert.equal((await stat(original)).mode & 0o777, 0o644);
});

test("storage failures are isolated, counted once and never reveal raw errors or paths", async () => {
  const directory = await fixture();
  const blocked = join(directory, "private-path-blocker");
  await writeFile(blocked, "existing-data");
  const warnings: string[] = [];
  const sink = new AsyncJsonlTrafficSink({
    path: join(blocked, "traffic.jsonl"),
    warn: (message) => warnings.push(message),
  });
  sink.append(record("accepted-before-failure"));
  sink.append(record("also-accepted-before-failure"));
  await sink.flush();
  assert.equal(sink.stats().failed, true);
  assert.equal(sink.stats().failureCount, 1);
  assert.equal(sink.stats().failedRecords, 2);
  assert.equal(sink.stats().pendingRecords, 0);
  assert.equal(sink.append(record("after-failure")), false);
  assert.equal(sink.stats().droppedRecords, 1);
  assert.equal(warnings.length, 1);
  assert.ok(warnings[0].length < 120);
  assert.equal(warnings[0].includes(directory), false);
  assert.equal(warnings[0].includes("private-path-blocker"), false);
  assert.equal(await readFile(blocked, "utf8"), "existing-data");
  await sink.close();
});

test("disabled file output has no sink and silent console still allows explicit file capture", async () => {
  for (const value of [undefined, "", " ", "off", "OFF"]) {
    const logger = new DebugTrafficLogger(
      new ConfigService({ TRAFFIC_LOG_FILE: value }),
    );
    assert.equal(logger.fileStats(), null);
    await logger.onModuleDestroy();
  }
  const path = join(await fixture(), "traffic.jsonl");
  const logger = new DebugTrafficLogger(
    new ConfigService({
      TRAFFIC_LOG_FILE: path,
      TRAFFIC_LOG_FORMAT: "silent",
    }),
  );
  logger.write(record());
  await logger.onModuleDestroy();
  assert.equal(
    JSON.parse(await readFile(path, "utf8")).requestId,
    "request-one",
  );
  assert.equal(logger.fileStats()?.closed, true);
});

test("file and console receive one detached redacted snapshot and throwing writers cannot stop capture", async () => {
  const path = join(await fixture(), "traffic.jsonl");
  const logger = new DebugTrafficLogger(
    new ConfigService({ TRAFFIC_LOG_FILE: path }),
  );
  let getterCalls = 0;
  const body = {
    get content() {
      getterCalls++;
      return "complete business content";
    },
    password: "private-password",
    imageUrl: "https://assets.test/photo?access_token=private-query",
  };
  const safeRecords: TrafficLogRecord[] = [];
  logger.writer = (safe) => {
    safeRecords.push(safe);
    (safe.requestBody as Record<string, unknown>).content = "writer mutation";
    throw new Error("Private console failure details");
  };
  assert.doesNotThrow(() => logger.write({ ...record(), requestBody: body }));
  await logger.onModuleDestroy();
  const written = JSON.parse(await readFile(path, "utf8"));
  assert.equal(getterCalls, 1);
  assert.equal(written.requestBody.content, "complete business content");
  assert.equal(written.requestBody.password, "[REDACTED]");
  assert.equal(
    written.requestBody.imageUrl,
    "https://assets.test/photo?access_token=[REDACTED]",
  );
  assert.equal(
    (safeRecords[0].requestBody as Record<string, unknown>).password,
    "[REDACTED]",
  );
  assert.equal(body.password, "private-password");
  assert.equal(logger.fileStats()?.writtenRecords, 1);
});

test("a failed file never prevents the replaceable record writer from receiving later requests", async (context) => {
  const directory = await fixture();
  const blocked = join(directory, "blocked");
  await writeFile(blocked, "preserved");
  context.mock.method(process.stderr, "write", () => true);
  const logger = new DebugTrafficLogger(
    new ConfigService({
      TRAFFIC_LOG_FILE: join(blocked, "traffic.jsonl"),
    }),
  );
  const received: string[] = [];
  logger.writer = (safe) => received.push(safe.requestId!);
  logger.write(record("before-storage-failure"));
  await logger.flush();
  logger.write(record("after-storage-failure"));
  await logger.onModuleDestroy();
  assert.deepEqual(received, [
    "before-storage-failure",
    "after-storage-failure",
  ]);
  assert.equal(logger.fileStats()?.failedRecords, 1);
  assert.equal(logger.fileStats()?.droppedRecords, 1);
});

test("an unexpectedly throwing file sink cannot interrupt console output or propagate to callers", async (context) => {
  const logger = new DebugTrafficLogger(
    new ConfigService({
      TRAFFIC_LOG_FILE: join(await fixture(), "traffic.jsonl"),
    }),
  );
  const sink = (logger as unknown as { fileSink: AsyncJsonlTrafficSink })
    .fileSink;
  context.mock.method(sink, "append", () => {
    throw new Error("Unexpected private storage failure details");
  });
  const received: string[] = [];
  logger.writer = (safe) => received.push(safe.requestId!);
  assert.doesNotThrow(() => logger.write(record("isolated-file-failure")));
  assert.deepEqual(received, ["isolated-file-failure"]);
  await logger.onModuleDestroy();
});

test("oversized producer payloads leave a bounded explicit omission and health sidecar", async () => {
  const directory = await fixture();
  const path = join(directory, "traffic.jsonl");
  const sink = new AsyncJsonlTrafficSink({
    path,
    reportStatus: true,
    warn: () => {},
  });
  sink.append({
    ...record("oversized"),
    actorUserId: "publish-actor",
    channel: "inbox:user#publish-recipient",
    pts: 7,
    responseBody: { text: "private".repeat(180000) },
  });
  await sink.close();
  const captured = await readFile(path, "utf8");
  assert.ok(Buffer.byteLength(captured) < 1024 * 1024 - 4096);
  assert.doesNotMatch(captured, /private/);
  const value = JSON.parse(captured);
  assert.equal(value.requestId, "oversized");
  assert.equal(value.actorUserId, "publish-actor");
  assert.equal(value.channel, "inbox:user#publish-recipient");
  assert.equal(value.pts, 7);
  assert.equal(value.payloadOmitted, true);
  assert.equal(value.omissionReason, "record_byte_limit");
  assert.ok(value.omittedBytes > 1024 * 1024);
  const status = JSON.parse(await readFile(`${path}.status.json`, "utf8"));
  assert.equal(status.omittedRecords, 1);
  assert.equal(status.writtenRecords, 1);
  assert.ok(status.lastSuccessAt);
  assert.equal((await stat(`${path}.status.json`)).mode & 0o777, 0o600);
});

test("temporary storage exhaustion loses ambiguous writes once and later safely reopens", async () => {
  const path = join(await fixture(), "traffic.jsonl");
  const sink = new AsyncJsonlTrafficSink({
    path,
    retryBackoffMs: 1,
    warn: () => {},
  });
  sink.append(record("before"));
  await sink.flush();
  const handle = (sink as any).file;
  const append = handle.appendFile.bind(handle);
  handle.appendFile = async () => {
    await append("{torn-private-record");
    throw Object.assign(new Error("private"), { code: "ENOSPC" });
  };
  sink.append(record("ambiguous"));
  await sink.flush();
  assert.equal(sink.stats().failed, true);
  assert.equal(sink.stats().permanentFailure, false);
  await new Promise((resolve) => setTimeout(resolve, 5));
  sink.append(record("recovered"));
  await sink.close();
  assert.equal(sink.stats().recoveries, 1);
  assert.equal(sink.stats().writtenRecords, 2);
  assert.equal(sink.stats().failedRecords, 1);
  assert.deepEqual(
    (await readFile(path, "utf8"))
      .trim()
      .split("\n")
      .filter((line) => line && !line.startsWith("{torn-private-record"))
      .map((line) => JSON.parse(line).requestId),
    ["before", "recovered"],
  );
});

test("important failures use reserved capacity and evict ordinary queued noise before losing failures", async () => {
  const path = join(await fixture(), "traffic.jsonl");
  const ordinary = record("ordinary-one");
  const ordinaryBytes = Buffer.byteLength(`${JSON.stringify(ordinary)}\n`);
  const sink = new AsyncJsonlTrafficSink({
    path,
    maxPendingBytes: ordinaryBytes * 2 + 32,
    importantReserveBytes: 600,
    warn: () => {},
  });
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const originalOpen = (sink as any).openFile.bind(sink);
  (sink as any).openFile = async () => {
    await gate;
    return originalOpen();
  };
  assert.equal(sink.append(ordinary), true);
  assert.equal(sink.append(record("ordinary-two")), true);
  assert.equal(sink.append(record("ordinary-over-budget")), false);
  assert.equal(
    sink.append({ ...record("reserved-failure"), status: 503 }),
    true,
  );
  assert.equal(sink.stats().evictedRecords, 0);
  assert.equal(
    sink.append({ ...record("priority-failure"), level: "error" }),
    true,
  );
  assert.ok(sink.stats().evictedRecords > 0);
  assert.equal(sink.stats().importantDroppedRecords, 0);
  assert.equal(sink.stats().importantPendingRecords, 2);
  assert.ok(sink.stats().pendingBytes <= ordinaryBytes * 2 + 632);
  release();
  await sink.close();
  const values = (await readFile(path, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.deepEqual(
    values.filter((value) => value.logRecordId).map((value) => value.requestId),
    ["reserved-failure", "priority-failure"],
  );
  assert.equal(sink.stats().importantWrittenRecords, 2);
  assert.equal(sink.stats().importantPendingRecords, 0);
});

test("an important-only saturated queue reports explicit important loss without exceeding its byte bound", async () => {
  const sink = new AsyncJsonlTrafficSink({
    path: join(await fixture(), "traffic.jsonl"),
    maxPendingBytes: 300,
    importantReserveBytes: 300,
    warn: () => {},
  });
  assert.equal(
    sink.append({ ...record("first-failure"), level: "warn" }),
    true,
  );
  assert.equal(
    sink.append({ ...record("second-failure"), result: "failure" }),
    false,
  );
  assert.equal(sink.stats().importantDroppedRecords, 1);
  assert.equal(sink.stats().droppedRecords, 1);
  assert.ok(sink.stats().pendingBytes <= 600);
  await sink.close();
  assert.equal(sink.stats().importantWrittenRecords, 1);
});

test("important admission cannot evict the ordinary entry reserved across an asynchronous pre-write stat", async () => {
  const path = join(await fixture(), "traffic.jsonl");
  const ordinary = record("inflight-ordinary");
  const bytes = Buffer.byteLength(`${JSON.stringify(ordinary)}\n`);
  const sink = new AsyncJsonlTrafficSink({
    path,
    maxPendingBytes: bytes * 2 + 32,
    importantReserveBytes: 900,
    warn: () => {},
  });
  sink.append(record("seed"));
  await sink.flush();
  const handle = (sink as any).file;
  const statFile = handle.stat.bind(handle);
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let block = true;
  handle.stat = async () => {
    if (block) {
      block = false;
      await gate;
    }
    return statFile();
  };
  sink.append(ordinary);
  sink.append(record("queued-ordinary"));
  sink.append({ ...record("important-one"), level: "error" });
  sink.append({ ...record("important-two"), level: "warn" });
  assert.equal(sink.stats().evictedRecords, 1);
  assert.equal(sink.stats().importantDroppedRecords, 0);
  release();
  await sink.close();
  const requests = (await readFile(path, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line).requestId);
  assert.deepEqual(requests, [
    "seed",
    "inflight-ordinary",
    "important-one",
    "important-two",
  ]);
  assert.equal(sink.stats().writtenRecords, 4);
  assert.equal(sink.stats().droppedRecords, 1);
});

test("important admitted failures automatically recover from a known zero-write storage outage without a new append", async () => {
  const path = join(await fixture(), "traffic.jsonl");
  const sink = new AsyncJsonlTrafficSink({
    path,
    retryBackoffMs: 1,
    importantRetryWindowMs: 1000,
    warn: () => {},
  });
  const originalOpen = (sink as any).openFile.bind(sink);
  let failures = 1;
  (sink as any).openFile = async () => {
    if (failures-- > 0)
      throw Object.assign(new Error("private path"), { code: "ENOSPC" });
    return originalOpen();
  };
  assert.equal(
    sink.append({ ...record("retained-important"), status: 401 }),
    true,
  );
  await sink.flush();
  assert.equal(sink.stats().importantWrittenRecords, 1);
  assert.equal(sink.stats().importantFailedRecords, 0);
  assert.equal(sink.stats().importantDroppedRecords, 0);
  assert.equal(sink.stats().recoveries, 1);
  assert.equal(
    JSON.parse((await readFile(path, "utf8")).trim()).requestId,
    "retained-important",
  );
  await sink.close();
});

test("a partial important append retries with explicit uncertainty and preserves the following important record", async () => {
  const path = join(await fixture(), "traffic.jsonl");
  const sink = new AsyncJsonlTrafficSink({
    path,
    retryBackoffMs: 1,
    importantRetryWindowMs: 1000,
    warn: () => {},
  });
  sink.append(record("before"));
  await sink.flush();
  const handle = (sink as any).file;
  const append = handle.appendFile.bind(handle);
  handle.appendFile = async () => {
    await append('{"torn":');
    throw Object.assign(new Error("private partial append"), {
      code: "ENOSPC",
    });
  };
  sink.append({ ...record("important-recovered"), level: "error" });
  sink.append({ ...record("following-important"), level: "warn" });
  await sink.close();
  const lines = (await readFile(path, "utf8")).trim().split("\n");
  assert.equal(lines.filter((line) => line === '{"torn":').length, 1);
  const values = lines
    .filter((line) => line !== '{"torn":')
    .map((line) => JSON.parse(line));
  assert.deepEqual(
    values.map((value) => value.requestId),
    ["before", "important-recovered", "following-important"],
  );
  assert.equal(values[1].logDeliveryAttempt, 2);
  assert.equal(values[1].logPreviousWriteOutcome, "uncertain");
  assert.match(values[1].logRecordId, /^[a-f0-9]{32}$/);
  assert.equal(values[1].data.logDelivery.logRecordId, values[1].logRecordId);
  assert.equal(values[1].data.logDelivery.logDeliveryAttempt, 2);
  assert.equal(values[1].data.logDelivery.logPreviousWriteOutcome, "uncertain");
  assert.equal(sink.stats().importantWrittenRecords, 2);
  assert.equal(sink.stats().importantUncertainRecords, 1);
  assert.equal(sink.stats().retriedRecords, 1);
  assert.equal(sink.stats().importantFailedRecords, 0);
});

test("a committed append with rejected acknowledgement replays with the same explicit identity and uncertainty", async () => {
  const path = join(await fixture(), "traffic.jsonl");
  const sink = new AsyncJsonlTrafficSink({
    path,
    retryBackoffMs: 1,
    importantRetryWindowMs: 1000,
    warn: () => {},
  });
  sink.append(record("before"));
  await sink.flush();
  const handle = (sink as any).file;
  const append = handle.appendFile.bind(handle);
  handle.appendFile = async (line: string) => {
    await append(line);
    throw Object.assign(new Error("private lost acknowledgement"), {
      code: "EIO",
    });
  };
  const input = {
    ...record("ambiguous-important"),
    level: "error" as const,
    data: { operation: "retained", logDelivery: { producer: "fixture" } },
  };
  sink.append(input);
  const existingData = [
    null,
    false,
    42,
    "retained",
    ["retained"],
    { logDelivery: { application: "unchanged" } },
    undefined,
  ];
  for (const [index, data] of existingData.entries())
    sink.append({ ...record(`existing-data-${index}`), level: "warn", data });
  await sink.close();
  const captured = (await readFile(path, "utf8"))
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const values = captured.filter(
    (value) => value.requestId === "ambiguous-important",
  );
  assert.equal(values.length, 2);
  assert.equal(values[0].logRecordId, values[1].logRecordId);
  assert.deepEqual(
    values.map((value) => value.logDeliveryAttempt),
    [1, 2],
  );
  assert.equal(values[1].logPreviousWriteOutcome, "uncertain");
  for (const value of values) {
    assert.deepEqual(
      value.data,
      input.data,
      "Captured publication data stays exact even when a record retries",
    );
  }
  for (const [index, data] of existingData.entries()) {
    const value = captured.find(
      (row) => row.requestId === `existing-data-${index}`,
    );
    assert.deepEqual(value.data, data);
    if (data === undefined) assert.equal(Object.hasOwn(value, "data"), false);
  }
  assert.deepEqual(input.data, {
    operation: "retained",
    logDelivery: { producer: "fixture" },
  });
  assert.equal(sink.stats().importantUncertainRecords, 1);
  assert.equal(sink.stats().importantWrittenRecords, 1 + existingData.length);
  assert.equal(sink.stats().importantFailedRecords, 0);
});

test("persistent transient failure expires important retries within the explicit retention window", async () => {
  const sink = new AsyncJsonlTrafficSink({
    path: join(await fixture(), "traffic.jsonl"),
    retryBackoffMs: 2,
    importantRetryWindowMs: 12,
    warn: () => {},
  });
  (sink as any).openFile = async () => {
    throw Object.assign(new Error("private disk outage"), { code: "ENOSPC" });
  };
  assert.equal(
    sink.append({ ...record("expires-important"), level: "error" }),
    true,
  );
  await sink.close();
  assert.equal(sink.stats().importantFailedRecords, 1);
  assert.equal(sink.stats().failedRecords, 1);
  assert.equal(sink.stats().importantPendingRecords, 0);
  assert.equal(sink.stats().pendingBytes, 0);
  assert.equal(sink.stats().importantWrittenRecords, 0);
});

test("oversized important failures preserve bounded identity/status and delivery metadata", async () => {
  const path = join(await fixture(), "traffic.jsonl");
  const sink = new AsyncJsonlTrafficSink({ path });
  sink.append({
    ...record("oversized-important"),
    status: 503,
    responseBody: { privateBody: "x".repeat(1024 * 1024) },
  });
  await sink.close();
  const value = JSON.parse((await readFile(path, "utf8")).trim());
  assert.equal(value.requestId, "oversized-important");
  assert.equal(value.status, 503);
  assert.equal(value.payloadOmitted, true);
  assert.equal(value.omissionReason, "record_byte_limit");
  assert.match(value.logRecordId, /^[a-f0-9]{32}$/);
  assert.equal(value.logDeliveryAttempt, 1);
  assert.equal(sink.stats().importantWrittenRecords, 1);
  assert.equal(sink.stats().omittedRecords, 1);
  assert.equal(value.responseBody, undefined);
});

test("full payloads require development or the explicit production override", () => {
  for (const environment of ["production", "test", "staging"]) {
    const config = new ConfigService({
      NODE_ENV: environment,
      DEBUG_TRAFFIC_LOGGING_ENABLED: "true",
    });
    assert.equal(new DebugTrafficLogger(config).debugEnabled, false);
  }
  assert.equal(
    new DebugTrafficLogger(
      new ConfigService({
        NODE_ENV: "development",
        DEBUG_TRAFFIC_LOGGING_ENABLED: "true",
      }),
    ).debugEnabled,
    true,
  );
  assert.equal(
    new DebugTrafficLogger(
      new ConfigService({
        NODE_ENV: "production",
        DEBUG_TRAFFIC_LOGGING_ENABLED: "true",
        ALLOW_PRODUCTION_DEBUG_TRAFFIC_LOGGING: "true",
      }),
    ).debugEnabled,
    true,
  );
});
