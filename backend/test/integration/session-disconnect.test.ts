import "reflect-metadata";
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { randomBytes, randomUUID } from "node:crypto";
import { ConfigService } from "@nestjs/config";
import { DebugTrafficLogger } from "../../src/infrastructure/debug-traffic-logger";
import { LocalServiceDiagnostics } from "../../src/infrastructure/local-service-diagnostics";
import { RedisSyncService } from "../../src/infrastructure/redis-sync.service";
import { CentrifugoService } from "../../src/infrastructure/centrifugo.service";
import { SessionDisconnectService } from "../../src/infrastructure/session-disconnect.service";

if (process.env.NODE_ENV === "production") throw new Error("Local tests only");
const config = new ConfigService({
  REDIS_URL: process.env.REDIS_URL ?? "redis://127.0.0.1:6379",
  REDIS_KEY_PREFIX: `session-disconnect-test:${randomUUID()}:`,
  HTTP_LOGGING_ENABLED: "false",
  TRAFFIC_LOG_FILE: "off",
  LOCAL_SERVICE_LOG_FILE: "off",
});
const traffic = new DebugTrafficLogger(config);
const diagnostics = new LocalServiceDiagnostics(config, traffic);
const redis = new RedisSyncService(config, diagnostics);
const otherRedis = new RedisSyncService(config, diagnostics);
const session = () => ({
  userId: randomBytes(12).toString("hex"),
  sessionId: randomBytes(32).toString("hex"),
});
before(async () => {
  await redis.onModuleInit();
  await otherRedis.onModuleInit();
});
after(async () => {
  await redis.onModuleDestroy();
  await otherRedis.onModuleDestroy();
  await diagnostics.onModuleDestroy();
});

test("retirement atomically persists one pending disconnect and repeated logout preserves its lease", async () => {
  const { userId, sessionId } = session();
  await Promise.all(
    Array.from({ length: 8 }, () => redis.retireSession(userId, sessionId)),
  );
  assert.equal(await redis.isSessionRetired(userId, sessionId), true);
  const key = redis.sessionDisconnectKey(userId, sessionId);
  assert.equal(await redis.client.hget(key, "state"), "pending");
  assert.ok((await redis.client.ttl(key)) > 86400);
  assert.equal(
    (await redis.dueSessionDisconnects(100)).filter(
      (id) => id === `${userId}:${sessionId}`,
    ).length,
    1,
  );
  assert.equal(
    await redis.claimSessionDisconnect(userId, sessionId, "first"),
    1,
  );
  await redis.retireSession(userId, sessionId);
  assert.equal(await redis.client.hget(key, "lease"), "first");
  assert.equal(
    await otherRedis.claimSessionDisconnect(userId, sessionId, "second"),
    null,
  );
});

test("a crashed worker lease is recoverable and stale completion cannot erase its replacement", async () => {
  const { userId, sessionId } = session();
  const member = `${userId}:${sessionId}`;
  const key = redis.sessionDisconnectKey(userId, sessionId);
  await redis.retireSession(userId, sessionId);
  const claims = await Promise.all([
    redis.claimSessionDisconnect(userId, sessionId, "worker-one"),
    otherRedis.claimSessionDisconnect(userId, sessionId, "worker-two"),
  ]);
  assert.equal(claims.filter((attempts) => attempts === 1).length, 1);
  assert.equal(claims.filter((attempts) => attempts === null).length, 1);
  const oldLease = (await redis.client.hget(key, "lease"))!;
  // Move only this synthetic job to its visibility deadline, simulating a crash.
  await redis.client.zadd(redis.sessionDisconnectQueueKey(), 0, member);
  assert.equal(
    await otherRedis.claimSessionDisconnect(userId, sessionId, "replacement"),
    2,
  );
  await redis.finishSessionDisconnect(userId, sessionId, oldLease, true, 1000);
  assert.equal(await redis.client.hget(key, "lease"), "replacement");
  await otherRedis.finishSessionDisconnect(
    userId,
    sessionId,
    "replacement",
    false,
    1000,
  );
  assert.equal(await redis.client.hget(key, "state"), "pending");
  assert.ok(
    Number(
      await redis.client.zscore(redis.sessionDisconnectQueueKey(), member),
    ) > Date.now(),
  );
});

