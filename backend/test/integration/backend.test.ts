import "reflect-metadata";
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import type { INestApplication } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { DatabaseService } from "../../src/infrastructure/database.service";
import { RedisSyncService } from "../../src/infrastructure/redis-sync.service";
import { HydratedRoomPayload } from "../../src/models";

if (existsSync(".env")) process.loadEnvFile(".env");
const runId = randomUUID().replaceAll("-", "");
process.env.MONGODB_URI = `mongodb://localhost:27017/chat_app_test_${runId}?replicaSet=rs0`;
process.env.REDIS_KEY_PREFIX = `chat-test:${runId}:`;
process.env.NODE_ENV = "development";
process.env.PORT = "3001";
process.env.HTTP_LOGGING_ENABLED = "false";
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
let app: INestApplication;
let base: string;
let db: DatabaseService;
let redis: RedisSyncService;
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
before(async () => {
  app = await createApplication();
  app.useLogger(false);
  await app.listen(0, "127.0.0.1");
  base = await app.getUrl();
  db = app.get(BuiltDatabase);
  redis = app.get(BuiltRedis);
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

test("message pagination handles equal timestamps and around includes the exact target", async () => {
  const ids: string[] = [];
  for (let i = 0; i < 7; i++)
    ids.push((await send(0, groupRoom, `cursor ${i}`)).message.id);
  const sameDate = new Date("2026-10-01T00:00:00Z");
  await db.messages.updateMany(
    { _id: { $in: ids } },
    { $set: { createdAt: sameDate } },
    { timestamps: false },
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
  const user = sessions[4].user._id;
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
  assert.equal(states.statuses[sessions[0].user._id], true);
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
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1XkAAAAASUVORK5CYII=",
    "base64",
  );
  const result = await upload(png, "image/png", "../../arbitrary.exe", 201);
  assert.match(result.imageUrl, /^\/public\/uploads\/[a-f0-9-]+\.png$/);
  const response = await fetch(`${base}${result.imageUrl}`);
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

test("Centrifugo secure JWT subscription permits only own personal channel and receives committed publications", async () => {
  function socketSession(session: UserSession) {
    const socket = new WebSocket("ws://localhost:8000/connection/websocket");
    const replies = new Map<number, (reply: any) => void>();
    const events: any[] = [];
    socket.addEventListener("message", (event) => {
      for (const line of String(event.data).split("\n").filter(Boolean)) {
        const packet = JSON.parse(line);
        events.push(packet);
        if (packet.id) {
          replies.get(packet.id)?.(packet);
          replies.delete(packet.id);
        }
        if (!Object.keys(packet).length) socket.send("{}");
      }
    });
    const call = (id: number, body: unknown) =>
      new Promise<any>((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("Centrifugo reply timeout")),
          4000,
        );
        replies.set(id, (reply) => {
          clearTimeout(timer);
          resolve(reply);
        });
        socket.send(JSON.stringify({ id, ...(body as object) }));
      });
    const ready = new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve(), { once: true });
      socket.addEventListener(
        "error",
        () => reject(new Error("Centrifugo unavailable")),
        { once: true },
      );
    });
    return { socket, events, call, ready };
  }
  const own = socketSession(sessions[0]);
  const foreign = socketSession(sessions[4]);
  try {
    await Promise.all([own.ready, foreign.ready]);
    const connect = await own.call(1, {
      connect: { token: sessions[0].centrifugoToken },
    });
    assert.ok(connect.connect && !connect.error);
    const subscribe = await own.call(2, {
      subscribe: { channel: `inbox:user#${sessions[0].user._id}` },
    });
    assert.ok(subscribe.subscribe && !subscribe.error);
    assert.ok(
      (
        await foreign.call(1, {
          connect: { token: sessions[4].centrifugoToken },
        })
      ).connect,
    );
    const denied = await foreign.call(2, {
      subscribe: { channel: `inbox:user#${sessions[0].user._id}` },
    });
    assert.ok(denied.error, "Another user must not subscribe to this inbox");
    const sent = await send(1, directRoom, "Secure socket publication");
    const deadline = Date.now() + 4000;
    while (
      !own.events.some(
        (packet) =>
          packet.push?.pub?.data?.room?.lastMessage?.id === sent.message.id,
      ) &&
      Date.now() < deadline
    )
      await new Promise((resolve) => setTimeout(resolve, 20));
    const event = own.events.find(
      (packet) =>
        packet.push?.pub?.data?.room?.lastMessage?.id === sent.message.id,
    );
    assert.ok(event);
    assert.equal(event.push.channel, `inbox:user#${sessions[0].user._id}`);
    assert.equal(event.push.pub.data.pts, event.push.pub.data.room.roomPts);
  } finally {
    own.socket.close();
    foreign.socket.close();
  }
});

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
    imageUrl: "/public/uploads/test-image.png",
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
