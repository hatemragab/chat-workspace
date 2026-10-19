import { constants } from "node:fs";
import {
  lstat,
  mkdir,
  open,
  readdir,
  rename,
  unlink,
  type FileHandle,
} from "node:fs/promises";
import {
  basename,
  dirname,
  join,
  parse,
  relative,
  resolve,
  sep,
} from "node:path";
import { randomBytes } from "node:crypto";
import type { Writable } from "node:stream";
import { stripVTControlCharacters } from "node:util";
import type { TrafficLogRecord } from "./debug-traffic-logger";

// Reserve space for Vector normalization metadata within its 1 MiB line cap.
export const MAX_TRAFFIC_RECORD_BYTES = 1024 * 1024 - 4096;

export type TrafficLogFormat = "pretty" | "json" | "silent";

const protectedOutputs = new WeakSet<Writable>();

/** A closed terminal/pipe is a logging failure, never an application failure. */
export function writeTrafficLine(stream: Writable, text: string): void {
  if (!protectedOutputs.has(stream)) {
    stream.on("error", () => undefined);
    protectedOutputs.add(stream);
  }
  stream.write(text, () => undefined);
}

export function resolveTrafficLogFormat(
  configured: unknown,
  nodeEnv: unknown,
): TrafficLogFormat {
  if (
    configured === "pretty" ||
    configured === "json" ||
    configured === "silent"
  )
    return configured;
  return nodeEnv === "development" ? "pretty" : "json";
}

function label(value: unknown, limit = 96): string {
  if (typeof value !== "string" && typeof value !== "number") return "-";
  const clean = stripVTControlCharacters(String(value))
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return clean.length > limit ? `${clean.slice(0, limit - 1)}…` : clean || "-";
}

/** A compact terminal view. Full bodies and headers belong in the JSON sink. */
export function formatTrafficSummary(
  record: TrafficLogRecord,
  options: { color?: boolean } = {},
): string {
  const timestamp = Date.parse(record.timestamp);
  const time = Number.isFinite(timestamp)
    ? new Date(timestamp).toISOString()
    : "[invalid timestamp]";
  const duration =
    typeof record.durationMs === "number" && Number.isFinite(record.durationMs)
      ? `${Math.max(0, record.durationMs).toFixed(1)}ms`
      : "-";
  const tint = (value: string, code: number) =>
    options.color ? `\u001b[${code}m${value}\u001b[0m` : value;
  const level = tint(
    label(record.level).toUpperCase().padEnd(5),
    record.level === "error" ? 31 : record.level === "warn" ? 33 : 36,
  );
  const prefix = `${time} ${level}`;
  if (record.event === "http_request") {
    const status = tint(
      label(record.status),
      typeof record.status === "number" && record.status >= 500
        ? 31
        : typeof record.status === "number" && record.status >= 400
          ? 33
          : 32,
    );
    return `${prefix} HTTP ${status} ${label(record.method, 12)} ${label(record.route, 160)} ${duration}${record.aborted ? " ABORTED" : ""}\n  user=${label(record.userId)} request=${label(record.requestId)}`;
  }
  const outcome = tint(
    label(record.result, 16),
    record.result === "success" ? 32 : 33,
  );
  return `${prefix} REALTIME ${outcome} ${label(record.eventType, 48)} pts=${label(record.pts)} ${duration}\n  actor=${label(record.actorUserId ?? record.userId)} recipient=${label(record.recipientUserId)} channel=${label(record.channel, 128)} attempt=${label(record.attempt)} status=${label(record.status)} request=${label(record.requestId)} publication=${label(record.publicationId)}`;
}

export interface TrafficLogSinkStats {
  pendingBytes: number;
  pendingRecords: number;
  writtenRecords: number;
  droppedRecords: number;
  failedRecords: number;
  failureCount: number;
  omittedRecords: number;
  importantPendingRecords: number;
  importantWrittenRecords: number;
  importantDroppedRecords: number;
  importantFailedRecords: number;
  evictedRecords: number;
  retriedRecords: number;
  uncertainRecords: number;
  importantUncertainRecords: number;
  lastSuccessAt: string | null;
  lastFailureAt: string | null;
  permanentFailure: boolean;
  recoveries: number;
  closed: boolean;
  failed: boolean;
}

