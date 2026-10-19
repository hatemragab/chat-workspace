import { Injectable, type OnModuleDestroy } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import type Redis from "ioredis";
import type {
  MongoClient,
  CommandStartedEvent,
  CommandSucceededEvent,
  CommandFailedEvent,
} from "mongodb";
import { randomUUID } from "node:crypto";
import { mongoCommandDetails } from "./mongo-command-details";
import type { ServiceOperationDetails } from "./service-operation-details";
import { centrifugoLogSnapshot } from "./centrifugo-command-details";
import {
  redisCommandDetails,
  redisResponseDetails,
  type RedisCommandDetails,
} from "./redis-command-details";
import {
  DebugTrafficLogger,
  sanitizeTrafficValue,
} from "./debug-traffic-logger";
import {
  AsyncJsonlTrafficSink,
  type TrafficLogSinkStats,
} from "./traffic-log-output";

type ServiceSource = "redis" | "mongodb" | "centrifugo";
type Identity = { requestId: string | null; userId: string | null };
export interface LocalServiceLogRecord extends Identity {
  timestamp: string;
  level: "info" | "warn" | "error";
  source: ServiceSource;
  event: "service_operation" | "service_connection";
  origin: "backend_client";
  instanceId: string;
  component: "ioredis" | "mongodb_driver" | "centrifugo_http";
  operation: string;
  name: string;
  category: "command" | "connection";
  result: "success" | "failure" | "omitted";
  durationMs?: number;
  method?: string;
  path?: string;
  summary?: string;
  databaseName?: string;
  collection?: string;
  driverRequestId?: number;
  errorType?: string;
  publicationId?: string;
  recipientUserId?: string;
  actorUserId?: string | null;
  channel?: string;
  eventType?: string;
  pts?: number;
  purpose?: string;
  channelCount?: number;
  stage?: string;
  epoch?: string;
  roomId?: string;
  correlationKey?: string;
  data?: unknown;
  responseBody?: unknown;
  attempt?: number;
  status?: number | null;
  omittedOperations?: number;
  omissionReason?: "capacity" | "age" | "pool_closed" | "shutdown";
  correlationUnavailable?: boolean;
}
type Completion = (error?: unknown, response?: unknown) => void;
const disabledCompletion: Completion = () => undefined;
const components = {
  redis: "ioredis",
  mongodb: "mongodb_driver",
  centrifugo: "centrifugo_http",
} as const;

export function localServiceLoggingEnabled(path: unknown): path is string {
  return (
    typeof path === "string" &&
    !!path.trim() &&
    path.trim().toLowerCase() !== "off"
  );
}

function operationName(value: string): string {
  return /^[a-z][a-z0-9_.-]{0,63}$/i.test(value) ? value : "unknown";
}

/** Error messages, stacks, driver addresses and command contents are excluded. */
function errorClass(error: unknown): string {
  try {
    if (!(error instanceof Error)) return "UnknownError";
    const name: string = error.constructor.name;
    return /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(name) ? name : "Error";
  } catch {
    return "Error";
  }
}

/**
 * Optional metadata from this backend's service clients, not server internals.
 * It shares the private, bounded JSONL writer; no operation waits on disk.
 */
@Injectable()
export class LocalServiceDiagnostics implements OnModuleDestroy {
  private readonly sink?: AsyncJsonlTrafficSink<LocalServiceLogRecord>;
  private stopping = false;
  private readonly cleanups = new Set<() => void>();
  private readonly observers = new WeakMap<object, () => void>();
  private readonly mongoOmissions = new Map<
    NonNullable<LocalServiceLogRecord["omissionReason"]>,
    number
  >();
  private mongoOmissionTimer?: NodeJS.Timeout;
  readonly instanceId = `backend-${process.pid}-${randomUUID()}`;

  constructor(
    config: ConfigService,
    private readonly traffic: DebugTrafficLogger,
  ) {
    const path = config.get<unknown>("LOCAL_SERVICE_LOG_FILE");
    if (localServiceLoggingEnabled(path))
      this.sink = new AsyncJsonlTrafficSink({ path, reportStatus: true });
  }

