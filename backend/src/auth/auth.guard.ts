import {
  CanActivate,
  createParamDecorator,
  ExecutionContext,
  Injectable,
  SetMetadata,
  UnauthorizedException,
} from "@nestjs/common";
import { Reflector } from "@nestjs/core";
import { JwtService } from "@nestjs/jwt";
import { ConfigService } from "@nestjs/config";
import { Request } from "express";
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
    try {
      const payload = await this.jwt.verifyAsync<{ sub: string }>(match[1], {
        secret: this.config.getOrThrow<string>("JWT_SECRET"),
        algorithms: ["HS256"],
        issuer: "chat-backend",
        audience: "chat-client",
      });
      if (
        !/^[0-9a-f]{24}$/i.test(payload.sub) ||
        !(await this.db.users.exists({ _id: payload.sub }))
      )
        throw new Error("Invalid subject");
      req.userId = payload.sub;
      return true;
    } catch {
      throw new UnauthorizedException("Invalid or expired access token");
    }
  }
}
