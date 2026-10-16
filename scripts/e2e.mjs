import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

const base = process.env.API_BASE_URL ?? "http://localhost:3000";
const socketUrl =
  process.env.SOCKET_URL ?? "ws://localhost:8000/connection/websocket";
const runId = `${Date.now()}_${randomUUID().slice(0, 6)}`;
const idOf = (value) => value._id ?? value.id;

async function request(path, { token, method = "GET", body, status } = {}) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      "x-device-id": `e2e-${runId}`,
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20000),
  });
  const requestId = response.headers.get("x-request-id");
  assert.match(requestId ?? "", /^[A-Za-z0-9._-]{1,64}$/);
  const text = await response.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = text;
  }
  if (!response.ok && data && typeof data === "object") {
    assert.equal(data.requestId, requestId, "Problem correlation must match");
  }
  if (status !== undefined) {
    assert.equal(
      response.status,
      status,
      `${method} ${path}: unexpected HTTP status`,
    );
  } else {
    assert.ok(
      response.ok,
      `${method} ${path} failed (${response.status}): ${JSON.stringify(data)}`,
    );
  }
  return data;
}

async function createUser(index) {
  const password = `TestOnly-${randomUUID()}`;
  const username = `e2e_${runId}_${index}`;
  const auth = await request("/auth/signup", {
    method: "POST",
    body: {
      username,
      email: `${username}@example.test`,
      displayName: `E2E ${index}`,
      password,
    },
  });
  assert.ok(auth.accessToken && auth.centrifugoToken && idOf(auth.user));
  assert.equal(auth.user.passwordHash, undefined);
  return { ...auth, password, username };
}

class InboxClient {
  #socket;
  #id = 0;
  #pending = new Map();
  publications = [];

  constructor() {
    this.#socket = new WebSocket(socketUrl);
    this.#socket.addEventListener("message", ({ data }) => {
      for (const line of String(data).split("\n").filter(Boolean)) {
        const reply = JSON.parse(line);
        if (!Object.keys(reply).length) {
          this.#socket.send("{}");
          continue;
        }
        const pending = this.#pending.get(reply.id);
        if (pending) {
          clearTimeout(pending.timer);
          this.#pending.delete(reply.id);
          pending.resolve(reply);
        }
        if (reply.push?.pub?.data) this.publications.push(reply.push.pub.data);
      }
    });
  }

  async command(command) {
    const id = ++this.#id;
    const result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(
          new Error(`WebSocket command ${Object.keys(command)[0]} timed out`),
        );
      }, 10000);
      this.#pending.set(id, { resolve, reject, timer });
    });
    this.#socket.send(JSON.stringify({ id, ...command }));
    return result;
  }

  async connect(auth, channel = `inbox:user#${idOf(auth.user)}`) {
    if (this.#socket.readyState !== WebSocket.OPEN)
      await new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("WebSocket open timed out")),
          10000,
        );
        this.#socket.addEventListener(
          "open",
          () => {
            clearTimeout(timer);
            resolve();
          },
          { once: true },
        );
        this.#socket.addEventListener(
          "error",
          () => {
            clearTimeout(timer);
            reject(new Error("WebSocket connection failed"));
          },
          { once: true },
        );
      });
    const connected = await this.command({
      connect: { token: auth.centrifugoToken },
    });
    assert.equal(connected.error, undefined, "Centrifugo connection rejected");
    assert.ok(
      connected.connect?.client,
      "Centrifugo did not return a client ID",
    );
    return this.command({ subscribe: { channel } });
  }

  async publication(predicate) {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      const found = this.publications.find(predicate);
      if (found) return found;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error("Expected realtime publication did not arrive");
  }

  close() {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("WebSocket closed"));
    }
    this.#pending.clear();
    this.#socket.close();
  }
}