export interface AsyncJsonlTrafficSinkOptions {
  path: string;
  cwd?: string;
  maxPendingBytes?: number;
  /** Extra bounded capacity unavailable to ordinary records. Defaults to 1 MiB. */
  importantReserveBytes?: number;
  /** Retain admitted important records across transient failures for at most 30s. */
  importantRetryWindowMs?: number;
  /** Private sidecar consumed only by the loopback diagnostics collector. */
  reportStatus?: boolean;
  retryBackoffMs?: number;
  rotation?: {
    maxBytes: number;
    maxArchives: number;
    maxAgeMs: number;
    rotateAfterMs?: number;
  };
  /** Receives one fixed, credential-free warning at most once per sink. */
  warn?: (message: string) => void;
}

interface PendingRecord {
  line: string;
  bytes: number;
  important: boolean;
  mirrorDeliveryData: boolean;
  queuedAt: number;
  attempts: number;
}

/** Operational failures retain priority even when their producer uses info. */
export function importantTrafficRecord(record: object): boolean {
  const value = record as Record<string, unknown>;
  return (
    value.level === "warn" ||
    value.level === "error" ||
    value.aborted === true ||
    value.result === "failure" ||
    value.result === "failed" ||
    (typeof value.status === "number" && value.status >= 400)
  );
}

/** Existing data can be an exact captured application publication. Add a
 * delivery payload only when the producer originally had no data field. */
function withLogDelivery(
  record: Record<string, unknown>,
  mirrorDeliveryData: boolean,
): Record<string, unknown> {
  if (
    !mirrorDeliveryData ||
    typeof record.logRecordId !== "string" ||
    !/^[a-f0-9]{32}$/.test(record.logRecordId) ||
    !Number.isSafeInteger(record.logDeliveryAttempt) ||
    (record.logDeliveryAttempt as number) < 1 ||
    (record.logDeliveryAttempt as number) > 32 ||
    !["not_attempted", "not_written", "uncertain"].includes(
      String(record.logPreviousWriteOutcome),
    )
  )
    return record;
  return {
    ...record,
    data: {
      logDelivery: {
        logRecordId: record.logRecordId,
        logDeliveryAttempt: record.logDeliveryAttempt,
        logPreviousWriteOutcome: record.logPreviousWriteOutcome,
      },
    },
  };
}

/**
 * Best-effort private JSONL capture. Appends never wait on disk in request paths;
 * A reserved byte budget protects important failures from ordinary log pressure.
 * Important accepted records retry transient storage failures within a finite
 * window. Ambiguous retries are explicitly marked; this is not a durable audit.
 */
export class AsyncJsonlTrafficSink<TRecord extends object = TrafficLogRecord> {
  private readonly path: string;
  private readonly maxPendingBytes: number;
  private readonly importantReserveBytes: number;
  private readonly importantRetryWindowMs: number;
  private readonly warn: (message: string) => void;
  private readonly queue = new Set<PendingRecord>();
  private file?: FileHandle;
  private draining?: Promise<void>;
  private closing?: Promise<void>;
  private warned = false;
  private readonly reportStatus: boolean;
  private readonly retryBackoffMs: number;
  private retryAt = 0;
  private recovering = false;
  private statusTimer?: NodeJS.Timeout;
  private statusWrite?: Promise<void>;
  private fileBytes = 0;
  private writing?: PendingRecord;
  private openedAt = Date.now();
  private readonly rotation: NonNullable<
    AsyncJsonlTrafficSinkOptions["rotation"]
  >;
  private state: TrafficLogSinkStats = {
    pendingBytes: 0,
    pendingRecords: 0,
    writtenRecords: 0,
    droppedRecords: 0,
    failedRecords: 0,
    failureCount: 0,
    omittedRecords: 0,
    importantPendingRecords: 0,
    importantWrittenRecords: 0,
    importantDroppedRecords: 0,
    importantFailedRecords: 0,
    evictedRecords: 0,
    retriedRecords: 0,
    uncertainRecords: 0,
    importantUncertainRecords: 0,
    lastSuccessAt: null,
    lastFailureAt: null,
    permanentFailure: false,
    recoveries: 0,
    closed: false,
    failed: false,
  };

