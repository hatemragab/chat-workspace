import { once } from "node:events";
import "reflect-metadata";
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { createHash, randomUUID } from "node:crypto";
import sharp from "sharp";
import { existsSync, mkdtempSync, realpathSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { parseEnv } from "node:util";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { INestApplication } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { JwtService } from "@nestjs/jwt";
import { Types } from "mongoose";
import { DatabaseService } from "../../src/infrastructure/database.service";
import { RedisSyncService } from "../../src/infrastructure/redis-sync.service";
import { HydratedRoomPayload } from "../../src/models";
import * as sessionScripts from "../../src/infrastructure/session-disconnect-scripts";
import * as lastSeenScripts from "../../src/infrastructure/last-seen-scripts";
import type { ChatService } from "../../src/chat/chat.service";
import type {
  DebugTrafficLogger,
  TrafficLogRecord,
} from "../../src/infrastructure/debug-traffic-logger";
import type {
  LocalServiceDiagnostics,
  LocalServiceLogRecord,
} from "../../src/infrastructure/local-service-diagnostics";

if (existsSync(".env")) process.loadEnvFile(".env");
if (existsSync("../centrifugo/.env"))
  Object.assign(
    process.env,
    parseEnv(readFileSync("../centrifugo/.env", "utf8")),
  );
const runId = randomUUID().replaceAll("-", "");
process.env.MONGODB_URI = `mongodb://localhost:27017/chat_app_test_${runId}?replicaSet=rs0`;
process.env.REDIS_KEY_PREFIX = `chat-test:${runId}:`;
process.env.NODE_ENV = "development";
process.env.PORT = "3001";
process.env.HTTP_LOGGING_ENABLED = "false";
process.env.DEBUG_TRAFFIC_LOGGING_ENABLED = "false";
const serviceLogFile = join(
  mkdtempSync(join(realpathSync(tmpdir()), "chat-integration-service-logs-")),
  "services.jsonl",
);
process.env.LOCAL_SERVICE_LOG_FILE = serviceLogFile;
const { createApplication } = require("../../dist/main.js") as {
  createApplication: () => Promise<INestApplication>;
};
const { DatabaseService: BuiltDatabase } =
  require("../../dist/infrastructure/database.service.js") as {
    DatabaseService: typeof DatabaseService;
  };
const { RedisSyncService: BuiltRedis } =
  require("../../dist/infrastructure/redis-sync.service.js") as {
    RedisSyncService: typeof RedisSyncService;
  };
const { ChatService: BuiltChat } =
  require("../../dist/chat/chat.service.js") as {
    ChatService: typeof ChatService;
  };
const { DebugTrafficLogger: BuiltTrafficLogger } =
  require("../../dist/infrastructure/debug-traffic-logger.js") as {
    DebugTrafficLogger: typeof DebugTrafficLogger;
  };
const { LocalServiceDiagnostics: BuiltServiceDiagnostics } =
  require("../../dist/infrastructure/local-service-diagnostics.js") as {
    LocalServiceDiagnostics: typeof LocalServiceDiagnostics;
  };
let app: INestApplication;
let base: string;
let db: DatabaseService;
let redis: RedisSyncService;
let chat: ChatService;
type UserSession = {
  user: { _id: string; displayName: string };
  accessToken: string;
  centrifugoToken: string;
};
const sessions: UserSession[] = [];
async function request(
  path: string,
  user?: number,
  method = "GET",
  body?: unknown,
  expected = 200,
): Promise<any> {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      ...(user !== undefined
        ? { authorization: `Bearer ${sessions[user].accessToken}` }
        : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const result = await response.json();
  assert.equal(
    response.status,
    expected,
    `${method} ${path}: ${JSON.stringify(result)}`,
  );
  assert.ok(!("passwordHash" in result));
  return result;
}
async function send(user: number, roomId: string, text: string, extra = {}) {
  return request("/messages", user, "POST", {
    roomId,
    idempotencyKey: randomUUID(),
    type: "text",
    text,
    ...extra,
  });
}
async function uploadFixture(user = 0) {
  const bytes = await sharp({
    create: { width: 2, height: 2, channels: 3, background: "#55aaff" },
  })
    .png()
    .toBuffer();
  const form = new FormData();
  form.append(
    "file",
    new Blob([bytes as BlobPart], { type: "image/png" }),
    "fixture.png",
  );
  const response = await fetch(`${base}/uploads/image`, {
    method: "POST",
    headers: { authorization: `Bearer ${sessions[user].accessToken}` },
    body: form,
  });
  assert.equal(response.status, 201);
  return (await response.json()).imageUrl as string;
}
before(async () => {
  app = await createApplication();
  app.useLogger(false);
  await app.listen(0, "127.0.0.1");
  base = await app.getUrl();
  db = app.get(BuiltDatabase);
  redis = app.get(BuiltRedis);
  chat = app.get(BuiltChat);
  for (let number = 1; number <= 5; number++)
    sessions.push(
      await request("/auth/debug-login", undefined, "POST", {
        debugUserNumber: number,
      }),
    );
});
after(async () => {
  await app?.close();
});

test("public GET and HEAD readiness are uncached and report dependency failures safely", async () => {
  for (const method of ["GET", "HEAD"]) {
    const response = await fetch(`${base}/health`, {
      method,
      headers: { origin: "http://localhost:5173" },
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.match(
      response.headers.get("access-control-expose-headers")!,
      /Retry-After/i,
    );
    if (method === "HEAD") assert.equal(await response.text(), "");
    else
      assert.deepEqual(await response.json(), {
        status: "ok",
        mongo: "ok",
        redis: "ok",
      });
  }
  for (const dependency of [db, redis]) {
    const original = dependency.ping;
    dependency.ping = async () => {
      throw new Error("private dependency failure");
    };
    try {
      for (const method of ["GET", "HEAD"]) {
        const response = await fetch(`${base}/health`, { method });
        assert.equal(response.status, 503);
        if (method === "HEAD") assert.equal(await response.text(), "");
        else {
          const problem = await response.json();
          assert.equal(problem.code, "SERVICE_UNAVAILABLE");
          assert.equal(problem.retryable, true);
          assert.equal(
            JSON.stringify(problem).includes("private dependency failure"),
            false,
          );
        }
      }
    } finally {
      dependency.ping = original;
    }
  }
});

test("invalid message requests return a nonretryable validation category", async () => {
  const problem = await request(
    "/messages",
    0,
    "POST",
    {
      idempotencyKey: randomUUID(),
      type: "text",
      text: 42,
    },
    400,
  );
  assert.equal(problem.code, "VALIDATION_FAILED");
  assert.equal(problem.retryable, false);
  assert.equal(problem.status, 400);
});

test("foundation, validation, signup, login and token renewal", async () => {
  assert.equal((await request("/health")).status, "ok");
  assert.equal((await request("/auth/debug-users")).length, 5);
  await request("/users", undefined, "GET", undefined, 401);
  await request(
    "/auth/debug-login",
    undefined,
    "POST",
    { debugUserNumber: 6 },
    400,
  );
  await request(
    "/auth/debug-login",
    undefined,
    "POST",
    { debugUserNumber: 1, unauthorized: true },
    400,
  );
  const signup = await request(
    "/auth/signup",
    undefined,
    "POST",
    {
      username: `normal_${runId.slice(0, 8)}`,
      email: `${runId}@example.test`,
      password: "a-strong-password",
      displayName: "Normal user",
    },
    201,
  );
  assert.ok(signup.accessToken);
  assert.ok(!signup.user.passwordHash);
  await request(
    "/auth/signup",
    undefined,
    "POST",
    {
      username: `normal_${runId.slice(0, 8)}`,
      email: `${runId}@example.test`,
      password: "a-strong-password",
      displayName: "Normal user",
    },
    409,
  );
  assert.equal(
    (
      await request("/auth/login", undefined, "POST", {
        email: `${runId}@example.test`,
        password: "a-strong-password",
      })
    ).user._id,
    signup.user._id,
  );
  await request(
    "/auth/login",
    undefined,
    "POST",
    { email: `${runId}@example.test`, password: "wrong" },
    401,
  );
  assert.ok(
    (await request("/auth/centrifugo-token", 0, "POST")).centrifugoToken,
  );
  assert.ok(
    (await request("/users", 0)).every((u: any) => !u.passwordHash && !u.email),
  );
});

let directRoom: string;
let firstId: string;
test("lazy direct creation, concurrent sender idempotency, UUID scope and transaction counters", async () => {
  const before = await request(`/rooms/direct-peer/${sessions[1].user._id}`, 0);
  assert.equal(before.exists, false);
  assert.equal(await db.rooms.countDocuments(), 0);
  const key = randomUUID();
  const body = {
    peerUserId: sessions[1].user._id,
    idempotencyKey: key,
    type: "text",
    text: "First transaction",
  };
  const sends = await Promise.all(
    Array.from({ length: 6 }, () => request("/messages", 0, "POST", body)),
  );
  assert.equal(new Set(sends.map((s) => s.message.id)).size, 1);
  directRoom = sends[0].room.roomId;
  firstId = sends[0].message.id;
  assert.equal(await db.rooms.countDocuments({ type: "direct" }), 1);
  assert.equal(await db.messages.countDocuments({ idempotencyKey: key }), 1);
  assert.equal((await db.users.findById(sessions[0].user._id).lean())!.pts, 1);
  assert.equal(sends[0].room.unreadCount, 0);
  assert.equal((await request("/rooms", 1)).rooms[0].unreadCount, 1);
  await request("/messages", 2, "POST", {
    peerUserId: sessions[3].user._id,
    idempotencyKey: key,
    type: "text",
    text: "Another sender may reuse UUID",
  });
  assert.equal(await db.messages.countDocuments({ idempotencyKey: key }), 2);
});
test("all read/write paths enforce room membership and sender permissions", async () => {
  await request(`/rooms/${directRoom}/messages`, 4, "GET", undefined, 403);
  await request(
    `/rooms/${directRoom}/messages/around/${firstId}`,
    4,
    "GET",
    undefined,
    403,
  );
  await request(
    `/rooms/${directRoom}/preferences`,
    4,
    "PATCH",
    { pin: true },
    403,
  );
  await request(`/rooms/${directRoom}/seen`, 4, "POST", {}, 403);
  await request(`/rooms/${directRoom}/delivered`, 4, "POST", {}, 403);
  await request(
    "/rooms/delivered-batch",
    4,
    "POST",
    { roomIds: [directRoom] },
    403,
  );
  await request(
    "/messages",
    4,
    "POST",
    {
      roomId: directRoom,
      idempotencyKey: randomUUID(),
      type: "text",
      text: "forbidden",
    },
    403,
  );
  await request(`/messages/${firstId}`, 4, "PATCH", { text: "forbidden" }, 403);
  await request(`/messages/${firstId}/for-me`, 4, "DELETE", undefined, 403);
  await request(`/messages/${firstId}/for-all`, 1, "DELETE", undefined, 403);
  await request(`/messages/${firstId}`, 1, "PATCH", { text: "forbidden" }, 403);
  await request("/rooms/not-an-id/messages", 0, "GET", undefined, 400);
  await request(
    `/rooms/${directRoom}/messages?beforeId=${firstId}`,
    0,
    "GET",
    undefined,
    400,
  );
});

test("preferences leave message revision and sortTimestamp unchanged and delta keeps latest room state", async () => {
  const full = await request("/rooms", 0);
  const previous = full.rooms.find((r: any) => r.roomId === directRoom);
  const pin = (
    await request(`/rooms/${directRoom}/preferences`, 0, "PATCH", {
      pin: true,
      isMuted: true,
    })
  ).room;
  assert.equal(pin.msgPts, previous.msgPts);
  assert.equal(pin.sortTimestamp, previous.sortTimestamp);
  assert.ok(pin.roomPts > previous.roomPts);
  const mute = (
    await request(`/rooms/${directRoom}/preferences`, 0, "PATCH", {
      isMuted: false,
    })
  ).room;
  const delta = await request(
    `/rooms/delta?sincePts=${full.pts}&epoch=${full.epoch}`,
    0,
  );
  assert.equal(delta.requiresFullSync, false);
  assert.equal(delta.rooms.length, 1);
  assert.equal(delta.rooms[0].roomPts, mute.roomPts);
  assert.equal(await redis.client.hlen(redis.keys(sessions[0].user._id)[2]), 1);
  assert.equal(
    (await request(`/rooms/delta?sincePts=${full.pts}&epoch=wrong`, 0))
      .requiresFullSync,
    true,
  );
  assert.equal(
    (await request(`/rooms/delta?sincePts=999999&epoch=${full.epoch}`, 0))
      .requiresFullSync,
    true,
  );
});

test("null preference booleans return 400 without changing preferences, revisions or Redis", async () => {
  const before = await db.members
    .findOne({ roomId: directRoom, userId: sessions[0].user._id })
    .lean();
  const userBefore = await db.users.findById(sessions[0].user._id).lean();
  const cachedBefore = await redis.client.hget(
    redis.keys(sessions[0].user._id)[2],
    directRoom,
  );
  for (const body of [
    { pin: null },
    { isMuted: null },
    { pin: false, isMuted: null },
  ]) {
    const problem = await request(
      `/rooms/${directRoom}/preferences`,
      0,
      "PATCH",
      body,
      400,
    );
    assert.equal(problem.status, 400);
  }
  assert.deepEqual(
    await db.members
      .findOne({ roomId: directRoom, userId: sessions[0].user._id })
      .lean(),
    before,
  );
  assert.equal(
    (await db.users.findById(sessions[0].user._id).lean())!.pts,
    userBefore!.pts,
  );
  assert.equal(
    await redis.client.hget(redis.keys(sessions[0].user._id)[2], directRoom),
    cachedBefore,
  );
});

test("delivered and peer seen advance sender ticks while unread clear leaves reader msgPts and outgoing messages alone", async () => {
  const outgoing = await send(1, directRoom, "Reader own outgoing message");
  const readerBefore = (await request("/rooms", 1)).rooms.find(
    (r: any) => r.roomId === directRoom,
  );
  await request(`/rooms/${directRoom}/delivered`, 1, "POST", {});
  let first = await db.messages.findById(firstId).lean();
  assert.ok(first!.deliveredAt);
  assert.equal(first!.seenAt, null);
  await request(`/rooms/${directRoom}/seen`, 1, "POST", {});
  first = await db.messages.findById(firstId).lean();
  assert.ok(first!.seenAt);
  const readerAfter = (await request("/rooms", 1)).rooms.find(
    (r: any) => r.roomId === directRoom,
  );
  assert.equal(readerAfter.unreadCount, 0);
  assert.equal(readerAfter.msgPts, readerBefore.msgPts);
  const own = await db.messages.findById(outgoing.message.id).lean();
  assert.equal(own!.seenAt, null);
  const readerCache = JSON.parse(
    (await redis.client.hget(redis.keys(sessions[1].user._id)[2], directRoom))!,
  );
  assert.equal(readerCache.eventType, "room_unread_cleared");
  const senderCache = JSON.parse(
    (await redis.client.hget(redis.keys(sessions[0].user._id)[2], directRoom))!,
  );
  assert.equal(senderCache.eventType, "room_peer_seen");
});

test("bounded receipts never mark messages beyond the client boundary", async () => {
  const earlier = await send(0, directRoom, "Receipt boundary earlier");
  await new Promise((resolve) => setTimeout(resolve, 2));
  const later = await send(0, directRoom, "Receipt boundary later");
  await request(`/rooms/${directRoom}/seen`, 1, "POST", {
    upToTimestamp: earlier.message.createdAt,
  });
  assert.ok((await db.messages.findById(earlier.message.id).lean())!.seenAt);
  assert.equal(
    (await db.messages.findById(later.message.id).lean())!.seenAt,
    null,
  );
  const event = JSON.parse(
    (await redis.client.hget(redis.keys(sessions[0].user._id)[2], directRoom))!,
  );
  assert.equal(event.actionTimestamp, earlier.message.createdAt);
});

test("transactional message sequences are unique and idempotent without renumbering legacy rows", async () => {
  const roomId = directRoom;
  const before = (await db.rooms.findById(roomId).lean())!.messageSeq;
  const key = randomUUID();
  const sent = await Promise.all(
    Array.from({ length: 6 }, (_, index) =>
      send(
        0,
        roomId,
        `Concurrent sequence ${index}`,
        index === 0 ? { idempotencyKey: key } : {},
      ),
    ),
  );
  const seqs = sent
    .map((item) => item.message.messageSeq)
    .sort((a, b) => a - b);
  assert.deepEqual(
    seqs,
    Array.from({ length: 6 }, (_, index) => before + index + 1),
  );
  const repeated = await send(0, roomId, "Idempotent repeat", {
    idempotencyKey: key,
  });
  assert.equal(repeated.message.id, sent[0].message.id);
  assert.equal(repeated.message.messageSeq, sent[0].message.messageSeq);
  assert.equal(
    (await db.rooms.findById(roomId).lean())!.messageSeq,
    before + 6,
  );
  await db.messages.collection.updateOne(
    { _id: new Types.ObjectId(sent[0].message.id) },
    { $unset: { messageSeq: "" } },
  );
  const page = await request(`/rooms/${roomId}/messages`, 0);
  assert.equal(
    page.messages.find((message: any) => message.id === sent[0].message.id)
      .messageSeq,
    null,
  );
  assert.equal(
    (await send(0, roomId, "After legacy cutover")).message.messageSeq,
    before + 7,
  );
});

test("sequence receipts persist cursors, keep later unread and legacy dates, and suppress duplicates", async (t) => {
  const config = app.get(ConfigService);
  config.set("RECEIPT_PUSH_MODE", "compact");
  t.after(() => config.set("RECEIPT_PUSH_MODE", "legacy"));
  const first = await request("/messages", 2, "POST", {
    peerUserId: sessions[3].user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Sequence prefix",
  });
  const roomId = first.room.roomId;
  const second = await send(2, roomId, "Sequence later");
  const legacy = await send(2, roomId, "Retained legacy");
  await db.messages.collection.updateOne(
    { _id: new Types.ObjectId(legacy.message.id) },
    { $unset: { messageSeq: "" } },
  );
  const initial = await db.members
    .findOne({ roomId, userId: sessions[2].user._id })
    .lean();
  await db.members.collection.updateOne(
    { _id: initial!._id },
    { $unset: { contentPts: "" } },
  );
  const ack = await request(`/rooms/${roomId}/seen`, 3, "POST", {
    upToSeq: first.message.messageSeq,
  });
  assert.equal(ack.rooms[0].ownSeenSeq, first.message.messageSeq);
  const reader = await db.members
    .findOne({ roomId, userId: sessions[3].user._id })
    .lean();
  assert.equal(reader!.unreadCount, 1);
  assert.ok((await db.messages.findById(first.message.id).lean())!.seenAt);
  assert.equal(
    (await db.messages.findById(second.message.id).lean())!.seenAt,
    null,
  );
  const legacyDate = (await db.messages.findById(legacy.message.id).lean())!
    .seenAt;
  assert.ok(legacyDate);
  const sender = await db.members
    .findOne({ roomId, userId: sessions[2].user._id })
    .lean();
  assert.equal(sender!.peerSeenSeq, first.message.messageSeq);
  assert.equal(sender!.contentPts, initial!.contentPts);
  assert.ok(sender!.msgPts > initial!.msgPts);
  const cached = JSON.parse(
    (await redis.client.hget(redis.keys(sessions[2].user._id)[2], roomId))!,
  );
  assert.equal(cached.sequenceReceipt, undefined);
  assert.equal(cached.lastMessage.id, legacy.message.id);
  await request(`/rooms/${roomId}/seen`, 3, "POST", {
    upToSeq: first.message.messageSeq,
  });
  assert.equal(
    (await db.members.findById(sender!._id).lean())!.msgPts,
    sender!.msgPts,
  );
  await request(
    `/rooms/${roomId}/seen`,
    3,
    "POST",
    { upToSeq: legacy.message.messageSeq + 1 },
    400,
  );
  for (const value of [null, -1, 0.5, Number.MAX_SAFE_INTEGER + 1])
    await request(`/rooms/${roomId}/seen`, 3, "POST", { upToSeq: value }, 400);
  await request(
    `/rooms/${roomId}/seen`,
    3,
    "POST",
    { upToSeq: 0, upToTimestamp: new Date().toISOString() },
    400,
  );
  await request(`/rooms/${roomId}/seen`, 3, "POST", {});
  assert.equal(
    (await db.messages
      .findById(legacy.message.id)
      .lean())!.seenAt!.toISOString(),
    legacyDate!.toISOString(),
  );
});

test("message coverage proves received bodies conservatively when timestamp and sequence order diverge", async () => {
  const first = await send(0, directRoom, "Coverage one");
  const second = await send(0, directRoom, "Coverage two");
  const third = await send(0, directRoom, "Coverage backdated");
  await db.messages.collection.updateOne(
    { _id: new Types.ObjectId(third.message.id) },
    { $set: { createdAt: new Date("2020-01-01T00:00:00.000Z") } },
  );
  const page = await request(`/rooms/${directRoom}/messages?limit=2`, 1);
  assert.ok(
    page.messages.some((message: any) => message.id === second.message.id),
  );
  assert.equal(page.coverage.headSeq, third.message.messageSeq);
  assert.equal(page.coverage.fromSeq, third.message.messageSeq + 1);
  assert.equal(page.coverage.throughSeq, third.message.messageSeq);
  assert.ok(page.coverage.contentPts <= page.coverage.msgPts);
  assert.ok(page.receiptState.ownDeliveredSeq >= 0);
  const normal = await request(`/rooms/${directRoom}/messages?limit=100`, 1);
  const ids = new Set(normal.messages.map((message: any) => message.id));
  assert.ok(ids.has(first.message.id));
});

test("sequence delivery batch validates every target atomically", async (t) => {
  const config = app.get(ConfigService);
  config.set("RECEIPT_PUSH_MODE", "compact");
  t.after(() => config.set("RECEIPT_PUSH_MODE", "legacy"));
  const message = await send(0, directRoom, "Atomic sequence batch");
  await request(
    "/rooms/delivered-batch",
    1,
    "POST",
    {
      targets: [
        { roomId: directRoom, upToSeq: message.message.messageSeq },
        { roomId: new Types.ObjectId().toString(), upToSeq: 1 },
      ],
    },
    403,
  );
  assert.equal(
    (await db.messages.findById(message.message.id).lean())!.deliveredAt,
    null,
  );
  await request(
    "/rooms/delivered-batch",
    1,
    "POST",
    {
      targets: [{ roomId: directRoom, upToSeq: message.message.messageSeq }],
      roomIds: [directRoom],
    },
    400,
  );
  const ack = await request("/rooms/delivered-batch", 1, "POST", {
    targets: [{ roomId: directRoom, upToSeq: message.message.messageSeq }],
  });
  assert.equal(ack.rooms[0].ownDeliveredSeq, message.message.messageSeq);
});

test("legacy rollout advertises its protocol and rejects sequence acknowledgements", async () => {
  const message = await send(0, directRoom, "Legacy capability guard");
  assert.equal(message.room.receiptProtocol, "legacy");
  await request(
    `/rooms/${directRoom}/delivered`,
    1,
    "POST",
    { upToSeq: message.message.messageSeq },
    400,
  );
  assert.equal(
    (await db.messages.findById(message.message.id).lean())!.deliveredAt,
    null,
  );
});

test("group sequence reads include legacy unread without fabricating ticks or resurrecting badges", async (t) => {
  const config = app.get(ConfigService);
  config.set("RECEIPT_PUSH_MODE", "compact");
  t.after(() => config.set("RECEIPT_PUSH_MODE", "legacy"));
  const group = await request(
    "/rooms/group",
    2,
    "POST",
    { title: "Sequence group read", participantIds: [sessions[3].user._id] },
    201,
  );
  const roomId = group.room.roomId;
  const legacy = await send(2, roomId, "Legacy group unread");
  await db.messages.collection.updateOne(
    { _id: new Types.ObjectId(legacy.message.id) },
    { $unset: { messageSeq: "" } },
  );
  const first = await send(2, roomId, "Group bounded prefix");
  const later = await send(2, roomId, "Group later");
  const member = () =>
    db.members.findOne({ roomId, userId: sessions[3].user._id }).lean();
  const before = (await member())!;
  await request(`/rooms/${roomId}/seen`, 3, "POST", {
    upToSeq: first.message.messageSeq,
  });
  assert.equal((await member())!.unreadCount, 1);
  assert.equal((await member())!.msgPts, before.msgPts);
  await request(`/rooms/${roomId}/seen`, 3, "POST", { upToSeq: 0 });
  assert.equal((await member())!.ownSeenSeq, first.message.messageSeq);
  assert.equal((await member())!.unreadCount, 1);
  await request(`/rooms/${roomId}/seen`, 3, "POST", {
    upToSeq: later.message.messageSeq,
  });
  assert.equal((await member())!.unreadCount, 0);
  await send(2, roomId, "New unread after group read");
  await request(`/rooms/${roomId}/seen`, 3, "POST", {
    upToSeq: first.message.messageSeq,
  });
  assert.equal((await member())!.unreadCount, 1);
  assert.equal(
    (await db.messages.findById(legacy.message.id).lean())!.seenAt,
    null,
  );
  assert.equal(
    (await db.messages.findById(first.message.id).lean())!.seenAt,
    null,
  );
});

test("legacy timestamp receipts stop sequence cursors before an unacknowledged sequence gap", async () => {
  const first = await request("/messages", 4, "POST", {
    peerUserId: sessions[3].user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Legacy prefix",
  });
  const roomId = first.room.roomId;
  const gap = await send(4, roomId, "Sequence gap with later timestamp");
  await db.messages.collection.updateOne(
    { _id: new Types.ObjectId(gap.message.id) },
    { $set: { createdAt: new Date(Date.now() + 60000) } },
  );
  const acknowledged = await send(
    4,
    roomId,
    "Timestamp acknowledges a higher sequence",
  );
  await request(`/rooms/${roomId}/seen`, 3, "POST", {
    upToTimestamp: new Date().toISOString(),
  });
  assert.equal(
    (await db.messages.findById(gap.message.id).lean())!.seenAt,
    null,
  );
  assert.ok(
    (await db.messages.findById(acknowledged.message.id).lean())!.seenAt,
  );
  const sender = await db.members
    .findOne({ roomId, userId: sessions[4].user._id })
    .lean();
  assert.ok(sender!.peerSeenSeq < gap.message.messageSeq);
});

test("latest direct page recovers coalesced receipts across 60 outgoing messages with sender and boundary isolation", async () => {
  const first = await request("/messages", 0, "POST", {
    peerUserId: sessions[4].user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Receipt recovery 0",
  });
  const roomId = first.room.roomId;
  const outgoing = [first.message];
  for (let i = 1; i < 60; i++)
    outgoing.push((await send(0, roomId, `Receipt recovery ${i}`)).message);
  await send(4, roomId, "Newer incoming message is not a sender watermark");
  const untouched = await request(`/rooms/${roomId}/messages`, 0);
  assert.deepEqual(untouched.receipts, {
    deliveredThrough: null,
    seenThrough: null,
    hasGaps: false,
  });
  const before = await request("/rooms", 0);
  await request(`/rooms/${roomId}/seen`, 4, "POST", {
    upToTimestamp: outgoing[44].createdAt,
  });
  await request(`/rooms/${roomId}/delivered`, 4, "POST", {
    upToTimestamp: outgoing[54].createdAt,
  });
  await request(`/rooms/${roomId}/preferences`, 0, "PATCH", { isMuted: true });
  const delta = await request(
    `/rooms/delta?sincePts=${before.pts}&epoch=${before.epoch}`,
    0,
  );
  assert.equal(delta.requiresFullSync, false);
  const coalesced = delta.rooms.find((room: any) => room.roomId === roomId);
  assert.equal(coalesced.eventType, "room_preferences");
  assert.equal(coalesced.lastMessage.senderId, sessions[4].user._id);
  const latest = await request(`/rooms/${roomId}/messages`, 0);
  assert.equal(latest.messages.length, 30);
  assert.equal(latest.hasMore, true);
  assert.deepEqual(latest.receipts, {
    deliveredThrough: outgoing[54].createdAt,
    seenThrough: outgoing[44].createdAt,
    hasGaps: false,
  });
  const actual = await db.messages
    .find({ _id: { $in: outgoing.map((m) => m.id) } })
    .lean();
  assert.equal(actual.filter((message) => message.seenAt !== null).length, 45);
  assert.equal(
    actual.filter((message) => message.deliveredAt !== null).length,
    55,
  );
  assert.ok(
    !actual.find((message) => message._id.toString() === outgoing[59].id)!
      .seenAt,
  );
  const oldest = latest.messages.at(-1);
  const history = await request(
    `/rooms/${roomId}/messages?beforeCreatedAt=${oldest.createdAt}&beforeId=${oldest.id}`,
    0,
  );
  assert.equal(Object.hasOwn(history, "receipts"), false);
  assert.deepEqual((await request(`/rooms/${roomId}/messages`, 4)).receipts, {
    deliveredThrough: null,
    seenThrough: null,
    hasGaps: false,
  });
});

test("receipt summary flags equal or backdated unacknowledged outgoing messages rather than certifying a false prefix", async () => {
  const first = await request("/messages", 2, "POST", {
    peerUserId: sessions[4].user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Acknowledged timestamp",
  });
  const roomId = first.room.roomId;
  await request(`/rooms/${roomId}/seen`, 4, "POST", {});
  const pending = await send(2, roomId, "Later committed timestamp tie");
  for (const createdAt of [
    first.message.createdAt,
    "2026-01-01T00:00:00.000Z",
  ]) {
    await db.messages.collection.updateOne(
      { _id: new Types.ObjectId(pending.message.id) },
      { $set: { createdAt: new Date(createdAt) } },
    );
    const latest = await request(`/rooms/${roomId}/messages`, 2);
    assert.deepEqual(latest.receipts, {
      deliveredThrough: first.message.createdAt,
      seenThrough: first.message.createdAt,
      hasGaps: true,
    });
    const unacknowledged = latest.messages.find(
      (message: any) => message.id === pending.message.id,
    );
    assert.equal(unacknowledged.deliveredAt, null);
    assert.equal(unacknowledged.seenAt, null);
  }
});

test("latest message rows and receipt boundaries use one coherent MongoDB read snapshot", async () => {
  const sent = await request("/messages", 1, "POST", {
    peerUserId: sessions[3].user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Receipt changes during a latest-page read",
  });
  const roomId = sent.room.roomId;
  let signalPaused!: () => void;
  let resume!: () => void;
  const paused = new Promise<void>((resolve) => {
    signalPaused = resolve;
  });
  const resumed = new Promise<void>((resolve) => {
    resume = resolve;
  });
  const membership = chat.membership;
  let intercepted = false;
  chat.membership = async (...args: Parameters<ChatService["membership"]>) => {
    const member = await membership.apply(chat, args);
    if (
      !intercepted &&
      args[0] === roomId &&
      args[1] === sessions[1].user._id
    ) {
      intercepted = true;
      assert.ok(
        args[2],
        "Message membership must be read within its snapshot session",
      );
      signalPaused();
      await resumed;
    }
    return member;
  };
  const reading = request(`/rooms/${roomId}/messages`, 1);
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      paused,
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(
          () => reject(new Error("Snapshot read did not pause")),
          4000,
        );
      }),
    ]);
    await request(`/rooms/${roomId}/seen`, 3, "POST", {});
    assert.ok((await db.messages.findById(sent.message.id).lean())!.seenAt);
    resume();
    const snapshot = await reading;
    assert.equal(snapshot.messages[0].seenAt, null);
    assert.deepEqual(snapshot.receipts, {
      deliveredThrough: null,
      seenThrough: null,
      hasGaps: false,
    });
  } finally {
    clearTimeout(timer);
    resume();
    chat.membership = membership;
    await reading.catch(() => undefined);
  }
  assert.deepEqual((await request(`/rooms/${roomId}/messages`, 1)).receipts, {
    deliveredThrough: sent.message.createdAt,
    seenThrough: sent.message.createdAt,
    hasGaps: false,
  });
});

