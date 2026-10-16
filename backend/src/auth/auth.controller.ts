import { Body, Controller, Get, HttpCode, Post, Req } from "@nestjs/common";
import { ApiBearerAuth, ApiTags } from "@nestjs/swagger";
import { Request } from "express";
import { AuthService } from "./auth.service";
import { CurrentUser, Public } from "./auth.guard";
import { DebugLoginDto, LoginDto, SignupDto } from "./dto";
import { RedisSyncService } from "../infrastructure/redis-sync.service";
@ApiTags("auth")
@Controller("auth")
export class AuthController {
  constructor(
    private readonly auth: AuthService,
    private readonly redis: RedisSyncService,
  ) {}
  @Public() @Get("debug-users") debugUsers() {
    return this.auth.debugUsers();
  }
  @Public() @Post("debug-login") @HttpCode(200) debugLogin(
    @Body() dto: DebugLoginDto,
  ) {
    return this.auth.debugLogin(dto.debugUserNumber);
  }
  @Public() @Post("signup") async signup(
    @Body() dto: SignupDto,
    @Req() req: Request,
  ) {
    await this.redis.limitAuth(req.ip ?? "unknown");
    return this.auth.signup(dto);
  }
  @Public() @Post("login") @HttpCode(200) async login(
    @Body() dto: LoginDto,
    @Req() req: Request,
  ) {
    await this.redis.limitAuth(req.ip ?? "unknown");
    return this.auth.login(dto);
  }
  @ApiBearerAuth() @Post("centrifugo-token") @HttpCode(200) async token(
    @CurrentUser() userId: string,
  ) {
    return { centrifugoToken: await this.auth.centrifugoToken(userId) };
  }
}