  constructor(options: AsyncJsonlTrafficSinkOptions) {
    this.path = resolve(options.cwd ?? process.cwd(), options.path);
    this.reportStatus = options.reportStatus === true;
    this.retryBackoffMs = Math.max(1, options.retryBackoffMs ?? 1000);
    const setting = (name: string, fallback: number, maximum: number) => {
      const raw = process.env[name];
      const value = raw == null ? fallback : Number(raw);
      if (!Number.isSafeInteger(value) || value < 1 || value > maximum)
        throw new Error(`Invalid ${name}.`);
      return value;
    };
    this.rotation = options.rotation ?? {
      maxBytes: setting("LOCAL_LOG_MAX_BYTES", 50 * 1024 * 1024, 1024 ** 3),
      maxArchives: setting("LOCAL_LOG_MAX_ARCHIVES", 7, 100),
      maxAgeMs: setting("LOCAL_LOG_MAX_AGE_DAYS", 7, 365) * 86400000,
      rotateAfterMs: 86400000,
    };
    if (
      Object.values(this.rotation).some(
        (value) => !Number.isSafeInteger(value) || value < 1,
      )
    )
      throw new Error("Invalid log retention policy.");
    this.maxPendingBytes =
      typeof options.maxPendingBytes === "number" &&
      Number.isSafeInteger(options.maxPendingBytes) &&
      options.maxPendingBytes > 0
        ? options.maxPendingBytes
        : 4 * 1024 * 1024;
    this.importantReserveBytes = options.importantReserveBytes ?? 1024 * 1024;
    this.importantRetryWindowMs = options.importantRetryWindowMs ?? 30_000;
    if (
      !Number.isSafeInteger(this.importantReserveBytes) ||
      this.importantReserveBytes < 0 ||
      this.importantReserveBytes > 16 * 1024 * 1024 ||
      !Number.isSafeInteger(this.importantRetryWindowMs) ||
      this.importantRetryWindowMs < 1 ||
      this.importantRetryWindowMs > 30_000
    )
      throw new Error("Invalid important log retention policy.");
    this.warn =
      options.warn ??
      ((message) => {
        writeTrafficLine(process.stderr, message);
      });
  }

  stats(): TrafficLogSinkStats {
    return { ...this.state };
  }

  /** Pass a previously sanitized record; returns false if capture is unavailable. */
  append(record: TRecord): boolean {
    const important = importantTrafficRecord(record);
    // Service-client metadata must retain the absence of application data when
    // full capture is disabled. Only backend traffic may add a safe mirror.
    const mirrorDeliveryData =
      (record as Record<string, unknown>).source === "backend" &&
      !Object.hasOwn(record, "data");
    if (this.state.closed || this.state.permanentFailure) {
      this.state.droppedRecords++;
      if (important) this.state.importantDroppedRecords++;
      this.warning();
      return false;
    }
    if (this.state.failed && !this.draining && Date.now() >= this.retryAt) {
      this.state.failed = false;
      this.recovering = true;
      this.state.recoveries++;
    }
    if (this.state.failed && !important) {
      this.state.droppedRecords++;
      this.warning();
      return false;
    }
    let line: string;
    try {
      line = `${JSON.stringify(important ? withLogDelivery({ ...record, logRecordId: randomBytes(16).toString("hex"), logDeliveryAttempt: 1, logPreviousWriteOutcome: "not_attempted" }, mirrorDeliveryData) : record)}\n`;
    } catch {
      this.state.failedRecords++;
      if (important) this.state.importantFailedRecords++;
      this.state.failureCount++;
      this.warning();
      return false;
    }
    let bytes = Buffer.byteLength(line);
    if (bytes > MAX_TRAFFIC_RECORD_BYTES) {
      this.state.omittedRecords++;
      const serialized = JSON.parse(line) as Record<string, unknown>;
      // Preserve operational identity/status, never a prefix of private payloads.
      const metadata = Object.fromEntries(
        [
          "timestamp",
          "level",
          "source",
          "event",
          "requestId",
          "userId",
          "method",
          "route",
          "status",
          "durationMs",
          "publicationId",
          "recipientUserId",
          "actorUserId",
          "channel",
          "pts",
          "eventType",
          "attempt",
          "result",
          "instanceId",
          "logRecordId",
          "logDeliveryAttempt",
          "logPreviousWriteOutcome",
        ].flatMap((key) => {
          const value = serialized[key];
          return value === null ||
            typeof value === "number" ||
            typeof value === "boolean" ||
            (typeof value === "string" && value.length <= 256)
            ? [[key, value]]
            : [];
        }),
      );
      line = `${JSON.stringify(
        withLogDelivery(
          {
            ...metadata,
            payloadOmitted: true,
            omissionReason: "record_byte_limit",
            omittedBytes: bytes,
          },
          mirrorDeliveryData,
        ),
      )}\n`;
      bytes = Buffer.byteLength(line);
    }
    const capacity =
      this.maxPendingBytes + (important ? this.importantReserveBytes : 0);
    if (
      important &&
      bytes <= capacity &&
      bytes > capacity - this.state.pendingBytes
    ) {
      for (const entry of this.queue) {
        if (entry.important || entry === this.writing) continue;
        this.remove(entry);
        this.state.droppedRecords++;
        this.state.evictedRecords++;
        this.warning();
        if (bytes <= capacity - this.state.pendingBytes) break;
      }
    }
    if (bytes > capacity - this.state.pendingBytes) {
      this.state.droppedRecords++;
      if (important) this.state.importantDroppedRecords++;
      this.warning();
      return false;
    }
    this.queue.add({
      line,
      bytes,
      important,
      mirrorDeliveryData,
      queuedAt: Date.now(),
      attempts: 0,
    });
    this.state.pendingBytes += bytes;
    this.state.pendingRecords++;
    if (important) this.state.importantPendingRecords++;
    if (!this.draining) this.startDrain();
    return true;
  }

