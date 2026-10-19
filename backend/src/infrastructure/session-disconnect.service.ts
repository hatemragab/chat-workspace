import {
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
  Optional,
} from "@nestjs/common";
import { randomUUID } from "node:crypto";
import { RedisSyncService } from "./redis-sync.service";
import { CentrifugoService } from "./centrifugo.service";
import { LastSeenService } from "./last-seen.service";

/** Only retired logins create provider work. Pending work survives API restarts. */
@Injectable()
export class SessionDisconnectService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(SessionDisconnectService.name);
  private timer?: NodeJS.Timeout;
  private stopped = false;
  private polling = false;
  private readonly active = new Set<Promise<void>>();
  constructor(
    private readonly redis: RedisSyncService,
    private readonly centrifugo: CentrifugoService,
    @Optional() private readonly lastSeen?: LastSeenService,
  ) {}

  onModuleInit() {
    this.stopped = false;
    this.timer = setInterval(() => void this.drain(), 1000);
    this.timer.unref();
    void this.drain();
  }

  async onModuleDestroy() {
    this.stopped = true;
    clearInterval(this.timer);
    await Promise.allSettled([...this.active]);
  }

  async drain() {
    if (this.stopped || this.polling || this.active.size >= 4) return;
    this.polling = true;
    try {
      const jobs = await this.redis.dueSessionDisconnects(4 - this.active.size);
      await Promise.all(
        jobs.map((job) => {
          const [userId, sessionId] = job.split(":");
          return this.disconnect(userId, sessionId);
        }),
      );
    } catch {
      this.logger.warn(
        "Session disconnect queue unavailable; pending work will retry",
      );
    } finally {
      this.polling = false;
    }
  }

  async disconnect(userId: string, sessionId: string) {
    if (this.stopped || this.active.size >= 4) return;
    const work = this.attempt(userId, sessionId);
    this.active.add(work);
    try {
      await work;
    } finally {
      this.active.delete(work);
    }
  }

  private async attempt(userId: string, sessionId: string) {
    const lease = randomUUID();
    try {
      const attempts = await this.redis.claimSessionDisconnect(
        userId,
        sessionId,
        lease,
      );
      if (attempts === null) return;
      const success = await this.centrifugo.disconnectSession(
        userId,
        sessionId,
      );
      if (success) await this.lastSeen?.checkSoon(userId);
      const retryMs = Math.min(30000, 1000 * 2 ** Math.min(attempts - 1, 5));
      await this.redis.finishSessionDisconnect(
        userId,
        sessionId,
        lease,
        success,
        retryMs,
      );
    } catch {
      // An ambiguous claim/ack stays visible after its Redis lease expires.
      // Never include session identifiers or provider errors in this warning.
      this.logger.warn(
        "Session disconnect incomplete; retained work will retry",
      );
    }
  }
}
