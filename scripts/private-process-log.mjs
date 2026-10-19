import { spawn } from "node:child_process";
import { StringDecoder } from "node:string_decoder";
import { resolve, dirname } from "node:path";
import { open, lstat, rename, unlink } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  RotatingJsonlWriter,
  retentionPolicy,
  pruneArchives,
} from "./log-retention.mjs";

export const MAX_PRIVATE_LOG_LINE_BYTES = 1024 * 1024 - 4096;

/** Structured severity wins over words in a message; stdout/stderr alone does
 * not establish severity. This classifier never returns source text. */
export function importantProcessLogLine(line) {
  try {
    const parsed = JSON.parse(line);
    const severity = String(parsed?.level ?? parsed?.s ?? "").toLowerCase();
    if (
      /^(trace|debug|d[1-5]?|info|i|warn|warning|w|error|e|fatal|f|panic|none)$/.test(
        severity,
      )
    )
      return /^(warn|warning|w|error|e|fatal|f|panic)$/.test(severity);
  } catch {}
  return /\b(warn(?:ing)?|error|fatal|panic)\b/i.test(line);
}

function withLogDelivery(record) {
  if (
    !/^[a-f0-9]{32}$/.test(record.logRecordId) ||
    !Number.isSafeInteger(record.logDeliveryAttempt) ||
    record.logDeliveryAttempt < 1 ||
    record.logDeliveryAttempt > 32 ||
    !["not_attempted", "not_written", "uncertain"].includes(
      record.logPreviousWriteOutcome,
    )
  )
    return record;
  const original = record.data;
  const data =
    original && typeof original === "object" && !Array.isArray(original)
      ? original
      : original === undefined
        ? {}
        : { originalData: original };
  return {
    ...record,
    data: {
      ...data,
      logDelivery: {
        ...(data.logDelivery &&
        typeof data.logDelivery === "object" &&
        !Array.isArray(data.logDelivery)
          ? data.logDelivery
          : {}),
        logRecordId: record.logRecordId,
        logDeliveryAttempt: record.logDeliveryAttempt,
        logPreviousWriteOutcome: record.logPreviousWriteOutcome,
      },
    },
  };
}

/** Only the owning launcher writes/rotates this path. Native input archives are
 * pruned by the collector after acknowledged EOF; process output is not input. */
