import "reflect-metadata";
import assert from "node:assert/strict";
import { test } from "node:test";
import { ConfigService } from "@nestjs/config";
import {
  DebugTrafficLogger,
  sanitizeTrafficValue,
  TrafficLogRecord,
} from "../src/infrastructure/debug-traffic-logger";
import { CentrifugoService } from "../src/infrastructure/centrifugo.service";
import { HydratedRoomPayload } from "../src/models";

function configuration(enabled = true) {
  return new ConfigService({
    HTTP_LOGGING_ENABLED: "false",
    DEBUG_TRAFFIC_LOGGING_ENABLED: String(enabled),
    CENTRIFUGO_API_URL: "http://synthetic-provider.test/api",
    CENTRIFUGO_API_KEY: "private-provider-api-key",
  });
}
function room(pts: number): HydratedRoomPayload {
  return {
    roomId: `room-${pts}`,
    roomType: "direct",
    peerUserId: "peer",
    displayTitle: "Full business room title",
    displayAvatarUrl: "/public/uploads/avatar.png",
    pinAt: null,
    isMuted: false,
    unreadCount: 0,
    clearedAt: null,
    deletedAt: null,
    sortTimestamp: "2026-10-16T12:00:00.000Z",
    roomPts: pts,
    msgPts: pts,
    lastHistoryEditPts: 0,
    lastMessage: null,
    eventType: "message_new",
    actionTimestamp: "2026-10-16T12:00:00.000Z",
  };
}

test("compact sequence receipts omit hydrated content while legacy and content events retain it", async (context) => {
  const config = configuration(false);
  config.set("RECEIPT_PUSH_MODE", "compact");
  const sent: { channel: string; data: unknown }[] = [];
  context.mock.method(
    globalThis,
    "fetch",
    async (_input: Parameters<typeof fetch>[0], init?: RequestInit) => {
      sent.push(JSON.parse(init!.body as string));
      return Response.json({ result: {} });
    },
  );
  const provider = new CentrifugoService(
    config,
    new DebugTrafficLogger(config),
  );
  const full = {
    ...room(15),
    eventType: "room_peer_seen" as const,
    contentPts: 12,
    peerDeliveredSeq: 9,
    peerSeenSeq: 7,
  };
  await provider.publish("recipient", "epoch", {
    ...full,
    sequenceReceipt: true,
  });
  assert.deepEqual(sent[0].data, {
    pts: 15,
    epoch: "epoch",
    receipt: {
      roomId: full.roomId,
      eventType: "room_peer_seen",
      contentPts: 12,
      peerDeliveredSeq: 9,
      peerSeenSeq: 7,
    },
  });
  await provider.publish("recipient", "epoch", full);
  assert.deepEqual(sent[1].data, { pts: 15, epoch: "epoch", room: full });
  config.set("RECEIPT_PUSH_MODE", "legacy");
  await provider.publish("recipient", "epoch", {
    ...full,
    sequenceReceipt: true,
  });
  assert.deepEqual(sent[2].data, {
    pts: 15,
    epoch: "epoch",
    room: { ...full, sequenceReceipt: true },
  });
});

test("compact unread publications carry only account badge and own checkpoints for direct and group rooms", async (context) => {
  const config = configuration(false);
  const sent: { channel: string; data: unknown }[] = [];
  context.mock.method(
    globalThis,
    "fetch",
    async (_input: Parameters<typeof fetch>[0], init?: RequestInit) => {
      sent.push(JSON.parse(init!.body as string));
      return Response.json({ result: {} });
    },
  );
  const provider = new CentrifugoService(
    config,
    new DebugTrafficLogger(config),
  );
  for (const roomType of ["direct", "group"] as const) {
    const full: HydratedRoomPayload = {
      ...room(15),
      roomType,
      eventType: "room_unread_cleared",
      unreadCount: 2,
      ownDeliveredSeq: 9,
      ownSeenSeq: 7,
      contentPts: 11,
      msgPts: 12,
    };
    config.set("RECEIPT_PUSH_MODE", "compact");
    await provider.publish("reader", "epoch", full);
    assert.deepEqual(sent.at(-1), {
      channel: "inbox:user#reader",
      data: {
        pts: 15,
        epoch: "epoch",
        unread: {
          eventType: "room_unread_cleared",
          roomId: full.roomId,
          unreadCount: 2,
          ownDeliveredSeq: 9,
          ownSeenSeq: 7,
        },
      },
    });
    config.set("RECEIPT_PUSH_MODE", "legacy");
    await provider.publish("reader", "epoch", full);
    assert.deepEqual(sent.at(-1)!.data, {
      pts: 15,
      epoch: "epoch",
      room: full,
    });
  }
});

