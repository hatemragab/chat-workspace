import "reflect-metadata";
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { spawn, spawnSync, ChildProcess } from "node:child_process";
import { randomBytes, randomUUID, createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer } from "node:net";
import { resolve } from "node:path";
import { once } from "node:events";
import type { INestApplication } from "@nestjs/common";
import { JwtService } from "@nestjs/jwt";
import { ConfigService } from "@nestjs/config";
import { pathToFileURL } from "node:url";
import { parseEnv } from "node:util";

const run = randomUUID().replaceAll("-", "");
const secret = () => randomBytes(32).toString("hex");
if (process.env.NODE_ENV === "production") throw new Error("Local tests only");
const privateEnv = parseEnv(readFileSync("../centrifugo/.env", "utf8"));
Object.assign(process.env, {
  NODE_ENV: "development",
  MONGODB_URI: `mongodb://127.0.0.1:27017/chat_realtime_test_${run}?replicaSet=rs0`,
  REDIS_URL: process.env.REDIS_URL ?? "redis://127.0.0.1:6379",
  REDIS_KEY_PREFIX: `chat-realtime-test:${run}:`,
  JWT_SECRET: secret(),
  CENTRIFUGO_TOKEN_HMAC_SECRET_KEY: secret(),
  CENTRIFUGO_PROXY_SECRET: secret(),
  CENTRIFUGO_API_KEY: secret(),
  HTTP_LOGGING_ENABLED: "false",
  DEBUG_TRAFFIC_LOGGING_ENABLED: "false",
  LOCAL_SERVICE_LOG_FILE: "off",
  TRAFFIC_LOG_FILE: "off",
  REALTIME_TOKEN_USER_LIMIT: "3",
  REALTIME_TOKEN_IP_LIMIT: "7",
});
const built = (file: string) => require(`../../dist/${file}.js`);
let app: INestApplication, child: ChildProcess;
let base: string, external: string, internal: string, ws: string;
let redis: any, db: any;
let serverLogs = "";
let refreshCallbacks = 0;
const sessions: any[] = [];
const jwt = new JwtService();
async function freePort() {
  const server = createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const port = (server.address() as { port: number }).port;
  await new Promise<void>((r) => server.close(() => r()));
  return port;
}
async function eventually<T>(
  fn: () => Promise<T> | T,
  predicate: (value: T) => boolean,
  timeout = 5000,
): Promise<T> {
  const end = Date.now() + timeout;
  do {
    const value = await fn();
    if (predicate(value)) return value;
    await new Promise((r) => setTimeout(r, 30));
  } while (Date.now() < end);
  assert.fail("Timed out waiting for realtime condition");
}
async function request(
  path: string,
  session?: any,
  body?: unknown,
  method = "POST",
  status = 200,
) {
  const response = await fetch(base + path, {
    method,
    headers: {
      "content-type": "application/json",
      ...(session ? { authorization: `Bearer ${session.accessToken}` } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  assert.equal(response.status, status, `${method} ${path}: unexpected status`);
  return response.json();
}
async function api(method: string, body: object) {
  const response = await fetch(`${internal}/api/${method}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-API-Key": process.env.CENTRIFUGO_API_KEY!,
    },
    body: JSON.stringify(body),
  });
  assert.equal(response.status, 200);
  return response.json() as Promise<any>;
}
class InboxSocket {
  socket = new WebSocket(ws);
  packets: any[] = [];
  pending = new Map<number, (reply: any) => void>();
  closed = false;
  nextId = 0;
  ready: Promise<void>;
  constructor() {
    this.ready = new Promise((resolve, reject) => {
      this.socket.addEventListener("open", () => resolve(), { once: true });
      this.socket.addEventListener(
        "error",
        () => reject(new Error("WebSocket failed")),
        { once: true },
      );
    });
    this.socket.addEventListener("message", (event) => {
      for (const line of String(event.data).split("\n").filter(Boolean)) {
        const packet = JSON.parse(line);
        this.packets.push(packet);
        if (packet.id) {
          this.pending.get(packet.id)?.(packet);
          this.pending.delete(packet.id);
        }
        if (!Object.keys(packet).length) this.socket.send("{}");
      }
    });
    this.socket.addEventListener("close", () => {
      this.closed = true;
      for (const cb of this.pending.values()) cb({ disconnected: true });
      this.pending.clear();
    });
  }
  async command(body: object) {
    await this.ready;
    const id = ++this.nextId;
    const result = new Promise<any>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("Command timed out")),
        5000,
      );
      this.pending.set(id, (value) => {
        clearTimeout(timer);
        resolve(value);
      });
    });
    this.socket.send(JSON.stringify({ id, ...body }));
    return result;
  }
  connect(token: string, direct = false) {
    return this.command({ connect: direct ? { token } : { data: { token } } });
  }
  close() {
    if (!this.closed) this.socket.close();
  }
  get publications() {
    return this.packets.filter((p) => p.push?.pub).map((p) => p.push.pub.data);
  }
}
before(async () => {
  const extPort = await freePort(),
    intPort = await freePort();
  external = `http://127.0.0.1:${extPort}`;
  internal = `http://127.0.0.1:${intPort}`;
  ws = `ws://127.0.0.1:${extPort}/connection/websocket`;
  process.env.CENTRIFUGO_API_URL = `${internal}/api`;
  app = await built("main").createApplication();
  app.useLogger(false);
  app.use((req: { path: string }, _res: unknown, next: () => void) => {
    if (req.path === "/internal/realtime/refresh") refreshCallbacks++;
    next();
  });
  await app.listen(0, "127.0.0.1");
  base = await app.getUrl();
  redis = app.get(built("infrastructure/redis-sync.service").RedisSyncService);
  db = app.get(built("infrastructure/database.service").DatabaseService);
  const binary = process.env.CENTRIFUGO_BIN ?? privateEnv.CENTRIFUGO_BIN;
  const version = spawnSync(binary!, ["version"], { encoding: "utf8" });
  assert.match(version.stdout, /Centrifugo v6\.9\.7 /);
  const env = {
    ...process.env,
    CENTRIFUGO_HTTP_SERVER_PORT: String(extPort),
    CENTRIFUGO_HTTP_SERVER_INTERNAL_PORT: String(intPort),
    CENTRIFUGO_CLIENT_EXPIRED_CLOSE_DELAY: "1s",
    CENTRIFUGO_CLIENT_PING_INTERVAL: "2s",
    CENTRIFUGO_CLIENT_PONG_TIMEOUT: "1s",
    CENTRIFUGO_HTTP_API_KEY: process.env.CENTRIFUGO_API_KEY,
    CENTRIFUGO_ADMIN_PASSWORD: secret(),
    CENTRIFUGO_ADMIN_SECRET: secret(),
    CENTRIFUGO_ENGINE_REDIS_ADDRESS: process.env.REDIS_URL,
    CENTRIFUGO_ENGINE_REDIS_PREFIX: `chat_centrifugo_test_${run}`,
    CENTRIFUGO_VAR_PROXY_SECRET: process.env.CENTRIFUGO_PROXY_SECRET,
    CENTRIFUGO_CLIENT_PROXY_CONNECT_ENDPOINT: `${base}/internal/realtime/connect`,
    // Any accidental refresh enablement fails this suite's request counter.
    CENTRIFUGO_CLIENT_PROXY_REFRESH_ENABLED: "false",
  };
  // Tests must never accept the direct JWT bypass, even if the shell configured it.
  for (const key of Object.keys(env))
    if (key.startsWith("CENTRIFUGO_CLIENT_TOKEN_"))
      delete env[key as keyof typeof env];
  const config = resolve("../centrifugo/config.json");
  assert.equal(
    spawnSync(binary!, ["checkconfig", `--config=${config}`], { env }).status,
    0,
  );
  child = spawn(binary!, [`--config=${config}`], {
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const { centrifugoLogFilter } = await import(
    pathToFileURL(resolve("../scripts/centrifugo-log.mjs")).href
  );
  for (const stream of [child.stdout!, child.stderr!]) {
    stream
      .pipe(
        centrifugoLogFilter(
          Object.entries(env)
            .filter(([key]) => /secret|password|token|api.?key/i.test(key))
            .map(([, value]) => value),
        ),
      )
      .on("data", (chunk: Buffer) => {
        serverLogs += chunk.toString();
      });
  }
  await eventually(async () => {
    try {
      return (await fetch(`${internal}/health`)).ok;
    } catch {
      return false;
    }
  }, Boolean);
  for (let n = 1; n <= 5; n++)
    sessions.push(
      await request("/auth/debug-login", undefined, { debugUserNumber: n }),
    );
});
after(async () => {
  child?.kill("SIGTERM");
  if (child && child.exitCode === null) await once(child, "exit");
  await app?.close();
});

test("v6.9.7 configuration exposes loopback diagnostics and authenticated internal APIs only", async () => {
  for (const path of [
    "/",
    "/debug/pprof/",
    "/metrics",
    "/swagger",
    "/health",
  ]) {
    assert.equal((await fetch(internal + path)).status, 200, path);
    assert.equal(
      (await fetch(external + path)).status,
      404,
      `external ${path}`,
    );
  }
  assert.equal(
    (await fetch(internal + "/api/info", { method: "POST", body: "{}" }))
      .status,
    401,
  );
  assert.ok((await api("info", {})).result.nodes.length);
  assert.doesNotMatch(serverLogs, /unknown (?:key|option)|unrecognized/i);
  await request(
    "/internal/realtime/connect",
    undefined,
    { data: { token: sessions[0].centrifugoToken } },
    "POST",
    403,
  );
});

test("proxy accepts verified JWT claims and rejects expired, malformed, anonymous, wrong issuer/audience/signature and direct-token bypass", async (t) => {
  const claims = jwt.decode(sessions[0].centrifugoToken) as any;
  assert.equal(claims.iss, "chat-api");
  assert.equal(claims.aud, "chat-realtime");
  assert.equal(claims.exp - claims.iat, 1800);
  assert.deepEqual(claims.channels, [`inbox:user#${sessions[0].user._id}`]);
  const valid = new InboxSocket();
  t.after(() => valid.close());
  const response = await valid.connect(sessions[0].centrifugoToken);
  assert.deepEqual(Object.keys(response.connect.subs), claims.channels);
  assert.equal(
    response.connect.subs[claims.channels[0]].recoverable ?? false,
    false,
  );
  assert.equal(
    response.connect.expires ?? false,
    true,
    "the socket expires at the access session deadline",
  );
  assert.ok(response.connect.ttl > 86000);
  const sign = (
    overrides: object,
    key = process.env.CENTRIFUGO_TOKEN_HMAC_SECRET_KEY!,
  ) =>
    jwt.sign({ ...claims, ...overrides }, { secret: key, algorithm: "HS256" });
  for (const token of [
    "",
    "malformed",
    sign({ exp: 1 }),
    sign({ aud: "foreign" }),
    sign({ iss: "foreign" }),
    sign({ sub: "" }),
    sign({ channels: [`inbox:user#${sessions[1].user._id}`] }),
    sign({}, secret()),
  ]) {
    const socket = new InboxSocket();
    t.after(() => socket.close());
    assert.ok(!(await socket.connect(token)).connect);
  }
  const bypass = new InboxSocket();
  t.after(() => bypass.close());
  assert.ok(!(await bypass.connect(sessions[0].centrifugoToken, true)).connect);
});

test("idle sockets last beyond the former refresh interval with zero refresh callbacks", async (t) => {
  const beforeCallbacks = refreshCallbacks;
  const login = await request("/auth/debug-login", undefined, {
    debugUserNumber: 5,
  });
  const device = new InboxSocket();
  t.after(() => device.close());
  const result = await device.connect(login.centrifugoToken);
  const clientId = result.connect.client;
  await new Promise((resolve) => setTimeout(resolve, 62000));
  assert.equal(device.closed, false);
  const channel = `inbox:user#${login.user._id}`;
  const state = await api("presence", { channel });
  assert.ok(
    state.result.presence[clientId],
    "an idle connection keeps its original client ID",
  );
  assert.equal(refreshCallbacks - beforeCallbacks, 0);
});

test("access-session expiry closes a connected socket without server callbacks or client renewal", async (t) => {
  const login = await request("/auth/debug-login", undefined, {
    debugUserNumber: 5,
  });
  const claims = jwt.decode(login.centrifugoToken) as {
    meta: { sessionExpiresAt: number };
  };
  const sessionExpiresAt = Math.floor(Date.now() / 1000) + 3;
  const token = jwt.sign(
    { ...claims, meta: { ...claims.meta, sessionExpiresAt } },
    {
      secret: process.env.CENTRIFUGO_TOKEN_HMAC_SECRET_KEY!,
      algorithm: "HS256",
    },
  );
  const device = new InboxSocket();
  t.after(() => device.close());
  const connected = await device.connect(token);
  assert.ok(connected.connect.ttl <= 3);
  await eventually(() => device.closed, Boolean, 6500);
  const replay = new InboxSocket();
  t.after(() => replay.close());
  assert.ok(!(await replay.connect(token)).connect);
});

test("provider outage at logout queues retries; an API restart disconnects only that login", async (t) => {
  const login = await request("/auth/debug-login", undefined, {
    debugUserNumber: 5,
  });
  const otherLogin = await request("/auth/debug-login", undefined, {
    debugUserNumber: 5,
  });
  const device = new InboxSocket(),
    otherDevice = new InboxSocket();
  t.after(() => {
    device.close();
    otherDevice.close();
  });
  await device.connect(login.centrifugoToken);
  await otherDevice.connect(otherLogin.centrifugoToken);
  const config = app.get(ConfigService);
  const current = config.get("CENTRIFUGO_API_URL");
  const hash = createHash("sha256").update(login.accessToken).digest("hex");
  const jobKey = redis.sessionDisconnectKey(login.user._id, hash);
  try {
    config.set("CENTRIFUGO_API_URL", "http://127.0.0.1:1/api");
    await request("/presence/offline", login);
    assert.equal(device.closed, false);
    assert.equal(await redis.client.hget(jobKey, "state"), "pending");
    await request("/users", login, undefined, "GET", 401);
    config.set("CENTRIFUGO_API_URL", current);
    // Recreate the entire API and its Redis connection, retaining the same
    // isolated database/namespace. Centrifugo and the sockets keep running.
    const port = Number(new URL(base).port);
    await app.close();
    app = await built("main").createApplication();
    app.useLogger(false);
    app.use((req: { path: string }, _res: unknown, next: () => void) => {
      if (req.path === "/internal/realtime/refresh") refreshCallbacks++;
      next();
    });
    await app.listen(port, "127.0.0.1");
    redis = app.get(
      built("infrastructure/redis-sync.service").RedisSyncService,
    );
    db = app.get(built("infrastructure/database.service").DatabaseService);
    await eventually(() => device.closed, Boolean, 6500);
    assert.equal(otherDevice.closed, false);
    await eventually(
      () => redis.client.hget(jobKey, "state"),
      (state) => state === "done",
      18000,
    );
    assert.equal(
      await redis.client.zscore(
        redis.sessionDisconnectQueueKey(),
        `${login.user._id}:${hash}`,
      ),
      null,
    );
  } finally {
    config.set("CENTRIFUGO_API_URL", current);
  }
});

test("logout racing an already authorized connect is caught by the persisted final pass", async (t) => {
  const login = await request("/auth/debug-login", undefined, {
    debugUserNumber: 5,
  });
  const hash = createHash("sha256").update(login.accessToken).digest("hex");
  const original = redis.isSessionRetired;
  let release!: () => void;
  let entered!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const authorized = new Promise<void>((resolve) => {
    entered = resolve;
  });
  let held = false;
  redis.isSessionRetired = async function (user: string, id: string) {
    const retired = await original.call(this, user, id);
    if (user === login.user._id && id === hash && !held) {
      held = true;
      entered();
      await gate;
    }
    return retired;
  };
  const device = new InboxSocket();
  t.after(() => {
    release();
    redis.isSessionRetired = original;
    device.close();
  });
  const connecting = device.connect(login.centrifugoToken);
  await Promise.race([
    authorized,
    new Promise((_, reject) =>
      setTimeout(
        () => reject(new Error("Connect did not reach session validation")),
        1500,
      ).unref(),
    ),
  ]);
  await request("/presence/offline", login);
  release();
  assert.ok((await connecting).connect);
  redis.isSessionRetired = original;
  await eventually(() => device.closed, Boolean, 18000);
});

test("last seen persists after the final socket leaves, preserves other devices and never changes inbox revisions", async (t) => {
  const first = await request("/auth/debug-login", undefined, {
    debugUserNumber: 5,
  });
  const second = await request("/auth/debug-login", undefined, {
    debugUserNumber: 5,
  });
  const userId = first.user._id;
  const previous = new Date("2020-01-01T00:00:00Z");
  await db.users.updateOne({ _id: userId }, { $set: { lastSeenAt: previous } });
  const before = await db.users.findById(userId).lean();
  const one = new InboxSocket(),
    two = new InboxSocket();
  t.after(() => {
    one.close();
    two.close();
  });
  const admittedAt = Date.now();
  await one.connect(first.centrifugoToken);
  await two.connect(second.centrifugoToken);
  const tracker = app.get(
    built("infrastructure/last-seen.service").LastSeenService,
  ) as {
    checkSoon: (id: string) => Promise<void>;
    observe: () => Promise<void>;
  };
  const count = async () =>
    (await api("presence_stats", { channel: `inbox:user#${userId}` })).result
      .num_clients;
  await tracker.checkSoon(userId);
  await tracker.observe();
  one.close();
  await eventually(count, (value) => value === 1);
  await tracker.checkSoon(userId);
  await tracker.observe();
  assert.equal(
    (await db.users.findById(userId).lean()).lastSeenAt.getTime(),
    previous.getTime(),
  );
  two.close(); // No logout request: native socket disappearance is sufficient.
  await eventually(count, (value) => value === 0);
  await tracker.checkSoon(userId);
  await tracker.observe();
  const after = await eventually(
    () => db.users.findById(userId).lean(),
    (value: any) => value.lastSeenAt.getTime() >= admittedAt,
  );
  assert.equal(after.pts, before.pts);
  const response = await request("/presence/status", first, {
    userIds: [userId],
  });
  assert.equal(response.lastSeenAt[userId], after.lastSeenAt.toISOString());
  const stranger = await request("/presence/status", sessions[0], {
    userIds: [userId],
  });
  assert.equal(stranger.lastSeenAt[userId], undefined);
});

test("clients cannot subscribe, publish, enumerate presence/history, use recovery or call unauthorized RPC", async (t) => {
  const socket = new InboxSocket();
  t.after(() => socket.close());
  await socket.connect(sessions[0].centrifugoToken);
  const own = `inbox:user#${sessions[0].user._id}`,
    foreign = `inbox:user#${sessions[1].user._id}`;
  for (const body of [
    { subscribe: { channel: foreign } },
    { subscribe: { channel: own } },
    {
      subscribe: {
        channel: "inbox:other",
        recover: true,
        offset: 1,
        epoch: "fake",
      },
    },
    { publish: { channel: own, data: { forbidden: true } } },
    { presence: { channel: own } },
    { presence_stats: { channel: own } },
    { history: { channel: own } },
    { rpc: { method: "forbidden" } },
  ]) {
    const result = await socket.command(body);
    assert.ok(result.error, `Denied ${Object.keys(body)[0]}`);
  }
  const history = await api("history", { channel: own, limit: 10 });
  assert.ok(history.error || !history.result?.publications?.length);
  const malformed = new InboxSocket();
  t.after(() => malformed.close());
  await malformed.ready;
  malformed.socket.send("{broken");
  await eventually(() => malformed.closed, Boolean);
  const oversized = new InboxSocket();
  t.after(() => oversized.close());
  await oversized.ready;
  oversized.socket.send("x".repeat(32769));
  await eventually(() => oversized.closed, Boolean);
});

test("eight device connections coexist, all receive publications, a ninth is rejected and one disconnect leaves the rest active", async (t) => {
  const devices: InboxSocket[] = [];
  t.after(() => devices.forEach((d) => d.close()));
  for (let i = 0; i < 8; i++) {
    const d = new InboxSocket();
    devices.push(d);
    assert.ok((await d.connect(sessions[2].centrifugoToken)).connect);
  }
  const ninth = new InboxSocket();
  t.after(() => ninth.close());
  assert.ok(!(await ninth.connect(sessions[2].centrifugoToken)).connect);
  const channel = `inbox:user#${sessions[2].user._id}`;
  assert.equal(
    (await api("presence_stats", { channel })).result.num_clients,
    8,
  );
  const data = { synthetic: randomUUID(), text: "PRIVATE_LOG_CANARY_" + run };
  await api("publish", { channel, data });
  for (const device of devices)
    await eventually(
      () => device.publications.some((p) => p.synthetic === data.synthetic),
      Boolean,
    );
  devices[0].close();
  await eventually(
    async () => (await api("presence_stats", { channel })).result.num_clients,
    (x) => x === 7,
  );
  assert.ok(devices.slice(1).every((d) => !d.closed));
  const replacement = new InboxSocket();
  t.after(() => replacement.close());
  assert.ok((await replacement.connect(sessions[2].centrifugoToken)).connect);
  assert.ok(devices.slice(1).every((d) => !d.closed));
});

test("Centrifugo presence follows sockets across logins, ignores heartbeats, preserves privacy and revokes only the logged-out login", async (t) => {
  const user = sessions[0].user._id,
    peer = sessions[1].user._id,
    stranger = sessions[4].user._id;
  await request("/messages", sessions[0], {
    peerUserId: peer,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Synthetic presence contact",
  });
  const statuses = () =>
    request("/presence/status", sessions[1], { userIds: [user, stranger] });
  assert.equal((await statuses()).statuses[user], false);
  await request("/presence/heartbeat", sessions[0]);
  assert.equal(
    (await statuses()).statuses[user],
    false,
    "heartbeat cannot fabricate online presence",
  );
  const other = await request("/auth/debug-login", undefined, {
    debugUserNumber: 1,
  });
  const device = new InboxSocket(),
    device2 = new InboxSocket();
  t.after(() => {
    device.close();
    device2.close();
  });
  await device.connect(sessions[0].centrifugoToken);
  await device2.connect(other.centrifugoToken);
  await eventually(async () => (await statuses()).statuses[user], Boolean);
  assert.equal((await statuses()).statuses[stranger], undefined);
  await request(
    "/presence/status",
    sessions[1],
    { userIds: Array(101).fill(user) },
    "POST",
    400,
  );
  await request(
    "/presence/heartbeat",
    other,
    { userId: stranger, timestamp: 0 },
    "POST",
    400,
  );
  const beforePts = (await request("/rooms", sessions[0], undefined, "GET"))
    .pts;
  // The socket remains online without authorization refresh or application leases.
  await new Promise((r) => setTimeout(r, 2200));
  assert.equal((await statuses()).statuses[user], true);
  assert.equal(
    await redis.client.exists(
      `${process.env.REDIS_KEY_PREFIX}presence:due`,
      `${process.env.REDIS_KEY_PREFIX}presence:${user}:sessions`,
      `${process.env.REDIS_KEY_PREFIX}presence:${user}:state`,
    ),
    0,
  );
  await request("/presence/offline", sessions[0]);
  await eventually(() => device.closed, Boolean);
  assert.equal(device2.closed, false);
  assert.equal((await statuses()).statuses[user], true);
  await request("/auth/centrifugo-token", sessions[0], undefined, "POST", 401);
  await request("/users", sessions[0], undefined, "GET", 401);
  const replay = new InboxSocket();
  t.after(() => replay.close());
  assert.ok(!(await replay.connect(sessions[0].centrifugoToken)).connect);
  await request("/presence/offline", other);
  await eventually(
    async () => (await statuses()).statuses[user],
    (x) => x === false,
  );
  const reconnected = await request("/auth/debug-login", undefined, {
    debugUserNumber: 1,
  });
  const device3 = new InboxSocket();
  t.after(() => device3.close());
  await device3.connect(reconnected.centrifugoToken);
  await eventually(async () => (await statuses()).statuses[user], Boolean);
  device3.close(); // No application offline request: Centrifugo removes the connection.
  await eventually(
    async () => (await statuses()).statuses[user],
    (x) => x === false,
  );
  assert.equal(
    (await request("/rooms", reconnected, undefined, "GET")).pts,
    beforePts,
  );
});

test("Centrifugo detects a crashed client without REST heartbeat or offline requests", async (t) => {
  const login = await request("/auth/debug-login", undefined, {
    debugUserNumber: 2,
  });
  const user = login.user._id;
  const crashedClient = spawn(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `
    import {readFileSync} from 'node:fs';
    const {url, token} = JSON.parse(readFileSync(0, 'utf8'));
    const socket = new WebSocket(url);
    socket.addEventListener('open', () => socket.send(JSON.stringify({id: 1, connect: {data: {token}}})));
    socket.addEventListener('message', ({data}) => {
      for (const line of String(data).split('\\n').filter(Boolean)) {
        const packet = JSON.parse(line);
        if (packet.connect) process.stdout.write('ready\\n');
        else if (!Object.keys(packet).length) socket.send('{}');
      }
    });
  `,
    ],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  t.after(() => {
    if (crashedClient.exitCode === null) crashedClient.kill("SIGKILL");
  });
  crashedClient.stdin.end(
    JSON.stringify({ url: ws, token: login.centrifugoToken }),
  );
  await Promise.race([
    once(crashedClient.stdout, "data"),
    new Promise((_, reject) =>
      setTimeout(
        () => reject(new Error("Crash client startup timed out")),
        5000,
      ).unref(),
    ),
  ]);
  const online = async () =>
    (await request("/presence/status", login, { userIds: [user] })).statuses[
      user
    ];
  await eventually(online, Boolean);
  const exited = once(crashedClient, "exit");
  crashedClient.kill("SIGKILL");
  await exited;
  await eventually(online, (value) => value === false, 5000);
});

test("provider outage returns 503 instead of an offline snapshot", async () => {
  const config = app.get(ConfigService);
  const current = config.get("CENTRIFUGO_API_URL");
  try {
    config.set("CENTRIFUGO_API_URL", "http://127.0.0.1:1/api");
    await request(
      "/presence/status",
      sessions[1],
      { userIds: [sessions[1].user._id] },
      "POST",
      503,
    );
    assert.deepEqual(
      await request("/presence/status", sessions[1], { userIds: [] }),
      { statuses: {}, lastSeenAt: {} },
    );
  } finally {
    config.set("CENTRIFUGO_API_URL", current);
  }
});

test("offline publications are never replayed and existing Redis delta recovers the committed room", async (t) => {
  const auth = sessions[3],
    peer = sessions[4];
  const baseline = await request("/rooms", auth, undefined, "GET");
  const sent = await request("/messages", peer, {
    peerUserId: auth.user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Missed synthetic publication",
  });
  const socket = new InboxSocket();
  t.after(() => socket.close());
  const connected = await socket.connect(auth.centrifugoToken);
  assert.ok(connected.connect);
  assert.ok(
    !connected.connect.subs[`inbox:user#${auth.user._id}`].publications?.length,
  );
  const recovered = await request(
    `/rooms/delta?sincePts=${baseline.pts}&epoch=${baseline.epoch}`,
    auth,
    undefined,
    "GET",
  );
  assert.equal(recovered.requiresFullSync, false);
  assert.equal(recovered.rooms[0].lastMessage.id, sent.message.id);
});

test("compact sequence receipts reach real inbox sockets while Redis keeps full offline snapshots", async (t) => {
  const config = app.get(ConfigService);
  const previous = config.get("RECEIPT_PUSH_MODE", "legacy");
  config.set("RECEIPT_PUSH_MODE", "compact");
  t.after(() => config.set("RECEIPT_PUSH_MODE", previous));
  const sender = await request("/auth/debug-login", undefined, {
    debugUserNumber: 3,
  });
  const reader = await request("/auth/debug-login", undefined, {
    debugUserNumber: 4,
  });
  const socket = new InboxSocket();
  t.after(() => socket.close());
  assert.ok((await socket.connect(sender.centrifugoToken)).connect);
  const sent = await request("/messages", sender, {
    peerUserId: reader.user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Compact receipt payload must omit this body",
  });
  await request(`/rooms/${sent.room.roomId}/seen`, reader, {
    upToSeq: sent.message.messageSeq,
  });
  const patch = await eventually<any>(
    () =>
      socket.publications.find(
        (publication) => publication.receipt?.roomId === sent.room.roomId,
      ),
    Boolean,
  );
  assert.equal(patch.receipt.eventType, "room_peer_seen");
  assert.equal(patch.receipt.peerSeenSeq, sent.message.messageSeq);
  assert.equal(patch.room, undefined);
  assert.equal(patch.receipt.contentPts, sent.room.contentPts);
  const snapshot = JSON.parse(
    await redis.client.hget(redis.keys(sender.user._id)[2], sent.room.roomId),
  );
  assert.equal(snapshot.lastMessage.id, sent.message.id);
  assert.equal(snapshot.sequenceReceipt, true);
  assert.equal(snapshot.peerSeenSeq, patch.receipt.peerSeenSeq);
  assert.ok(
    Buffer.byteLength(JSON.stringify(patch)) <
      Buffer.byteLength(
        JSON.stringify({ pts: patch.pts, epoch: patch.epoch, room: snapshot }),
      ) /
        2,
  );
});

test("compact unread patches preserve partial direct/group badges, separate peer ticks and retain full offline deltas", async (t) => {
  const config = app.get(ConfigService);
  const previous = config.get("RECEIPT_PUSH_MODE", "legacy");
  config.set("RECEIPT_PUSH_MODE", "compact");
  t.after(() => config.set("RECEIPT_PUSH_MODE", previous));
  const sender = await request("/auth/debug-login", undefined, {
    debugUserNumber: 5,
  });
  const reader = await request("/auth/debug-login", undefined, {
    debugUserNumber: 4,
  });
  const senderSocket = new InboxSocket();
  const readerSocket = new InboxSocket();
  t.after(() => {
    senderSocket.close();
    readerSocket.close();
  });
  assert.ok((await senderSocket.connect(sender.centrifugoToken)).connect);
  assert.ok((await readerSocket.connect(reader.centrifugoToken)).connect);
  const first = await request("/messages", sender, {
    peerUserId: reader.user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Compact unread direct first",
  });
  const roomId = first.room.roomId;
  for (let index = 0; index < 2; index++)
    await request("/messages", sender, {
      roomId,
      idempotencyKey: randomUUID(),
      type: "text",
      text: `Compact unread direct later ${index}`,
    });
  const readerBefore = await db.members
    .findOne({ roomId, userId: reader.user._id })
    .lean();
  await request(`/rooms/${roomId}/seen`, reader, {
    upToSeq: first.message.messageSeq,
  });
  const unread = await eventually<any>(
    () =>
      readerSocket.publications.find(
        (publication) => publication.unread?.roomId === roomId,
      ),
    Boolean,
  );
  const peer = await eventually<any>(
    () =>
      senderSocket.publications.find(
        (publication) => publication.receipt?.roomId === roomId,
      ),
    Boolean,
  );
  assert.deepEqual(unread.unread, {
    eventType: "room_unread_cleared",
    roomId,
    unreadCount: 2,
    ownDeliveredSeq: first.message.messageSeq,
    ownSeenSeq: first.message.messageSeq,
  });
  assert.deepEqual(Object.keys(unread).sort(), ["epoch", "pts", "unread"]);
  assert.equal(peer.receipt.eventType, "room_peer_seen");
  const readerAfter = await db.members
    .findOne({ roomId, userId: reader.user._id })
    .lean();
  assert.equal(readerAfter.msgPts, readerBefore.msgPts);
  assert.equal(readerAfter.contentPts, readerBefore.contentPts);
  assert.equal(readerAfter.roomPts, unread.pts);
  const counts = {
    reader: readerSocket.publications.length,
    sender: senderSocket.publications.length,
  };
  await request(`/rooms/${roomId}/seen`, reader, {
    upToSeq: first.message.messageSeq,
  });
  assert.equal(
    (await db.members.findById(readerAfter._id).lean()).roomPts,
    readerAfter.roomPts,
  );
  assert.equal(readerSocket.publications.length, counts.reader);
  assert.equal(senderSocket.publications.length, counts.sender);
  const snapshot = JSON.parse(
    await redis.client.hget(redis.keys(reader.user._id)[2], roomId),
  );
  assert.equal(snapshot.unreadCount, 2);
  assert.ok(
    snapshot.lastMessage.text.startsWith("Compact unread direct later"),
  );
  assert.equal(snapshot.msgPts, readerBefore.msgPts);
  const delta = await request(
    `/rooms/delta?sincePts=${readerBefore.roomPts}&epoch=${encodeURIComponent(unread.epoch)}`,
    reader,
    undefined,
    "GET",
  );
  assert.equal(delta.requiresFullSync, false);
  const recovered = delta.rooms.find((room: any) => room.roomId === roomId);
  assert.equal(recovered.unreadCount, 2);
  assert.equal(recovered.lastMessage.id, snapshot.lastMessage.id);

  const group = await request(
    "/rooms/group",
    sender,
    { title: "Compact unread group", participantIds: [reader.user._id] },
    "POST",
    201,
  );
  let groupFirst: any;
  for (let index = 0; index < 3; index++) {
    const sent = await request("/messages", sender, {
      roomId: group.room.roomId,
      idempotencyKey: randomUUID(),
      type: "text",
      text: `Compact unread group ${index}`,
    });
    groupFirst ??= sent;
  }
  await request(`/rooms/${group.room.roomId}/seen`, reader, {
    upToSeq: groupFirst.message.messageSeq,
  });
  const groupUnread = await eventually<any>(
    () =>
      readerSocket.publications.find(
        (publication) => publication.unread?.roomId === group.room.roomId,
      ),
    Boolean,
  );
  assert.equal(groupUnread.unread.unreadCount, 2);
  assert.equal(groupUnread.unread.ownSeenSeq, groupFirst.message.messageSeq);
  assert.equal(
    senderSocket.publications.some(
      (publication) => publication.receipt?.roomId === group.room.roomId,
    ),
    false,
  );
  const groupSnapshot = JSON.parse(
    await redis.client.hget(redis.keys(reader.user._id)[2], group.room.roomId),
  );
  assert.equal(groupSnapshot.unreadCount, 2);
  assert.equal(groupSnapshot.lastMessage.text, "Compact unread group 2");
});

test("configurable Redis user/IP limits return 429 Retry-After without rejecting ordinary token renewal", async () => {
  for (let i = 0; i < 3; i++)
    await request("/auth/centrifugo-token", sessions[3]);
  const limited = await fetch(base + "/auth/centrifugo-token", {
    method: "POST",
    headers: { authorization: `Bearer ${sessions[3].accessToken}` },
  });
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("Retry-After"), "60");
  for (let i = 0; i < 3; i++)
    await request("/auth/centrifugo-token", sessions[4]);
  await request("/auth/centrifugo-token", sessions[1], undefined, "POST", 429);
  const config = app.get(ConfigService);
  config.set("REALTIME_HEARTBEAT_USER_LIMIT", 1);
  await request("/presence/heartbeat", sessions[3]);
  await request("/presence/heartbeat", sessions[3], undefined, "POST", 429);
  config.set("REALTIME_STATUS_USER_LIMIT", 1);
  await request("/presence/status", sessions[3], { userIds: [] });
  await request("/presence/status", sessions[3], { userIds: [] }, "POST", 429);
});

test("native debug logs exclude authentication secrets, signed tokens and private publication bodies", () => {
  for (const value of [
    process.env.JWT_SECRET!,
    process.env.CENTRIFUGO_TOKEN_HMAC_SECRET_KEY!,
    process.env.CENTRIFUGO_API_KEY!,
    process.env.CENTRIFUGO_PROXY_SECRET!,
    ...sessions.flatMap((s) => [s.accessToken, s.centrifugoToken]),
    "PRIVATE_LOG_CANARY_" + run,
  ]) {
    assert.equal(
      serverLogs.includes(value),
      false,
      `Sensitive data category ${value === "PRIVATE_LOG_CANARY_" + run ? "publication" : sessions.some((s) => s.centrifugoToken === value) ? "realtime token" : sessions.some((s) => s.accessToken === value) ? "access token" : "server secret"} appeared in native logs`,
    );
  }
  assert.doesNotMatch(serverLogs, /unknown (?:key|option)|unrecognized/i);
});