export async function createPrivateProcessLog(
  file,
  {
    input = false,
    policy = retentionPolicy(),
    maxPendingBytes = 4 * 1024 * 1024,
    importantReserveBytes = 1024 * 1024,
    importantRetryWindowMs = 30_000,
    retryBackoffMs = 1000,
  } = {},
) {
  if (
    !Number.isSafeInteger(maxPendingBytes) ||
    maxPendingBytes < 1 ||
    !Number.isSafeInteger(importantReserveBytes) ||
    importantReserveBytes < 0 ||
    importantReserveBytes > 16 * 1024 * 1024 ||
    !Number.isSafeInteger(importantRetryWindowMs) ||
    importantRetryWindowMs < 1 ||
    importantRetryWindowMs > 30_000 ||
    !Number.isSafeInteger(retryBackoffMs) ||
    retryBackoffMs < 1 ||
    retryBackoffMs > 30_000
  )
    throw new Error("Invalid private log queue policy.");
  const writer = await new RotatingJsonlWriter(file, policy).open();
  const queue = new Set();
  let draining,
    writing,
    pendingBytes = 0,
    closed = false,
    statusTimer,
    statusWork;
  const writeStatus = async () => {
    const target = `${file}.status.json`;
    const temporary = `${target}.${randomBytes(8).toString("hex")}.tmp`;
    try {
      let parent = dirname(target);
      while (true) {
        const entry = await lstat(parent);
        if (!entry.isDirectory() || entry.isSymbolicLink()) return;
        const next = dirname(parent);
        if (next === parent) break;
        parent = next;
      }
      const existing = await lstat(target).catch((error) => {
        if (error.code !== "ENOENT") throw error;
      });
      if (
        existing &&
        (!existing.isFile() ||
          existing.isSymbolicLink() ||
          existing.nlink !== 1)
      )
        return;
      const handle = await open(temporary, "wx", 0o600);
      try {
        await handle.writeFile(
          JSON.stringify({
            ...stats,
            pendingBytes,
            closed,
            updatedAt: new Date().toISOString(),
          }),
        );
      } finally {
        await handle.close();
      }
      const current = await lstat(target).catch((error) => {
        if (error.code !== "ENOENT") throw error;
      });
      if (
        current &&
        (!existing ||
          current.ino !== existing.ino ||
          current.dev !== existing.dev ||
          current.nlink !== 1)
      )
        return;
      await rename(temporary, target);
    } catch {
    } finally {
      await unlink(temporary).catch(() => {});
    }
  };
  const scheduleStatus = () => {
    if (statusTimer || closed) return;
    statusTimer = setTimeout(() => {
      statusTimer = undefined;
      statusWork = writeStatus();
    }, 1000);
    statusTimer.unref();
  };
  let carry = "",
    oversized = false;
  const decoder = new StringDecoder("utf8");
  const stats = {
    writtenRecords: 0,
    droppedRecords: 0,
    failedRecords: 0,
    omittedRecords: 0,
    importantPendingRecords: 0,
    importantWrittenRecords: 0,
    importantDroppedRecords: 0,
    importantFailedRecords: 0,
    evictedRecords: 0,
    retriedRecords: 0,
    uncertainRecords: 0,
    importantUncertainRecords: 0,
    maintenanceFailures: 0,
    lastSuccessAt: null,
  };
  const remove = (entry) => {
    if (!queue.delete(entry)) return;
    pendingBytes -= entry.bytes;
    if (entry.important) stats.importantPendingRecords--;
  };
  const drain = async () => {
    for (const entry of queue) {
      writing = entry;
      const previous = writer.bytes;
      while (queue.has(entry)) {
        try {
          if (
            entry.important &&
            Date.now() - entry.queuedAt >= importantRetryWindowMs
          )
            throw new Error("Important private log retry expired.");
          entry.attempts++;
          await writer.write(entry.line);
          remove(entry);
          stats.writtenRecords++;
          if (entry.important) stats.importantWrittenRecords++;
          stats.lastSuccessAt = new Date().toISOString();
          if (!input && writer.bytes <= entry.bytes && previous) {
            try {
              await pruneArchives(file, policy, Date.now(), 0);
            } catch {
              stats.maintenanceFailures++;
            }
          }
        } catch (error) {
          const recoverable = [
            "EIO",
            "ENOSPC",
            "EMFILE",
            "ENFILE",
            "EBUSY",
            "EAGAIN",
          ].includes(error?.code);
          const uncertain = error?.logWriteOutcome !== "not_written";
          if (uncertain && recoverable) {
            stats.uncertainRecords++;
            if (entry.important) stats.importantUncertainRecords++;
          }
          const remaining =
            importantRetryWindowMs - (Date.now() - entry.queuedAt);
          if (
            entry.important &&
            recoverable &&
            remaining > 0 &&
            entry.attempts < 32
          ) {
            const value = JSON.parse(entry.line);
            value.logDeliveryAttempt = entry.attempts + 1;
            value.logPreviousWriteOutcome = uncertain
              ? "uncertain"
              : "not_written";
            const line = `${JSON.stringify(withLogDelivery(value))}\n`;
            pendingBytes += Buffer.byteLength(line) - entry.bytes;
            entry.line = line;
            entry.bytes = Buffer.byteLength(line);
            stats.retriedRecords++;
            scheduleStatus();
            await new Promise((resolve) =>
              setTimeout(
                resolve,
                Math.max(1, Math.min(retryBackoffMs, remaining)),
              ),
            );
            continue;
          }
          remove(entry);
          stats.failedRecords++;
          if (entry.important) stats.importantFailedRecords++;
        } finally {
          scheduleStatus();
        }
      }
      writing = undefined;
    }
  };
  const startDrain = () => {
    draining = drain().finally(() => {
      draining = undefined;
      if (queue.size) startDrain();
    });
  };
  const enqueue = (line) => {
    const important = importantProcessLogLine(line);
    if (important) {
      let value;
      try {
        value = JSON.parse(line);
      } catch {}
      if (!value || typeof value !== "object" || Array.isArray(value))
        value = { level: "warn", message: line.replace(/\n$/, "") };
      line = `${JSON.stringify(withLogDelivery({ ...value, logRecordId: randomBytes(16).toString("hex"), logDeliveryAttempt: 1, logPreviousWriteOutcome: "not_attempted" }))}\n`;
      if (Buffer.byteLength(line) > MAX_PRIVATE_LOG_LINE_BYTES) {
        stats.omittedRecords++;
        line = `${JSON.stringify(withLogDelivery({ level: "warn", message: "Oversized important process diagnostic omitted", payloadOmitted: true, logRecordId: randomBytes(16).toString("hex"), logDeliveryAttempt: 1, logPreviousWriteOutcome: "not_attempted" }))}\n`;
      }
    }
    const size = Buffer.byteLength(line);
    const capacity = maxPendingBytes + (important ? importantReserveBytes : 0);
    if (important && size <= capacity && size + pendingBytes > capacity) {
      for (const entry of queue) {
        if (entry.important || entry === writing) continue;
        remove(entry);
        stats.droppedRecords++;
        stats.evictedRecords++;
        scheduleStatus();
        if (size + pendingBytes <= capacity) break;
      }
    }
    if (closed || size + pendingBytes > capacity) {
      stats.droppedRecords++;
      if (important) stats.importantDroppedRecords++;
      scheduleStatus();
      return;
    }
    pendingBytes += size;
    queue.add({
      line,
      bytes: size,
      important,
      queuedAt: Date.now(),
      attempts: 0,
    });
    if (important) stats.importantPendingRecords++;
    if (!draining) startDrain();
  };
  const accept = (text) => {
    for (const part of text.split(/(?<=\n)/)) {
      if (!oversized) carry += part;
      if (Buffer.byteLength(carry) > MAX_PRIVATE_LOG_LINE_BYTES) {
        carry = "";
        oversized = true;
      }
      if (part.endsWith("\n")) {
        if (oversized) {
          stats.omittedRecords++;
          enqueue(
            JSON.stringify({
              level: "warn",
              message: "Oversized owned process diagnostic omitted",
              payloadOmitted: true,
            }) + "\n",
          );
        } else enqueue(carry);
        carry = "";
        oversized = false;
      }
    }
  };
  return {
    append(chunk) {
      if (!closed)
        accept(
          decoder.write(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)),
        );
    },
    stats() {
      return { ...stats, pendingBytes, closed };
    },
    async close() {
      if (closed) {
        while (draining) await draining;
        return;
      }
      accept(decoder.end());
      if (carry || oversized) accept("\n");
      closed = true;
      while (draining) await draining;
      await writer.close();
      clearTimeout(statusTimer);
      await statusWork;
      await writeStatus();
    },
  };
}

