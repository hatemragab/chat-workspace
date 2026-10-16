import { Body, Controller, Get, HttpCode, Post, Query } from "@nestjs/common";
import { ApiBearerAuth, ApiTags } from "@nestjs/swagger";
import { CurrentUser } from "../auth/auth.guard";
import { PresenceQuery } from "../chat/dto";
import { DatabaseService } from "../infrastructure/database.service";
import { RedisSyncService } from "../infrastructure/redis-sync.service";
@ApiTags("presence")
@ApiBearerAuth()
@Controller("presence")
export class PresenceController {
  constructor(
    private readonly db: DatabaseService,
    private readonly redis: RedisSyncService,
  ) {}
  @Post("heartbeat") @HttpCode(200) async heartbeat(
    @CurrentUser() user: string,
  ) {
    await this.redis.client.set(this.redis.presenceKey(user), "1", "EX", 45);
    await this.db.users.updateOne(
      { _id: user },
      { $set: { lastSeenAt: new Date() } },
    );
    return { ok: true };
  }
  @Post("status") @HttpCode(200) statusPost(@Body() query: PresenceQuery) {
    return this.status(query);
  }
  @Get("status") async status(@Query() query: PresenceQuery) {
    const ids = [...new Set(query.userIds)];
    if (!ids.length) return { statuses: {} };
    const values = await this.redis.client.mget(
      ...ids.map((id) => this.redis.presenceKey(id)),
    );
    return {
      statuses: Object.fromEntries(ids.map((id, i) => [id, values[i] === "1"])),
    };
  }
}