  get enabled(): boolean {
    return !!this.sink;
  }
  fileStats(): TrafficLogSinkStats | null {
    return this.sink?.stats() ?? null;
  }
  async flush(): Promise<void> {
    await this.sink?.flush();
  }

  identity(): Identity {
    try {
      return this.traffic.identity();
    } catch {
      return { requestId: null, userId: null };
    }
  }

  private emit(
    record: Omit<
      LocalServiceLogRecord,
      "timestamp" | "origin" | "instanceId" | "name" | "category"
    >,
    allowStopping = false,
  ): void {
    if (!this.sink || (this.stopping && !allowStopping)) return;
    try {
      this.sink.append(
        sanitizeTrafficValue({
          ...record,
          name: `${record.source}.${operationName(record.operation)}`,
          category:
            record.event === "service_connection" ? "connection" : "command",
          timestamp: new Date().toISOString(),
          origin: "backend_client",
          instanceId: this.instanceId,
        }) as LocalServiceLogRecord,
      );
    } catch {
      /* Diagnostics cannot change client results or driver events. */
    }
  }

  private omitMongoObservation(
    reason: NonNullable<LocalServiceLogRecord["omissionReason"]>,
    count: number,
  ): void {
    if (!count) return;
    this.mongoOmissions.set(
      reason,
      (this.mongoOmissions.get(reason) ?? 0) + count,
    );
    if (this.mongoOmissionTimer || this.stopping) return;
    this.mongoOmissionTimer = setTimeout(() => {
      this.mongoOmissionTimer = undefined;
      this.flushMongoOmissions();
    }, 1000);
    this.mongoOmissionTimer.unref();
  }

  private flushMongoOmissions(): void {
    for (const [reason, count] of this.mongoOmissions) {
      this.emit(
        {
          requestId: null,
          userId: null,
          source: "mongodb",
          component: "mongodb_driver",
          event: "service_connection",
          operation: "monitor_tracking_omitted",
          level: "warn",
          result: "omitted",
          omittedOperations: count,
          omissionReason: reason,
        },
        true,
      );
    }
    this.mongoOmissions.clear();
  }

  begin(
    source: ServiceSource,
    operation: string,
    identity?: Identity,
    details?: ServiceOperationDetails,
  ): Completion {
    if (!this.enabled || this.stopping) return disabledCompletion;
    const capturedIdentity = identity ?? this.identity();
    const started = performance.now();
    let completed = false;
    return (error?: unknown, response?: unknown) => {
      if (completed) return;
      completed = true;
      let debugFields: Partial<LocalServiceLogRecord> = {};
      if (source === "centrifugo" && details) {
        debugFields = {
          summary: details.summary,
          method: details.method,
          path: details.path,
          channel: details.channel,
          status: details.status,
          purpose: details.purpose,
          channelCount: details.channelCount,
        };
      }
      try {
        if (details && this.traffic.debugEnabled)
          debugFields = {
            ...debugFields,
            summary: details.summary,
            data: details.data,
            databaseName: details.databaseName,
            collection: details.collection,
            driverRequestId: details.driverRequestId,
            method: details.method,
            path: details.path,
            channel: details.channel,
            status: details.status,
            ...(details.includeResponse && response !== undefined
              ? {
                  responseBody: (
                    details.responseSnapshot ?? redisResponseDetails
                  )(response),
                }
              : {}),
            ...(error !== undefined && details.errorSnapshot
              ? {
                  responseBody: {
                    errorType: errorClass(error),
                    details: details.errorSnapshot(error),
                  },
                }
              : {}),
          };
      } catch {
        /* Snapshot failures cannot escape driver event handlers. */
      }
      this.emit({
        ...capturedIdentity,
        source,
        component: components[source],
        operation: operationName(operation),
        event: "service_operation",
        level: error === undefined ? "info" : "warn",
        result: error === undefined ? "success" : "failure",
        durationMs:
          Math.round(Math.max(0, performance.now() - started) * 100) / 100,
        ...(error === undefined ? {} : { errorType: errorClass(error) }),
        ...debugFields,
      });
    };
  }