let groupRoom: string;
test("groups omit directPairKey and multiple groups coexist; unread clear does not fabricate ticks", async () => {
  const group1 = await request(
    "/rooms/group",
    0,
    "POST",
    {
      title: "First group",
      participantIds: [sessions[1].user._id, sessions[2].user._id],
    },
    201,
  );
  const group2 = await request(
    "/rooms/group",
    0,
    "POST",
    { title: "Second group", participantIds: [sessions[1].user._id] },
    201,
  );
  groupRoom = group1.room.roomId;
  const raw = await db.rooms.findById(groupRoom).lean();
  assert.ok(!Object.hasOwn(raw!, "directPairKey"));
  assert.notEqual(groupRoom, group2.room.roomId);
  const sent = await send(0, groupRoom, "Group has no delivery ticks");
  await request(`/rooms/${groupRoom}/seen`, 1, "POST", {});
  assert.equal(
    (await db.messages.findById(sent.message.id).lean())!.seenAt,
    null,
  );
  await request(`/rooms/${groupRoom}/delivered`, 1, "POST", {}, 400);
  assert.equal(
    Object.hasOwn(await request(`/rooms/${groupRoom}/messages`, 0), "receipts"),
    false,
  );
});

test("edit/delete history revisions, reply snapshots and delete-for-me preview rollback preserve order", async () => {
  const target = await send(0, directRoom, "Reply target");
  const reply = await send(1, directRoom, "Reply text", {
    replyToMessageId: target.message.id,
  });
  assert.equal(reply.message.replyTo.messageId, target.message.id);
  const edited = await request(`/messages/${target.message.id}`, 0, "PATCH", {
    text: "Edited target",
  });
  assert.equal(edited.message.isEdited, true);
  assert.equal(edited.room.lastHistoryEditPts, edited.room.msgPts);
  assert.equal(
    (await db.messages.findById(reply.message.id).lean())!.replyTo!.text,
    "Edited target",
  );
  const sort = edited.room.sortTimestamp;
  const deleted = await request(
    `/messages/${target.message.id}/for-all`,
    0,
    "DELETE",
  );
  assert.equal(deleted.message.isDeletedForAll, true);
  assert.equal(deleted.message.imageUrl, null);
  assert.equal(deleted.room.sortTimestamp, sort);
  const quote = (await db.messages.findById(reply.message.id).lean())!.replyTo!;
  assert.equal(quote.isDeleted, true);
  assert.equal(quote.imageUrl, null);
  await request(
    `/messages/${target.message.id}`,
    0,
    "PATCH",
    { text: "not allowed" },
    400,
  );
  await request(
    `/rooms/${directRoom}/messages/around/${target.message.id}`,
    0,
    "GET",
    undefined,
    404,
  );
  const hidden = await request(
    `/messages/${reply.message.id}/for-me`,
    1,
    "DELETE",
  );
  assert.notEqual(hidden.room.lastMessage?.id, reply.message.id);
  assert.equal(hidden.room.sortTimestamp, sort);
  assert.equal(hidden.room.eventType, "message_deleted_me");
  assert.equal(hidden.room.lastHistoryEditPts, hidden.room.msgPts);
  assert.ok(
    !(await request(`/rooms/${directRoom}/messages`, 1)).messages.some(
      (m: any) => m.id === reply.message.id,
    ),
  );
  assert.ok(
    (await request(`/rooms/${directRoom}/messages`, 0)).messages.some(
      (m: any) => m.id === reply.message.id,
    ),
  );
  await request(
    "/messages",
    1,
    "POST",
    {
      roomId: directRoom,
      idempotencyKey: randomUUID(),
      type: "text",
      text: "invalid reply",
      replyToMessageId: reply.message.id,
    },
    400,
  );
  await request(
    "/messages",
    0,
    "POST",
    {
      roomId: groupRoom,
      idempotencyKey: randomUUID(),
      type: "text",
      text: "cross room",
      replyToMessageId: reply.message.id,
    },
    400,
  );
});

