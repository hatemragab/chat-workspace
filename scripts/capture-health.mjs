import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { dirname } from "node:path";

async function safeFile(path) {
  let parent = dirname(path);
  while (true) {
    const entry = await lstat(parent);
    if (!entry.isDirectory() || entry.isSymbolicLink())
      throw new Error("Unsafe local diagnostic");
    const next = dirname(parent);
    if (next === parent) break;
    parent = next;
  }
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1)
    throw new Error("Unsafe local diagnostic");
  const file = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  const actual = await file.stat();
  if (
    actual.ino !== stat.ino ||
    actual.dev !== stat.dev ||
    actual.nlink !== 1
  ) {
    await file.close();
    throw new Error("Unsafe local diagnostic");
  }
  return { file, stat: actual };
}
const fields = [
  "pendingBytes",
  "pendingRecords",
  "writtenRecords",
  "droppedRecords",
  "failedRecords",
  "failureCount",
  "omittedRecords",
  "recoveries",
  "importantPendingRecords",
  "importantWrittenRecords",
  "importantDroppedRecords",
  "importantFailedRecords",
  "evictedRecords",
  "retriedRecords",
  "uncertainRecords",
  "importantUncertainRecords",
];

/** Bounded, metadata-only view for the existing Host/Origin-protected ingress. */
export async function captureHealth(paths, previous = {}) {
  const now = Date.now();
  const health = {
    checkedAt: new Date(now).toISOString(),
    inputs: {},
    sources: { ...(previous.sources ?? {}) },
    output: { available: false },
  };
  for (const name of ["backend", "services", "flutter", "native_centrifugo"]) {
    let opened;
    try {
      opened = await safeFile(paths[name]);
      health.inputs[name] = {
        bytes: opened.stat.size,
        lastAppendAt: opened.stat.mtime.toISOString(),
        idleMs: Math.max(0, now - opened.stat.mtimeMs),
      };
    } catch {
      health.inputs[name] = { available: false };
    } finally {
      await opened?.file.close();
    }
    if (name === "flutter") continue;
    let status;
    try {
      status = await safeFile(`${paths[name]}.status.json`);
      if (status.stat.size > 8192) throw new Error("Invalid local diagnostic");
      const data = JSON.parse(await status.file.readFile("utf8"));
      const sink = {};
      for (const field of fields)
        if (Number.isSafeInteger(data[field]) && data[field] >= 0)
          sink[field] = data[field];
      for (const field of ["closed", "failed", "permanentFailure"])
        if (typeof data[field] === "boolean") sink[field] = data[field];
      for (const field of ["updatedAt", "lastSuccessAt", "lastFailureAt"])
        if (
          typeof data[field] === "string" &&
          Number.isFinite(Date.parse(data[field]))
        )
          sink[field] = new Date(data[field]).toISOString();
      health.inputs[name].sink = sink;
    } catch {
      health.inputs[name].sinkStatusAvailable = false;
    } finally {
      await status?.file.close();
    }
  }
  let output;
  try {
    output = await safeFile(paths.events);
    const bytes = Math.min(256 * 1024, output.stat.size);
    const buffer = Buffer.alloc(bytes);
    await output.file.read(buffer, 0, bytes, output.stat.size - bytes);
    let lines = buffer.toString("utf8").split("\n");
    if (output.stat.size > bytes) lines.shift();
    lines.pop(); // never parse a partial trailing write
    for (const line of lines) {
      try {
        const row = JSON.parse(line);
        if (
          ![
            "backend",
            "flutter",
            "redis",
            "mongodb",
            "centrifugo",
            "collector",
          ].includes(row.source)
        )
          continue;
        const event = Date.parse(row.timestamp),
          collected = Date.parse(row.collectedAt);
        if (!Number.isFinite(event) || !Number.isFinite(collected)) continue;
        const prior = health.sources[row.source];
        if (!prior || collected >= Date.parse(prior.lastCollectedAt)) {
          health.sources[row.source] = {
            lastEventAt: new Date(event).toISOString(),
            lastCollectedAt: new Date(collected).toISOString(),
            collectionLagMs: Math.max(0, collected - event),
          };
          // Flutter's ingress assigns receivedAt after transport. Keep the two
          // independently observed stages visible instead of attributing all
          // producer-to-collection time to the browser exporter.
          const received = Date.parse(row.receivedAt);
          if (row.source === "flutter" && Number.isFinite(received)) {
            health.sources[row.source].producerToIngressMs = Math.max(
              0,
              received - event,
            );
            health.sources[row.source].ingressToCollectionMs = Math.max(
              0,
              collected - received,
            );
          }
        }
      } catch {
        /* Only already-normalized safe time metadata is promoted. */
      }
    }
    health.output = {
      available: true,
      bytes: output.stat.size,
      lastAppendAt: output.stat.mtime.toISOString(),
      idleMs: Math.max(0, now - output.stat.mtimeMs),
      sampledTailBytes: bytes,
    };
    for (const value of Object.values(health.sources))
      value.idleMs = Math.max(0, now - Date.parse(value.lastCollectedAt));
  } catch {
    /* Missing output is explicit and never creates a capture. */
  } finally {
    await output?.file.close();
  }
  return health;
}
