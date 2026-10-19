import assert from "node:assert/strict";
import { mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { captureHealth } from "./capture-health.mjs";

test("capture health separates browser transport from file collection and reports important sink loss safely", async (t) => {
  const root = await mkdtemp(join(await realpath(tmpdir()), "capture-health-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const paths = Object.fromEntries(
    ["backend", "services", "flutter", "native_centrifugo", "events"].map(
      (name) => [name, join(root, `${name}.jsonl`)],
    ),
  );
  for (const file of Object.values(paths))
    await writeFile(file, "", { mode: 0o600 });
  const timing = {
    timestamp: "2026-10-17T10:00:00.000Z",
    receivedAt: "2026-10-17T10:00:00.400Z",
    collectedAt: "2026-10-17T10:00:00.650Z",
  };
  await writeFile(
    paths.events,
    JSON.stringify({
      source: "flutter",
      ...timing,
      data: { password: "private" },
    }) + "\n",
  );
  await writeFile(
    `${paths.backend}.status.json`,
    JSON.stringify({
      importantPendingRecords: 1,
      importantWrittenRecords: 11,
      importantDroppedRecords: 2,
      importantFailedRecords: 3,
      evictedRecords: 4,
      retriedRecords: 5,
      uncertainRecords: 6,
      importantUncertainRecords: 7,
      privateData: "private",
      unsafe: -1,
    }),
  );
  const health = await captureHealth(paths);
  assert.equal(health.sources.flutter.collectionLagMs, 650);
  assert.equal(health.sources.flutter.producerToIngressMs, 400);
  assert.equal(health.sources.flutter.ingressToCollectionMs, 250);
  assert.deepEqual(health.inputs.backend.sink, {
    importantPendingRecords: 1,
    importantWrittenRecords: 11,
    importantDroppedRecords: 2,
    importantFailedRecords: 3,
    evictedRecords: 4,
    retriedRecords: 5,
    uncertainRecords: 6,
    importantUncertainRecords: 7,
  });
  assert.doesNotMatch(
    JSON.stringify(health),
    /privateData|password|private|unsafe/,
  );
});

test("missing or invalid ingress timestamps never fabricate per-stage timing", async (t) => {
  const root = await mkdtemp(join(await realpath(tmpdir()), "capture-health-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const paths = Object.fromEntries(
    ["backend", "services", "flutter", "native_centrifugo", "events"].map(
      (name) => [name, join(root, `${name}.jsonl`)],
    ),
  );
  for (const file of Object.values(paths))
    await writeFile(file, "", { mode: 0o600 });
  const row = {
    source: "flutter",
    timestamp: "2026-10-17T10:00:00Z",
    collectedAt: "2026-10-17T10:00:01Z",
    receivedAt: "invalid-private-text",
  };
  await writeFile(paths.events, JSON.stringify(row) + "\n");
  const health = await captureHealth(paths, {
    sources: {
      flutter: {
        lastEventAt: "2026-10-17T09:00:00Z",
        lastCollectedAt: "2026-10-17T09:00:01Z",
        producerToIngressMs: 800,
      },
    },
  });
  assert.equal(health.sources.flutter.collectionLagMs, 1000);
  assert.equal(health.sources.flutter.producerToIngressMs, undefined);
  assert.equal(health.sources.flutter.ingressToCollectionMs, undefined);
  assert.doesNotMatch(JSON.stringify(health), /invalid-private-text/);
});