test("hidden originals update visible quotes after edits and global deletion without resurfacing or leaking their full content", async () => {
  const original = await request("/messages", 2, "POST", {
    peerUserId: sessions[3].user._id,
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Initial target " + "original ".repeat(30),
  });
  const roomId = original.room.roomId;
  const quoted = await send(3, roomId, "Visible reply", {
    replyToMessageId: original.message.id,
  });
  const newer = await send(2, roomId, "Unrelated newer tail");
  await request(`/messages/${original.message.id}/for-me`, 3, "DELETE");
  const editedText = "Revised quote " + "edited ".repeat(30);
  await request(`/messages/${original.message.id}`, 2, "PATCH", {
    text: editedText,
  });
  const recipientKey = redis.keys(sessions[3].user._id)[2];
  const editEvent = JSON.parse(
    (await redis.client.hget(recipientKey, roomId))!,
  );
  assert.equal(editEvent.eventType, "message_edited");
  assert.equal(Object.hasOwn(editEvent, "updatedMessage"), false);
  assert.equal(editEvent.lastMessage.id, newer.message.id);
  assert.deepEqual(editEvent.quoteUpdate, {
    messageId: original.message.id,
    senderId: sessions[2].user._id,
    senderName: sessions[2].user.displayName,
    type: "text",
    text: editedText.slice(0, 120),
    imageUrl: null,
    isDeleted: false,
  });
  assert.equal(JSON.stringify(editEvent).includes(editedText), false);
  const senderEvent = JSON.parse(
    (await redis.client.hget(redis.keys(sessions[2].user._id)[2], roomId))!,
  );
  assert.equal(senderEvent.updatedMessage.id, original.message.id);
  assert.equal(Object.hasOwn(senderEvent, "quoteUpdate"), false);
  const visible = (await request(`/rooms/${roomId}/messages`, 3)).messages;
  assert.equal(
    visible.some((message: any) => message.id === original.message.id),
    false,
  );
  assert.equal(
    visible.find((message: any) => message.id === quoted.message.id).replyTo
      .text,
    editedText.slice(0, 120),
  );
  await request(`/messages/${original.message.id}/for-all`, 2, "DELETE");
  const deletion = JSON.parse((await redis.client.hget(recipientKey, roomId))!);
  assert.equal(Object.hasOwn(deletion, "updatedMessage"), false);
  assert.equal(deletion.quoteUpdate.messageId, original.message.id);
  assert.equal(deletion.quoteUpdate.isDeleted, true);
  assert.equal(deletion.quoteUpdate.text, "🚫 This message was deleted");
  assert.equal(deletion.quoteUpdate.imageUrl, null);
  assert.equal(deletion.lastMessage.id, newer.message.id);
  const reply = await db.messages.findById(quoted.message.id).lean();
  assert.equal(reply!.replyTo!.isDeleted, true);

  const image = await send(2, roomId, "Hidden image", {
    type: "image",
    imageUrl: await uploadFixture(2),
  });
  const imageReply = await send(3, roomId, "Visible image quote", {
    replyToMessageId: image.message.id,
  });
  await send(2, roomId, "Newer tail after image quote");
  await request(`/messages/${image.message.id}/for-me`, 3, "DELETE");
  await request(`/messages/${image.message.id}/for-all`, 2, "DELETE");
  const imageDeletion = JSON.parse(
    (await redis.client.hget(recipientKey, roomId))!,
  );
  assert.equal(Object.hasOwn(imageDeletion, "updatedMessage"), false);
  assert.equal(imageDeletion.quoteUpdate.type, "image");
  assert.equal(imageDeletion.quoteUpdate.imageUrl, null);
  assert.equal(imageDeletion.quoteUpdate.isDeleted, true);
  assert.equal(
    (await db.messages.findById(imageReply.message.id).lean())!.replyTo!
      .imageUrl,
    null,
  );

  const unquoted = await send(2, roomId, "Hidden without a visible quote");
  await request(`/messages/${unquoted.message.id}/for-me`, 3, "DELETE");
  await request(`/messages/${unquoted.message.id}`, 2, "PATCH", {
    text: "Hidden revision without a visible quote",
  });
  const noQuote = JSON.parse((await redis.client.hget(recipientKey, roomId))!);
  assert.equal(Object.hasOwn(noQuote, "updatedMessage"), false);
  assert.equal(Object.hasOwn(noQuote, "quoteUpdate"), false);
});