  publication(
    record: Identity & {
      publicationId: string;
      recipientUserId: string;
      channel: string;
      eventType: string;
      pts?: number;
      epoch?: string;
      roomId?: string;
      correlationKey?: string;
      data?: unknown;
      responseBody?: unknown;
      attempt: number;
      status: number | null;
      durationMs: number;
      success: boolean;
      error?: unknown;
    },
  ): void {
    if (!this.enabled) return;
    this.emit({
      requestId: record.requestId,
      userId: record.userId,
      source: "centrifugo",
      component: "centrifugo_http",
      event: "service_operation",
      operation: "publish",
      method: "POST",
      path: "/api/publish",
      summary: `Publish ${record.eventType} to ${record.channel}, attempt ${record.attempt}: ${record.success ? "provider accepted" : "failed"}.`,
      publicationId: record.publicationId,
      recipientUserId: record.recipientUserId,
      actorUserId: record.userId,
      channel: record.channel,
      eventType: record.eventType,
      pts: record.pts,
      epoch: record.epoch,
      roomId: record.roomId,
      correlationKey: record.correlationKey,
      stage: record.success ? "provider_accepted" : "provider_failed",
      purpose: "inbox_publish",
      ...(this.traffic.debugEnabled
        ? {
            data: centrifugoLogSnapshot(record.data),
            responseBody: centrifugoLogSnapshot(record.responseBody),
          }
        : {}),
      attempt: record.attempt,
      status: record.status,
      durationMs: record.durationMs,
      level: record.success ? "info" : "warn",
      result: record.success ? "success" : "failure",
      ...(!record.success && record.error !== undefined
        ? { errorType: errorClass(record.error) }
        : {}),
    });
  }

  private connection(
    source: ServiceSource,
    operation: string,
    error?: unknown,
  ): void {
    this.emit({
      requestId: null,
      userId: null,
      source,
      component: components[source],
      event: "service_connection",
      operation,
      level: error === undefined ? "info" : "warn",
      result: error === undefined ? "success" : "failure",
      ...(error === undefined ? {} : { errorType: errorClass(error) }),
    });
  }

  observeRedis(client: Redis): () => void {
    if (!this.enabled) return () => undefined;
    const existing = this.observers.get(client);
    if (existing) return existing;
    const diagnostics = this;
    const observed = new WeakMap<object, Completion>();
    const original = client.sendCommand;
    const instrumented: Redis["sendCommand"] = function (
      this: Redis,
      command,
      stream,
    ) {
      let done = observed.get(command);
      if (!done) {
        let details: RedisCommandDetails | undefined;
        try {
          if (diagnostics.traffic.debugEnabled)
            details = redisCommandDetails(command);
        } catch {
          /* Inspection failure must never prevent a Redis command. */
        }
        done = diagnostics.begin("redis", command.name, undefined, details);
        observed.set(command, done);
        // Observe the driver's own completion; return values and callbacks remain untouched.
        void command.promise.then(
          (response: unknown) => done!(undefined, response),
          (error: unknown) => done!(error ?? new Error()),
        );
      }
      try {
        return original.call(this, command, stream);
      } catch (error) {
        done(error ?? new Error());
        throw error;
      }
    };
    client.sendCommand = instrumented;
    const listeners = [
      "connect",
      "ready",
      "close",
      "reconnecting",
      "end",
      "error",
    ].map((name) => {
      const listener = (error?: unknown) =>
        this.connection("redis", name, name === "error" ? error : undefined);
      client.on(name, listener);
      return { name, listener };
    });
    const cleanup = () => {
      if (client.sendCommand === instrumented) client.sendCommand = original;
      for (const { name, listener } of listeners) client.off(name, listener);
      this.cleanups.delete(cleanup);
      this.observers.delete(client);
    };
    this.cleanups.add(cleanup);
    this.observers.set(client, cleanup);
    return cleanup;
  }

