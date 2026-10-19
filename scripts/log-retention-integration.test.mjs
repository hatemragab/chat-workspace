import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  realpath,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { startLocalLogs } from "./local-logs.mjs";
import { vectorPaths, verifiedVector } from "./vector-tool.mjs";
import { patchedVectorPaths } from "./vector-source-build.mjs";

const workspace = fileURLToPath(new URL("../", import.meta.url));
const installed = vectorPaths(workspace);
const patched = patchedVectorPaths(workspace);
const available = [
  installed.binary,
  installed.archive,
  installed.manifest,
  patched.binary,
  patched.archive,
  patched.manifest,
].every(existsSync);

async function copyVerifiedVector(root) {
  await verifiedVector(workspace);
  const copied = vectorPaths(root),
    nextPatched = patchedVectorPaths(root);
  for (const [original, target, mode] of [
    [installed.binary, copied.binary, 0o700],
    [installed.archive, copied.archive, 0o600],
    [installed.manifest, copied.manifest, 0o600],
    [patched.binary, nextPatched.binary, 0o700],
    [patched.archive, nextPatched.archive, 0o600],
    [patched.manifest, nextPatched.manifest, 0o600],
  ]) {
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    await copyFile(original, target);
    await chmod(target, mode);
    assert.equal((await lstat(target)).nlink, 1);
  }
}

async function captureRecords(file) {
  const archives = join(dirname(file), "archives");
  const files = [file];
  for (const name of await readdir(archives).catch((error) => {
    if (error.code === "ENOENT") return [];
    throw error;
  }))
    if (/^events\.\d{8}T\d{9}Z-[a-f0-9]{8}\.jsonl$/.test(name))
      files.push(join(archives, name));
  const records = [];
  for (const path of files) {
    const text = await readFile(path, "utf8");
    for (const line of text.split("\n").filter(Boolean)) {
      try {
        records.push(JSON.parse(line));
      } catch {
        /* A running sink may have an unfinished last line. */
      }
    }
  }
  return records;
}

async function until(predicate, failure, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await predicate();
    if (result) return result;
    await delay(40);
  }
  assert.fail(failure);
}

function event(seq) {
  return {
    source: "flutter",
    event: "flutter_inspector",
    level: "info",
    timestamp: new Date().toISOString(),
    seq,
    category: "retention_test",
    name: `synthetic.retention.${seq}`,
    phase: "instant",
    traceId: "synthetic-retention-trace",
    sessionGeneration: 1,
    data: { operation: "synthetic", count: seq },
  };
}

