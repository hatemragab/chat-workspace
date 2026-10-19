import {
  Injectable,
  Logger,
  OnModuleInit,
  OnModuleDestroy,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { randomUUID } from "node:crypto";
import { boundedSetting } from "./bounded-work";
import { RedisSyncService } from "./redis-sync.service";
import { DatabaseService } from "./database.service";
import { CentrifugoService } from "./centrifugo.service";
import {
  trackLastSeenLua,
  claimLastSeenLua,
  finishLastSeenLua,
  checkLastSeenSoonLua,
} from "./last-seen-scripts";

type Observation = { userId: string; version: string; lastOnlineAt: number };

/** Records last confirmed online time after all of a user's sockets disappear.
 * This is bounded snapshot observation, never an application online/offline lease.
 */
@Injectable()
export class LastSeenService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(LastSeenService.name);
  private readonly keys: [string, string];
  private readonly intervalMs: number;
  private timer?: NodeJS.Timeout;
  private running?: Promise<void>;
  private stopped = false;
  constructor(
    config: ConfigService,
    private readonly redis: RedisSyncService,
    private readonly db: DatabaseService,
    private readonly centrifugo: CentrifugoService,
  ) {
    const prefix = config.get<string>("REDIS_KEY_PREFIX", "");
    this.keys = [`${prefix}last-seen:due`, `${prefix}last-seen:observations`];
    this.intervalMs =
      boundedSetting(config, "LAST_SEEN_CHECK_SECONDS", 30, 300) * 1000;
  }
  onModuleInit() {
    this.stopped = false;
    this.timer = setInterval(() => void this.observe(), 5000);
    this.timer.unref();
    void this.observe();
  }
  async onModuleDestroy() {
    this.stopped = true;
    clearInterval(this.timer);
    await this.running;
  }
  async track(userId: string) {
    await this.redis.client.eval(
      trackLastSeenLua,
      2,
      ...this.keys,
      userId,
      randomUUID(),
      this.intervalMs,
    );
  }
  async checkSoon(userId: string) {
    await this.redis.client.eval(checkLastSeenSoonLua, 2, ...this.keys, userId);
  }
  async observe() {
    if (this.stopped || this.running) return;
    this.running = this.batch();
    try {
      await this.running;
    } finally {
      this.running = undefined;
    }
  }
  private async batch() {
    const lease = randomUUID();
    let observations: Observation[] = [];
    try {
      const raw = String(
        await this.redis.client.eval(claimLastSeenLua, 2, ...this.keys, lease),
      );
      const parsed: unknown = JSON.parse(raw);
      // Redis Lua encodes an empty table as {}, not [].
      observations = Array.isArray(parsed) ? (parsed as Observation[]) : [];
      if (!observations.length) return;
      const statuses = await this.centrifugo.presenceStatuses(
        observations.map(({ userId }) => userId),
        "last_seen_observer",
      );
      if (
        observations.some(({ userId }) => typeof statuses[userId] !== "boolean")
      )
        throw new Error("Incomplete presence snapshot");
      const offline = observations.filter(
        ({ userId }) => statuses[userId] === false,
      );
      if (offline.length)
        await this.db.users.bulkWrite(
          offline.map(({ userId, lastOnlineAt }) => ({
            updateOne: {
              filter: { _id: userId },
              update: { $max: { lastSeenAt: new Date(lastOnlineAt) } },
              timestamps: false,
            },
          })),
          { maxTimeMS: 5000 },
        );
      await Promise.all(
        observations.map((observation) =>
          this.finish(
            observation,
            lease,
            statuses[observation.userId] ? "online" : "offline",
          ),
        ),
      );
    } catch {
      // Provider failures never manufacture offline status. A failed MongoDB
      // write or ambiguous Redis acknowledgement retains retryable observations.
      this.logger.warn(
        "Last-seen observation unavailable; retained users will retry",
      );
      await Promise.allSettled(
        observations.map((observation) =>
          this.finish(observation, lease, "retry"),
        ),
      );
    }
  }
  private async finish(
    observation: Observation,
    lease: string,
    result: "online" | "offline" | "retry",
  ) {
    await this.redis.client.eval(
      finishLastSeenLua,
      2,
      ...this.keys,
      observation.userId,
      observation.version,
      lease,
      result,
      this.intervalMs,
    );
  }
}