test("message pagination handles equal timestamps and around includes the exact target", async () => {
  const ids: string[] = [];
  for (let i = 0; i < 7; i++)
    ids.push((await send(0, groupRoom, `cursor ${i}`)).message.id);
  const sameDate = new Date("2026-10-01T00:00:00Z");
  await db.messages.collection.updateMany(
    { _id: { $in: ids.map((id) => new Types.ObjectId(id)) } },
    { $set: { createdAt: sameDate } },
  );
  assert.equal(
    await db.messages.countDocuments({
      _id: { $in: ids },
      createdAt: sameDate,
    }),
    ids.length,
  );
  let before = "";
  const seen = new Set<string>();
  for (let page = 0; page < 10; page++) {
    const result = await request(
      `/rooms/${groupRoom}/messages?limit=2${before}`,
      0,
    );
    for (const msg of result.messages) {
      assert.ok(!seen.has(msg.id));
      seen.add(msg.id);
    }
    if (!result.hasMore) break;
    const last = result.messages.at(-1);
    before = `&beforeCreatedAt=${last.createdAt}&beforeId=${last.id}`;
  }
  assert.ok(ids.every((id) => seen.has(id)));
  const around = await request(
    `/rooms/${groupRoom}/messages/around/${ids[3]}?limit=4`,
    0,
  );
  assert.equal(around.targetMessageId, ids[3]);
  assert.equal(around.messages.length, 5);
  assert.equal(around.messages.filter((m: any) => m.id === ids[3]).length, 1);
});

test("room cursor includes every tied unpinned room and all pinned rooms on page one", async () => {
  const created: string[] = [];
  for (let i = 0; i < 6; i++)
    created.push(
      (
        await request(
          "/rooms/group",
          0,
          "POST",
          { title: `Page group ${i}`, participantIds: [sessions[1].user._id] },
          201,
        )
      ).room.roomId,
    );
  const sameDate = new Date("2026-10-01T00:00:00Z");
  await db.members.updateMany(
    { userId: sessions[0].user._id, roomId: { $in: created } },
    { $set: { sortTimestamp: sameDate } },
  );
  const first = await request("/rooms?limit=2", 0);
  assert.ok(first.rooms.some((r: any) => r.roomId === directRoom && r.pinAt));
  const seen = new Set<string>();
  let page = first;
  for (let n = 0; n < 10; n++) {
    for (const room of page.rooms) {
      assert.ok(!seen.has(room.roomId));
      seen.add(room.roomId);
    }
    if (!page.nextCursor) break;
    page = await request(
      `/rooms?limit=2&beforeSortTimestamp=${page.nextCursor.beforeSortTimestamp}&beforeRoomId=${page.nextCursor.beforeRoomId}`,
      0,
    );
    assert.ok(page.rooms.every((r: any) => r.pinAt === null));
  }
  assert.ok(created.every((id) => seen.has(id)));
});

test("atomic Redis Lua cannot regress metadata or a room snapshot when writes arrive out of order", async () => {
  const user = new Types.ObjectId().toString();
  const room = (await request("/rooms", 0)).rooms[0] as HydratedRoomPayload;
  await redis.upsert(user, { ...room, roomPts: 102, msgPts: 102 });
  await redis.upsert(user, { ...room, roomPts: 101, msgPts: 101 });
  assert.equal(
    Number(await redis.client.hget(redis.keys(user)[0], "current_pts")),
    102,
  );
  assert.equal(
    JSON.parse((await redis.client.hget(redis.keys(user)[2], room.roomId))!)
      .roomPts,
    102,
  );
  assert.equal(await redis.client.zcard(redis.keys(user)[1]), 1);
  assert.ok((await redis.client.ttl(redis.keys(user)[0])) > 600000);
});

test("missing Redis, epoch reset and a post-commit cache failure force safe full recovery", async () => {
  const full = await request("/rooms", 0);
  const original = redis.upsert.bind(redis);
  redis.upsert = async () => {
    throw new Error("Injected cache outage");
  };
  let sent;
  try {
    sent = await send(0, directRoom, "Committed despite injected Redis outage");
  } finally {
    redis.upsert = original;
  }
  assert.ok(await db.messages.findById(sent.message.id));
  assert.equal(
    (await request(`/rooms/delta?sincePts=${full.pts}&epoch=${full.epoch}`, 0))
      .requiresFullSync,
    true,
  );
  const recovered = await request("/rooms", 0);
  assert.notEqual(recovered.epoch, full.epoch);
  const next = await send(0, directRoom, "After recovery");
  const delta = await request(
    `/rooms/delta?sincePts=${recovered.pts}&epoch=${recovered.epoch}`,
    0,
  );
  assert.equal(delta.requiresFullSync, false);
  assert.equal(
    delta.rooms.find((r: any) => r.roomId === directRoom).lastMessage.id,
    next.message.id,
  );
});

test("presence heartbeat, safe uploads, spoof rejection, size limit and static serving", async () => {
  await request("/presence/heartbeat", 0, "POST");
  const states = await request(
    `/presence/status?userIds=${sessions[0].user._id},${sessions[1].user._id}`,
    0,
  );
  assert.equal(states.statuses[sessions[0].user._id], false);
  assert.equal(states.statuses[sessions[1].user._id], false);
  const upload = async (
    bytes: Uint8Array,
    mime: string,
    filename: string,
    expected: number,
  ) => {
    const form = new FormData();
    form.append(
      "file",
      new Blob([bytes as BlobPart], { type: mime }),
      filename,
    );
    const response = await fetch(`${base}/uploads/image`, {
      method: "POST",
      headers: { authorization: `Bearer ${sessions[0].accessToken}` },
      body: form,
    });
    assert.equal(response.status, expected);
    return response.json() as Promise<any>;
  };
  await upload(
    Buffer.from("not an image"),
    "image/png",
    "../../exploit.png",
    400,
  );
  await upload(Buffer.from("<svg/>"), "image/svg+xml", "image.svg", 400);
  await upload(
    Buffer.alloc(5 * 1024 * 1024 + 1),
    "image/png",
    "large.png",
    413,
  );
  const png = await sharp({
    create: { width: 2, height: 2, channels: 3, background: "#55aaff" },
  })
    .png()
    .toBuffer();
  const result = await upload(png, "image/png", "../../arbitrary.exe", 201);
  assert.match(result.imageUrl, /^\/public\/uploads\/[a-f0-9-]+\.png$/);
  const response = await fetch(`${base}${result.imageUrl}`, {
    headers: { authorization: `Bearer ${sessions[0].accessToken}` },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), png);
  const image = await send(0, directRoom, "", {
    type: "image",
    imageUrl: result.imageUrl,
  });
  assert.equal(image.message.imageUrl, result.imageUrl);
  const quoted = await send(1, directRoom, "Quoted image", {
    replyToMessageId: image.message.id,
  });
  assert.equal(quoted.message.replyTo.imageUrl, result.imageUrl);
  await request(`/messages/${image.message.id}/for-all`, 0, "DELETE");
  assert.equal(
    (await db.messages.findById(quoted.message.id).lean())!.replyTo!.imageUrl,
    null,
  );
  await request(
    "/messages",
    0,
    "POST",
    {
      roomId: directRoom,
      idempotencyKey: randomUUID(),
      type: "image",
      text: "",
      imageUrl: "https://untrusted.test/image.png",
    },
    400,
  );
});

test("compatibility heartbeats create no presence state and logout retires only its login", async () => {
  const firstIndex = sessions.length;
  sessions.push(
    await request("/auth/debug-login", undefined, "POST", {
      debugUserNumber: 5,
    }),
  );
  const secondIndex = sessions.length;
  sessions.push(
    await request("/auth/debug-login", undefined, "POST", {
      debugUserNumber: 5,
    }),
  );
  const userId = sessions[firstIndex].user._id;
  const before = (await db.users.findById(userId).lean())!;
  const hash = (index: number) =>
    createHash("sha256").update(sessions[index].accessToken).digest("hex");
  for (const index of [firstIndex, secondIndex])
    await request("/presence/heartbeat", index, "POST");
  assert.equal(
    (await request(`/presence/status?userIds=${userId}`, 4)).statuses[userId],
    false,
  );
  assert.equal(
    await redis.client.exists(
      `${process.env.REDIS_KEY_PREFIX}presence:due`,
      `${process.env.REDIS_KEY_PREFIX}presence:${userId}:sessions`,
      `${process.env.REDIS_KEY_PREFIX}presence:${userId}:state`,
    ),
    0,
  );
  assert.deepEqual(await request("/presence/offline", firstIndex, "POST"), {
    ok: true,
  });
  assert.ok(
    (await redis.client.ttl(
      redis.sessionRetiredKey(userId, hash(firstIndex)),
    )) > 86390,
  );
  await request("/presence/heartbeat", firstIndex, "POST", undefined, 401);
  await request("/users", firstIndex, "GET", undefined, 401);
  await request("/users", secondIndex);
  await request("/presence/offline", firstIndex, "POST");
  await request("/presence/offline", secondIndex, "POST");
  await request("/presence/heartbeat", secondIndex, "POST", undefined, 401);
  const after = (await db.users.findById(userId).lean())!;
  assert.equal(after.pts, before.pts);
  assert.equal(after.lastSeenAt.getTime(), before.lastSeenAt.getTime());
});