  observeMongo(client: MongoClient): () => void {
    if (!this.enabled) return () => undefined;
    const existing = this.observers.get(client);
    if (existing) return existing;
    // A missing completion or disconnected driver cannot retain unbounded identity maps.
    const pending = new Map<
      number,
      {
        done: Completion;
        started: number;
        detailBytes: number;
        includeResponse: boolean;
      }
    >();
    const maxPending = 4096;
    const maxAgeMs = 60_000;
    const maxPendingDetailBytes = 4 * 1024 * 1024;
    let pendingDetailBytes = 0;
    const take = (requestId: number) => {
      const entry = pending.get(requestId);
      if (entry) {
        pendingDetailBytes -= entry.detailBytes;
        pending.delete(requestId);
      }
      return entry;
    };
    const started = (event: CommandStartedEvent) => {
      const now = performance.now();
      for (const [key, entry] of pending) {
        if (now - entry.started < maxAgeMs && pending.size < maxPending) break;
        take(key);
        this.omitMongoObservation(
          now - entry.started >= maxAgeMs ? "age" : "capacity",
          1,
        );
      }
      let details: ServiceOperationDetails | undefined;
      let detailBytes = 0;
      try {
        if (this.traffic.debugEnabled) {
          details = mongoCommandDetails(event);
          detailBytes = Buffer.byteLength(JSON.stringify(details));
          if (pendingDetailBytes + detailBytes > maxPendingDetailBytes) {
            details = {
              ...details,
              data: {
                payloadOmitted: true,
                omissionReason: "pending_detail_byte_limit",
                limitBytes: maxPendingDetailBytes,
              },
            };
            detailBytes = Buffer.byteLength(JSON.stringify(details));
          }
        }
      } catch {
        /* A monitoring event must never interrupt database work. */
      }
      take(event.requestId);
      pendingDetailBytes += detailBytes;
      pending.set(event.requestId, {
        done: this.begin("mongodb", event.commandName, undefined, details),
        started: now,
        detailBytes,
        includeResponse: details?.includeResponse === true,
      });
    };
    const succeeded = (event: CommandSucceededEvent) => {
      const entry = take(event.requestId);
      if (!entry) return;
      let reply: unknown;
      try {
        if (entry.includeResponse && this.traffic.debugEnabled)
          reply = event.reply;
      } catch {
        /* Preserve completion even if reply inspection fails. */
      }
      entry.done(undefined, reply);
    };
    const failed = (event: CommandFailedEvent) => {
      const entry = take(event.requestId);
      if (entry) entry.done(event.failure);
      else
        this.emit({
          requestId: null,
          userId: null,
          source: "mongodb",
          component: "mongodb_driver",
          event: "service_operation",
          operation: operationName(event.commandName),
          level: "warn",
          result: "failure",
          errorType: errorClass(event.failure),
          correlationUnavailable: true,
        });
    };
    const heartbeatFailed = (event: { failure: Error }) =>
      this.connection("mongodb", "heartbeat", event.failure);
    const poolReady = () => this.connection("mongodb", "pool_ready");
    const poolClosed = () => {
      this.omitMongoObservation("pool_closed", pending.size);
      pending.clear();
      pendingDetailBytes = 0;
      this.connection("mongodb", "pool_closed");
    };
    client.on("commandStarted", started);
    client.on("commandSucceeded", succeeded);
    client.on("commandFailed", failed);
    client.on("serverHeartbeatFailed", heartbeatFailed);
    client.on("connectionPoolReady", poolReady);
    client.on("connectionPoolClosed", poolClosed);
    this.connection("mongodb", "monitor_attached");
    const cleanup = () => {
      client.off("commandStarted", started);
      client.off("commandSucceeded", succeeded);
      client.off("commandFailed", failed);
      client.off("serverHeartbeatFailed", heartbeatFailed);
      client.off("connectionPoolReady", poolReady);
      client.off("connectionPoolClosed", poolClosed);
      this.omitMongoObservation("shutdown", pending.size);
      pending.clear();
      pendingDetailBytes = 0;
      this.cleanups.delete(cleanup);
      this.observers.delete(client);
    };
    this.cleanups.add(cleanup);
    this.observers.set(client, cleanup);
    return cleanup;
  }

  async onModuleDestroy(): Promise<void> {
    this.stopping = true;
    for (const cleanup of this.cleanups) cleanup();
    if (this.mongoOmissionTimer) clearTimeout(this.mongoOmissionTimer);
    this.flushMongoOmissions();
    await this.sink?.close();
  }
}