  async flush(): Promise<void> {
    while (this.draining) await this.draining;
  }

  close(): Promise<void> {
    if (!this.closing) {
      this.state.closed = true;
      this.closing = this.finish();
    }
    return this.closing;
  }

  private warning(): void {
    this.state.lastFailureAt = new Date().toISOString();
    this.scheduleStatus();
    if (this.warned) return;
    this.warned = true;
    try {
      this.warn(
        "Traffic log file capture dropped records or could not write. Console logging continues.\n",
      );
    } catch {
      // Neither failed diagnostics nor a broken stderr may affect the API.
    }
  }

  private async openFile(): Promise<FileHandle> {
    const parent = dirname(this.path);
    let directory = parse(parent).root;
    for (const part of relative(directory, parent).split(sep).filter(Boolean)) {
      directory = join(directory, part);
      try {
        await mkdir(directory, { mode: 0o700 });
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      }
      const info = await lstat(directory);
      if (!info.isDirectory() || info.isSymbolicLink())
        throw new Error("Unsafe log directory");
    }
    try {
      const target = await lstat(this.path);
      if (!target.isFile() || target.isSymbolicLink() || target.nlink !== 1)
        throw new Error("Unsafe log file");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    const file = await open(
      this.path,
      constants.O_WRONLY |
        constants.O_APPEND |
        constants.O_CREAT |
        constants.O_NOFOLLOW |
        constants.O_NONBLOCK,
      0o600,
    );
    try {
      const info = await file.stat();
      if (!info.isFile() || info.nlink !== 1)
        throw new Error("Unsafe log file");
      await file.chmod(0o600);
      this.fileBytes = info.size;
      this.openedAt = info.size ? info.mtimeMs : Date.now();
      return file;
    } catch (error) {
      await file.close();
      throw error;
    }
  }

  private startDrain(): void {
    this.draining = this.drain().finally(() => {
      this.draining = undefined;
      // A new append can run between drain completion and this continuation.
      if (this.queue.size && !this.state.permanentFailure) this.startDrain();
    });
  }

  private async drain(): Promise<void> {
    while (this.queue.size) {
      let beforeWrite: { size: number; ino: number; dev: number } | undefined;
      let appendStarted = false;
      try {
        if (this.state.failed) {
          await new Promise((resolve) =>
            setTimeout(resolve, Math.max(1, this.retryAt - Date.now())),
          );
          this.state.failed = false;
          this.recovering = true;
          this.state.recoveries++;
        }
        this.file ??= await this.openFile();
        if (this.recovering) {
          // A failed append may have written a partial line. Fence that lost
          // record so recovery never concatenates it with a later valid event.
          await this.file.appendFile("\n", "utf8");
          this.fileBytes++;
          this.recovering = false;
        }
        for (const entry of this.queue) {
          this.writing = entry;
          appendStarted = false;
          if (
            entry.important &&
            Date.now() - entry.queuedAt >= this.importantRetryWindowMs
          ) {
            this.remove(entry);
            this.state.failedRecords++;
            this.state.importantFailedRecords++;
            this.writing = undefined;
            this.warning();
            continue;
          }
          if (
            this.fileBytes &&
            (this.fileBytes + entry.bytes > this.rotation.maxBytes ||
              Date.now() - this.openedAt >=
                (this.rotation.rotateAfterMs ?? 86400000))
          ) {
            if (!(await this.rotate())) {
              this.remove(entry);
              this.state.droppedRecords++;
              if (entry.important) this.state.importantDroppedRecords++;
              this.writing = undefined;
              this.warning();
              continue;
            }
          }
          beforeWrite = await this.file.stat();
          entry.attempts++;
          appendStarted = true;
          await this.file.appendFile(entry.line, "utf8");
          this.fileBytes += entry.bytes;
          this.remove(entry);
          this.writing = undefined;
          this.state.writtenRecords++;
          if (entry.important) this.state.importantWrittenRecords++;
          this.state.lastSuccessAt = new Date().toISOString();
          this.scheduleStatus();
        }
      } catch (error) {
        const entry = this.writing;
        this.writing = undefined;
        let outcome = "not_written";
        if (entry && appendStarted) {
          const afterWrite = await this.file?.stat().catch(() => undefined);
          if (
            !beforeWrite ||
            !afterWrite ||
            beforeWrite.size !== afterWrite.size ||
            beforeWrite.ino !== afterWrite.ino ||
            beforeWrite.dev !== afterWrite.dev
          ) {
            outcome = "uncertain";
            this.state.uncertainRecords++;
            if (entry.important) this.state.importantUncertainRecords++;
          }
        }
        const code = (error as NodeJS.ErrnoException)?.code;
        this.state.permanentFailure = ![
          "EIO",
          "ENOSPC",
          "EMFILE",
          "ENFILE",
          "EBUSY",
          "EAGAIN",
        ].includes(code ?? "");
        this.retryAt = Date.now() + this.retryBackoffMs;
        this.state.failed = true;
        this.state.failureCount++;
        for (const pending of this.queue) {
          if (
            !this.state.permanentFailure &&
            pending.important &&
            pending.attempts < 32 &&
            Date.now() - pending.queuedAt < this.importantRetryWindowMs
          ) {
            if (pending === entry) {
              // A full write may have reached disk despite its rejected promise.
              // Preserve correlation and make possible duplicate delivery explicit.
              const value = JSON.parse(pending.line) as Record<string, unknown>;
              value.logRecordId ??= randomBytes(16).toString("hex");
              value.logDeliveryAttempt = pending.attempts + 1;
              value.logPreviousWriteOutcome = outcome;
              const line = `${JSON.stringify(withLogDelivery(value, pending.mirrorDeliveryData))}\n`;
              this.state.pendingBytes +=
                Buffer.byteLength(line) - pending.bytes;
              pending.line = line;
              pending.bytes = Buffer.byteLength(line);
              this.state.retriedRecords++;
            }
            continue;
          }
          this.remove(pending);
          this.state.failedRecords++;
          if (pending.important) this.state.importantFailedRecords++;
        }
        this.warning();
        await this.closeFile();
        if (this.queue.size && !this.state.permanentFailure) {
          const remaining = Math.min(
            ...Array.from(
              this.queue,
              (pending) =>
                this.importantRetryWindowMs - (Date.now() - pending.queuedAt),
            ),
          );
          await new Promise((resolve) =>
            setTimeout(
              resolve,
              Math.max(1, Math.min(this.retryBackoffMs, remaining)),
            ),
          );
          this.state.failed = false;
          this.recovering = true;
          this.state.recoveries++;
        }
      }
    }
  }

  private remove(entry: PendingRecord): void {
    if (!this.queue.delete(entry)) return;
    this.state.pendingBytes -= entry.bytes;
    this.state.pendingRecords--;
    if (entry.important) this.state.importantPendingRecords--;
  }

  private async rotate(): Promise<boolean> {
    // Only this sink writes its active file. Close before rename so Vector can
    // finish the old inode while the next append uses the new active path.
    const identity = await this.file!.stat();
    let ancestor = dirname(this.path);
    while (true) {
      const entry = await lstat(ancestor);
      if (!entry.isDirectory() || entry.isSymbolicLink())
        throw new Error("Unsafe archive ancestor");
      const next = dirname(ancestor);
      if (next === ancestor) break;
      ancestor = next;
    }
    const target = await lstat(this.path);
    if (
      !target.isFile() ||
      target.isSymbolicLink() ||
      target.nlink !== 1 ||
      target.ino !== identity.ino ||
      target.dev !== identity.dev
    )
      throw new Error("Unsafe log file");
    const directory = join(dirname(this.path), "archives");
    await mkdir(directory, { mode: 0o700 }).catch(
      (error: NodeJS.ErrnoException) => {
        if (error.code !== "EEXIST") throw error;
      },
    );
    const info = await lstat(directory);
    if (!info.isDirectory() || info.isSymbolicLink())
      throw new Error("Unsafe archive directory");
    const stem = basename(this.path, ".jsonl");
    let archives = 0;
    for (const name of await readdir(directory)) {
      if (
        !name.startsWith(`${stem}.`) ||
        !/^\d{8}T\d{9}Z-[a-f0-9]{8}\.jsonl$/.test(name.slice(stem.length + 1))
      )
        continue;
      const candidate = await lstat(join(directory, name));
      if (
        !candidate.isFile() ||
        candidate.isSymbolicLink() ||
        candidate.nlink !== 1
      )
        throw new Error("Unsafe archived capture");
      archives++;
    }
    if (archives > this.rotation.maxArchives) return false;
    await this.closeFile();
    const stamp = new Date().toISOString().replace(/[-:.]/g, "");
    await rename(
      this.path,
      join(
        directory,
        `${stem}.${stamp}-${randomBytes(4).toString("hex")}.jsonl`,
      ),
    );
    this.file = await this.openFile();
    // The collector owns pruning after a persisted acknowledged checkpoint.
    // A producer must never delete inputs just because Vector is offline.
    return true;
  }

  private async closeFile(): Promise<void> {
    const file = this.file;
    this.file = undefined;
    if (!file) return;
    try {
      await file.close();
    } catch {
      this.state.failureCount++;
      this.state.failed = true;
      this.warning();
    }
  }

  private async finish(): Promise<void> {
    await this.flush();
    await this.closeFile();
    if (this.statusTimer) clearTimeout(this.statusTimer);
    await this.statusWrite;
    await this.writeStatus();
  }

  private scheduleStatus(): void {
    if (!this.reportStatus || this.statusTimer || this.state.closed) return;
    this.statusTimer = setTimeout(() => {
      this.statusTimer = undefined;
      this.statusWrite = this.writeStatus();
    }, 1000);
    this.statusTimer.unref();
  }

  private async writeStatus(): Promise<void> {
    if (!this.reportStatus) return;
    const target = `${this.path}.status.json`;
    const temporary = `${target}.${randomBytes(8).toString("hex")}.tmp`;
    try {
      let parent = dirname(target);
      while (true) {
        const info = await lstat(parent);
        if (!info.isDirectory() || info.isSymbolicLink()) return;
        const next = dirname(parent);
        if (next === parent) break;
        parent = next;
      }
      const existing = await lstat(target).catch(
        (error: NodeJS.ErrnoException) => {
          if (error.code === "ENOENT") return undefined;
          throw error;
        },
      );
      if (
        existing &&
        (!existing.isFile() ||
          existing.isSymbolicLink() ||
          existing.nlink !== 1)
      )
        return;
      const file = await open(temporary, "wx", 0o600);
      try {
        await file.writeFile(
          JSON.stringify({
            ...this.stats(),
            updatedAt: new Date().toISOString(),
          }),
        );
      } finally {
        await file.close();
      }
      const current = await lstat(target).catch(
        (error: NodeJS.ErrnoException) => {
          if (error.code === "ENOENT") return undefined;
          throw error;
        },
      );
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
      // A private diagnostic sidecar can never change primary logging/results.
    } finally {
      await unlink(temporary).catch(() => undefined);
    }
  }
}
