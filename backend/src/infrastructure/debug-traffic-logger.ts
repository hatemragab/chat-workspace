import {
  Injectable,
  type OnModuleDestroy,
  type OnModuleInit,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { AsyncLocalStorage } from "node:async_hooks";
import {
  AsyncJsonlTrafficSink,
  formatTrafficSummary,
  resolveTrafficLogFormat,
  writeTrafficLine,
  type TrafficLogSinkStats,
} from "./traffic-log-output";

export interface TrafficLogRecord {
  timestamp: string;
  level: "info" | "warn" | "error";
  event: "http_request" | "realtime_publication";
  source: "backend";
  requestId: string | null;
  userId: string | null;
  [field: string]: unknown;
}

export type TrafficLogWriter = (record: TrafficLogRecord) => void;
export interface RequestTrafficContext {
  requestId: string;
  // AuthGuard populates the request later, so retain a getter, not its value.
  getUserId: () => string | null;
}

const REDACTED = "[REDACTED]";
export function credentialField(key: string): boolean {
  if (key.includes(".")) return key.split(".").some(credentialField);
  const normalized = key.replace(/[^a-z0-9]/gi, "").toLowerCase();
  return /password|passwd|pwd|token|authorization|cookie|secret|apikey|credential|signature|privatekey|accesskey|^jwt$|^bearer$|^session(?:id|key)$/.test(
    normalized,
  );
}

function safeText(value: string): string {
  return value
    .replace(/(\b[a-z][a-z0-9+.-]*:\/\/)[^/\s?#]+@/gi, `$1${REDACTED}@`)
    .replace(/\b(?:Bearer|Basic)\s+[a-z0-9._~+/=-]+/gi, REDACTED)
    .replace(/\beyJ[a-z0-9_-]+\.eyJ[a-z0-9_-]+\.[a-z0-9_-]+\b/gi, REDACTED)
    .replace(/([?&])([^=&#]+)=([^&#]*)/g, (original, prefix, key: string) => {
      try {
        return credentialField(decodeURIComponent(key))
          ? `${prefix}${key}=${REDACTED}`
          : original;
      } catch {
        return original;
      }
    });
}

/** Make a detached, credential-safe JSON snapshot without changing the source. */
export function sanitizeTrafficValue(value: unknown): unknown {
  const ancestors = new WeakSet<object>();
  const visit = (current: unknown): unknown => {
    if (typeof current === "string") {
      if (/^[\s]*[\[{\"]/.test(current)) {
        try {
          const parsed: unknown = JSON.parse(current);
          const sanitized = JSON.stringify(visit(parsed));
          if (sanitized !== JSON.stringify(parsed)) return sanitized;
        } catch {
          // Ordinary message text is not necessarily an encoded JSON value.
        }
      }
      return safeText(current);
    }
    if (current === null || typeof current !== "object") {
      return typeof current === "bigint" ? current.toString() : current;
    }
    if (ArrayBuffer.isView(current)) {
      return { kind: "binary", byteLength: current.byteLength };
    }
    if (current instanceof ArrayBuffer) {
      return { kind: "binary", byteLength: current.byteLength };
    }
    if (current instanceof Date) return current.toISOString();
    if (ancestors.has(current)) return "[Circular]";
    ancestors.add(current);
    try {
      if (Array.isArray(current)) return current.map(visit);
      return Object.fromEntries(
        Object.entries(current).map(([key, item]) => [
          key,
          credentialField(key) ? REDACTED : visit(item),
        ]),
      );
    } finally {
      ancestors.delete(current);
    }
  };
  try {
    return visit(value);
  } catch {
    return "[Unserializable]";
  }
}

@Injectable()
export class DebugTrafficLogger implements OnModuleDestroy, OnModuleInit {
  private readonly contexts = new AsyncLocalStorage<RequestTrafficContext>();
  private readonly fileSink?: AsyncJsonlTrafficSink;
  // A replaceable local sink also lets tests inspect records without stdout.
  writer: TrafficLogWriter = (record) => {
    const format = resolveTrafficLogFormat(
      this.config.get("TRAFFIC_LOG_FORMAT"),
      this.config.get("NODE_ENV"),
    );
    if (format === "silent") return;
    const text =
      format === "pretty"
        ? formatTrafficSummary(record, {
            color:
              process.stdout.isTTY === true && !("NO_COLOR" in process.env),
          })
        : JSON.stringify(record);
    writeTrafficLine(process.stdout, `${text}\n`);
  };

  constructor(private readonly config: ConfigService) {
    const path = this.config.get<unknown>("TRAFFIC_LOG_FILE");
    if (
      typeof path === "string" &&
      path.trim() &&
      path.trim().toLowerCase() !== "off"
    ) {
      this.fileSink = new AsyncJsonlTrafficSink({ path, reportStatus: true });
    }
  }

  fileStats(): TrafficLogSinkStats | null {
    return this.fileSink?.stats() ?? null;
  }

  async flush(): Promise<void> {
    await this.fileSink?.flush();
  }

  async onModuleDestroy(): Promise<void> {
    await this.fileSink?.close();
  }

  payloadPolicy() {
    const environment = this.config.get<string>(
      "NODE_ENV",
      process.env.NODE_ENV ?? "development",
    );
    const requested =
      String(this.config.get("DEBUG_TRAFFIC_LOGGING_ENABLED", "false")) ===
      "true";
    const productionOverride =
      environment === "production" &&
      String(
        this.config.get("ALLOW_PRODUCTION_DEBUG_TRAFFIC_LOGGING", "false"),
      ) === "true";
    return {
      environment: ["development", "test", "production"].includes(environment)
        ? environment
        : "other",
      requested,
      enabled:
        requested && (environment === "development" || productionOverride),
      productionOverride,
    };
  }
  onModuleInit(): void {
    writeTrafficLine(
      process.stderr,
      `${JSON.stringify({ event: "traffic_logging_policy", ...this.payloadPolicy() })}\n`,
    );
  }
  get debugEnabled(): boolean {
    return this.payloadPolicy().enabled;
  }
  get httpEnabled(): boolean {
    return String(this.config.get("HTTP_LOGGING_ENABLED", "true")) !== "false";
  }

  runWithRequest<T>(context: RequestTrafficContext, work: () => T): T {
    return this.contexts.run(context, work);
  }

  identity(): { requestId: string | null; userId: string | null } {
    const context = this.contexts.getStore();
    return {
      requestId: context?.requestId ?? null,
      userId: context?.getUserId() ?? null,
    };
  }

  write(record: TrafficLogRecord, writer = this.writer): void {
    const safe = sanitizeTrafficValue(record) as TrafficLogRecord;
    // Serialize the detached snapshot before a replaceable console writer runs.
    // Each output fails independently and never changes application behavior.
    try {
      this.fileSink?.append(safe);
    } catch {
      // Guard unexpected sink failures independently of the console writer.
    }
    try {
      const written: unknown = writer(safe);
      if (written instanceof Promise) void written.catch(() => undefined);
    } catch {
      // Debug logging must never change HTTP completion or publication retries.
    }
  }
}
