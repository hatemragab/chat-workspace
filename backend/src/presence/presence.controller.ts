import {
  Body,
  BadRequestException,
  Controller,
  Get,
  Headers,
  HttpCode,
  HttpException,
  Post,
  Query,
  Req,
} from "@nestjs/common";
import { ApiBearerAuth, ApiTags } from "@nestjs/swagger";
import { Request } from "express";
import { SessionDisconnectService } from "../infrastructure/session-disconnect.service";
import { PresenceService } from "./presence.service";
import { sessionHash } from "../auth/session";
import { CurrentUser } from "../auth/auth.guard";
import { PresenceQuery } from "../chat/dto";
import { RedisSyncService } from "../infrastructure/redis-sync.service";

@ApiTags("presence")
@ApiBearerAuth()
@Controller("presence")
export class PresenceController {
  constructor(
    private readonly redis: RedisSyncService,
    private readonly presence: PresenceService,
    private readonly disconnects: SessionDisconnectService,
  ) {}
  private requireEmptyBody(body: unknown) {
    if (
      body != null &&
      (typeof body !== "object" ||
        Array.isArray(body) ||
        Object.keys(body).length)
    )
      throw new BadRequestException(
        "Presence session operations accept no body",
      );
  }
  @Post("heartbeat") @HttpCode(200) async heartbeat(
    @CurrentUser() user: string,
    @Headers("authorization") authorization: string,
    @Req() request: Request,
    @Body() body: unknown,
  ) {
    this.requireEmptyBody(body);
    await this.redis.limitRealtime("heartbeat", user, request.ip ?? "unknown");
    // Compatibility endpoint only. Centrifugo owns connection presence;
    // older clients may call this, but it creates no presence keys or leases.
    return { ok: true };
  }
  @Post("offline") @HttpCode(200) async offline(
    @CurrentUser() user: string,
    @Headers("authorization") authorization: string,
    @Req() request: Request,
    @Body() body: unknown,
  ) {
    this.requireEmptyBody(body);
    const id = sessionHash(authorization);
    await this.redis.retireSession(user, id);
    try {
      await this.redis.limitRealtime("logout", user, request.ip ?? "unknown");
    } catch (error) {
      if (error instanceof HttpException && error.getStatus() === 429)
        return { ok: true };
      throw error;
    }
    // Retirement atomically queued this work before the optional immediate pass.
    // Quota exhaustion, provider failure and API restarts cannot discard it.
    await this.disconnects.disconnect(user, id);
    return { ok: true };
  }
  @Post("status") @HttpCode(200) statusPost(
    @Body() query: PresenceQuery,
    @CurrentUser() user: string,
    @Req() request: Request,
  ) {
    return this.status(query, user, request);
  }
  @Get("status") async status(
    @Query() query: PresenceQuery,
    @CurrentUser() user: string,
    @Req() request: Request,
  ) {
    await this.redis.limitRealtime("status", user, request.ip ?? "unknown");
    return this.presence.statuses(user, [...new Set(query.userIds)]);
  }
}