test("concurrent compatibility heartbeat and logout cannot recreate presence or unretire a login", async () => {
  const index = sessions.length;
  sessions.push(
    await request("/auth/debug-login", undefined, "POST", {
      debugUserNumber: 5,
    }),
  );
  const userId = sessions[index].user._id;
  await Promise.all([
    ...Array.from({ length: 12 }, async () => {
      const response = await fetch(`${base}/presence/heartbeat`, {
        method: "POST",
        headers: { authorization: `Bearer ${sessions[index].accessToken}` },
      });
      assert.ok([200, 401].includes(response.status));
    }),
    request("/presence/offline", index, "POST"),
  ]);
  await request("/presence/heartbeat", index, "POST", undefined, 401);
  assert.equal(
    await redis.client.exists(
      `${process.env.REDIS_KEY_PREFIX}presence:${userId}:sessions`,
    ),
    0,
  );
});

test("legacy authentication revocations remain enforced after removing Redis presence tracking", async () => {
  const userId = sessions[4].user._id;
  const token = await app.get(JwtService).signAsync(
    { sub: userId },
    {
      secret: app.get(ConfigService).getOrThrow<string>("JWT_SECRET"),
      expiresIn: "1d",
      algorithm: "HS256",
      issuer: "chat-backend",
      audience: "chat-client",
    },
  );
  const index = sessions.length;
  sessions.push({ ...sessions[4], accessToken: token });
  const hash = createHash("sha256").update(token).digest("hex");
  await request("/presence/heartbeat", index, "POST");
  await redis.client.set(
    `${process.env.REDIS_KEY_PREFIX}presence:${userId}:retired:${hash}`,
    "1",
    "EX",
    60,
  );
  await request("/users", index, "GET", undefined, 401);
  await request("/presence/heartbeat", index, "POST", undefined, 401);
  await request("/presence/offline", index, "POST");
  assert.deepEqual(
    await request("/presence/status", 0, "POST", { userIds: [] }),
    { statuses: {}, lastSeenAt: {} },
  );
  for (const path of [
    "/presence/heartbeat",
    "/presence/offline",
    "/presence/status",
  ])
    await request(
      path,
      undefined,
      "POST",
      path.endsWith("status") ? { userIds: [userId] } : undefined,
      401,
    );
  for (const path of ["/presence/heartbeat", "/presence/offline"])
    await request(path, 0, "POST", { userId }, 400);
});

test("background Redis work is limited to logout retries and last-seen observation, never application presence leases", async () => {
  const original = redis.client.sendCommand;
  const commands: { name: string; script: unknown }[] = [];
  redis.client.sendCommand = function (command, ...args) {
    commands.push({ name: command.name, script: command.args[0] });
    return original.call(this, command, ...args);
  };
  try {
    await new Promise((resolve) => setTimeout(resolve, 1200));
  } finally {
    redis.client.sendCommand = original;
  }
  const allowed: string[] = [
    ...Object.values(sessionScripts),
    ...Object.values(lastSeenScripts),
  ];
  assert.ok(
    commands.every(
      ({ name, script }) => name === "eval" && allowed.includes(String(script)),
    ),
  );
});

test("CORS accepts the specified browser device header and rejects unlisted origins", async () => {
  const response = await fetch(`${base}/messages`, {
    method: "OPTIONS",
    headers: {
      Origin: "http://localhost:5173",
      "Access-Control-Request-Method": "POST",
      "Access-Control-Request-Headers":
        "authorization,content-type,x-device-id",
    },
  });
  assert.equal(response.status, 204);
  assert.match(
    response.headers.get("access-control-allow-headers")!,
    /x-device-id/,
  );
  const rejected = await fetch(`${base}/users`, {
    headers: { Origin: "https://not-allowed.example" },
  });
  assert.equal(rejected.headers.get("access-control-allow-origin"), null);
});

// Socket/auth/Redis-engine acceptance lives in realtime.test.ts, which runs
// an isolated Centrifugo proxy against this run's own backend and database.

test("atomic delta rejects cache holes and too many room states", async () => {
  const userId = sessions[3].user._id;
  const full = await request("/rooms", 3);
  const template = (await request("/rooms", 0)).rooms[0] as HydratedRoomPayload;
  for (let i = 1; i <= 101; i++) {
    const fakeId = i.toString(16).padStart(24, "0");
    await redis.upsert(userId, {
      ...template,
      roomId: fakeId,
      roomPts: full.pts + i,
      msgPts: full.pts + i,
    });
  }
  assert.equal(
    (await redis.delta(userId, full.pts, full.epoch)).requiresFullSync,
    true,
  );
  const original = redis.keys(userId);
  const epoch = await redis.ensureEpoch(userId, full.pts);
  await redis.client.hdel(original[2], template.roomId);
  assert.equal(
    (await request(`/rooms/delta?sincePts=${full.pts}&epoch=${epoch}`, 3))
      .requiresFullSync,
    true,
  );
});

test("auth throttling returns 429 problem JSON with Retry-After and no exception stack", async () => {
  let limited = false;
  for (let i = 0; i < 35; i++) {
    const response = await fetch(`${base}/auth/login`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        email: "missing@example.test",
        password: "wrong",
      }),
    });
    if (response.status === 429) {
      const body = await response.json();
      assert.equal(response.headers.get("retry-after"), "60");
      assert.equal(
        response.headers
          .get("content-type")
          ?.startsWith("application/problem+json"),
        true,
      );
      assert.ok(!body.stack);
      limited = true;
      break;
    }
    assert.equal(response.status, 401);
  }
  assert.equal(limited, true);
});

test("simultaneous distinct first sends create one direct room without losing messages or unread counters", async () => {
  const first = sessions[1].user._id;
  const peer = sessions[4].user._id;
  const beforeUser = await db.users.findById(first).lean();
  const sent = await Promise.all(
    Array.from({ length: 10 }, (_, index) =>
      request("/messages", 1, "POST", {
        peerUserId: peer,
        idempotencyKey: randomUUID(),
        type: "text",
        text: `Concurrent ${index}`,
      }),
    ),
  );
  assert.equal(new Set(sent.map((s) => s.room.roomId)).size, 1);
  assert.equal(new Set(sent.map((s) => s.message.id)).size, 10);
  const roomId = sent[0].room.roomId;
  assert.equal(await db.messages.countDocuments({ roomId }), 10);
  const member = await db.members.findOne({ roomId, userId: peer }).lean();
  assert.equal(member!.unreadCount, 10);
  assert.equal(
    (await db.users.findById(first).lean())!.pts,
    beforeUser!.pts + 10,
  );
});

test("full sync rebases a permanently lagging Redis cursor after a missed post-commit cache write", async () => {
  const userId = sessions[2].user._id;
  const before = await request("/rooms", 2);
  await db.users.updateOne({ _id: userId }, { $inc: { pts: 1 } });
  assert.equal(
    (
      await request(
        `/rooms/delta?sincePts=${before.pts}&epoch=${before.epoch}`,
        2,
      )
    ).requiresFullSync,
    true,
  );
  const full = await request("/rooms", 2);
  assert.equal(full.pts, before.pts + 1);
  assert.notEqual(full.epoch, before.epoch);
  const delta = await request(
    `/rooms/delta?sincePts=${full.pts}&epoch=${full.epoch}`,
    2,
  );
  assert.equal(delta.requiresFullSync, false);
  assert.equal(delta.pts, full.pts);
  assert.deepEqual(delta.rooms, []);
});

test("HTTP correlation is bounded, returned on failures and exposed to browser clients", async () => {
  const trace = `integration-${runId}`;
  const failed = await fetch(
    `${base}/rooms/not-an-id/messages?privateQuery=never-log-me`,
    {
      headers: {
        authorization: `Bearer ${sessions[0].accessToken}`,
        "X-Request-ID": trace,
        Origin: "http://localhost:5173",
      },
    },
  );
  assert.equal(failed.status, 400);
  assert.equal(failed.headers.get("x-request-id"), trace);
  assert.equal((await failed.json()).requestId, trace);
  assert.match(
    failed.headers.get("access-control-expose-headers")!,
    /X-Request-ID/i,
  );
  const generated = await fetch(`${base}/health`, {
    headers: { "X-Request-ID": "invalid request id" },
  });
  assert.match(generated.headers.get("x-request-id")!, /^[a-f0-9-]{36}$/);
  const long = await fetch(`${base}/health`, {
    headers: { "X-Request-ID": "a".repeat(128) },
  });
  assert.match(long.headers.get("x-request-id")!, /^[a-f0-9-]{36}$/);
  const preflight = await fetch(`${base}/messages`, {
    method: "OPTIONS",
    headers: {
      Origin: "http://localhost:5173",
      "Access-Control-Request-Method": "POST",
      "Access-Control-Request-Headers":
        "x-request-id,authorization,content-type",
    },
  });
  assert.equal(preflight.status, 204);
  assert.match(
    preflight.headers.get("access-control-allow-headers")!,
    /x-request-id/i,
  );
  assert.ok(preflight.headers.get("x-request-id"));
});
test("image edits are rejected without modifying content or account revisions", async () => {
  const image = await send(0, directRoom, "Original caption", {
    type: "image",
    imageUrl: await uploadFixture(0),
  });
  const before = await db.users.findById(sessions[0].user._id).lean();
  await request(
    `/messages/${image.message.id}`,
    0,
    "PATCH",
    { text: "Unsupported image edit" },
    400,
  );
  await request(
    `/messages/${image.message.id}`,
    1,
    "PATCH",
    { text: "Unauthorized image edit" },
    403,
  );
  const unchanged = await db.messages.findById(image.message.id).lean();
  assert.equal(unchanged!.text, "Original caption");
  assert.equal(unchanged!.isEdited, false);
  assert.equal(
    (await db.users.findById(sessions[0].user._id).lean())!.pts,
    before!.pts,
  );
});

async function captureTraffic(
  work: (records: TrafficLogRecord[], config: ConfigService) => Promise<void>,
) {
  const config = app.get(ConfigService);
  const logger = app.get(BuiltTrafficLogger);
  const originalWriter = logger.writer;
  const originalHttp = config.get("HTTP_LOGGING_ENABLED");
  const originalDebug = config.get("DEBUG_TRAFFIC_LOGGING_ENABLED");
  const records: TrafficLogRecord[] = [];
  logger.writer = (record) => records.push(structuredClone(record));
  try {
    await work(records, config);
  } finally {
    config.set("HTTP_LOGGING_ENABLED", originalHttp);
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", originalDebug);
    logger.writer = originalWriter;
  }
}

function trafficMap(value: unknown): Record<string, unknown> {
  assert.ok(
    value !== null && typeof value === "object" && !Array.isArray(value),
  );
  return value as Record<string, unknown>;
}

function httpTraffic(records: TrafficLogRecord[], requestId: string) {
  const matches = records.filter(
    (record) =>
      record.event === "http_request" && record.requestId === requestId,
  );
  assert.equal(matches.length, 1, "Each request has one completion record");
  return matches[0];
}

test("traffic logging flags change at runtime and independently gate HTTP and realtime records", async () => {
  await captureTraffic(async (records, config) => {
    config.set("HTTP_LOGGING_ENABLED", "false");
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "false");
    await send(0, directRoom, "Logging disabled integration message");
    assert.equal(records.length, 0);

    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
    await send(0, directRoom, "Realtime-only integration message");
    assert.equal(records.length, 2);
    assert.ok(
      records.every((record) => record.event === "realtime_publication"),
    );

    records.length = 0;
    config.set("HTTP_LOGGING_ENABLED", "true");
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "false");
    await request("/users", 0);
    assert.equal(records.length, 1);
    assert.equal(records[0].event, "http_request");
    assert.equal(records[0].status, 200);
    assert.equal("requestBody" in records[0], false);
    assert.equal("responseBody" in records[0], false);
    assert.equal("path" in records[0], false);
  });
});

