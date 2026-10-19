import {
  CanActivate,
  createParamDecorator,
  ExecutionContext,
  Injectable,
  SetMetadata,
  ServiceUnavailableException,
  UnauthorizedException,
} from "@nestjs/common";
import { Reflector } from "@nestjs/core";
import { JwtService } from "@nestjs/jwt";
import { ConfigService } from "@nestjs/config";
import { Request } from "express";
import { RedisSyncService } from "../infrastructure/redis-sync.service";
import { sessionHash } from "./session";
import { DatabaseService } from "../infrastructure/database.service";
export const Public = () => SetMetadata("public", true);
export type AuthRequest = Request & { userId: string };
export const CurrentUser = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): string =>
    ctx.switchToHttp().getRequest<AuthRequest>().userId,
);
@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
    private readonly db: DatabaseService,
    private readonly redis: RedisSyncService,
  ) {}
  async canActivate(ctx: ExecutionContext) {
    if (
      this.reflector.getAllAndOverride<boolean>("public", [
        ctx.getHandler(),
        ctx.getClass(),
      ])
    )
      return true;
    const req = ctx.switchToHttp().getRequest<AuthRequest>();
    const match = /^Bearer ([^ ]+)$/.exec(req.headers.authorization ?? "");
    if (!match) throw new UnauthorizedException();
    let subject: string;
    try {
      const payload = await this.jwt.verifyAsync<{ sub: string }>(match[1], {
        secret: this.config.getOrThrow<string>("JWT_SECRET"),
        algorithms: ["HS256"],
        issuer: "chat-backend",
        audience: "chat-client",
      });
      if (
        typeof payload.sub !== "string" ||
        !/^[0-9a-f]{24}$/i.test(payload.sub)
      )
        throw new Error("Invalid subject");
      subject = payload.sub.toLowerCase();
    } catch {
      throw new UnauthorizedException("Invalid or expired access token");
    }
    try {
      if (!(await this.db.users.exists({ _id: subject })))
        throw new UnauthorizedException("Invalid or expired access token");
      if (
        !(req.method === "POST" && req.path === "/presence/offline") &&
        (await this.redis.isSessionRetired(
          subject,
          sessionHash(req.headers.authorization!),
        ))
      )
        throw new UnauthorizedException("Session retired");
      req.userId = subject;
      return true;
    } catch (error) {
      if (error instanceof UnauthorizedException) throw error;
      throw new ServiceUnavailableException(
        "Authentication service temporarily unavailable",
      );
    }
  }
}
