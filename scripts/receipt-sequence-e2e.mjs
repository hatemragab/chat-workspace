import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

const base = process.env.API_BASE_URL ?? "http://localhost:3000";
const socketUrl =
  process.env.SOCKET_URL ?? "ws://localhost:8000/connection/websocket";
const runId = `receipts_${Date.now()}_${randomUUID().slice(0, 6)}`;
const idOf = (value) => value._id ?? value.id;

async function request(
  path,
  token,
  body,
  method = body === undefined ? "GET" : "POST",
  status = 200,
) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(20000),
  });
  const data = await response.json();
  assert.equal(
    response.status,
    status,
    `${method} ${path} returned ${response.status}`,
  );
  return data;
}

async function signup(index) {
  const username = `${runId}_${index}`;
  return request(
    "/auth/signup",
    undefined,
    {
      username,
      email: `${username}@example.test`,
      displayName: `Sequence receipt ${index}`,
      password: `Synthetic-${randomUUID()}`,
    },
    "POST",
    201,
  );
}

class Inbox {
  socket;
  publications = [];
  async connect(auth) {
    this.socket = new WebSocket(socketUrl);
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("Socket open timeout")),
        10000,
      );
      this.socket.addEventListener(
        "open",
        () => {
          clearTimeout(timeout);
          resolve();
        },
        { once: true },
      );
      this.socket.addEventListener(
        "error",
        () => {
          clearTimeout(timeout);
          reject(new Error("Socket error"));
        },
        { once: true },
      );
    });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error("Socket connect timeout")),
        10000,
      );
      this.socket.addEventListener("message", ({ data }) => {
        for (const line of String(data).split("\n").filter(Boolean)) {
          const event = JSON.parse(line);
          if (!Object.keys(event).length) {
            this.socket.send("{}");
            continue;
          }
          if (event.id === 1) {
            clearTimeout(timeout);
            if (event.error) reject(new Error("Socket authentication failed"));
            else resolve();
          }
          if (event.push?.pub?.data)
            this.publications.push(event.push.pub.data);
        }
      });
      this.socket.send(
        JSON.stringify({
          id: 1,
          connect: { data: { token: auth.centrifugoToken } },
        }),
      );
    });
  }
  async receipt(type, minimumSeq) {
    return this.publication(
      (event) =>
        event.receipt?.eventType === type &&
        Math.max(
          event.receipt.peerDeliveredSeq ?? 0,
          event.receipt.peerSeenSeq ?? 0,
        ) >= minimumSeq,
      type,
    );
  }
  async unread(count) {
    return this.publication(
      (event) =>
        event.unread?.eventType === "room_unread_cleared" &&
        event.unread.unreadCount === count,
      `unread count ${count}`,
    );
  }
  async publication(predicate, description) {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      const found = this.publications.find(predicate);
      if (found) return found;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error(`Compact ${description} publication did not arrive`);
  }
  close() {
    this.socket?.close();
  }
}