test("rich HTTP traffic skips preflight, identifies trusted users and redacts credentials while preserving JSON problems", async () => {
  await captureTraffic(async (records, config) => {
    config.set("HTTP_LOGGING_ENABLED", "true");
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
    const options = await fetch(`${base}/messages`, {
      method: "OPTIONS",
      headers: {
        Origin: "http://localhost:5173",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers":
          "authorization,content-type,x-request-id",
        "X-Request-ID": `options-${runId}`,
      },
    });
    assert.equal(options.status, 204);
    assert.equal(options.headers.get("x-request-id"), `options-${runId}`);
    await options.text();
    assert.equal(records.length, 0);

    const anonymousId = `anonymous-${runId}`;
    const anonymous = await fetch(`${base}/users`, {
      headers: {
        authorization: "Bearer synthetic-invalid-credential",
        "X-Request-ID": anonymousId,
      },
    });
    const anonymousProblem = await anonymous.json();
    assert.equal(anonymous.status, 401);
    const anonymousLog = httpTraffic(records, anonymousId);
    assert.equal(anonymousLog.userId, null);
    assert.deepEqual(anonymousLog.responseBody, anonymousProblem);
    assert.equal(
      trafficMap(anonymousLog.requestHeaders).authorization === "[REDACTED]",
      true,
      "Even rejected bearer credentials are redacted",
    );

    const loginId = `login-${runId}`;
    const login = await fetch(`${base}/auth/debug-login`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "X-Request-ID": loginId,
      },
      body: JSON.stringify({ debugUserNumber: 1 }),
    });
    const loginResult = (await login.json()) as UserSession;
    assert.equal(login.status, 200);
    const loginLog = httpTraffic(records, loginId);
    assert.equal(loginLog.userId, loginResult.user._id);
    assert.deepEqual(loginLog.requestBody, { debugUserNumber: 1 });
    const loggedLogin = trafficMap(loginLog.responseBody);
    assert.equal(trafficMap(loggedLogin.user)._id, loginResult.user._id);
    assert.equal(loggedLogin.accessToken === "[REDACTED]", true);
    assert.equal(loggedLogin.centrifugoToken === "[REDACTED]", true);

    const validationId = `validation-${runId}`;
    const password = "synthetic-password-that-must-be-redacted";
    const validation = await fetch(
      `${base}/auth/login?accessToken=synthetic-query-token`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          cookie: "session=synthetic-cookie-secret",
          "X-Request-ID": validationId,
        },
        body: JSON.stringify({ email: "not-an-email", password }),
      },
    );
    const validationProblem = await validation.json();
    assert.equal(validation.status, 400);
    const validationLog = httpTraffic(records, validationId);
    assert.deepEqual(validationLog.responseBody, validationProblem);
    assert.equal(trafficMap(validationLog.requestBody).email, "not-an-email");
    assert.equal(
      trafficMap(validationLog.requestBody).password === "[REDACTED]",
      true,
    );
    assert.equal(
      trafficMap(validationLog.query).accessToken === "[REDACTED]",
      true,
    );
    assert.equal(
      trafficMap(validationLog.requestHeaders).cookie === "[REDACTED]",
      true,
    );

    const failureId = `problem-${runId}`;
    const failure = await fetch(`${base}/rooms/not-an-id/messages`, {
      headers: {
        authorization: `Bearer ${sessions[0].accessToken}`,
        "X-Request-ID": failureId,
      },
    });
    const problem = await failure.json();
    assert.equal(failure.status, 400);
    const failureLog = httpTraffic(records, failureId);
    assert.equal(failureLog.userId, sessions[0].user._id);
    assert.equal(failureLog.route, "/rooms/:roomId/messages");
    assert.equal(failureLog.path, "/rooms/not-an-id/messages");
    assert.deepEqual(failureLog.params, { roomId: "not-an-id" });
    assert.deepEqual(failureLog.responseBody, problem);
    assert.equal(trafficMap(failureLog.responseBody).requestId, failureId);

    const serialized = JSON.stringify(records);
    for (const secret of [
      sessions[0].accessToken,
      loginResult.accessToken,
      loginResult.centrifugoToken,
      "synthetic-invalid-credential",
      password,
      "synthetic-query-token",
      "synthetic-cookie-secret",
    ]) {
      assert.equal(
        serialized.includes(secret),
        false,
        "Credentials never enter captured traffic",
      );
    }
  });
});

