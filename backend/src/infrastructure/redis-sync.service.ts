import {
  HttpException,
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import Redis, { Command } from "ioredis";
import { boundedSetting } from "./bounded-work";
import { createHash, randomUUID } from "node:crypto";
import { HydratedRoomPayload } from "../models";
import { LocalServiceDiagnostics } from "./local-service-diagnostics";
import {
  retireSessionLua,
  dueSessionDisconnectsLua,
  claimSessionDisconnectLua,
  finishSessionDisconnectLua,
} from "./session-disconnect-scripts";

import {
  upsertUserRoomDeltaLua,
  deltaLua,
  invalidateLua,
  ensureEpochLua,
  limitAuthLua,
  limitRealtimeLua,
} from "./redis-scripts";
export { upsertUserRoomDeltaLua } from "./redis-scripts";

@Injectable()
export class RedisSyncService implements OnModuleInit, OnModuleDestroy {
  readonly client: Redis;
  private readonly prefix: string;
  private readonly config: ConfigService;
  private readonly logger = new Logger(RedisSyncService.name);
  private readonly detachDiagnostics: () => void;
  constructor(config: ConfigService, diagnostics: LocalServiceDiagnostics) {
    this.config = config;
    this.prefix = config.get<string>("REDIS_KEY_PREFIX", "");
    this.client = new Redis(config.getOrThrow<string>("REDIS_URL"), {
      maxRetriesPerRequest: 1,
      commandTimeout: boundedSetting(
        config,
        "REDIS_COMMAND_TIMEOUT_MS",
        1500,
        10000,
      ),
      connectTimeout: 3000,
      retryStrategy: (n) => Math.min(n * 200, 3000),
    });
    this.detachDiagnostics = diagnostics.observeRedis(this.client);
    this.client.on("error", () =>
      this.logger.warn(
        "Redis connection unavailable; clients will recover through a full sync",
      ),
    );
  }
  async onModuleInit() {
    await this.client.ping();
  }
  async ping(timeoutMs = 1500): Promise<void> {
    // A disconnected readiness probe must not join the reconnect/offline queue.
    if (this.client.status !== "ready")
      throw new Error("Redis is not connected");
    const command = new Command("ping", [], { replyEncoding: "utf8" });
    command.setTimeout(timeoutMs);
    try {
      this.client.sendCommand(command);
    } catch (error) {
      command.reject(
        error instanceof Error ? error : new Error("Redis unavailable"),
      );
    }
    const result = await command.promise;
    if (result !== "PONG") throw new Error("Unexpected Redis ping response");
  }
  async onModuleDestroy() {
    try {
      await this.client.quit();
    } finally {
      this.detachDiagnostics();
    }
  }
  keys(userId: string) {
    return ["meta", "dirty_rooms", "rooms_data"].map(
      (suffix) => `${this.prefix}user:${userId}:${suffix}`,
    );
  }
  private async deadlineCommand(
    name: string,
    args: (string | number)[],
    deadline: number,
  ): Promise<unknown> {
    if (deadline <= Date.now())
      return Promise.reject(new Error("Inbox deadline expired"));
    const command = new Command(name, args);
    command.setTimeout(
      Math.max(
        1,
        Math.min(
          boundedSetting(this.config, "REDIS_COMMAND_TIMEOUT_MS", 1500, 10000),
          deadline - Date.now(),
        ),
      ),
    );
    try {
      this.client.sendCommand(command);
    } catch (error) {
      command.reject(
        error instanceof Error ? error : new Error("Redis command failed"),
      );
    }
    return command.promise;
  }
  async upsert(
    userId: string,
    room: HydratedRoomPayload,
    deadline = Date.now() +
      boundedSetting(this.config, "REDIS_COMMAND_TIMEOUT_MS", 1500, 10000),
  ): Promise<string> {
    return String(
      await this.deadlineCommand(
        "eval",
        [
          upsertUserRoomDeltaLua,
          3,
          ...this.keys(userId),
          room.roomPts,
          room.roomId,
          JSON.stringify(room),
          randomUUID(),
          604800,
          deadline,
        ],
        deadline,
      ),
    );
  }
  async invalidate(
    userId: string,
    deadline = Date.now() +
      boundedSetting(this.config, "REDIS_COMMAND_TIMEOUT_MS", 1500, 10000),
  ) {
    if (deadline <= Date.now()) return;
    await this.deadlineCommand(
      "eval",
      [invalidateLua, 1, this.keys(userId)[0], deadline],
      deadline,
    ).catch(() => undefined);
  }
  async ensureEpoch(userId: string, pts: number): Promise<string> {
    return String(
      await this.client.eval(
        ensureEpochLua,
        1,
        this.keys(userId)[0],
        randomUUID(),
        pts,
      ),
    );
  }
  async delta(
    userId: string,
    sincePts: number,
    epoch: string,
  ): Promise<
    | { requiresFullSync: true }
    | {
        requiresFullSync: false;
        pts: number;
        epoch: string;
        rooms: HydratedRoomPayload[];
      }
  > {
    try {
      const result = await this.client.eval(
        deltaLua,
        3,
        ...this.keys(userId),
        sincePts,
        epoch,
      );
      if (!result) return { requiresFullSync: true };
      const parsed = JSON.parse(String(result)) as {
        requiresFullSync: false;
        pts: number;
        epoch: string;
        rooms: HydratedRoomPayload[] | object;
      };
      return {
        ...parsed,
        rooms: Array.isArray(parsed.rooms) ? parsed.rooms : [],
      };
    } catch {
      return { requiresFullSync: true };
    }
  }
  async limitAuth(ip: string) {
    const key = `${this.prefix}auth-rate:${createHash("sha256").update(ip).digest("hex")}`;
    const count = Number(await this.client.eval(limitAuthLua, 1, key));
    if (count > 30)
      throw new HttpException(
        "Too many authentication attempts. Try again in a minute.",
        429,
      );
  }
  private setting(key: string, fallback: number, minimum = 1) {
    const value = Number(this.config.get(key, fallback));
    if (!Number.isSafeInteger(value) || value < minimum || value > 86400000)
      throw new Error(`Invalid ${key}`);
    return value;
  }
  async limitRealtime(
    kind: "token" | "heartbeat" | "status" | "logout" | "upload",
    userId: string,
    ip: string,
  ) {
    const defaults = {
      token: [30, 120],
      heartbeat: [120, 600],
      status: [300, 1200],
      logout: [30, 120],
      upload: [30, 120],
    };
    const limits = defaults[kind];
    const tag = kind.toUpperCase();
    const userLimit = this.setting(`REALTIME_${tag}_USER_LIMIT`, limits[0]);
    const ipLimit = this.setting(`REALTIME_${tag}_IP_LIMIT`, limits[1]);
    const digest = createHash("sha256").update(ip).digest("hex");
    const allowed = await this.client.eval(
      limitRealtimeLua,
      2,
      `${this.prefix}realtime-rate:${kind}:user:${userId}`,
      `${this.prefix}realtime-rate:${kind}:ip:${digest}`,
      userLimit,
      ipLimit,
    );
    if (Number(allowed) !== 1)
      throw new HttpException("Realtime request limit exceeded", 429);
  }
  sessionRetiredKey(userId: string, sessionHash: string) {
    return `${this.prefix}auth-session:${userId}:retired:${sessionHash}`;
  }
  async isSessionRetired(userId: string, sessionHash: string) {
    // Honor existing revocations until their original TTL expires after upgrade.
    return (
      (await this.client.exists(
        this.sessionRetiredKey(userId, sessionHash),
        `${this.prefix}presence:${userId}:retired:${sessionHash}`,
      )) > 0
    );
  }
  async retireSession(userId: string, sessionHash: string) {
    await this.client.eval(
      retireSessionLua,
      3,
      this.sessionRetiredKey(userId, sessionHash),
      this.sessionDisconnectKey(userId, sessionHash),
      this.sessionDisconnectQueueKey(),
      `${userId}:${sessionHash}`,
    );
  }
  sessionDisconnectQueueKey() {
    return `${this.prefix}auth-session:disconnect:due`;
  }
  sessionDisconnectKey(userId: string, sessionHash: string) {
    return `${this.prefix}auth-session:${userId}:disconnect-job:${sessionHash}`;
  }
  async dueSessionDisconnects(limit: number): Promise<string[]> {
    return (await this.client.eval(
      dueSessionDisconnectsLua,
      1,
      this.sessionDisconnectQueueKey(),
      limit,
    )) as string[];
  }
  async claimSessionDisconnect(
    userId: string,
    sessionHash: string,
    lease: string,
  ) {
    const attempts = await this.client.eval(
      claimSessionDisconnectLua,
      2,
      this.sessionDisconnectQueueKey(),
      this.sessionDisconnectKey(userId, sessionHash),
      `${userId}:${sessionHash}`,
      lease,
    );
    return attempts === null ? null : Number(attempts);
  }
  async finishSessionDisconnect(
    userId: string,
    sessionHash: string,
    lease: string,
    success: boolean,
    retryMs: number,
  ) {
    await this.client.eval(
      finishSessionDisconnectLua,
      2,
      this.sessionDisconnectQueueKey(),
      this.sessionDisconnectKey(userId, sessionHash),
      `${userId}:${sessionHash}`,
      lease,
      success ? "1" : "0",
      retryMs,
    );
  }
}
