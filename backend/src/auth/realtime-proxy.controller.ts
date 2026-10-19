import {
  Body,
  Controller,
  ForbiddenException,
  Headers,
  HttpCode,
  Post,
  Req,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { JwtService } from "@nestjs/jwt";
import { ApiExcludeController } from "@nestjs/swagger";
import { timingSafeEqual } from "node:crypto";
import { Request } from "express";
import { DatabaseService } from "../infrastructure/database.service";
import { RedisSyncService } from "../infrastructure/redis-sync.service";
import { LastSeenService } from "../infrastructure/last-seen.service";
import { Public } from "./auth.guard";

type SessionMeta = { sessionId: string; sessionExpiresAt: number };
type RealtimeClaims = {
  exp: number;
  iat: number;
  sub: string;
  channels: string[];
  meta: SessionMeta;
};
const record = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};

@ApiExcludeController()
@Public()
@Controller("internal/realtime")
export class RealtimeProxyController {
  constructor(
    private readonly config: ConfigService,
    private readonly jwt: JwtService,
    private readonly redis: RedisSyncService,
    private readonly db: DatabaseService,
    private readonly lastSeen: LastSeenService,
  ) {}

  private authenticateProxy(request: Request, supplied: string | undefined) {
    const expected = this.config.getOrThrow<string>("CENTRIFUGO_PROXY_SECRET");
    const local = ["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(
      request.socket.remoteAddress ?? "",
    );
    if (
      !local ||
      !supplied ||
      Buffer.byteLength(supplied) !== Buffer.byteLength(expected) ||
      !timingSafeEqual(Buffer.from(supplied), Buffer.from(expected))
    )
      throw new ForbiddenException();
  }
  private async validSession(user: unknown, meta: unknown) {
    const data = record(meta);
    return (
      typeof user === "string" &&
      /^[a-f0-9]{24}$/.test(user) &&
      typeof data.sessionId === "string" &&
      /^[a-f0-9]{64}$/.test(data.sessionId) &&
      typeof data.sessionExpiresAt === "number" &&
      Number.isSafeInteger(data.sessionExpiresAt) &&
      data.sessionExpiresAt > Math.floor(Date.now() / 1000) &&
      !(await this.redis.isSessionRetired(user, data.sessionId)) &&
      Boolean(await this.db.users.exists({ _id: user }))
    );
  }
  @Post("connect") @HttpCode(200) async connect(
    @Body() body: unknown,
    @Req() request: Request,
    @Headers("x-api-key") key?: string,
  ) {
    this.authenticateProxy(request, key);
    const token = record(record(body).data).token;
    if (typeof token !== "string" || token.length > 4096)
      return { disconnect: { code: 4501, reason: "unauthorized" } };
    let claims: RealtimeClaims;
    try {
      claims = await this.jwt.verifyAsync<RealtimeClaims>(token, {
        secret: this.config.getOrThrow<string>(
          "CENTRIFUGO_TOKEN_HMAC_SECRET_KEY",
        ),
        algorithms: ["HS256"],
        issuer: "chat-api",
        audience: "chat-realtime",
      });
    } catch {
      return { disconnect: { code: 4501, reason: "unauthorized" } };
    }
    const now = Math.floor(Date.now() / 1000);
    if (
      !Number.isSafeInteger(claims.exp) ||
      !Number.isSafeInteger(claims.iat) ||
      claims.exp <= now ||
      claims.iat > now + 5 ||
      claims.exp - claims.iat > 1800 ||
      !Array.isArray(claims.channels) ||
      claims.channels.length !== 1 ||
      claims.channels[0] !== `inbox:user#${claims.sub}` ||
      !(await this.validSession(claims.sub, claims.meta))
    )
      return { disconnect: { code: 4501, reason: "unauthorized" } };
    await this.lastSeen.track(claims.sub);
    return {
      result: {
        user: claims.sub,
        channels: claims.channels,
        info: { sessionId: claims.meta.sessionId },
        meta: claims.meta,
        expire_at: claims.meta.sessionExpiresAt,
      },
    };
  }
  @Post("refresh") @HttpCode(200) async refresh(
    @Body() body: unknown,
    @Req() request: Request,
    @Headers("x-api-key") key?: string,
  ) {
    this.authenticateProxy(request, key);
    // Compatibility for an older provider during restart: never renew a socket.
    // Current Centrifugo configuration disables this callback altogether.
    return { result: { expired: true } };
  }
}