test("a committed HTTP send records its full JSON and correlates each recipient's retried publication with the actor", async () => {
  await captureTraffic(async (records, config) => {
    config.set("HTTP_LOGGING_ENABLED", "true");
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
    const target = `${config.getOrThrow<string>("CENTRIFUGO_API_URL").replace(/\/$/, "")}/publish`;
    const originalFetch = globalThis.fetch;
    const attempts = new Map<string, Record<string, unknown>[]>();
    globalThis.fetch = async (input, init) => {
      if (typeof input !== "string" || input !== target) {
        return originalFetch(input, init);
      }
      const publication = JSON.parse(String(init?.body)) as {
        channel: string;
        data: Record<string, unknown>;
      };
      const previous = attempts.get(publication.channel) ?? [];
      previous.push(publication.data);
      attempts.set(publication.channel, previous);
      if (previous.length === 1) {
        return new Response(
          JSON.stringify({ error: { code: 100, message: "Synthetic retry" } }),
          {
            status: 503,
            headers: { "content-type": "application/json" },
          },
        );
      }
      return originalFetch(input, init);
    };
    try {
      const requestId = `publish-${runId}`;
      const body = {
        roomId: directRoom,
        idempotencyKey: randomUUID(),
        type: "text",
        text: "Synthetic correlated publication",
      };
      const response = await fetch(`${base}/messages`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${sessions[0].accessToken}`,
          "content-type": "application/json",
          "X-Request-ID": requestId,
        },
        body: JSON.stringify(body),
      });
      const sent = await response.json();
      assert.equal(response.status, 200);
      assert.equal(response.headers.get("x-request-id"), requestId);
      const http = httpTraffic(records, requestId);
      assert.equal(http.userId, sessions[0].user._id);
      assert.deepEqual(http.requestBody, body);
      assert.deepEqual(http.responseBody, sent);
      assert.equal(http.status, 200);
      assert.equal(
        trafficMap(http.requestHeaders).authorization === "[REDACTED]",
        true,
      );

      const realtime = records.filter(
        (record) => record.event === "realtime_publication",
      );
      assert.equal(realtime.length, 4);
      assert.deepEqual(
        new Set(realtime.map((record) => record.recipientUserId)),
        new Set([sessions[0].user._id, sessions[1].user._id]),
      );
      const publicationIds = new Set<unknown>();
      for (const recipient of [sessions[0].user._id, sessions[1].user._id]) {
        const recipientLogs = realtime.filter(
          (record) => record.recipientUserId === recipient,
        );
        assert.deepEqual(
          recipientLogs.map((record) => record.attempt),
          [1, 2],
        );
        assert.deepEqual(
          recipientLogs.map((record) => record.result),
          ["failure", "success"],
        );
        assert.deepEqual(
          recipientLogs.map((record) => record.status),
          [503, 200],
        );
        assert.equal(
          recipientLogs[0].publicationId,
          recipientLogs[1].publicationId,
        );
        assert.equal(typeof recipientLogs[0].publicationId, "string");
        publicationIds.add(recipientLogs[0].publicationId);
        const channel = `inbox:user#${recipient}`;
        const submitted = attempts.get(channel)!;
        assert.equal(submitted.length, 2);
        for (const record of recipientLogs) {
          assert.equal(record.source, "backend");
          assert.equal(record.direction, "publish");
          assert.equal(record.requestId, requestId);
          assert.equal(record.userId, sessions[0].user._id);
          assert.equal(record.actorUserId, sessions[0].user._id);
          assert.equal(record.channel, channel);
          assert.equal(record.eventType, "message_new");
          assert.deepEqual(record.data, submitted[0]);
          const data = trafficMap(record.data);
          const room = trafficMap(data.room);
          assert.equal(data.pts, room.roomPts);
          assert.equal(trafficMap(room.lastMessage).id, sent.message.id);
          assert.ok(
            typeof record.durationMs === "number" && record.durationMs >= 0,
          );
        }
      }
      assert.equal(
        publicationIds.size,
        2,
        "Each recipient has its own publication identity",
      );
      assert.equal(
        (await db.messages.findById(sent.message.id).lean())!.text,
        body.text,
      );
      assert.equal(
        JSON.stringify(records).includes(sessions[0].accessToken),
        false,
      );
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

test("publication retry exhaustion stays correlated without converting a committed HTTP mutation into failure", async () => {
  await captureTraffic(async (records, config) => {
    config.set("HTTP_LOGGING_ENABLED", "true");
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
    const target = `${config.getOrThrow<string>("CENTRIFUGO_API_URL").replace(/\/$/, "")}/publish`;
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async (input, init) => {
      if (typeof input !== "string" || input !== target) {
        return originalFetch(input, init);
      }
      return new Response(
        JSON.stringify({
          error: { code: 100, message: "Synthetic permanent rejection" },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    };
    try {
      const requestId = `exhausted-${runId}`;
      const response = await fetch(`${base}/messages`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${sessions[0].accessToken}`,
          "content-type": "application/json",
          "X-Request-ID": requestId,
        },
        body: JSON.stringify({
          roomId: directRoom,
          idempotencyKey: randomUUID(),
          type: "text",
          text: "Committed despite synthetic publication outage",
        }),
      });
      const result = await response.json();
      assert.equal(response.status, 200);
      assert.equal(httpTraffic(records, requestId).status, 200);
      assert.ok(await db.messages.exists({ _id: result.message.id }));
      const realtime = records.filter(
        (record) => record.event === "realtime_publication",
      );
      assert.equal(realtime.length, 6);
      for (const recipient of [sessions[0].user._id, sessions[1].user._id]) {
        const recipientLogs = realtime.filter(
          (record) => record.recipientUserId === recipient,
        );
        assert.deepEqual(
          recipientLogs.map((record) => record.attempt),
          [1, 2, 3],
        );
        assert.equal(
          new Set(recipientLogs.map((record) => record.publicationId)).size,
          1,
        );
        for (const record of recipientLogs) {
          assert.equal(record.requestId, requestId);
          assert.equal(record.actorUserId, sessions[0].user._id);
          assert.equal(record.result, "failure");
          assert.equal(
            record.status,
            200,
            "A Centrifugo error body is a failed attempt even with HTTP 200",
          );
          assert.equal(
            trafficMap(trafficMap(record.responseBody).error).code,
            100,
          );
          assert.deepEqual(record.data, recipientLogs[0].data);
        }
      }
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

test("local metadata correlates real MongoDB, Redis and Centrifugo operations without full traffic capture", async () => {
  await captureTraffic(async (trafficRecords, config) => {
    config.set("HTTP_LOGGING_ENABLED", "false");
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "false");
    const diagnostics = app.get(BuiltServiceDiagnostics);
    // Earlier cases deliberately enable private publication payloads in this
    // same retained input. Check only the newly emitted metadata-only interval.
    await diagnostics.flush();
    const serviceLogStart = (await readFile(serviceLogFile, "utf8")).length;
    const requestId = `local-services-${runId}`;
    const privateText = `Private content excluded from service metadata ${runId}`;
    const response = await fetch(`${base}/messages`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${sessions[0].accessToken}`,
        "content-type": "application/json",
        "X-Request-ID": requestId,
      },
      body: JSON.stringify({
        roomId: directRoom,
        idempotencyKey: randomUUID(),
        type: "text",
        text: privateText,
      }),
    });
    assert.equal(response.status, 200);
    const sent = await response.json();
    assert.equal(sent.message.text, privateText);
    assert.equal(
      trafficRecords.length,
      0,
      "Metadata capture does not enable full HTTP/realtime payload logging",
    );
    const failureId = `local-services-failure-${runId}`;
    const traffic = app.get(BuiltTrafficLogger);
    await traffic.runWithRequest(
      { requestId: failureId, getUserId: () => sessions[0].user._id },
      async () => {
        await assert.rejects(
          redis.client.eval(
            "return redis.error_reply('Synthetic private Redis error')",
            0,
          ),
        );
        await assert.rejects(
          db.connection.db!.command({
            invalidSyntheticMetadataCommand: 1,
            privateQuery: privateText,
          }),
        );
      },
    );
    await diagnostics.flush();
    const values: LocalServiceLogRecord[] = (
      await readFile(serviceLogFile, "utf8")
    )
      .slice(serviceLogStart)
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    const flow = values.filter((record) => record.requestId === requestId);
    for (const source of ["mongodb", "redis", "centrifugo"]) {
      assert.ok(
        flow.some(
          (record) =>
            record.source === source &&
            record.result === "success" &&
            record.userId === sessions[0].user._id,
        ),
        `Real ${source} completion has original actor/request identity`,
      );
    }
    const publication = flow.filter((record) => record.source === "centrifugo");
    assert.deepEqual(
      new Set(publication.map((record) => record.recipientUserId)),
      new Set([sessions[0].user._id, sessions[1].user._id]),
    );
    assert.ok(
      publication.every(
        (record) =>
          typeof record.publicationId === "string" && record.attempt === 1,
      ),
    );
    const failures = values.filter(
      (record) => record.requestId === failureId && record.result === "failure",
    );
    assert.deepEqual(
      new Set(failures.map((record) => record.source)),
      new Set(["redis", "mongodb"]),
    );
    assert.ok(failures.every((record) => typeof record.errorType === "string"));
    assert.ok(
      values.every(
        (record) =>
          record.origin === "backend_client" &&
          Number.isFinite(Date.parse(record.timestamp)),
      ),
    );
    assert.equal(new Set(values.map((record) => record.instanceId)).size, 1);
    const json = JSON.stringify(values);
    for (const excluded of [
      privateText,
      sessions[0].accessToken,
      "Synthetic private Redis error",
      "privateQuery",
      "requestBody",
      "responseBody",
    ])
      assert.equal(
        json.includes(excluded),
        false,
        "Service metadata excludes content, command arguments and raw errors",
      );
  });
});

test("transient revocation-store failure returns 503 without rejecting the otherwise valid session", async () => {
  const original = redis.isSessionRetired;
  redis.isSessionRetired = async () => {
    throw new Error("Synthetic dependency outage");
  };
  try {
    await request("/users", 0, "GET", undefined, 503);
  } finally {
    redis.isSessionRetired = original;
  }
  await request("/users", 0);
});

test("logout retirement remains available after heartbeat and disconnect quota exhaustion", async () => {
  const auth = await request("/auth/debug-login", undefined, "POST", {
    debugUserNumber: 5,
  });
  const config = app.get(ConfigService);
  const previous = config.get("REALTIME_HEARTBEAT_USER_LIMIT");
  const previousLogout = config.get("REALTIME_LOGOUT_USER_LIMIT");
  config.set("REALTIME_HEARTBEAT_USER_LIMIT", 1);
  config.set("REALTIME_LOGOUT_USER_LIMIT", 1);
  const call = async (path: string, method = "POST") =>
    fetch(base + path, {
      method,
      headers: {
        authorization: `Bearer ${auth.accessToken}`,
        "content-type": "application/json",
      },
      ...(method === "POST" ? { body: "{}" } : {}),
    });
  try {
    await call("/presence/heartbeat");
    assert.equal((await call("/presence/heartbeat")).status, 429);
    // Exhaust the separate expensive-work quota as well; retirement must still succeed.
    await redis
      .limitRealtime("logout", auth.user._id, "127.0.0.1")
      .catch(() => undefined);
    assert.equal((await call("/presence/offline")).status, 200);
    assert.equal((await call("/users", "GET")).status, 401);
    assert.equal((await call("/presence/offline")).status, 200);
    await request("/users", 4); // another login for the same account remains valid
  } finally {
    config.set("REALTIME_HEARTBEAT_USER_LIMIT", previous ?? 120);
    config.set("REALTIME_LOGOUT_USER_LIMIT", previousLogout ?? 30);
  }
});

test("mixed-case JSON/query IDs preserve self rejection, duplicate validation and presence authorization", async () => {
  await request(
    "/messages",
    0,
    "POST",
    {
      peerUserId: sessions[0].user._id.toUpperCase(),
      idempotencyKey: randomUUID(),
      type: "text",
      text: "Self rejected",
    },
    400,
  );
  const peer = await request("/messages", 0, "POST", {
    peerUserId: sessions[1].user._id.toUpperCase(),
    idempotencyKey: randomUUID(),
    type: "text",
    text: "Canonical peer",
  });
  assert.equal(peer.room.roomId, directRoom);
  await request(
    "/rooms/group",
    0,
    "POST",
    {
      title: "Duplicate normalization",
      participantIds: [
        sessions[1].user._id,
        sessions[1].user._id.toUpperCase(),
      ],
    },
    400,
  );
  const status = await request(
    `/presence/status?userIds=${sessions[0].user._id.toUpperCase()}`,
    0,
  );
  assert.equal(typeof status.statuses[sessions[0].user._id], "boolean");
  const posted = await request("/presence/status", 0, "POST", {
    userIds: [sessions[0].user._id.toUpperCase()],
  });
  assert.deepEqual(posted, status);
});

test("bounded directory and pinned pages retain complete legacy shapes and compound ties", async () => {
  const legacy = await request("/users", 0);
  assert.ok(Array.isArray(legacy));
  const ids: string[] = [];
  let cursor: string | null = null;
  do {
    const page = await request(
      `/users?limit=2${cursor ? `&afterUserId=${cursor.toUpperCase()}` : ""}`,
      0,
    );
    ids.push(...page.users.map((u: any) => u.id));
    cursor = page.nextCursor;
  } while (cursor);
  assert.equal(new Set(ids).size, legacy.length);
  const config = app.get(ConfigService);
  config.set("LEGACY_DIRECTORY_MAX_USERS", 1);
  try {
    await request("/users", 0, "GET", undefined, 413);
  } finally {
    config.set("LEGACY_DIRECTORY_MAX_USERS", 10000);
  }
  const groups = [];
  for (let i = 0; i < 5; i++) {
    const group = await request(
      "/rooms/group",
      0,
      "POST",
      { title: `Pinned page ${i}`, participantIds: [sessions[1].user._id] },
      201,
    );
    groups.push(group.room.roomId);
    await request(`/rooms/${group.room.roomId}/preferences`, 0, "PATCH", {
      pin: true,
    });
  }
  const tie = new Date();
  await db.members.updateMany(
    {
      roomId: { $in: groups.map((id) => new Types.ObjectId(id)) },
      userId: new Types.ObjectId(sessions[0].user._id),
    },
    { $set: { pinAt: tie } },
  );
  const pinned: string[] = [];
  let pinnedCursor: any = null;
  do {
    const page = await request(
      `/rooms?pinnedLimit=2${pinnedCursor ? `&pinnedOnly=true&beforePinAt=${encodeURIComponent(pinnedCursor.beforePinAt)}&beforePinnedRoomId=${pinnedCursor.beforePinnedRoomId}` : ""}`,
      0,
    );
    pinned.push(
      ...page.rooms
        .filter((room: any) => room.pinAt)
        .map((room: any) => room.roomId),
    );
    pinnedCursor = page.pinnedNextCursor;
  } while (pinnedCursor);
  for (const id of groups) assert.ok(pinned.includes(id));
  assert.equal(new Set(pinned).size, pinned.length);
  config.set("LEGACY_PINNED_MAX_ROOMS", 1);
  try {
    await request("/rooms", 0, "GET", undefined, 413);
  } finally {
    config.set("LEGACY_PINNED_MAX_ROOMS", 1000);
  }
});

test("private media enforces pending ownership, current visible references and deletion revocation while retaining bytes", async () => {
  const path = await uploadFixture(0);
  const read = (user?: number) =>
    fetch(base + path, {
      headers:
        user === undefined
          ? {}
          : { authorization: `Bearer ${sessions[user].accessToken}` },
    });
  const anonymous = await read();
  assert.equal(anonymous.status, 401);
  assert.equal(anonymous.headers.get("cache-control"), "no-store");
  const pendingOwner = await read(0);
  assert.equal(pendingOwner.status, 200);
  assert.equal(pendingOwner.headers.get("cache-control"), "private, no-store");
  const pendingPeer = await read(1);
  assert.equal(pendingPeer.status, 404);
  assert.equal(pendingPeer.headers.get("cache-control"), "no-store");
  await request(
    "/messages",
    1,
    "POST",
    {
      roomId: directRoom,
      idempotencyKey: randomUUID(),
      type: "image",
      text: "",
      imageUrl: path,
    },
    404,
  );
  const image = await send(0, directRoom, "Private upload", {
    type: "image",
    imageUrl: path,
  });
  const peer = await read(1);
  assert.equal(peer.status, 200);
  assert.equal(peer.headers.get("cache-control"), "private, no-store");
  assert.equal((await read(4)).status, 404);
  await request(`/messages/${image.message.id}/for-me`, 1, "DELETE");
  assert.equal((await read(1)).status, 404);
  assert.equal((await read(0)).status, 200);
  await request(`/messages/${image.message.id}/for-all`, 0, "DELETE");
  const revokedOwner = await read(0);
  assert.equal(revokedOwner.status, 404);
  assert.equal(revokedOwner.headers.get("cache-control"), "no-store");
  assert.ok(existsSync(join(process.cwd(), path.slice(1))));
  const metadata = await db.uploads
    .findOne({ filename: path.split("/").at(-1) })
    .lean();
  assert.ok(metadata?.attachedAt);
  assert.equal(metadata!.state, "retained");
});

test("full image decoding rejects matching-header corruption and configured dimension bombs", async () => {
  const config = app.get(ConfigService);
  const upload = async (bytes: Buffer) => {
    const form = new FormData();
    form.append(
      "file",
      new Blob([bytes as BlobPart], { type: "image/png" }),
      "probe.png",
    );
    return fetch(`${base}/uploads/image`, {
      method: "POST",
      headers: { authorization: `Bearer ${sessions[0].accessToken}` },
      body: form,
    });
  };
  const corrupt = Buffer.alloc(30);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(corrupt);
  assert.equal((await upload(corrupt)).status, 400);
  const valid = await sharp({
    create: { width: 20, height: 1, channels: 3, background: "red" },
  })
    .png()
    .toBuffer();
  config.set("UPLOAD_MAX_DIMENSION", 10);
  try {
    assert.equal((await upload(valid)).status, 400);
  } finally {
    config.set("UPLOAD_MAX_DIMENSION", 8192);
  }
  const before = await db.uploads.countDocuments();
  config.set("REALTIME_UPLOAD_USER_LIMIT", 1);
  try {
    assert.equal((await upload(valid)).status, 429);
    assert.equal(await db.uploads.countDocuments(), before);
  } finally {
    config.set("REALTIME_UPLOAD_USER_LIMIT", 30);
  }
});

test("around context uses one snapshot across concurrent edit and global deletion", async () => {
  const anchor = await send(0, directRoom, "Snapshot target original");
  const neighbor = await send(0, directRoom, "Snapshot neighbor original");
  const originalFindOne = db.messages.findOne;
  let paused!: () => void, resume!: () => void;
  const pause = new Promise<void>((r) => (paused = r)),
    gate = new Promise<void>((r) => (resume = r));
  let intercepted = false;
  db.messages.findOne = function (
    this: typeof db.messages,
    ...args: Parameters<typeof originalFindOne>
  ) {
    const query = originalFindOne.apply(this, args);
    const filter = args[0] as any;
    if (
      !intercepted &&
      filter?._id?.toString() === anchor.message.id &&
      filter.isDeletedForAll === false
    ) {
      intercepted = true;
      const lean = query.lean;
      query.lean = async function (this: typeof query, ...params: any[]) {
        const result = await lean.apply(this, params as never);
        paused();
        await gate;
        return result;
      } as never;
    }
    return query;
  } as typeof originalFindOne;
  const pending = request(
    `/rooms/${directRoom}/messages/around/${anchor.message.id}`,
    1,
  );
  try {
    await pause;
    await request(`/messages/${neighbor.message.id}`, 0, "PATCH", {
      text: "Snapshot neighbor revised",
    });
    await request(`/messages/${anchor.message.id}/for-all`, 0, "DELETE");
    resume();
    const result = await pending;
    assert.equal(
      result.messages.find((m: any) => m.id === anchor.message.id).text,
      "Snapshot target original",
    );
    assert.equal(
      result.messages.find((m: any) => m.id === neighbor.message.id).text,
      "Snapshot neighbor original",
    );
  } finally {
    resume();
    db.messages.findOne = originalFindOne;
  }
  await request(
    `/rooms/${directRoom}/messages/around/${anchor.message.id}`,
    1,
    "GET",
    undefined,
    404,
  );
});

test("private quote and legacy attachment access respects hidden originals, membership and global deletion", async () => {
  const path = await uploadFixture(0);
  const image = await send(0, directRoom, "Visible image", {
    type: "image",
    imageUrl: path,
  });
  await send(1, directRoom, "Visible image quote", {
    replyToMessageId: image.message.id,
  });
  await request(`/messages/${image.message.id}/for-me`, 1, "DELETE");
  const read = (url: string, user: number) =>
    fetch(base + url, {
      headers: { authorization: `Bearer ${sessions[user].accessToken}` },
    });
  assert.equal((await read(path, 1)).status, 200);
  await request(`/messages/${image.message.id}/for-all`, 0, "DELETE");
  assert.equal((await read(path, 1)).status, 404);
  // A metadata-free legacy file remains readable only through a currently visible member reference.
  const filename = `legacy_${runId}.png`,
    legacyPath = `/public/uploads/${filename}`;
  const { writeFile } = await import("node:fs/promises");
  const bytes = await sharp({
    create: { width: 2, height: 2, channels: 3, background: "blue" },
  })
    .png()
    .toBuffer();
  await writeFile(join(process.cwd(), "public/uploads", filename), bytes, {
    flag: "wx",
    mode: 0o600,
  });
  assert.equal((await read(legacyPath, 0)).status, 404);
  const legacy = await db.messages.create({
    roomId: new Types.ObjectId(directRoom),
    roomType: "direct",
    senderId: new Types.ObjectId(sessions[0].user._id),
    senderName: "Synthetic legacy",
    idempotencyKey: randomUUID(),
    type: "image",
    text: "Legacy image",
    imageUrl: legacyPath,
  });
  assert.equal((await read(legacyPath, 1)).status, 200);
  assert.equal((await read(legacyPath, 4)).status, 404);
  await request(`/messages/${legacy._id}/for-all`, 0, "DELETE");
  assert.equal((await read(legacyPath, 0)).status, 404);
  assert.ok(existsSync(join(process.cwd(), legacyPath.slice(1))));
});

test("media inventory defaults to dry-run and preserves expired synthetic orphan bytes and metadata", async () => {
  const path = await uploadFixture(0),
    filename = path.split("/").at(-1)!;
  await db.uploads.updateOne(
    { filename },
    { $set: { orphanEligibleAt: new Date(0) } },
  );
  const before = await db.uploads.countDocuments();
  const { spawn } = await import("node:child_process");
  const child = spawn(
    process.execPath,
    ["--import", "tsx", "scripts/media-cleanup.ts"],
    {
      cwd: process.cwd(),
      env: { ...process.env },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  let output = "";
  for await (const chunk of child.stdout!) output += chunk.toString();
  if (child.exitCode === null) await once(child, "exit");
  assert.equal(child.exitCode, 0);
  const inventory = JSON.parse(output.trim());
  assert.equal(inventory.mode, "dry-run");
  assert.ok(inventory.orphanCandidates >= 1);
  assert.equal(inventory.removed, 0);
  assert.equal(await db.uploads.countDocuments(), before);
  assert.ok(existsSync(join(process.cwd(), path.slice(1))));
  assert.equal(
    (await db.uploads.findOne({ filename }).lean())!.state,
    "retained",
  );
});

test("upload concurrency rejects the next multipart request before accepting its body and releases on abort", async () => {
  const config = app.get(ConfigService);
  config.set("UPLOAD_MAX_CONCURRENT", 1);
  const { request: httpRequest } = await import("node:http");
  const {
    UploadBudgetGuard: BuiltGuard,
  } = require("../../dist/chat/uploads.controller.js");
  const guard = app.get(BuiltGuard) as { active: number };
  const boundary = `audit_${runId}`;
  const first = httpRequest(`${base}/uploads/image`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${sessions[0].accessToken}`,
      "content-type": `multipart/form-data; boundary=${boundary}`,
    },
  });
  first.on("error", () => undefined);
  first.write(
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="held.png"\r\nContent-Type: image/png\r\n\r\n`,
  );
  try {
    const until = Date.now() + 2000;
    while (guard.active !== 1 && Date.now() < until)
      await new Promise((r) => setTimeout(r, 10));
    assert.equal(guard.active, 1);
    const rejected = await fetch(`${base}/uploads/image`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${sessions[0].accessToken}`,
        "content-type": "application/octet-stream",
      },
      body: "This invalid body must not reach the multipart parser",
    });
    assert.equal(rejected.status, 429);
  } finally {
    first.destroy();
    const until = Date.now() + 2000;
    while (Number(guard.active) !== 0 && Date.now() < until)
      await new Promise((r) => setTimeout(r, 10));
    config.set("UPLOAD_MAX_CONCURRENT", 4);
  }
  assert.equal(guard.active, 0);
});

test("post-commit Redis blackhole is deadline bounded and expired Lua cannot apply late writes", async () => {
  const config = app.get(ConfigService);
  const previous = config.get("INBOX_FANOUT_DEADLINE_MS");
  config.set("INBOX_FANOUT_DEADLINE_MS", 80);
  const original = redis.client.sendCommand;
  redis.client.sendCommand = function (command, ...args) {
    if (
      command.name === "eval" &&
      command.args[0]?.toString().includes("local newPts = tonumber(ARGV[1])")
    )
      return command.promise;
    return original.call(this, command, ...args);
  };
  const before = await request("/rooms", 0);
  let sent: any;
  const start = performance.now();
  try {
    sent = await send(
      0,
      directRoom,
      "Committed under synthetic blackholed Redis reply",
    );
  } finally {
    redis.client.sendCommand = original;
    config.set("INBOX_FANOUT_DEADLINE_MS", previous ?? 10000);
  }
  assert.ok(performance.now() - start < 1500);
  assert.ok(await db.messages.exists({ _id: sent.message.id }));
  assert.equal(
    (
      await request(
        `/rooms/delta?sincePts=${before.pts}&epoch=${before.epoch}`,
        0,
      )
    ).requiresFullSync,
    true,
  );
  const {
    upsertUserRoomDeltaLua,
  } = require("../../dist/infrastructure/redis-sync.service.js");
  const keys = redis.keys(new Types.ObjectId().toString());
  await assert.rejects(
    redis.client.eval(
      upsertUserRoomDeltaLua,
      3,
      ...keys,
      100,
      directRoom,
      JSON.stringify(sent.room),
      randomUUID(),
      604800,
      Date.now() - 100,
    ),
    /Inbox deadline expired/,
  );
  assert.equal(await redis.client.exists(...keys), 0);
});

test("failed provider disconnect stays queued and rejects credentials without another logout request", async () => {
  const {
    CentrifugoService: BuiltProvider,
  } = require("../../dist/infrastructure/centrifugo.service.js");
  const provider = app.get(BuiltProvider) as {
    disconnectSession: (user: string, id: string) => Promise<boolean>;
  };
  const original = provider.disconnectSession;
  let calls = 0;
  provider.disconnectSession = async () => {
    calls++;
    return calls > 1;
  };
  const auth = await request("/auth/debug-login", undefined, "POST", {
    debugUserNumber: 2,
  });
  const release = () =>
    fetch(`${base}/presence/offline`, {
      method: "POST",
      headers: { authorization: `Bearer ${auth.accessToken}` },
    });
  try {
    assert.equal((await release()).status, 200);
    const until = Date.now() + 5000;
    while (calls < 2 && Date.now() < until)
      await new Promise((resolve) => setTimeout(resolve, 30));
    assert.ok(calls >= 2);
    assert.equal(
      (
        await fetch(base + "/users", {
          headers: { authorization: `Bearer ${auth.accessToken}` },
        })
      ).status,
      401,
    );
  } finally {
    provider.disconnectSession = original;
  }
});

test("profile and group avatars are private current references for authorized peers and members", async () => {
  const path = await uploadFixture(0),
    other = await uploadFixture(0);
  await db.users.updateOne(
    { _id: sessions[0].user._id },
    { $set: { avatarUrl: path } },
  );
  const read = (url: string, user: number) =>
    fetch(base + url, {
      headers: { authorization: `Bearer ${sessions[user].accessToken}` },
    });
  try {
    assert.equal((await read(path, 0)).status, 200);
    assert.equal((await read(path, 1)).status, 200);
    // Use an account with no room relationship to the profile owner.
    const stranger = await db.users.create({
      username: `avatar_stranger_${runId}`,
      email: `avatar_stranger_${runId}@example.test`,
      passwordHash: "unusable-synthetic-password",
      displayName: "Avatar stranger",
    });
    const {
      UploadsService: BuiltUploads,
    } = require("../../dist/chat/uploads.service.js");
    const uploads = app.get(BuiltUploads) as {
      canRead: (user: string, path: string) => Promise<boolean>;
    };
    assert.equal(await uploads.canRead(stranger._id.toString(), path), false);
    const group = await request(
      "/rooms/group",
      0,
      "POST",
      {
        title: "Private group avatar",
        participantIds: [sessions[1].user._id],
        avatarUrl: other,
      },
      201,
    );
    assert.equal((await read(other, 1)).status, 200);
    assert.equal(await uploads.canRead(stranger._id.toString(), other), false);
    assert.ok(group.room.displayAvatarUrl);
  } finally {
    await db.users.updateOne(
      { _id: sessions[0].user._id },
      { $set: { avatarUrl: null } },
    );
  }
});

test("full-debug Mongo diagnostics capture actual filters, write data, cursor batches and results in an isolated collection", async () => {
  await captureTraffic(async (_trafficRecords, config) => {
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
    const diagnostics = app.get<LocalServiceDiagnostics>(
      BuiltServiceDiagnostics,
    );
    const traffic = app.get<DebugTrafficLogger>(BuiltTrafficLogger);
    await diagnostics.flush();
    const start = (await readFile(serviceLogFile, "utf8")).length;
    const requestId = `mongo-details-${runId}`;
    const collection = db.connection.db!.collection("observability_fixtures");
    await traffic.runWithRequest(
      { requestId, getUserId: () => sessions[0].user._id },
      async () => {
        await collection.insertMany(
          [1, 2, 3].map((index) => ({
            index,
            text: `query detail ${runId}`,
            passwordHash: "private-observation-password",
          })),
        );
        const documents = await collection
          .find(
            { text: `query detail ${runId}`, index: { $gte: 1 } },
            { projection: { passwordHash: 0 } },
          )
          .sort({ index: 1 })
          .batchSize(1)
          .toArray();
        assert.equal(documents.length, 3);
        await collection.updateOne(
          { _id: documents[0]._id },
          { $set: { text: "observability updated" } },
        );
        const counts = await collection
          .aggregate([{ $match: { index: { $gte: 1 } } }, { $count: "count" }])
          .toArray();
        assert.equal(counts[0].count, 3);
      },
    );
    await diagnostics.flush();
    const values: LocalServiceLogRecord[] = (
      await readFile(serviceLogFile, "utf8")
    )
      .slice(start)
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    const flow = values.filter(
      (value) => value.requestId === requestId && value.source === "mongodb",
    );
    for (const operation of [
      "insert",
      "find",
      "getMore",
      "update",
      "aggregate",
    ]) {
      const value = flow.find((value) => value.operation === operation);
      assert.ok(value, `Actual ${operation} command was captured`);
      assert.equal(value.collection, "observability_fixtures");
      assert.equal(value.databaseName, db.connection.name);
      assert.equal(value.userId, sessions[0].user._id);
      assert.equal(value.result, "success");
      assert.ok(value.responseBody);
    }
    const json = JSON.stringify(flow);
    assert.match(
      json,
      /\$gte|projection|sort|firstBatch|nextBatch|nModified|pipeline|\$oid/,
    );
    assert.doesNotMatch(json, /private-observation-password/);
  });
});
