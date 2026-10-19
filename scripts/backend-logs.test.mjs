import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  appendFile,
  chmod,
  copyFile,
  link,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import http from "node:http";
import { join } from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import {
  GO_TOOLCHAIN,
  LOGDY_VERSION,
  childEnvironment,
  createViewerLayout,
  compactCentrifugo,
  ensureLogFile,
  parseArguments,
  startLogViewer,
  verifyPinnedFile,
  viewerPaths,
} from "./backend-logs.mjs";
import {
  createLogProxy,
  parseProxyPath,
  rewriteStatus,
} from "./backend-logs-proxy.mjs";

async function temporaryRoot(t) {
  const root = await realpath(await mkdtemp("/tmp/chat-log-viewer-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

function request(url, { path = "/", method = "GET", headers = {}, body } = {}) {
  return new Promise((resolveRequest, rejectRequest) => {
    const parsed = new URL(url);
    const req = http.request(
      {
        hostname: parsed.hostname,
        port: parsed.port,
        path,
        method,
        headers,
        agent: false,
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("error", rejectRequest);
        response.on("end", () => {
          resolveRequest({
            status: response.statusCode,
            headers: response.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.on("error", rejectRequest);
    req.end(body);
  });
}

async function proxyFixture(t, handler) {
  const root = await temporaryRoot(t);
  const socketPath = join(root, "viewer.sock");
  const seen = [];
  const upstreamSockets = new Set();
  const upstream = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    seen.push({
      url: req.url,
      headers: req.headers,
      body: Buffer.concat(chunks).toString(),
    });
    if (handler) return handler(req, res);
    if (req.url === "/api/status") {
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      });
      return res.end(
        JSON.stringify({
          authRequired: true,
          apiPrefix: "/private/",
          analyticsEnabled: false,
        }),
      );
    }
    res.writeHead(200, {
      "Content-Type": "text/plain",
      "Access-Control-Allow-Origin": "*",
    });
    res.end("viewer content");
  });
  upstream.on("connection", (socket) => {
    upstreamSockets.add(socket);
    socket.once("close", () => upstreamSockets.delete(socket));
  });
  upstream.on("upgrade", (req, socket, head) => {
    seen.push({ url: req.url, headers: req.headers, upgrade: true });
    const accept = createHash("sha1")
      .update(
        `${req.headers["sec-websocket-key"]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`,
      )
      .digest("base64");
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
    if (head.length) socket.write(head);
    socket.on("error", () => {});
    socket.on("data", (data) => socket.write(data));
  });
  await new Promise((resolveListen) =>
    upstream.listen(socketPath, resolveListen),
  );
  const proxy = await createLogProxy({
    upstreamSocketPath: socketPath,
    port: 0,
  });
  t.after(async () => {
    await proxy.close();
    for (const socket of upstreamSockets) socket.destroy();
    await new Promise((resolveClose) => upstream.close(resolveClose));
  });
  return { ...proxy, upstream, seen, root };
}

test("CLI validates commands and only accepts an explicit file on start", () => {
  assert.deepEqual(parseArguments([]), { command: "start" });
  assert.deepEqual(parseArguments(["start", "--file", "saved logs.jsonl"]), {
    command: "start",
    file: "saved logs.jsonl",
  });
  for (const args of [
    ["run"],
    ["install", "--file", "x"],
    ["start", "--file"],
    ["start", "--port", "3000"],
  ]) {
    assert.throws(() => parseArguments(args), /Use node/);
  }
});

test("isolated paths and child environment cannot inherit application configuration", () => {
  const paths = viewerPaths("/workspace");
  assert.equal(paths.logFile, "/workspace/.runtime/backend-logs/traffic.jsonl");
  assert.match(
    paths.binary,
    /\.runtime\/backend-log-viewer\/logdy-bridge-[a-f0-9]{16}$/,
  );
  assert.equal(LOGDY_VERSION, "0.17.1");
  assert.match(GO_TOOLCHAIN.sha256, /^[a-f0-9]{64}$/);
  assert.match(GO_TOOLCHAIN.url, /^https:\/\/go\.dev\/dl\//);
  assert.deepEqual(
    childEnvironment({
      PATH: "/bin",
      HOME: "/private-home",
      LANG: "en",
      LOGDY_CONFIG: "untrusted",
      LOGDY_UI_IP: "0.0.0.0",
      NODE_OPTIONS: "bad",
      JWT_SECRET: "secret",
      GOPROXY: "untrusted",
    }),
    { PATH: "/bin", HOME: "/private-home", LANG: "en" },
  );
});

test("trusted UI layout has bounded records, visible actor and useful facets", () => {
  const layout = createViewerLayout();
  assert.equal(layout.settings.maxMessages, 10000);
  assert.equal(layout.settings.entriesOrder, "desc");
  const actor = layout.columns.find((column) => column.id === "chat-userId");
  assert.equal(actor.hidden, false);
  assert.equal(actor.faceted, true);
  assert.equal(
    layout.columns.find((column) => column.id === "chat-requestId").hidden,
    true,
  );
  const operation = layout.columns.find((column) => column.id === "chat-event");
  assert.equal(operation.name, "Operation / event");
  const summary = layout.columns.find((column) => column.id === "chat-summary");
  assert.equal(summary.name, "What happened");
  assert.equal(summary.hidden, false);
  const channel = layout.columns.find((column) => column.id === "chat-channel");
  assert.equal(channel.hidden, false);
  assert.equal(channel.faceted, true);
  assert.match(channel.handlerTsCode, /data\.channel.*data\.data\?\.channels/);
  assert.equal(
    layout.columns.find((column) => column.id === "chat-result").hidden,
    false,
  );
  assert.equal(
    layout.columns.find((column) => column.id === "chat-attempt").faceted,
    true,
  );
  for (const field of ["databaseName", "collection"]) {
    const column = layout.columns.find(
      (column) => column.id === `chat-${field}`,
    );
    assert.equal(column.hidden, true);
    assert.equal(column.faceted, true);
  }
  assert.match(
    operation.handlerTsCode,
    /data\.name \?\? data\.operation \?\? data\.event/,
  );
  const eventKind = layout.columns.find(
    (column) => column.id === "chat-eventKind",
  );
  assert.equal(eventKind.hidden, true);
  assert.equal(eventKind.faceted, true);
  assert.match(eventKind.handlerTsCode, /const value = data\.event;/);
  assert.match(layout.settings.middlewares[0].handlerTsCode, /correlation_id/);
});

test("viewer renders native HTTP method, path, status, duration and original level", () => {
  const layout = createViewerLayout();
  const record = {
    level: "debug",
    name: "http.request",
    method: "POST",
    path: "/api/publish",
    route: "/api/publish",
    status: 200,
    durationMs: 0.158792,
    summary: "POST /api/publish HTTP 200 in 158.792µs",
  };
  for (const [field, expected] of [
    ["level", "debug"],
    ["event", "http.request"],
    ["method", "POST"],
    ["route", "/api/publish"],
    ["status", "200"],
    ["durationMs", "0.158792"],
    ["summary", record.summary],
  ]) {
    const column = layout.columns.find((value) => value.id === `chat-${field}`);
    assert.equal(column.hidden, false);
    const render = runInNewContext(
      column.handlerTsCode.replace(
        "(line: Message): CellHandler =>",
        "(line) =>",
      ),
    );
    assert.equal(render({ json_content: record }).text, expected);
  }
});

test("viewer renders current queue aliases and older nested retry metadata", () => {
  const layout = createViewerLayout();
  const render = (field, record) =>
    runInNewContext(
      layout.columns
        .find((column) => column.id === `chat-${field}`)
        .handlerTsCode.replace("(line: Message): CellHandler =>", "(line) =>"),
    )({ json_content: record }).text;
  const data = {
    operationId: "stable-operation",
    attempt: 2,
    retryCount: 2,
    enqueueOrder: 7,
    queuedCount: 3,
    failedCount: 1,
    pausedCount: 0,
    sessionPhysicalAttempts: 9,
    healthStatus: "unavailable",
    reason: "server_unavailable",
    nextRetryAt: "2026-10-18T12:00:05.000Z",
    outcomeUnknown: true,
  };
  for (const record of [
    { category: "outbox", data },
    { category: "outbox", ...data },
  ]) {
    for (const [field, expected] of Object.entries(data)) {
      assert.equal(render(field, record), String(expected), field);
      assert.equal(
        layout.columns.find((column) => column.id === `chat-${field}`).hidden,
        true,
      );
    }
  }
  assert.equal(render("attempt", { attempt: 1, data: { attempt: 9 } }), "1");
  assert.equal(
    viewerPaths("/tmp/example").layout.endsWith("layout-services-v11.json"),
    true,
  );
});

test("Cairo timestamps use 12-hour AM/PM display across noon, midnight and DST", () => {
  const column = createViewerLayout().columns.find(
    (entry) => entry.id === "chat-timestamp",
  );
  const render = runInNewContext(
    column.handlerTsCode.replace(
      "(line: Message): CellHandler =>",
      "(line) =>",
    ),
  );
  assert.ok(column.width >= 165);
  for (const [timestamp, expected] of [
    ["2026-10-18T18:42:01.123Z", "18 09:42:01 PM"],
    ["2026-10-18T09:00:00.000Z", "18 12:00:00 PM"],
    ["2026-10-17T21:00:00.000Z", "18 12:00:00 AM"],
    ["2026-01-18T19:42:01.000Z", "18 09:42:01 PM"],
  ]) {
    const line = { json_content: { timestamp } };
    assert.equal(render(line).text, expected);
    assert.equal(line.json_content.timestamp, timestamp);
  }
  assert.equal(
    render({ json_content: { timestamp: "invalid" } }).text,
    "invalid",
  );
  assert.equal(render({ json_content: {} }).text, "—");
});

test("log file preparation is append-only and creates private files and directories", async (t) => {
  const root = await temporaryRoot(t);
  const file = join(root, "logs", "traffic.jsonl");
  await ensureLogFile(file);
  assert.equal((await lstat(join(root, "logs"))).mode & 0o777, 0o700);
  assert.equal((await lstat(file)).mode & 0o777, 0o600);
  await appendFile(file, '{"event":"existing"}\n');
  await chmod(file, 0o644);
  await ensureLogFile(file);
  assert.equal(await readFile(file, "utf8"), '{"event":"existing"}\n');
  assert.equal((await lstat(file)).mode & 0o777, 0o600);
});

test("log file preparation rejects links, FIFO and linked ancestors without changing data", async (t) => {
  const root = await temporaryRoot(t);
  const original = join(root, "original.jsonl");
  await writeFile(original, "preserve");
  const symbolic = join(root, "symbolic.jsonl");
  const hard = join(root, "hard.jsonl");
  await symlink(original, symbolic);
  await link(original, hard);
  await assert.rejects(ensureLogFile(symbolic), /regular log file/);
  await assert.rejects(ensureLogFile(hard), /regular log file/);
  const fifo = join(root, "fifo");
  execFileSync("/usr/bin/mkfifo", [fifo]);
  await assert.rejects(ensureLogFile(fifo), /regular log file/);
  await mkdir(join(root, "target"));
  await symlink(join(root, "target"), join(root, "linked"));
  await assert.rejects(
    ensureLogFile(join(root, "linked", "traffic.jsonl"), {
      createParent: false,
    }),
    /symbolic links/,
  );
  assert.equal(await readFile(original, "utf8"), "preserve");
});

test("pinned artifact verification rejects mismatches and symbolic links without overwrites", async (t) => {
  const root = await temporaryRoot(t);
  const binary = join(root, "artifact");
  await writeFile(binary, "trusted");
  const expected = createHash("sha256").update("trusted").digest("hex");
  assert.equal(await verifyPinnedFile(binary, expected), true);
  assert.equal(await verifyPinnedFile(binary, "0".repeat(64)), false);
  await symlink(binary, join(root, "alias"));
  assert.equal(await verifyPinnedFile(join(root, "alias"), expected), false);
  assert.equal(await readFile(binary, "utf8"), "trusted");
});

test("canonical path handling rejects traversal, encoded slashes and malformed input", () => {
  for (const path of [
    "//evil/",
    "/../api/status",
    "/api/./status",
    "/%2e%2e/api/status",
    "/api%2flog",
    "/api%5clog",
    "/api%252flog",
    "/api/%00",
    "/%ff",
    "/a\\b",
    "http://evil/",
  ]) {
    assert.equal(parseProxyPath(path), null, path);
  }
  assert.equal(
    parseProxyPath("/ap%69/config/save").pathname,
    "/api/config/save",
  );
  assert.equal(parseProxyPath("/api/status?filter=%2f").search, "?filter=%2f");
});

test("status rewriting recognizes upstream field spellings", () => {
  for (const [auth, prefix] of [
    ["AuthRequired", "ApiPrefix"],
    ["auth_required", "api_prefix"],
    ["authRequired", "apiPrefix"],
  ]) {
    assert.deepEqual(rewriteStatus({ [auth]: true, [prefix]: "/private/" }), {
      [auth]: false,
      [prefix]: "/",
    });
  }
  assert.throws(() => rewriteStatus([]), /Invalid/);
});

test("local viewer serves assets/status, strips CORS and forwards only permitted headers", async (t) => {
  const proxy = await proxyFixture(t);
  const response = await request(proxy.url, {
    path: "/api/status",
    headers: {
      authorization: "secret",
      cookie: "secret",
      "x-forwarded-host": "evil",
    },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers["content-type"], "application/json");
  assert.deepEqual(JSON.parse(response.body), {
    authRequired: false,
    apiPrefix: "/",
    analyticsEnabled: false,
  });
  assert.equal(response.headers["access-control-allow-origin"], undefined);
  assert.equal(response.headers["cache-control"], "no-store");
  assert.equal(response.headers["referrer-policy"], "no-referrer");
  assert.match(
    response.headers["content-security-policy"],
    /frame-ancestors 'none'/,
  );
  assert.equal(proxy.seen[0].headers.authorization, undefined);
  assert.equal(proxy.seen[0].headers.cookie, undefined);
  assert.equal(proxy.seen[0].headers["x-forwarded-host"], undefined);
  assert.equal(
    (await request(proxy.url, { path: "/assets/helper-abc.js" })).status,
    200,
  );
  for (const path of [
    "/wasm_exec.js",
    "/main.wasm",
    "/monacoeditorwork/ts.worker.bundle.js",
    "/fonts/roboto-mono-v23-latin-regular.woff2",
    "/logdy-transparent.png",
  ]) {
    assert.equal((await request(proxy.url, { path })).status, 200, path);
  }
});

test("viewer denies mutation endpoints, encoded bypasses and unknown paths before upstream", async (t) => {
  const proxy = await proxyFixture(t);
  for (const path of [
    "/api/log",
    "/api/config/save",
    "/ap%69/log",
    "/ap%69/config/save",
  ]) {
    for (const method of ["GET", "POST"]) {
      assert.equal(
        (
          await request(proxy.url, {
            path,
            method,
            headers: { "content-length": "2" },
            body: "{}",
          })
        ).status,
        405,
        `${method} ${path}`,
      );
    }
  }
  for (const path of [
    "/not-an-asset",
    "/api/unknown",
    "/ws",
    "/assets/subdir/private",
  ]) {
    assert.equal((await request(proxy.url, { path })).status, 404);
  }
  assert.equal((await request(proxy.url, { method: "PUT" })).status, 405);
  assert.equal(proxy.seen.length, 0);
});

test("viewer rejects bad Hosts, external/null origins and cross-site API or asset requests", async (t) => {
  const proxy = await proxyFixture(t);
  for (const headers of [
    { host: "evil.example" },
    { origin: "https://evil.example" },
    { origin: "null" },
    { "sec-fetch-site": "cross-site" },
    { "sec-fetch-site": "same-site" },
  ]) {
    assert.equal(
      (await request(proxy.url, { path: "/api/status", headers })).status,
      403,
    );
  }
  assert.equal(
    (
      await request(proxy.url, {
        path: "/assets/index.js",
        headers: { "sec-fetch-site": "cross-site" },
      })
    ).status,
    403,
  );
  assert.equal(
    (
      await request(proxy.url, {
        headers: {
          "sec-fetch-site": "cross-site",
          "sec-fetch-mode": "navigate",
          "sec-fetch-dest": "document",
        },
      })
    ).status,
    200,
  );
  assert.equal(proxy.seen.length, 1);
});

test("viewer permits same-origin client controls and bounds request bodies", async (t) => {
  const proxy = await proxyFixture(t);
  const body = JSON.stringify({ idxs: [1, 2] });
  assert.equal(
    (
      await request(proxy.url, {
        path: "/api/client/peek-log",
        method: "POST",
        headers: {
          origin: new URL(proxy.url).origin,
          "content-type": "application/json",
          "content-length": String(Buffer.byteLength(body)),
          "logdy-client-id": "synthetic",
        },
        body,
      })
    ).status,
    200,
  );
  assert.equal(proxy.seen[0].body, body);
  assert.equal(proxy.seen[0].headers["logdy-client-id"], "synthetic");
  assert.equal(
    (
      await request(proxy.url, {
        path: "/api/client/peek-log",
        method: "POST",
        headers: { "content-length": String(256 * 1024 + 1) },
        body: Buffer.alloc(256 * 1024 + 1),
      })
    ).status,
    413,
  );
  assert.equal(proxy.seen.length, 1);
});

test("oversized or malformed upstream status is a controlled error", async (t) => {
  const proxy = await proxyFixture(t, (_req, res) => {
    res.writeHead(200);
    res.end("x".repeat(1024 * 1024 + 1));
  });
  const response = await request(proxy.url, { path: "/api/status" });
  assert.equal(response.status, 502);
  assert.match(response.body, /viewer status/i);
});

function upgrade(url, headers = {}) {
  return new Promise((resolveUpgrade, rejectUpgrade) => {
    const parsed = new URL(url);
    const req = http.request({
      hostname: parsed.hostname,
      port: parsed.port,
      path: "/ws?should_follow=true&password=untrusted",
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-version": "13",
        "sec-websocket-key": randomBytes(16).toString("base64"),
        ...headers,
      },
    });
    req.once("upgrade", (response, socket, head) =>
      resolveUpgrade({ status: response.statusCode, socket, head }),
    );
    req.once("response", (response) => {
      response.resume();
      resolveUpgrade({ status: response.statusCode });
    });
    req.once("error", rejectUpgrade);
    req.end();
  });
}

test("WebSocket proxy requires exact origin and forwards only to its private socket", async (t) => {
  const proxy = await proxyFixture(t);
  assert.equal((await upgrade(proxy.url)).status, 403);
  assert.equal(
    (await upgrade(proxy.url, { origin: "https://evil.example" })).status,
    403,
  );
  assert.equal(
    (
      await upgrade(proxy.url, {
        origin: new URL(proxy.url).origin,
        host: "evil.example",
      })
    ).status,
    403,
  );
  const connected = await upgrade(proxy.url, {
    origin: new URL(proxy.url).origin,
  });
  assert.equal(connected.status, 101);
  assert.equal(proxy.seen.length, 1);
  assert.equal(proxy.seen[0].url, "/ws?should_follow=true");
  connected.socket.destroy();
});

test("proxy close is idempotent and releases its public listener", async (t) => {
  const proxy = await proxyFixture(t);
  assert.equal((await request(proxy.url)).status, 200);
  await proxy.close();
  await proxy.close();
  await assert.rejects(request(proxy.url), /ECONNREFUSED/);
});

function collectMessages(socket, initial) {
  const messages = [];
  let buffered = Buffer.alloc(0);
  const consume = (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    while (buffered.length >= 2) {
      const opcode = buffered[0] & 0x0f;
      let length = buffered[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffered.length < 4) return;
        length = buffered.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffered.length < 10) return;
        length = Number(buffered.readBigUInt64BE(2));
        offset = 10;
      }
      if (buffered.length < offset + length) return;
      const payload = buffered.subarray(offset, offset + length);
      buffered = buffered.subarray(offset + length);
      if (opcode === 1) messages.push(JSON.parse(payload.toString("utf8")));
    }
  };
  socket.on("data", consume);
  consume(initial);
  return async (predicate) => {
    const deadline = Date.now() + 5000;
    while (!messages.some(predicate)) {
      if (Date.now() > deadline)
        throw new Error("Expected viewer message was not delivered.");
      await new Promise((resume) => setTimeout(resume, 20));
    }
    return messages.find(predicate);
  };
}

test(
  "installed bridge streams existing and appended JSONL past its bounded ring capacity",
  {
    skip: process.env.BACKEND_LOG_VIEWER_INTEGRATION !== "1",
  },
  async (t) => {
    const root = await temporaryRoot(t);
    const installed = viewerPaths();
    const isolated = viewerPaths(root);
    await mkdir(isolated.installDir, { recursive: true, mode: 0o700 });
    await copyFile(installed.binary, isolated.binary);
    await chmod(isolated.binary, 0o700);
    await copyFile(installed.manifest, isolated.manifest);
    await chmod(isolated.manifest, 0o600);
    const file = join(root, "existing.jsonl");
    const capacity = 10000;
    const batchSize = capacity + 401;
    const batch = (event) =>
      Array.from({ length: batchSize }, (_, sequence) =>
        JSON.stringify({ event, sequence, userId: "synthetic-user" }),
      ).join("\n") + "\n";
    await writeFile(file, batch("test_existing"), { mode: 0o600 });
    const viewer = await startLogViewer({ root, file, port: 0 });
    t.after(viewer.close);
    const response = await request(viewer.url, { path: "/api/status" });
    assert.equal(response.status, 200);
    assert.equal(JSON.parse(response.body).analyticsEnabled, false);
    assert.equal(response.headers["content-type"], "application/json");
    assert.equal(JSON.parse(response.body).authRequired, false);
    const document = await request(viewer.url);
    for (const inline of document.body.matchAll(
      /<script>([\s\S]*?)<\/script>/g,
    )) {
      const hash = createHash("sha256").update(inline[1]).digest("base64");
      assert.ok(
        document.headers["content-security-policy"].includes(
          `'sha256-${hash}'`,
        ),
      );
    }
    for (const path of [
      "/wasm_exec.js",
      "/main.wasm",
      "/monacoeditorwork/ts.worker.bundle.js",
      "/fonts/roboto-mono-v23-latin-regular.woff2",
    ]) {
      assert.equal((await request(viewer.url, { path })).status, 200, path);
    }
    const sockets = await readdir(isolated.socketDir);
    assert.equal(sockets.length, 1);
    assert.equal(
      (await lstat(join(isolated.socketDir, sockets[0]))).mode & 0o777,
      0o600,
    );
    assert.equal((await lstat(isolated.socketDir)).mode & 0o777, 0o700);
    const connected = await upgrade(viewer.url, {
      origin: new URL(viewer.url).origin,
    });
    assert.equal(connected.status, 101);
    t.after(() => connected.socket.destroy());
    const waitFor = collectMessages(connected.socket, connected.head);
    const hasEvent = (event) => (message) =>
      message.messages?.some(
        (entry) =>
          entry.json_content?.event === event &&
          entry.json_content.sequence === batchSize - 1,
      );
    const preload = await waitFor(hasEvent("test_existing"));
    assert.equal(preload.status.max_count, capacity);
    assert.equal(preload.status.msg_count, capacity);
    await appendFile(file, batch("test_appended"));
    const appended = await waitFor(hasEvent("test_appended"));
    assert.equal(appended.status.max_count, capacity);
    assert.equal(appended.status.msg_count, capacity);
    await viewer.close();
    await viewer.close();
    assert.deepEqual(await readdir(isolated.socketDir), []);
    assert.equal(
      (await readFile(file, "utf8")).split("\n").filter(Boolean).length,
      batchSize * 2,
    );
  },
);

test("compact Centrifugo groups only successful checks and preserves failures and publications", () => {
  const state = { seen: new Map(), groups: new Map() };
  const row = (id, overrides = {}) => ({
    id,
    json_content: {
      source: "centrifugo",
      name: "centrifugo.batch",
      timestamp: "2026-10-18T17:00:01Z",
      instanceId: "backend-one",
      purpose: "client_status",
      channel: "inbox:user#one",
      level: "info",
      result: "success",
      ...overrides,
    },
  });
  const first = row("one");
  assert.equal(compactCentrifugo(first, state, true), first);
  assert.equal(compactCentrifugo(row("two"), state, true), null);
  assert.ok(
    compactCentrifugo(
      row("three", { purpose: "last_seen_observer" }),
      state,
      true,
    ),
  );
  assert.ok(
    compactCentrifugo(
      row("four", { result: "failure", level: "debug" }),
      state,
      true,
    ),
  );
  assert.ok(
    compactCentrifugo(row("five", { name: "centrifugo.publish" }), state, true),
  );
  assert.equal(
    compactCentrifugo(row("six", { name: "http.request" }), state, true),
    null,
  );
  assert.ok(compactCentrifugo(row("seven"), state, false));
  assert.equal(state.seen.size, 4);
  assert.equal(compactCentrifugo(first, state, true), first);
  assert.equal(state.seen.size, 4);
});