test(
  "live REST and two-client WebSocket end-to-end chat",
  { timeout: 180000 },
  async (t) => {
    const alice = await createUser(1);
    const bob = await createUser(2);
    const outsider = await createUser(3);
    const a = alice.accessToken;
    const b = bob.accessToken;
    const x = outsider.accessToken;
    const aliceSocket = new InboxClient();
    const bobSocket = new InboxClient();
    const unauthorizedSocket = new InboxClient();
    t.after(() => {
      aliceSocket.close();
      bobSocket.close();
      unauthorizedSocket.close();
    });
    let roomId;
    let original;
    let reply;

    await t.test(
      "auth, validation, user discovery, token refresh and private channels",
      async () => {
        await request("/users", { status: 401 });
        await request("/auth/login", {
          method: "POST",
          body: { username: alice.username, password: "incorrect" },
          status: 401,
        });
        const login = await request("/auth/login", {
          method: "POST",
          body: { username: alice.username, password: alice.password },
        });
        assert.equal(idOf(login.user), idOf(alice.user));
        const users = await request("/users", { token: a });
        assert.ok(users.some((user) => idOf(user) === idOf(bob.user)));
        assert.ok(users.every((user) => !("passwordHash" in user)));
        assert.ok(
          (
            await request("/auth/centrifugo-token", {
              token: a,
              method: "POST",
            })
          ).centrifugoToken,
        );
        assert.equal((await aliceSocket.connect(alice)).error, undefined);
        assert.equal((await bobSocket.connect(bob)).error, undefined);
        assert.ok(
          (
            await unauthorizedSocket.connect(
              outsider,
              `inbox:user#${idOf(alice.user)}`,
            )
          ).error,
          "Foreign inbox subscription must be rejected",
        );
      },
    );

    await t.test("opening a direct draft does not create a room", async () => {
      const draft = await request(`/rooms/direct-peer/${idOf(bob.user)}`, {
        token: a,
      });
      assert.equal(draft.exists, false);
      assert.equal(draft.room, null);
      assert.equal((await request("/rooms", { token: a })).rooms.length, 0);
    });

    await t.test(
      "first send creates a direct room and reaches both sockets",
      async () => {
        const sent = await request("/messages", {
          token: a,
          method: "POST",
          body: {
            peerUserId: idOf(bob.user),
            idempotencyKey: randomUUID(),
            type: "text",
            text: `Hello from Alice ${runId}`,
          },
        });
        original = sent.message;
        roomId = sent.room.roomId;
        assert.equal(original.roomId, roomId);
        assert.equal(sent.room.lastMessage.text, original.text);
        for (const socket of [aliceSocket, bobSocket]) {
          const event = await socket.publication(
            (event) =>
              event.room?.lastMessage?.idempotencyKey ===
              original.idempotencyKey,
          );
          assert.equal(event.room.eventType, "message_new");
          assert.ok(event.pts > 0 && event.epoch);
        }
        const peerRoom = (await request("/rooms", { token: b })).rooms.find(
          (room) => room.roomId === roomId,
        );
        assert.equal(peerRoom.unreadCount, 1);
      },
    );

    await t.test(
      "concurrent idempotent retries produce one message and unread increment",
      async () => {
        const key = randomUUID();
        const payload = {
          roomId,
          idempotencyKey: key,
          type: "text",
          text: "A retry must not duplicate me",
        };
        const results = await Promise.all(
          Array.from({ length: 5 }, () =>
            request("/messages", { token: a, method: "POST", body: payload }),
          ),
        );
        assert.equal(
          new Set(results.map((result) => idOf(result.message))).size,
          1,
        );
        const history = await request(`/rooms/${roomId}/messages`, {
          token: b,
        });
        assert.equal(
          history.messages.filter((message) => message.idempotencyKey === key)
            .length,
          1,
        );
        assert.equal(
          (await request("/rooms", { token: b })).rooms.find(
            (room) => room.roomId === roomId,
          ).unreadCount,
          2,
        );
      },
    );

    await t.test(
      "bidirectional replies, edits and quote previews stay coherent",
      async () => {
        const response = await request("/messages", {
          token: b,
          method: "POST",
          body: {
            roomId,
            idempotencyKey: randomUUID(),
            type: "text",
            text: "Bob replies",
            replyToMessageId: idOf(original),
          },
        });
        reply = response.message;
        assert.equal(reply.replyTo.messageId, idOf(original));
        await aliceSocket.publication(
          (event) =>
            event.room?.lastMessage?.idempotencyKey === reply.idempotencyKey,
        );
        await request(`/messages/${idOf(original)}`, {
          token: a,
          method: "PATCH",
          body: { text: "Alice edited this message" },
        });
        const history = await request(`/rooms/${roomId}/messages`, {
          token: b,
        });
        assert.equal(
          history.messages.find((message) => idOf(message) === idOf(original))
            .isEdited,
          true,
        );
        assert.equal(
          history.messages.find((message) => idOf(message) === idOf(reply))
            .replyTo.text,
          "Alice edited this message",
        );
      },
    );

    await t.test(
      "membership, sender permissions and foreign reply targets are enforced",
      async () => {
        await request(`/rooms/${roomId}/messages`, { token: x, status: 403 });
        await request(`/messages/${idOf(original)}`, {
          token: b,
          method: "PATCH",
          body: { text: "Not mine" },
          status: 403,
        });
        await request(`/rooms/${roomId}/seen`, {
          token: x,
          method: "POST",
          body: {},
          status: 403,
        });
        const foreign = await request("/messages", {
          token: x,
          method: "POST",
          body: {
            peerUserId: idOf(alice.user),
            idempotencyKey: randomUUID(),
            type: "text",
            text: "Different conversation",
          },
        });
        await request("/messages", {
          token: b,
          method: "POST",
          body: {
            roomId,
            idempotencyKey: randomUUID(),
            type: "text",
            text: "Invalid quote",
            replyToMessageId: idOf(foreign.message),
          },
          status: 400,
        });
      },
    );

    await t.test(
      "preferences change room revision without changing message revision or activity time",
      async () => {
        const before = (await request("/rooms", { token: a })).rooms.find(
          (room) => room.roomId === roomId,
        );
        const { room } = await request(`/rooms/${roomId}/preferences`, {
          token: a,
          method: "PATCH",
          body: { pin: true, isMuted: true },
        });
        assert.ok(room.pinAt && room.isMuted);
        assert.ok(room.roomPts > before.roomPts);
        assert.equal(room.msgPts, before.msgPts);
        assert.equal(room.sortTimestamp, before.sortTimestamp);
        const snapshot = await request("/rooms", { token: a });
        await request(`/rooms/${roomId}/preferences`, {
          token: a,
          method: "PATCH",
          body: { pin: false, isMuted: false },
        });
        const delta = await request(
          `/rooms/delta?sincePts=${snapshot.pts}&epoch=${encodeURIComponent(snapshot.epoch)}`,
          { token: a },
        );
        assert.equal(delta.requiresFullSync, false);
        assert.ok(
          delta.rooms.some(
            (room) => room.roomId === roomId && room.isMuted === false,
          ),
        );
        assert.equal(
          (await request(`/rooms/delta?sincePts=0&epoch=wrong`, { token: a }))
            .requiresFullSync,
          true,
        );
      },
    );

    await t.test(
      "delivered and read events preserve direction and timestamp boundary",
      async () => {
        await request(`/rooms/${roomId}/delivered`, {
          token: b,
          method: "POST",
          body: { upToTimestamp: original.createdAt },
        });
        const delivered = await aliceSocket.publication(
          (event) =>
            event.room?.roomId === roomId &&
            event.room.eventType === "room_delivered",
        );
        assert.equal(delivered.room.actionTimestamp, original.createdAt);
        await request(`/rooms/${roomId}/seen`, {
          token: b,
          method: "POST",
          body: { upToTimestamp: original.createdAt },
        });
        await aliceSocket.publication(
          (event) =>
            event.room?.roomId === roomId &&
            event.room.eventType === "room_peer_seen",
        );
        await bobSocket.publication(
          (event) =>
            event.room?.roomId === roomId &&
            event.room.eventType === "room_unread_cleared",
        );
        const history = (
          await request(`/rooms/${roomId}/messages`, { token: a })
        ).messages;
        assert.ok(
          history.find((message) => idOf(message) === idOf(original)).seenAt,
        );
        assert.equal(
          history.find(
            (message) => message.text === "A retry must not duplicate me",
          ).seenAt,
          null,
        );
      },
    );

    await t.test(
      "delete for me is private; delete for everyone redacts reply previews",
      async () => {
        await request(`/messages/${idOf(reply)}/for-me`, {
          token: a,
          method: "DELETE",
        });
        assert.ok(
          !(
            await request(`/rooms/${roomId}/messages`, { token: a })
          ).messages.some((message) => idOf(message) === idOf(reply)),
        );
        assert.ok(
          (
            await request(`/rooms/${roomId}/messages`, { token: b })
          ).messages.some((message) => idOf(message) === idOf(reply)),
        );
        await request(`/messages/${idOf(original)}/for-all`, {
          token: a,
          method: "DELETE",
        });
        const history = (
          await request(`/rooms/${roomId}/messages`, { token: b })
        ).messages;
        assert.ok(
          history.find((message) => idOf(message) === idOf(original))
            .isDeletedForAll,
        );
        assert.ok(
          history.find((message) => idOf(message) === idOf(reply)).replyTo
            .isDeleted,
        );
      },
    );

    await t.test(
      "multiple group rooms, group messaging and target-centered history work",
      async () => {
        const groups = [];
        for (let index = 0; index < 2; index++)
          groups.push(
            (
              await request("/rooms/group", {
                token: a,
                method: "POST",
                body: {
                  title: `E2E group ${index} ${runId}`,
                  participantIds: [idOf(bob.user)],
                },
              })
            ).room,
          );
        assert.notEqual(groups[0].roomId, groups[1].roomId);
        const groupMessage = await request("/messages", {
          token: b,
          method: "POST",
          body: {
            roomId: groups[0].roomId,
            idempotencyKey: randomUUID(),
            type: "text",
            text: "Hello group",
          },
        });
        assert.equal(groupMessage.room.roomType, "group");
        const context = await request(
          `/rooms/${groups[0].roomId}/messages/around/${idOf(groupMessage.message)}?limit=30`,
          { token: a },
        );
        assert.ok(
          context.messages.some(
            (message) => idOf(message) === context.targetMessageId,
          ),
        );
      },
    );

    await t.test(
      "message pagination returns each message exactly once",
      async () => {
        for (let index = 0; index < 35; index++)
          await request("/messages", {
            token: a,
            method: "POST",
            body: {
              roomId,
              idempotencyKey: randomUUID(),
              type: "text",
              text: `Page fixture ${index}`,
            },
          });
        const ids = new Set();
        let suffix = "";
        let hasMore = true;
        let pages = 0;
        while (hasMore) {
          const page = await request(
            `/rooms/${roomId}/messages?limit=7${suffix}`,
            { token: b },
          );
          for (const message of page.messages) {
            assert.ok(
              !ids.has(idOf(message)),
              "Pagination returned a duplicate",
            );
            ids.add(idOf(message));
          }
          hasMore = page.hasMore;
          if (hasMore) {
            const oldest = page.messages.at(-1);
            assert.ok(oldest, "Empty page cannot have more results");
            suffix = `&beforeCreatedAt=${encodeURIComponent(oldest.createdAt)}&beforeId=${idOf(oldest)}`;
          }
          assert.ok(++pages < 20, "Pagination failed to terminate");
        }
        assert.equal(ids.size, 38);
      },
    );

    await t.test(
      "image upload, media retrieval, image messages and upload validation work",
      async () => {
        const image = Buffer.from(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=",
          "base64",
        );
        const form = new FormData();
        form.append(
          "file",
          new Blob([image], { type: "image/png" }),
          "e2e.png",
        );
        const uploaded = await fetch(`${base}/uploads/image`, {
          method: "POST",
          headers: { Authorization: `Bearer ${a}` },
          body: form,
        });
        assert.ok(uploaded.ok, "Image upload failed");
        const { imageUrl } = await uploaded.json();
        assert.ok(imageUrl.startsWith("/public/uploads/"));
        const media = await fetch(`${base}${imageUrl}`);
        assert.ok(
          media.ok && media.headers.get("content-type")?.startsWith("image/"),
        );
        assert.deepEqual(Buffer.from(await media.arrayBuffer()), image);
        const message = await request("/messages", {
          token: a,
          method: "POST",
          body: {
            roomId,
            idempotencyKey: randomUUID(),
            type: "image",
            text: "",
            imageUrl,
          },
        });
        assert.equal(message.message.imageUrl, imageUrl);
        await request(`/messages/${idOf(message.message)}`, {
          token: a,
          method: "PATCH",
          body: { text: "Images cannot be converted into edited text" },
          status: 400,
        });
        const invalidForm = new FormData();
        invalidForm.append(
          "file",
          new Blob(["not an image"], { type: "text/plain" }),
          "e2e.txt",
        );
        const invalid = await fetch(`${base}/uploads/image`, {
          method: "POST",
          headers: { Authorization: `Bearer ${a}` },
          body: invalidForm,
        });
        assert.ok(
          invalid.status >= 400 && invalid.status < 500,
          "Unsupported upload should be rejected",
        );
      },
    );

    await t.test("presence heartbeat is visible to the peer", async () => {
      await request("/presence/heartbeat", { token: a, method: "POST" });
      const result = await request("/presence/status", {
        token: b,
        method: "POST",
        body: { userIds: [idOf(alice.user)] },
      });
      assert.equal(result.statuses[idOf(alice.user)], true);
    });
  },
);
