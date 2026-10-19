import {
  Controller,
  Get,
  Head,
  ServiceUnavailableException,
} from "@nestjs/common";
import { Public } from "./auth/auth.guard";
import { DatabaseService } from "./infrastructure/database.service";
import { RedisSyncService } from "./infrastructure/redis-sync.service";

@Controller()
export class HealthController {
  constructor(
    private readonly db: DatabaseService,
    private readonly redis: RedisSyncService,
  ) {}
  @Public() @Head("health") head() {
    return this.health();
  }
  @Public() @Get("health") async health() {
    try {
      await Promise.all([this.db.ping(1500), this.redis.ping(1500)]);
      return { status: "ok", mongo: "ok", redis: "ok" };
    } catch {
      throw new ServiceUnavailableException(
        "A required service is unavailable",
      );
    }
  }
}