test(
  "installed Vector drains rotated input archives exactly once and restarts only its sink writer during capture rotation",
  { skip: !available, timeout: 40000 },
  async (t) => {
    const root = await mkdtemp(
      join(await realpath(tmpdir()), "chat-retention-vector-test-"),
    );
    let runtime;
    t.after(async () => {
      await runtime?.close();
      await rm(root, { recursive: true, force: true });
    });
    await copyVerifiedVector(root);
    runtime = await startLocalLogs({
      root,
      port: 0,
      nativeFiles: {},
      captureId: "synthetic-retention-capture",
      retention: {
        maxBytes: 1200,
        maxArchives: 20,
        maxAgeMs: 7 * 86400000,
        rotateAfterMs: 86400000,
      },
      retentionIntervalMs: 60000,
    });
    const healthUrl = new URL("/health", runtime.url);
    const initialHealth = await (await fetch(healthUrl)).json();
    assert.equal(initialHealth.captureId, "synthetic-retention-capture");
    async function send(sequences) {
      const response = await fetch(runtime.url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          instanceId: "synthetic-retention-tab",
          events: sequences.map(event),
        }),
      });
      assert.equal(response.status, 202);
      assert.equal((await response.json()).accepted, sequences.length);
    }
    for (let seq = 1; seq <= 16; seq += 2) await send([seq, seq + 1]);
    const expected = Array.from({ length: 16 }, (_, index) => index + 1);
    await until(async () => {
      const records = await captureRecords(runtime.paths.events);
      return expected.every((seq) =>
        records.some((record) => record.seq === seq),
      );
    }, "Rotated owner inputs must all reach the unified sink before rotation.");
    const inputArchives = (
      await readdir(join(runtime.paths.inputs, "archives"))
    ).filter((name) => name.startsWith("flutter.") && name.endsWith(".jsonl"));
    assert.ok(
      inputArchives.length >= 2,
      "The fixture must exercise multiple owner input rotations before tail discovery.",
    );
    const previous = runtime.child;
    const rotation = runtime.maintain();
    // The browser endpoint must keep accepting while Vector flushes and restarts.
    await send([17]);
    await rotation;
    assert.notEqual(runtime.child.pid, previous.pid);
    assert.equal(previous.exitCode, 0);
    assert.equal(runtime.child.exitCode, null);
    process.kill(runtime.child.pid, 0);
    const archiveFiles = (
      await readdir(join(runtime.paths.directory, "archives"))
    ).filter((name) => name.startsWith("events.") && name.endsWith(".jsonl"));
    assert.equal(archiveFiles.length, 1);
    const archivedRecords = (
      await readFile(
        join(runtime.paths.directory, "archives", archiveFiles[0]),
        "utf8",
      )
    )
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    assert.ok(
      expected.every((seq) =>
        archivedRecords.some((record) => record.seq === seq),
      ),
      "Graceful Vector shutdown must leave a complete old sink archive.",
    );
    assert.equal((await lstat(runtime.paths.events)).mode & 0o777, 0o600);
    await send([18]);
    await until(async () => {
      const records = await captureRecords(runtime.paths.events);
      return (
        records.some((record) => record.seq === 17) &&
        records.some((record) => record.seq === 18)
      );
    }, "Fresh Vector must ingest activity accepted during and after rotation.");
    await send([19, 20]);
    await until(async () => {
      const records = await captureRecords(runtime.paths.events);
      return records.some((record) => record.seq === 20);
    }, "The second rotation must include additional confirmed sink writes.");
    const restarted = runtime.child;
    assert.ok((await lstat(runtime.paths.events)).size >= 1200);
    await runtime.maintain();
    assert.notEqual(runtime.child.pid, restarted.pid);
    assert.equal(restarted.exitCode, 0);
    // A further checkpointed restart must not replay owner archives already drained.
    await send([21, 22]);
    await until(async () => {
      const records = await captureRecords(runtime.paths.events);
      return records.some((record) => record.seq === 22);
    }, "The capture must continue after subsequent maintenance.");
    await delay(300);
    const records = await captureRecords(runtime.paths.events);
    assert.deepEqual(
      records.map((record) => record.seq).sort((a, b) => a - b),
      Array.from({ length: 22 }, (_, index) => index + 1),
    );
    assert.ok(
      records.every(
        (record) => record.captureId === "synthetic-retention-capture",
      ),
    );
    assert.equal(runtime.child.exitCode, null);
    const finalHealth = await (await fetch(healthUrl)).json();
    assert.equal(finalHealth.captureId, initialHealth.captureId);
    assert.equal(finalHealth.acceptedEvents, 22);
    assert.equal(finalHealth.failedBatches, 0);
    assert.equal(finalHealth.rejectedBatches, 0);
    process.kill(runtime.child.pid, 0);
  },
);

test(
  "owned native Centrifugo rotation drains every archive before checkpoint-aware expiry",
  { skip: !available, timeout: 40000 },
  async (t) => {
    const root = await mkdtemp(
      join(await realpath(tmpdir()), "chat-native-retention-vector-"),
    );
    let runtime, writer;
    t.after(async () => {
      await writer?.close();
      await runtime?.close();
      await rm(root, { recursive: true, force: true });
    });
    await copyVerifiedVector(root);
    const { createPrivateProcessLog } =
      await import("./private-process-log.mjs");
    const native = join(
      root,
      ".runtime/observability/inputs/centrifugo-server.log",
    );
    writer = await createPrivateProcessLog(native, {
      input: true,
      policy: {
        maxBytes: 600,
        maxArchives: 20,
        maxAgeMs: 86400000,
        rotateAfterMs: 86400000,
      },
    });
    runtime = await startLocalLogs({
      root,
      port: 0,
      nativeFiles: { centrifugo: native },
      retention: {
        maxBytes: 2000,
        maxArchives: 20,
        maxAgeMs: 86400000,
        rotateAfterMs: 86400000,
      },
      retentionIntervalMs: 60000,
    });
    for (let i = 0; i < 20; i++)
      writer.append(
        JSON.stringify({
          level: "info",
          time: new Date().toISOString(),
          message: `NativeRetentionFixture-${i}-${"safe-padding".repeat(20)}`,
        }) + "\n",
      );
    await writer.close();
    writer = undefined;
    await until(async () => {
      const rows = await captureRecords(runtime.paths.events);
      const observed = rows.filter(
        (row) =>
          row.source === "centrifugo" &&
          row.data?.message?.startsWith("NativeRetentionFixture-"),
      );
      return new Set(observed.map((row) => row.data.message)).size === 20;
    }, "All owned native records must survive rotation into the unified stream");
    await runtime.maintain();
    const health = await (await fetch(new URL("/health", runtime.url))).json();
    assert.ok(health.retention.inputs.native_centrifugo);
    assert.equal(
      health.retention.inputs.native_centrifugo.unconsumedArchives,
      0,
    );
  },
);