test("recursive snapshots redact credential keys and bearer/URL tokens without modifying business data", () => {
  const value = {
    userId: "business-user-id",
    idempotencyKey: "business-uuid",
    text: "Full business text",
    imageUrl: "/public/uploads/photo.png?size=100&access_token=private-query",
    nested: [
      {
        "X_API-Key": "private-key",
        passwordHash: "private-hash",
        setCookie: ["private-cookie"],
        private_key: "private-signing-key",
      },
    ],
    bearerText: "Provider rejected Bearer private-bearer",
    bytes: Buffer.from("private-binary-data"),
    createdAt: new Date("2026-10-16T12:00:00.000Z"),
  };
  const safe = sanitizeTrafficValue(value) as Record<string, unknown>;
  assert.equal(safe.userId, value.userId);
  assert.equal(safe.idempotencyKey, value.idempotencyKey);
  assert.equal(safe.text, value.text);
  assert.equal(
    safe.imageUrl,
    "/public/uploads/photo.png?size=100&access_token=[REDACTED]",
  );
  assert.deepEqual(safe.nested, [
    {
      "X_API-Key": "[REDACTED]",
      passwordHash: "[REDACTED]",
      setCookie: "[REDACTED]",
      private_key: "[REDACTED]",
    },
  ]);
  assert.equal(safe.bearerText, "Provider rejected [REDACTED]");
  assert.deepEqual(safe.bytes, { kind: "binary", byteLength: 19 });
  assert.equal(safe.createdAt, "2026-10-16T12:00:00.000Z");
  assert.equal(value.nested[0]["X_API-Key"], "private-key");
  assert.equal(JSON.stringify(safe).includes("private-"), false);
  const circular: { text: string; nested?: unknown } = { text: "retained" };
  circular.nested = circular;
  assert.deepEqual(sanitizeTrafficValue(circular), {
    text: "retained",
    nested: "[Circular]",
  });
});

test("traffic switches are independent and update through configuration without replacing the sink", () => {
  const config = configuration(false);
  const logger = new DebugTrafficLogger(config);
  assert.equal(logger.httpEnabled, false);
  assert.equal(logger.debugEnabled, false);
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  assert.equal(logger.debugEnabled, true);
  assert.equal(logger.httpEnabled, false);
  config.set("HTTP_LOGGING_ENABLED", "true");
  assert.equal(logger.httpEnabled, true);
});

test("encoded JSON strings and URL userinfo cannot bypass credential redaction", () => {
  const ordinary =
    '  { "text": "Preserve business formatting", "id": "123" }  ';
  const nested = JSON.stringify({
    note: JSON.stringify({ password: "encoded-password", value: "retained" }),
  });
  const value = {
    metadata:
      '{"password":"private-password","nested":[{"api_key":"private-key"}]}',
    doublyEncoded: JSON.stringify(nested),
    target:
      "https://private-user:private-password@example.test/photo.png?width=400",
    repeatedAt:
      "https://private-user:private-password@realm@example.test/photo.png",
    businessUrl: "https://example.test?email=name@example.test#contact@team",
    ordinary,
  };
  const safe = sanitizeTrafficValue(value) as Record<string, string>;
  assert.deepEqual(JSON.parse(safe.metadata), {
    password: "[REDACTED]",
    nested: [{ api_key: "[REDACTED]" }],
  });
  const decoded = JSON.parse(JSON.parse(safe.doublyEncoded)) as {
    note: string;
  };
  assert.deepEqual(JSON.parse(decoded.note), {
    password: "[REDACTED]",
    value: "retained",
  });
  assert.equal(
    safe.target,
    "https://[REDACTED]@example.test/photo.png?width=400",
  );
  assert.equal(safe.repeatedAt, "https://[REDACTED]@example.test/photo.png");
  assert.equal(safe.businessUrl, value.businessUrl);
  assert.equal(safe.ordinary, ordinary);
  for (const secret of [
    "private-password",
    "private-key",
    "private-user",
    "encoded-password",
  ]) {
    assert.equal(JSON.stringify(safe).includes(secret), false);
  }
});

