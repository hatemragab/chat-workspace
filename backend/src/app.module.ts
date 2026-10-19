import { Module } from "@nestjs/common";
import { ConfigModule, ConfigService } from "@nestjs/config";
import { MongooseModule } from "@nestjs/mongoose";
import { HealthController } from "./health.controller";
import { InfrastructureModule } from "./infrastructure/infrastructure.module";
import { AuthModule } from "./auth/auth.module";
import { UsersModule } from "./users/users.module";
import { ChatModule } from "./chat/chat.module";
import { PresenceModule } from "./presence/presence.module";
import { localServiceLoggingEnabled } from "./infrastructure/local-service-diagnostics";
function validateEnvironment(values: Record<string, unknown>) {
  const config = { PORT: 3000, NODE_ENV: "development", ...values };
  for (const key of [
    "MONGODB_URI",
    "REDIS_URL",
    "JWT_SECRET",
    "CENTRIFUGO_TOKEN_HMAC_SECRET_KEY",
    "CENTRIFUGO_API_URL",
    "CENTRIFUGO_API_KEY",
    "CENTRIFUGO_PROXY_SECRET",
  ]) {
    if (
      typeof config[key as keyof typeof config] !== "string" ||
      !String(config[key as keyof typeof config]).trim()
    )
      throw new Error(`Required configuration missing: ${key}`);
  }
  for (const key of [
    "CENTRIFUGO_TOKEN_HMAC_SECRET_KEY",
    "CENTRIFUGO_API_KEY",
    "CENTRIFUGO_PROXY_SECRET",
  ])
    if (String(values[key]).length < 32)
      throw new Error(`${key} must contain at least 32 characters`);
  if (values.JWT_SECRET === values.CENTRIFUGO_TOKEN_HMAC_SECRET_KEY)
    throw new Error("Access and realtime JWT secrets must be independent");
  if (String(values.JWT_SECRET).length < 32)
    throw new Error("JWT_SECRET must contain at least 32 characters");
  if (config.NODE_ENV === "production" && !values.CORS_ORIGINS)
    throw new Error("CORS_ORIGINS is required in production");
  const budgets: Record<string, number> = {
    REDIS_COMMAND_TIMEOUT_MS: 10000,
    INBOX_FANOUT_CONCURRENCY: 64,
    INBOX_FANOUT_MAX_WAITING: 10000,
    INBOX_FANOUT_DEADLINE_MS: 60000,
    REALTIME_PUBLISH_TIMEOUT_MS: 10000,
    UPLOAD_MAX_CONCURRENT: 64,
    UPLOAD_MAX_CONCURRENT_PER_USER: 16,
    UPLOAD_REQUEST_TIMEOUT_MS: 120000,
    UPLOAD_MAX_PIXELS: 64000000,
    UPLOAD_MAX_DIMENSION: 32768,
    UPLOAD_MAX_FRAMES: 1000,
    UPLOAD_ORPHAN_RETENTION_DAYS: 3650,
    LEGACY_DIRECTORY_MAX_USERS: 100000,
    LEGACY_PINNED_MAX_ROOMS: 100000,
  };
  for (const [name, max] of Object.entries(budgets)) {
    if (values[name] === undefined) continue;
    const value = Number(values[name]);
    if (!Number.isSafeInteger(value) || value < 1 || value > max)
      throw new Error(`Invalid ${name}`);
  }
  const port = Number(config.PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65535)
    throw new Error("Invalid PORT");
  return { ...config, PORT: port };
}
@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: ["../centrifugo/.env", ".env"],
      validate: validateEnvironment,
    }),
    MongooseModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => ({
        uri: process.env.MONGODB_URI,
        serverSelectionTimeoutMS: 5000,
        maxPoolSize: 30,
        // DatabaseService.onModuleInit owns the awaited index initialization.
        autoIndex: false,
        monitorCommands: localServiceLoggingEnabled(
          config.get("LOCAL_SERVICE_LOG_FILE"),
        ),
      }),
    }),
    InfrastructureModule,
    AuthModule,
    UsersModule,
    ChatModule,
    PresenceModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
