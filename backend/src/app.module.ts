import {
  Controller,
  Get,
  Module,
  ServiceUnavailableException,
} from "@nestjs/common";
import { ConfigModule } from "@nestjs/config";
import { MongooseModule } from "@nestjs/mongoose";
import { ServeStaticModule } from "@nestjs/serve-static";
import { join } from "node:path";
import { DatabaseService } from "./infrastructure/database.service";
import { RedisSyncService } from "./infrastructure/redis-sync.service";
import { Public } from "./auth/auth.guard";
import { InfrastructureModule } from "./infrastructure/infrastructure.module";
import { AuthModule } from "./auth/auth.module";
import { UsersModule } from "./users/users.module";
import { ChatModule } from "./chat/chat.module";
import { PresenceModule } from "./presence/presence.module";
function validateEnvironment(values: Record<string, unknown>) {
  const config = { PORT: 3000, NODE_ENV: "development", ...values };
  for (const key of [
    "MONGODB_URI",
    "REDIS_URL",
    "JWT_SECRET",
    "CENTRIFUGO_TOKEN_HMAC_SECRET_KEY",
    "CENTRIFUGO_API_URL",
    "CENTRIFUGO_API_KEY",
  ]) {
    if (
      typeof config[key as keyof typeof config] !== "string" ||
      !String(config[key as keyof typeof config]).trim()
    )
      throw new Error(`Required configuration missing: ${key}`);
  }
  if (String(values.JWT_SECRET).length < 32)
    throw new Error("JWT_SECRET must contain at least 32 characters");
  if (config.NODE_ENV === "production" && !values.CORS_ORIGINS)
    throw new Error("CORS_ORIGINS is required in production");
  const port = Number(config.PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65535)
    throw new Error("Invalid PORT");
  return { ...config, PORT: port };
}
@Controller()
class HealthController {
  constructor(
    private readonly db: DatabaseService,
    private readonly redis: RedisSyncService,
  ) {}
  @Public() @Get("health") async health() {
    try {
      await this.db.connection.db!.admin().ping();
      await this.redis.client.ping();
      return { status: "ok", mongo: "ok", redis: "ok" };
    } catch {
      throw new ServiceUnavailableException(
        "A required service is unavailable",
      );
    }
  }
}
@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, validate: validateEnvironment }),
    MongooseModule.forRootAsync({
      useFactory: () => ({
        uri: process.env.MONGODB_URI,
        serverSelectionTimeoutMS: 5000,
        maxPoolSize: 30,
      }),
    }),
    InfrastructureModule,
    AuthModule,
    UsersModule,
    ChatModule,
    PresenceModule,
    ServeStaticModule.forRoot({
      rootPath: join(process.cwd(), "public/uploads"),
      serveRoot: "/public/uploads",
      serveStaticOptions: {
        index: false,
        dotfiles: "deny",
        fallthrough: false,
        setHeaders: (res) => {
          res.setHeader("X-Content-Type-Options", "nosniff");
          res.setHeader("Content-Security-Policy", "default-src 'none'");
        },
      },
    }),
  ],
  controllers: [HealthController],
})
export class AppModule {}