test("disabled realtime logging performs no context lookup or debug emission", async (context) => {
  const config = configuration(false);
  const logger = new DebugTrafficLogger(config);
  logger.identity = () => {
    throw new Error("Disabled debug must not capture context");
  };
  let written = false;
  logger.writer = () => {
    written = true;
  };
  const requests: { channel: string; data: unknown }[] = [];
  context.mock.method(
    globalThis,
    "fetch",
    async (_input: Parameters<typeof fetch>[0], init?: RequestInit) => {
      requests.push(JSON.parse(init!.body as string));
      return Response.json({ result: {} });
    },
  );
  assert.equal(
    await new CentrifugoService(config, logger).publish(
      "recipient",
      "epoch",
      room(3),
    ),
    true,
  );
  assert.equal(written, false);
  assert.deepEqual(requests, [
    {
      channel: "inbox:user#recipient",
      data: { pts: 3, epoch: "epoch", room: room(3) },
    },
  ]);
});

test("concurrent publication retries keep their actor, recipient, original HTTP ID and exact wire data", async (context) => {
  const config = configuration();
  const logger = new DebugTrafficLogger(config);
  const service = new CentrifugoService(config, logger);
  const records: TrafficLogRecord[] = [];
  logger.writer = (record) => {
    records.push(record);
  };
  const attempts = new Map<string, number>();
  const bodies = new Map<string, unknown>();
  context.mock.method(
    globalThis,
    "fetch",
    async (_input: Parameters<typeof fetch>[0], init?: RequestInit) => {
      const body = JSON.parse(init!.body as string) as {
        channel: string;
        data: unknown;
      };
      assert.equal(
        (init!.headers as Record<string, string>)["X-API-Key"],
        "private-provider-api-key",
      );
      const attempt = (attempts.get(body.channel) ?? 0) + 1;
      attempts.set(body.channel, attempt);
      bodies.set(body.channel, body.data);
      return attempt === 1
        ? Response.json(
            {
              error: {
                message: "Retry this advisory event",
                apiKey: "private-provider-api-key",
              },
            },
            { status: 503 },
          )
        : Response.json({
            result: {},
            credentials: "private-provider-credential",
          });
    },
  );
  await Promise.all(
    [1, 2].map((number) => {
      let actor = `actor-${number}`;
      return logger.runWithRequest(
        { requestId: `http-${number}`, getUserId: () => actor },
        async () => {
          const publishing = service.publish(
            `recipient-${number}`,
            `epoch-${number}`,
            room(number),
          );
          actor = "changed-after-publication-started";
          assert.equal(await publishing, true);
        },
      );
    }),
  );
  assert.equal(records.length, 4);
  for (const number of [1, 2]) {
    const related = records.filter(
      (record) => record.recipientUserId === `recipient-${number}`,
    );
    assert.equal(related.length, 2);
    assert.deepEqual(
      related.map((record) => record.attempt),
      [1, 2],
    );
    assert.deepEqual(
      related.map((record) => record.result),
      ["failure", "success"],
    );
    assert.equal(
      new Set(related.map((record) => record.publicationId)).size,
      1,
    );
    assert.match(related[0].publicationId as string, /^[a-f0-9-]{36}$/);
    for (const record of related) {
      assert.equal(record.event, "realtime_publication");
      assert.equal(record.direction, "publish");
      assert.equal(record.userId, `actor-${number}`);
      assert.equal(record.actorUserId, `actor-${number}`);
      assert.equal(record.requestId, `http-${number}`);
      assert.equal(record.channel, `inbox:user#recipient-${number}`);
      assert.equal(record.pts, number);
      assert.equal(record.eventType, "message_new");
      assert.equal(typeof record.durationMs, "number");
      assert.ok((record.durationMs as number) >= 0);
      assert.ok(Number.isFinite(Date.parse(record.timestamp)));
      assert.deepEqual(record.data, bodies.get(record.channel as string));
    }
  }
  assert.equal(new Set(records.map((record) => record.publicationId)).size, 2);
  assert.equal(JSON.stringify(records).includes("private-provider"), false);
});

test("a throwing debug writer cannot change publication success or exhausted retry results", async (context) => {
  const config = configuration();
  const logger = new DebugTrafficLogger(config);
  logger.writer = () => {
    throw new Error("Synthetic log writer failure");
  };
  const service = new CentrifugoService(config, logger);
  (service as unknown as { logger: { warn: () => void } }).logger = {
    warn: () => {},
  };
  let calls = 0;
  let fail = false;
  context.mock.method(globalThis, "fetch", async () => {
    calls++;
    return fail
      ? Response.json({ error: { code: 100 } })
      : Response.json({ result: {} });
  });
  assert.equal(await service.publish("recipient", "epoch", room(1)), true);
  assert.equal(calls, 1);
  fail = true;
  assert.equal(await service.publish("recipient", "epoch", room(2)), false);
  assert.equal(calls, 4);
});
