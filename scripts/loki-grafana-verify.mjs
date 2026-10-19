import assert from "node:assert/strict";
import { createReadStream } from "node:fs";
import { lstat, readdir } from "node:fs/promises";
import { createInterface } from "node:readline";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  comparisonPaths,
  LOKI_URL,
  GRAFANA_URL,
  ALLOY_URL,
} from "./loki-grafana-config.mjs";

async function json(url) {
  const response = await fetch(url, {
    redirect: "error",
    signal: AbortSignal.timeout(60000),
  });
  if (!response.ok)
    throw new Error(`Local verification HTTP ${response.status}`);
  return response.json();
}

/** Read-only check: compare bounded file snapshots with Loki's matching time range. */
export async function verifyComparison(root) {
  const paths = comparisonPaths(root);
  const archiveDir = join(dirname(paths.capture), "archives");
  const archives = (
    await readdir(archiveDir).catch((error) => {
      if (error.code === "ENOENT") return [];
      throw error;
    })
  ).filter((name) => /^events\.\d{8}T\d{9}Z-[a-f0-9]{8}\.jsonl$/.test(name));
  const files = [
    ...archives.map((name) => join(archiveDir, name)),
    paths.capture,
  ];
  const counts = {},
    samples = new Map();
  let first = Infinity,
    last = 0,
    records = 0;
  for (const file of files) {
    const info = await lstat(file);
    assert.ok(info.isFile() && !info.isSymbolicLink() && info.nlink === 1);
    if (!info.size) continue;
    for await (const line of createInterface({
      input: createReadStream(file, { end: info.size - 1 }),
      crlfDelay: Infinity,
    })) {
      if (!line) continue;
      const row = JSON.parse(line);
      const time = Date.parse(row.timestamp);
      assert.ok(Number.isFinite(time), "Capture timestamp must parse");
      first = Math.min(first, time);
      last = Math.max(last, time);
      counts[row.source] = (counts[row.source] ?? 0) + 1;
      records++;
      // Prefer the most recent raw record from every service.
      if (
        !samples.has(row.source) ||
        Date.parse(samples.get(row.source).row.timestamp) <= time
      )
        samples.set(row.source, { row, line });
    }
  }
  assert.ok(records > 0, "No records available for comparison");
  const end = Math.ceil(last / 1000) + 1;
  const duration = end - Math.floor(first / 1000) + 1;
  const params = new URLSearchParams({
    query: `sum by (source) (count_over_time({job="chat-workspace"}[${duration}s]))`,
    time: String(end),
  });
  const result = await json(`${LOKI_URL}/loki/api/v1/query?${params}`);
  const ingested = Object.fromEntries(
    result.data.result.map((r) => [r.metric.source, Number(r.value[1])]),
  );
  assert.deepEqual(
    ingested,
    counts,
    "Loki/source counts differ; allow import to finish or inspect Alloy drops",
  );
  for (const [source, { row, line }] of samples) {
    const time = Date.parse(row.timestamp);
    const query = new URLSearchParams({
      query: `{job="chat-workspace",source=${JSON.stringify(source)}}`,
      start: String(BigInt(time - 1) * 1000000n),
      end: String(BigInt(time + 1000) * 1000000n),
      limit: "10000",
    });
    const sample = await json(`${LOKI_URL}/loki/api/v1/query_range?${query}`);
    assert.ok(
      sample.data.result.some((stream) =>
        stream.values.some((value) => value[1] === line),
      ),
      `Original JSON missing for ${source}`,
    );
  }
  const health = await json(
    `${GRAFANA_URL}/api/datasources/uid/chat-loki/health`,
  );
  assert.equal(health.status, "OK");
  const metricsResponse = await fetch(`${ALLOY_URL}/metrics`, {
    redirect: "error",
    signal: AbortSignal.timeout(5000),
  });
  assert.ok(metricsResponse.ok, "Alloy metrics are unavailable");
  const metrics = await metricsResponse.text();
  const drops = metrics
    .split("\n")
    .filter((line) => /^loki_write_dropped_entries_total\{/.test(line));
  assert.ok(
    drops.length > 0,
    "Alloy delivery metrics are not initialized yet; retry after a new log arrives",
  );
  assert.ok(
    drops.every((line) => Number(line.slice(line.lastIndexOf(" ") + 1)) === 0),
    "Alloy reports dropped entries",
  );
  return {
    files: files.length,
    records,
    sources: counts,
    originalJsonSamples: samples.size,
    grafanaDatasource: health.status,
    alloyDroppedEntries: 0,
    first: new Date(first).toISOString(),
    last: new Date(last).toISOString(),
  };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
)
  verifyComparison(fileURLToPath(new URL("../", import.meta.url)))
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
