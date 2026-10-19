import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { debugBackendLaunch } from "./backend-debug.mjs";

test("development and debug commands both use the logging launcher", async () => {
  const manifest = JSON.parse(
    await readFile(new URL("../backend/package.json", import.meta.url), "utf8"),
  );
  assert.equal(
    manifest.scripts["start:dev"],
    "node ../scripts/backend-debug.mjs",
  );
  assert.equal(manifest.scripts["start:debug"], manifest.scripts["start:dev"]);
  assert.equal(manifest.scripts.start, "node dist/main.js");
});

test("manual debug command uses existing backend runtime and private default capture", () => {
  const launch = debugBackendLaunch("/work/project with spaces", {
    PATH: "/bin",
  });
  assert.equal(launch.command, process.execPath);
  assert.deepEqual(launch.args, [
    "/work/project with spaces/backend/node_modules/ts-node/dist/bin.js",
    "src/main.ts",
  ]);
  assert.equal(launch.options.cwd, "/work/project with spaces/backend");
  assert.equal(
    launch.options.env.TRAFFIC_LOG_FILE,
    "/work/project with spaces/.runtime/backend-logs/traffic.jsonl",
  );
  assert.equal(launch.options.env.TRAFFIC_LOG_FORMAT, "pretty");
  assert.equal(launch.options.env.DEBUG_TRAFFIC_LOGGING_ENABLED, "true");
  assert.equal(launch.options.env.HTTP_LOGGING_ENABLED, "true");
  assert.equal(
    launch.options.env.LOCAL_SERVICE_LOG_FILE,
    "/work/project with spaces/.runtime/observability/inputs/services.jsonl",
  );
  assert.equal(launch.options.stdio, "inherit");
});

test("explicit logger choices remain authoritative without mutating inherited settings", () => {
  const original = {
    TRAFFIC_LOG_FILE: "off",
    TRAFFIC_LOG_FORMAT: "json",
    HTTP_LOGGING_ENABLED: "false",
    DEBUG_TRAFFIC_LOGGING_ENABLED: "false",
    PORT: "3010",
    LOCAL_SERVICE_LOG_FILE: "off",
  };
  const launch = debugBackendLaunch("/project", original);
  assert.deepEqual(launch.options.env, original);
  assert.notEqual(launch.options.env, original);
});

test("backend env logging settings precede defaults while shell values take priority", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "backend-debug-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, "backend"));
  await writeFile(
    join(root, "backend", ".env"),
    "TRAFFIC_LOG_FILE=off\nTRAFFIC_LOG_FORMAT=json\nHTTP_LOGGING_ENABLED=false\nDEBUG_TRAFFIC_LOGGING_ENABLED=false\nUNRELATED_PRIVATE_SETTING=local-fixture\n",
  );
  const launch = debugBackendLaunch(root, { TRAFFIC_LOG_FORMAT: "silent" });
  assert.equal(launch.options.env.TRAFFIC_LOG_FILE, "off");
  assert.equal(launch.options.env.TRAFFIC_LOG_FORMAT, "silent");
  assert.equal(launch.options.env.HTTP_LOGGING_ENABLED, "false");
  assert.equal(launch.options.env.DEBUG_TRAFFIC_LOGGING_ENABLED, "false");
  assert.equal(launch.options.env.UNRELATED_PRIVATE_SETTING, undefined);
});