/** Fixed owner paths/cwd; Flutter labels must match the explicitly chosen port. */
export function privateProcessLaunch(
  name,
  command,
  args = [],
  root = fileURLToPath(new URL("../", import.meta.url)),
) {
  const flutterPort =
    name === "flutter5173"
      ? "5173"
      : name === "flutter5174"
        ? "5174"
        : undefined;
  if (
    (!flutterPort && !["backend", "collector", "logdy"].includes(name)) ||
    typeof command !== "string" ||
    !command ||
    command.includes("\0") ||
    !Array.isArray(args) ||
    args.some((value) => typeof value !== "string" || value.includes("\0"))
  )
    throw new Error(
      "Usage: private-process-log.mjs backend|collector|logdy|flutter5173|flutter5174 COMMAND [ARG...]",
    );
  if (flutterPort) {
    const ports = args.flatMap((value, index) =>
      value.startsWith("--web-port=")
        ? [value.slice("--web-port=".length)]
        : value === "--web-port"
          ? [args[index + 1]]
          : [],
    );
    if (ports.length !== 1 || ports[0] !== flutterPort)
      throw new Error(
        "Flutter log owner requires its matching explicit web port.",
      );
  }
  return {
    command,
    args: [...args],
    file: resolve(
      root,
      ".runtime/observability",
      flutterPort ? `flutter-web-${flutterPort}.log` : `${name}-process.log`,
    ),
    options: {
      cwd: flutterPort ? resolve(root, "mobile_and_web") : resolve(root),
      stdio: ["ignore", "pipe", "pipe"],
    },
  };
}

// Optional manual launcher. No shell, arbitrary output path or auto-run.
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const [name, command, ...args] = process.argv.slice(2);
  const launch = privateProcessLaunch(name, command, args);
  const log = await createPrivateProcessLog(launch.file);
  const child = spawn(launch.command, launch.args, launch.options);
  for (const stream of [child.stdout, child.stderr])
    stream.on("data", (chunk) => log.append(chunk));
  for (const signal of ["SIGINT", "SIGTERM"])
    process.once(signal, () => child.kill(signal));
  child.once("error", () => {
    process.exitCode = 1;
    void log.close();
  });
  child.once("close", (code) => {
    process.exitCode = code ?? 1;
    void log.close();
  });
}