test(
  "live sequence receipts preserve boundaries, compact pushes and offline recovery",
  { timeout: 120000 },
  async (t) => {
    const alice = await signup(1);
    const bob = await signup(2);
    const outsider = await signup(3);
    const inbox = new Inbox();
    const reader = new Inbox();
    const otherReaderDevice = new Inbox();
    t.after(() => {
      inbox.close();
      reader.close();
      otherReaderDevice.close();
    });
    await inbox.connect(alice);
    await reader.connect(bob);
    await otherReaderDevice.connect(bob);
    const send = (roomId, index, key = randomUUID()) =>
      request("/messages", alice.accessToken, {
        ...(roomId ? { roomId } : { peerUserId: idOf(bob.user) }),
        idempotencyKey: key,
        type: "text",
        text: `Sequence fixture ${index}`,
      });
    const key = randomUUID();
    const first = await send(undefined, 1, key);
    const roomId = first.room.roomId;
    assert.equal(first.message.messageSeq, 1);
    const retry = await request("/messages", alice.accessToken, {
      roomId,
      idempotencyKey: key,
      type: "text",
      text: "Sequence fixture 1",
    });
    assert.equal(idOf(retry.message), idOf(first.message));
    assert.equal(retry.message.messageSeq, 1);
    const later = await Promise.all([send(roomId, 2), send(roomId, 3)]);
    assert.deepEqual(
      later.map((r) => r.message.messageSeq).sort((a, b) => a - b),
      [2, 3],
    );

    await request(`/rooms/${roomId}/delivered`, bob.accessToken, {
      upToSeq: 2,
    });
    const delivered = await inbox.receipt("room_delivered", 2);
    assert.equal(delivered.room, undefined);
    assert.equal(delivered.receipt.peerDeliveredSeq, 2);
    assert.equal(delivered.receipt.peerSeenSeq, 0);
    assert.equal(JSON.stringify(delivered).includes("Sequence fixture"), false);
    assert.ok(JSON.stringify(delivered).length < 400);

    const readerBeforeSeen = await request("/rooms", bob.accessToken);
    const readerRoomBeforeSeen = readerBeforeSeen.rooms.find(
      (r) => r.roomId === roomId,
    );
    await request(`/rooms/${roomId}/seen`, bob.accessToken, { upToSeq: 1 });
    const unread = await reader.unread(2);
    const otherDeviceUnread = await otherReaderDevice.unread(2);
    assert.deepEqual(otherDeviceUnread, unread);
    assert.equal(unread.room, undefined);
    assert.equal(unread.receipt, undefined);
    assert.deepEqual(Object.keys(unread.unread).sort(), [
      "eventType",
      "ownDeliveredSeq",
      "ownSeenSeq",
      "roomId",
      "unreadCount",
    ]);
    assert.equal(unread.unread.ownDeliveredSeq, 2);
    assert.equal(unread.unread.ownSeenSeq, 1);
    assert.ok(JSON.stringify(unread).length < 300);
    await inbox.receipt("room_peer_seen", 2);
    let page = await request(`/rooms/${roomId}/messages`, alice.accessToken);
    const bySeq = (seq) => page.messages.find((m) => m.messageSeq === seq);
    assert.ok(bySeq(1).seenAt);
    assert.ok(bySeq(2).deliveredAt);
    assert.equal(bySeq(2).seenAt, null);
    assert.equal(bySeq(3).deliveredAt, null);
    const originalSeenAt = bySeq(1).seenAt;
    const bobRooms = await request("/rooms", bob.accessToken);
    const bobRoom = bobRooms.rooms.find((r) => r.roomId === roomId);
    assert.equal(
      bobRooms.rooms.find((r) => r.roomId === roomId).unreadCount,
      2,
    );
    assert.equal(bobRoom.roomPts, unread.pts);
    assert.equal(bobRoom.msgPts, readerRoomBeforeSeen.msgPts);
    assert.equal(bobRoom.contentPts, readerRoomBeforeSeen.contentPts);
    assert.equal(bobRoom.sortTimestamp, readerRoomBeforeSeen.sortTimestamp);
    assert.equal(
      bobRoom.lastHistoryEditPts,
      readerRoomBeforeSeen.lastHistoryEditPts,
    );

    const beforeRetry = await request("/rooms", alice.accessToken);
    await request(`/rooms/${roomId}/delivered`, bob.accessToken, {
      upToSeq: 1,
    });
    await request(`/rooms/${roomId}/seen`, bob.accessToken, { upToSeq: 1 });
    const afterRetry = await request("/rooms", alice.accessToken);
    assert.equal(
      afterRetry.pts,
      beforeRetry.pts,
      "Duplicate/older receipts must not allocate inbox revisions",
    );
    const readerAfterRetry = await request("/rooms", bob.accessToken);
    assert.equal(readerAfterRetry.pts, bobRooms.pts);
    assert.equal(reader.publications.filter((event) => event.unread).length, 1);
    await request(
      `/rooms/${roomId}/seen`,
      bob.accessToken,
      { upToSeq: 99999 },
      "POST",
      400,
    );
    await request(
      `/rooms/${roomId}/seen`,
      outsider.accessToken,
      { upToSeq: 1 },
      "POST",
      403,
    );

    inbox.close();
    reader.close();
    otherReaderDevice.close();
    await request(`/rooms/${roomId}/seen`, bob.accessToken, { upToSeq: 3 });
    await request(
      `/rooms/${roomId}/preferences`,
      alice.accessToken,
      { isMuted: true },
      "PATCH",
    );
    await request(
      `/rooms/${roomId}/preferences`,
      bob.accessToken,
      { isMuted: true },
      "PATCH",
    );
    const readerDelta = await request(
      `/rooms/delta?sincePts=${bobRooms.pts}&epoch=${encodeURIComponent(bobRooms.epoch)}`,
      bob.accessToken,
    );
    assert.equal(readerDelta.requiresFullSync, false);
    const recoveredReader = readerDelta.rooms.find((r) => r.roomId === roomId);
    assert.equal(recoveredReader.eventType, "room_preferences");
    assert.equal(recoveredReader.unreadCount, 0);
    assert.equal(recoveredReader.ownSeenSeq, 3);
    assert.equal(recoveredReader.msgPts, readerRoomBeforeSeen.msgPts);
    const delta = await request(
      `/rooms/delta?sincePts=${afterRetry.pts}&epoch=${encodeURIComponent(afterRetry.epoch)}`,
      alice.accessToken,
    );
    assert.equal(delta.requiresFullSync, false);
    const recovered = delta.rooms.find((r) => r.roomId === roomId);
    assert.equal(recovered.peerDeliveredSeq, 3);
    assert.equal(recovered.peerSeenSeq, 3);
    assert.equal(
      recovered.eventType,
      "room_preferences",
      "Receipt state must survive a newer coalesced room event",
    );
    page = await request(`/rooms/${roomId}/messages`, alice.accessToken);
    assert.ok(page.messages.every((m) => m.deliveredAt && m.seenAt));
    assert.equal(
      bySeq(1).seenAt,
      originalSeenAt,
      "Later cursors must preserve exact first receipt dates",
    );
    assert.ok(page.coverage);
    console.log(
      JSON.stringify({
        compactReceiptBytes: JSON.stringify(delivered).length,
        compactUnreadBytes: JSON.stringify(unread).length,
        readerDevicesVerified: 2,
        recoveredUnreadCount: recoveredReader.unreadCount,
        verifiedMessages: page.messages.length,
        recoveredSeenSeq: recovered.peerSeenSeq,
      }),
    );
  },
);
