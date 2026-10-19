import "reflect-metadata";
import assert from "node:assert/strict";
import { test } from "node:test";
import { ConfigService } from "@nestjs/config";
import { JwtService } from "@nestjs/jwt";
import { RealtimeProxyController } from "../src/auth/realtime-proxy.controller";
import { Command } from "ioredis";
import { redisCommandDetails } from "../src/infrastructure/redis-command-details";
import * as scripts from "../src/infrastructure/session-disconnect-scripts";

const secret = "synthetic-realtime-key-for-unit-tests-only";
const proxyKey = "synthetic-proxy-key-for-unit-tests-only";
const userId = "507f1f77bcf86cd799439011";
const sessionId = "a".repeat(64);
const jwt = new JwtService();
const config = new ConfigService({
  CENTRIFUGO_TOKEN_HMAC_SECRET_KEY: secret,
  CENTRIFUGO_PROXY_SECRET: proxyKey,
});
const request = { socket: { remoteAddress: "127.0.0.1" } } as never;

test("connect grants the actual login expiry, independent of the obsolete refresh interval", async () => {
  config.set("REALTIME_REFRESH_SECONDS", 1);
  const sessionExpiresAt = Math.floor(Date.now() / 1000) + 86400;
  const token = jwt.sign(
    {
      sub: userId,
      channels: [`inbox:user#${userId}`],
      meta: { sessionId, sessionExpiresAt },
    },
    {
      secret,
      algorithm: "HS256",
      issuer: "chat-api",
      audience: "chat-realtime",
      expiresIn: 1800,
    },
  );
  const controller = new RealtimeProxyController(
    config,
    jwt,
    { isSessionRetired: async () => false } as never,
    { users: { exists: async () => true } } as never,
    { track: async () => undefined } as never,
  );
  const response = await controller.connect(
    { data: { token } },
    request,
    proxyKey,
  );
  assert.equal(response.result?.expire_at, sessionExpiresAt);
  assert.deepEqual(response.result?.channels, [`inbox:user#${userId}`]);
});

test("the compatibility refresh callback fails closed and keeps proxy authentication", async () => {
  const controller = new RealtimeProxyController(
    config,
    jwt,
    {} as never,
    {} as never,
    {} as never,
  );
  assert.deepEqual(await controller.refresh({}, request, proxyKey), {
    result: { expired: true },
  });
  await assert.rejects(controller.refresh({}, request, "wrong-key"), {
    status: 403,
  });
  await assert.rejects(
    controller.refresh(
      {},
      { socket: { remoteAddress: "192.0.2.1" } } as never,
      proxyKey,
    ),
    { status: 403 },
  );
});

test("authentication queue diagnostics omit session keys, lease tokens and members", () => {
  for (const source of Object.values(scripts)) {
    const details = redisCommandDetails(
      new Command("eval", [
        source,
        "1",
        `private-session-key:${sessionId}`,
        "private-lease-token",
      ]),
    );
    assert.equal(details.includeResponse, false);
    assert.match(JSON.stringify(details), /auth_session\./);
    assert.doesNotMatch(
      JSON.stringify(details),
      /private-session-key|private-lease-token|aaaaaaaa/,
    );
  }
});