test("early success requires a final settled pass and a completed login cannot create duplicate work", async () => {
  const { userId, sessionId } = session();
  const key = redis.sessionDisconnectKey(userId, sessionId);
  const member = `${userId}:${sessionId}`;
  await redis.retireSession(userId, sessionId);
  await redis.claimSessionDisconnect(userId, sessionId, "early");
  await redis.finishSessionDisconnect(userId, sessionId, "early", true, 1000);
  assert.equal(await redis.client.hget(key, "state"), "pending");
  assert.equal(
    await redis.client.zscore(redis.sessionDisconnectQueueKey(), member),
    await redis.client.hget(key, "settleAt"),
  );
  await redis.client.hset(key, "settleAt", 0);
  await redis.client.zadd(redis.sessionDisconnectQueueKey(), 0, member);
  await redis.claimSessionDisconnect(userId, sessionId, "settled");
  await redis.finishSessionDisconnect(userId, sessionId, "settled", true, 1000);
  assert.equal(await redis.client.hget(key, "state"), "done");
  assert.equal(
    await redis.client.zscore(redis.sessionDisconnectQueueKey(), member),
    null,
  );
  await redis.retireSession(userId, sessionId);
  assert.equal(
    await redis.client.zscore(redis.sessionDisconnectQueueKey(), member),
    null,
  );
});

test("a new worker and Redis client resume failed disconnects without a second logout", async (t) => {
  const { userId, sessionId } = session();
  let calls = 0;
  const provider = {
    disconnectSession: async (user: string, id: string) => {
      if (user !== userId || id !== sessionId) return false;
      calls++;
      return calls > 1;
    },
  } as unknown as CentrifugoService;
  const first = new SessionDisconnectService(redis, provider);
  await redis.retireSession(userId, sessionId);
  await first.disconnect(userId, sessionId);
  assert.equal(calls, 1);
  await first.onModuleDestroy();
  const key = redis.sessionDisconnectKey(userId, sessionId);
  await redis.client.hset(key, "settleAt", 0);
  await redis.client.zadd(
    redis.sessionDisconnectQueueKey(),
    0,
    `${userId}:${sessionId}`,
  );
  const replacement = new SessionDisconnectService(otherRedis, provider);
  t.after(() => replacement.onModuleDestroy());
  await replacement.disconnect(userId, sessionId);
  assert.equal(calls, 2);
  assert.equal(await redis.client.hget(key, "state"), "done");
});

test("worker bounds concurrent provider calls and keeps excess jobs persisted", async (t) => {
  const jobs = Array.from({ length: 9 }, session);
  const releases: (() => void)[] = [];
  const provider = {
    disconnectSession: async () =>
      new Promise<boolean>((resolve) => releases.push(() => resolve(true))),
  } as unknown as CentrifugoService;
  const worker = new SessionDisconnectService(redis, provider);
  t.after(() => worker.onModuleDestroy());
  await Promise.all(
    jobs.map(({ userId, sessionId }) => redis.retireSession(userId, sessionId)),
  );
  const attempts = jobs.map(({ userId, sessionId }) =>
    worker.disconnect(userId, sessionId),
  );
  const until = Date.now() + 1000;
  while (releases.length < 4 && Date.now() < until)
    await new Promise((resolve) => setTimeout(resolve, 5));
  try {
    assert.equal(releases.length, 4);
  } finally {
    releases.forEach((release) => release());
    await Promise.all(attempts);
  }
  assert.equal(
    await redis.client.hget(
      redis.sessionDisconnectKey(jobs[8].userId, jobs[8].sessionId),
      "attempts",
    ),
    "0",
  );
});
