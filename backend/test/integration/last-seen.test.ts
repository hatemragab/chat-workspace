import "reflect-metadata";
import assert from "node:assert/strict";
import { before, after, test } from "node:test";
import { randomBytes, randomUUID } from "node:crypto";
import { ConfigService } from "@nestjs/config";
import { DebugTrafficLogger } from "../../src/infrastructure/debug-traffic-logger";
import { LocalServiceDiagnostics } from "../../src/infrastructure/local-service-diagnostics";
import { RedisSyncService } from "../../src/infrastructure/redis-sync.service";
import { LastSeenService } from "../../src/infrastructure/last-seen.service";

if (process.env.NODE_ENV === "production") throw new Error("Local tests only");
const prefix = `last-seen-test:${randomUUID()}:`;
const config = new ConfigService({
  REDIS_URL: process.env.REDIS_URL ?? "redis://127.0.0.1:6379",
  REDIS_KEY_PREFIX: prefix,
  TRAFFIC_LOG_FILE: "off",
  LOCAL_SERVICE_LOG_FILE: "off",
  HTTP_LOGGING_ENABLED: "false",
});
const diagnostics = new LocalServiceDiagnostics(
  config,
  new DebugTrafficLogger(config),
);
const redis = new RedisSyncService(config, diagnostics);
const user = () => randomBytes(12).toString("hex");
const state = async (id: string) => {
  const raw = await redis.client.hget(`${prefix}last-seen:observations`, id);
  return raw ? JSON.parse(raw) : null;
};
const writes: {
  updateOne: {
    filter: { _id: string };
    update: { $max: { lastSeenAt: Date } };
  };
}[][] = [];
let online = true,
  failProvider = false,
  failDatabase = false;
const db = {
  users: {
    bulkWrite: async (operations: (typeof writes)[number]) => {
      if (failDatabase) throw new Error("Synthetic MongoDB outage");
      writes.push(operations);
    },
  },
};
let statusReader = async (ids: string[]) => {
  if (failProvider) throw new Error("Synthetic Centrifugo outage");
  return Object.fromEntries(ids.map((id) => [id, online]));
};
const provider = { presenceStatuses: (ids: string[]) => statusReader(ids) };
const service = () =>
  new LastSeenService(config, redis, db as never, provider as never);
before(() => redis.onModuleInit());
after(async () => {
  await redis.onModuleDestroy();
  await diagnostics.onModuleDestroy();
});

test("online users remain tracked; final offline observation persists last seen and removes only observation metadata", async () => {
  const id = user(),
    tracker = service();
  await tracker.track(id);
  const admittedAt = (await state(id)).lastOnlineAt;
  const beforeWrites = writes.length;
  online = true;
  await tracker.checkSoon(id);
  await tracker.observe();
  const lastOnlineAt = (await state(id)).lastOnlineAt;
  assert.ok(lastOnlineAt >= admittedAt);
  assert.equal(writes.length, beforeWrites);
  online = false;
  await tracker.checkSoon(id);
  await tracker.observe();
  const operation = writes
    .at(-1)!
    .find(({ updateOne }) => updateOne.filter._id === id)!;
  assert.equal(
    operation.updateOne.update.$max.lastSeenAt.getTime(),
    lastOnlineAt,
  );
  assert.equal(await state(id), null);
  assert.equal(await redis.client.zscore(`${prefix}last-seen:due`, id), null);
});

test("provider and MongoDB failures retain observations and never fabricate a later last-seen timestamp", async () => {
  const id = user(),
    tracker = service();
  await tracker.track(id);
  const lastOnlineAt = (await state(id)).lastOnlineAt;
  const beforeWrites = writes.length;
  try {
    failProvider = true;
    await tracker.checkSoon(id);
    await tracker.observe();
    assert.equal(writes.length, beforeWrites);
    assert.equal((await state(id)).lastOnlineAt, lastOnlineAt);
    failProvider = false;
    online = false;
    failDatabase = true;
    await tracker.checkSoon(id);
    await tracker.observe();
    assert.equal((await state(id)).lastOnlineAt, lastOnlineAt);
    assert.equal(writes.length, beforeWrites);
  } finally {
    failProvider = false;
    failDatabase = false;
  }
  await tracker.checkSoon(id);
  await tracker.observe();
  assert.equal(await state(id), null);
});

test("a reconnect fences completion of an older offline snapshot", async () => {
  const id = user(),
    tracker = service();
  await tracker.track(id);
  let release!: () => void, entered!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const reading = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const original = statusReader;
  statusReader = async (ids) => {
    entered();
    await gate;
    return Object.fromEntries(ids.map((uid) => [uid, false]));
  };
  try {
    await tracker.checkSoon(id);
    const observation = tracker.observe();
    await reading;
    const oldVersion = (await state(id)).version;
    await tracker.track(id);
    const newVersion = (await state(id)).version;
    assert.notEqual(newVersion, oldVersion);
    release();
    await observation;
    assert.equal((await state(id)).version, newVersion);
  } finally {
    release();
    statusReader = original;
  }
});

test("a replacement worker resumes retained observations after restart, including when nobody remains connected", async () => {
  const id = user(),
    original = service();
  await original.track(id);
  await original.checkSoon(id);
  await original.onModuleDestroy();
  online = false;
  const replacement = service();
  replacement.onModuleInit();
  await replacement.onModuleDestroy();
  assert.equal(await state(id), null);
});
