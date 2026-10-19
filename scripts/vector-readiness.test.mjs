import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import {
  appendFile,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { childEnvironment } from "./backend-logs.mjs";
import { localLogPaths, vectorConfiguration } from "./local-logs.mjs";
import { patchedVectorPaths } from "./vector-source-build.mjs";
import { vectorPaths } from "./vector-tool.mjs";

const workspace = fileURLToPath(new URL("../", import.meta.url));
const upstream = vectorPaths(workspace).binary;
const patched = patchedVectorPaths(workspace).binary;
const padding = "metadata-only-padding-".repeat(20);

async function fixture(t, binary) {
  const root = await mkdtemp(
    join(await realpath(tmpdir()), "vector-readiness-"),
  );
  const paths = localLogPaths(root);
  const nativeFiles = {
    redis: join(root, "redis.log"),
    mongodb: join(root, "mongodb.log"),
    centrifugo: paths.native_centrifugo,
  };
  for (const directory of [paths.inputs, dirname(paths.backend), paths.state])
    await mkdir(directory, { recursive: true, mode: 0o700 });
  const entry = (source, marker) => ({
    timestamp: new Date().toISOString(),
    receivedAt: new Date().toISOString(),
    level: "error",
    source,
    event: marker,
    requestId: marker,
    padding,
  });
  for (const source of ["backend", "services", "flutter"])
    await writeFile(
      paths[source],
      JSON.stringify(
        entry(source === "services" ? "mongodb" : source, `initial_${source}`),
      ) + "\n",
      { mode: 0o600 },
    );
  for (const [source, file] of Object.entries(nativeFiles))
    await writeFile(
      file,
      JSON.stringify({
        time: new Date().toISOString(),
        level: "info",
        message: `initial_${source}`,
        padding,
      }) + "\n",
      { mode: 0o600 },
    );
  await writeFile(paths.events, "", { mode: 0o600 });
  const config = join(paths.directory, "fixture-config.json");
  await writeFile(
    config,
    JSON.stringify(
      vectorConfiguration(paths, {
        captureId: "idle-readiness-fixture",
        nativeFiles,
      }),
    ),
    { mode: 0o600 },
  );
  let current;
  const children = [];
  const start = () => {
    const mask = process.umask(0o077);
    try {
      current = spawn(binary, ["--config", config], {
        env: {
          ...childEnvironment(),
          VECTOR_LOG: "error",
          VECTOR_THREADS: "2",
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
    } finally {
      process.umask(mask);
    }
    const value = { child: current, diagnostics: "", exited: false };
    value.closed = new Promise((done) =>
      current.once("close", (code) => {
        value.exited = true;
        value.code = code;
        done();
      }),
    );
    current.once("error", (error) => {
      value.error = error;
    });
    for (const stream of [current.stdout, current.stderr])
      stream.on("data", (chunk) => {
        if (value.diagnostics.length < 65536)
          value.diagnostics += chunk.toString();
      });
    children.push(value);
    return value;
  };
  const stop = async (value) => {
    if (value.exited) return;
    value.child.kill("SIGTERM");
    const force = setTimeout(() => value.child.kill("SIGKILL"), 5000);
    force.unref();
    await value.closed;
    clearTimeout(force);
    assert.equal(value.code, 0, value.diagnostics);
  };
  t.after(async () => {
    try {
      for (const value of children) await stop(value);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
  const rows = async () =>
    (await readFile(paths.events, "utf8"))
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse);
  const until = async (predicate, timeoutMs = 13000) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const value = children.at(-1);
      assert.ok(!value?.exited && !value?.error, value?.diagnostics);
      const captured = await rows();
      if (predicate(captured)) return captured;
      await delay(20);
    }
    assert.fail(
      `Vector readiness fixture timed out: ${children.at(-1)?.diagnostics}`,
    );
  };
  const append = async (marker) => {
    const timestamp = new Date().toISOString();
    for (const source of ["backend", "services", "flutter"])
      await appendFile(
        paths[source],
        JSON.stringify({
          ...entry(
            source === "services" ? "mongodb" : source,
            `${marker}_${source}`,
          ),
          timestamp,
          receivedAt: timestamp,
        }) + "\n",
      );
    for (const [source, file] of Object.entries(nativeFiles))
      await appendFile(
        file,
        JSON.stringify({
          time: timestamp,
          level: "warn",
          message: `${marker}_${source}`,
          padding,
        }) + "\n",
      );
    return timestamp;
  };
  const matching = (values, marker) =>
    values.filter(
      (row) =>
        row.requestId?.startsWith(marker) ||
        row.data?.message?.startsWith(marker),
    );
  return { paths, start, stop, rows, until, append, matching };
}

test(
  "pinned upstream idle gate reproduces multi-second collection latency",
  { skip: !existsSync(upstream), timeout: 40000 },
  async (t) => {
    const f = await fixture(t, upstream);
    f.start();
    await f.until((values) =>
      values.some((row) => row.event === "initial_flutter"),
    );
    await delay(13000); // cross FileWatcher::should_read's hardcoded idle threshold
    const timestamp = await f.append("upstream_probe");
    const values = await f.until(
      (values) => f.matching(values, "upstream_probe").length === 6,
    );
    const lags = f
      .matching(values, "upstream_probe")
      .map((row) => Date.parse(row.collectedAt) - Date.parse(timestamp));
    t.diagnostic(
      `Pinned upstream idle collection lags(ms): ${JSON.stringify(lags)}`,
    );
    assert.ok(
      Math.max(...lags) > 2500,
      "The pinned upstream idle gate is actually exercised",
    );
  },
);

test(
  "patched Vector promptly collects all quiet source types and preserves checkpoint/restart/rotation records",
  { skip: !existsSync(patched), timeout: 40000 },
  async (t) => {
    const f = await fixture(t, patched);
    let child = f.start();
    await f.until((values) =>
      values.some((row) => row.event === "initial_flutter"),
    );
    await delay(13000);
    const timestamp = await f.append("patched_probe");
    let values = await f.until(
      (values) => f.matching(values, "patched_probe").length === 6,
      1800,
    );
    const lags = f
      .matching(values, "patched_probe")
      .map((row) => Date.parse(row.collectedAt) - Date.parse(timestamp));
    t.diagnostic(`Patched idle collection lags(ms): ${JSON.stringify(lags)}`);
    assert.ok(
      Math.max(...lags) < 1500,
      "All file input types collect promptly after idle",
    );
    await f.stop(child);
    await f.append("offline_probe");
    const archives = join(f.paths.inputs, "archives");
    await mkdir(archives, { mode: 0o700 });
    await rename(
      f.paths.flutter,
      join(archives, "flutter.20261017T130000000Z-12345678.jsonl"),
    );
    await writeFile(
      f.paths.flutter,
      JSON.stringify({
        timestamp: new Date().toISOString(),
        source: "flutter",
        level: "error",
        event: "rotation_probe",
        requestId: "rotation_probe",
        padding,
      }) + "\n",
      { mode: 0o600 },
    );
    child = f.start();
    values = await f.until(
      (values) =>
        f.matching(values, "offline_probe").length === 6 &&
        values.some((row) => row.requestId === "rotation_probe"),
      3000,
    );
    assert.equal(
      f.matching(values, "patched_probe").length,
      6,
      "Acknowledged records do not replay on graceful restart",
    );
    assert.equal(
      f.matching(values, "offline_probe").length,
      6,
      "All six source streams retain records written while stopped",
    );
    assert.equal(
      values.filter((row) => row.requestId === "rotation_probe").length,
      1,
      "Unread owned rotation is retained and the new active input is discovered",
    );
    await f.stop(child);
  },
);
