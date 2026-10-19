import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { Readable } from "node:stream";
import { localEnvironment, nativeEnvironment } from "./centrifugo-local.mjs";
import {
  centrifugoLogFilter,
  sanitizeCentrifugoLog,
} from "./centrifugo-log.mjs";

test("all configuration keys exist in the installed v6.9.7 schema", () => {
  const env = localEnvironment();
  const result = spawnSync(
    env.CENTRIFUGO_BIN ?? "centrifugo",
    ["defaultconfig", "--dry-run"],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0);
  const defaults = JSON.parse(result.stdout),
    config = JSON.parse(
      readFileSync(new URL("../centrifugo/config.json", import.meta.url)),
    );
  function check(value, schema, path = "") {
    for (const [key, child] of Object.entries(value)) {
      if (path === "channel.namespaces" && key === "name") continue;
      assert.ok(Object.hasOwn(schema, key), `Unknown option ${path}.${key}`);
      if (key === "namespaces") {
        for (const namespace of child)
          check(
            namespace,
            defaults.channel.without_namespace,
            "channel.namespaces",
          );
      } else if (
        child &&
        typeof child === "object" &&
        !Array.isArray(child) &&
        key !== "static_headers"
      )
        check(child, schema[key], path ? `${path}.${key}` : key);
    }
  }
  check(config, defaults);
  assert.equal(config.channel.namespaces[0].history_size, 0);
  assert.equal(config.channel.namespaces[0].allow_user_limited_channels, false);
  assert.equal(config.channel.namespaces[0].presence, true);
  assert.equal(config.client.proxy.refresh.enabled, false);
});

test("launcher prevents direct JWT and insecure admin bypasses and keeps diagnostics on loopback", () => {
  const env = localEnvironment({
    CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY: "unsafe",
    CENTRIFUGO_ADMIN_INSECURE: "true",
    CENTRIFUGO_HTTP_SERVER_INTERNAL_ADDRESS: "0.0.0.0",
    CENTRIFUGO_HTTP_SERVER_ADDRESS: "192.168.1.10",
    CENTRIFUGO_CLIENT_USER_CONNECTION_LIMIT: "12",
    CENTRIFUGO_CLIENT_PROXY_REFRESH_ENABLED: "true",
  });
  assert.equal(env.CENTRIFUGO_CLIENT_TOKEN_HMAC_SECRET_KEY, undefined);
  assert.equal(env.CENTRIFUGO_ADMIN_INSECURE, "false");
  assert.equal(env.CENTRIFUGO_HTTP_SERVER_INTERNAL_ADDRESS, "127.0.0.1");
  assert.equal(env.CENTRIFUGO_HTTP_SERVER_ADDRESS, "192.168.1.10");
  assert.equal(env.CENTRIFUGO_CLIENT_USER_CONNECTION_LIMIT, "12");
  assert.equal(env.CENTRIFUGO_CLIENT_PROXY_REFRESH_ENABLED, "false");
});

test("native child omits only launcher aliases and preserves mapped effective settings", () => {
  const aliases = {
    CENTRIFUGO_API_KEY: "fixture-api-key-".repeat(4),
    CENTRIFUGO_API_URL: "http://127.0.0.1:9000/api",
    CENTRIFUGO_BIN: "/fixture/centrifugo",
    CENTRIFUGO_PROXY_SECRET: "fixture-proxy-secret-".repeat(4),
    CENTRIFUGO_TOKEN_HMAC_SECRET_KEY: "fixture-backend-hmac-".repeat(4),
  };
  const parent = localEnvironment({
    ...aliases,
    CENTRIFUGO_ENGINE_REDIS_ADDRESS: "redis://127.0.0.1:6379",
    CENTRIFUGO_CLIENT_USER_CONNECTION_LIMIT: "12",
    CENTRIFUGO_HTTP_SERVER_ADDRESS: "127.0.0.1",
    CENTRIFUGO_LOG_LEVEL: "debug",
  });
  const native = nativeEnvironment(parent);
  for (const key of Object.keys(aliases)) {
    assert.equal(Object.hasOwn(native, key), false, key);
    assert.equal(Object.hasOwn(parent, key), true, key);
  }
  assert.deepEqual(
    Object.keys(native).sort(),
    Object.keys(parent)
      .filter((key) => !Object.hasOwn(aliases, key))
      .sort(),
  );
  for (const [key, value] of Object.entries(native))
    assert.ok(value === parent[key], `Native setting changed: ${key}`);
  assert.equal(native.CENTRIFUGO_HTTP_API_KEY, aliases.CENTRIFUGO_API_KEY);
  assert.equal(
    native.CENTRIFUGO_VAR_PROXY_SECRET,
    aliases.CENTRIFUGO_PROXY_SECRET,
  );
});

test("native protobuf commands and trace payloads are redacted before every sink", async () => {
  const jwt = "eyJheader.eyJpayload.signature";
  const raw = {
    level: "debug",
    command: `connect token: ${jwt} data: secret-message`,
    data: { text: "private message" },
    reason: `bad token ${jwt}`,
    message: "connection closed",
    nested: { password: "hidden" },
    service: "redis://name:password@localhost:6379",
    error: "dedicated-secret",
  };
  const value = sanitizeCentrifugoLog(JSON.stringify(raw), [
    "dedicated-secret",
  ]);
  for (const forbidden of [
    jwt,
    "secret-message",
    "private message",
    "dedicated-secret",
    "name:password",
    "hidden",
  ])
    assert.equal(value.includes(forbidden), false);
  assert.equal(JSON.parse(value).message, "connection closed");
  const filter = centrifugoLogFilter(["dedicated-secret"]);
  let output = "";
  filter.on("data", (chunk) => (output += chunk));
  await new Promise((resolve, reject) => {
    filter.on("end", resolve);
    filter.on("error", reject);
    Readable.from([
      JSON.stringify(raw).slice(0, 40),
      JSON.stringify(raw).slice(40) + "\n",
      "not-json\n",
      "x".repeat(1024 * 1024 + 1) + "\n",
    ]).pipe(filter);
  });
  const records = output.trim().split("\n").map(JSON.parse);
  assert.equal(records.length, 3);
  assert.equal(records[0].command, "[REDACTED]");
  assert.equal(
    records[1].message,
    "Unstructured Centrifugo diagnostic omitted",
  );
});

test("native server run IDs are fixed per launcher and do not weaken redaction", () => {
  const id = "11111111-2222-4333-8444-555555555555";
  const row = JSON.parse(
    sanitizeCentrifugoLog(
      JSON.stringify({
        message: "closed",
        error: "Bearer abcdef",
        client: "client-one",
      }),
      ["abcdef"],
      id,
    ),
  );
  assert.equal(row.serverRunId, id);
  assert.equal(JSON.stringify(row).includes("abcdef"), false);
});
