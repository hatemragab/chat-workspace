import "reflect-metadata";
import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer } from "node:http";
import { once } from "node:events";
import { ConfigService } from "@nestjs/config";
import { DebugTrafficLogger } from "../src/infrastructure/debug-traffic-logger";
import { CentrifugoService } from "../src/infrastructure/centrifugo.service";

test("presence snapshots batch exact personal inboxes and count all connected devices", async (t) => {
  let calls = 0;
  let response: unknown = {
    replies: [
      { presence_stats: { num_clients: 2, num_users: 1 } },
      { presence_stats: { num_clients: 0, num_users: 0 } },
    ],
  };
  const server = createServer(async (req, res) => {
    calls++;
    let body = "";
    for await (const chunk of req) body += chunk;
    assert.equal(req.url, "/api/batch");
    assert.equal(req.headers["x-api-key"], "synthetic-test-key");
    assert.deepEqual(JSON.parse(body), {
      commands: [
        { presence_stats: { channel: "inbox:user#alice" } },
        { presence_stats: { channel: "inbox:user#bob" } },
      ],
    });
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify(response));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const port = (server.address() as { port: number }).port;
  const config = new ConfigService({
    CENTRIFUGO_API_URL: `http://127.0.0.1:${port}/api`,
    CENTRIFUGO_API_KEY: "synthetic-test-key",
    TRAFFIC_LOG_FILE: "off",
  });
  const service = new CentrifugoService(config, new DebugTrafficLogger(config));
  assert.deepEqual(await service.presenceStatuses([]), {});
  await assert.rejects(
    service.presenceStatuses(Array.from({ length: 101 }, (_, i) => String(i))),
  );
  assert.equal(calls, 0);
  assert.deepEqual(await service.presenceStatuses(["alice", "bob", "alice"]), {
    alice: true,
    bob: false,
  });
  // Never interpret a provider failure, partial batch or malformed counter as offline.
  for (response of [
    { error: { code: 100 } },
    {},
    { replies: [] },
    {
      replies: [
        { error: { code: 100 } },
        { presence_stats: { num_clients: 0, num_users: 0 } },
      ],
    },
    { replies: [{ presence_stats: { num_clients: -1, num_users: 0 } }, {}] },
    { replies: [{ presence_stats: { num_clients: "1", num_users: 1 } }, {}] },
  ])
    await assert.rejects(service.presenceStatuses(["alice", "bob"]));
});

test("logout retains retries when disconnect is accepted but the selected socket remains or presence is malformed", async (t) => {
  const config = new ConfigService({
    CENTRIFUGO_API_URL: "http://synthetic-provider.test/api",
    CENTRIFUGO_API_KEY: "synthetic-key",
    TRAFFIC_LOG_FILE: "off",
  });
  const service = new CentrifugoService(config, new DebugTrafficLogger(config));
  let presence: unknown = {
    presence: {
      "still-connected": {
        user: "alice",
        conn_info: { sessionId: "synthetic-session" },
      },
    },
  };
  t.mock.method(globalThis, "fetch", async (url: unknown) =>
    Response.json({
      result: String(url).endsWith("/presence") ? presence : {},
    }),
  );
  assert.equal(
    await service.disconnectSession("alice", "synthetic-session"),
    false,
  );
  presence = {};
  assert.equal(
    await service.disconnectSession("alice", "synthetic-session"),
    false,
  );
  presence = { presence: {} };
  assert.equal(
    await service.disconnectSession("alice", "synthetic-session"),
    true,
  );
});
