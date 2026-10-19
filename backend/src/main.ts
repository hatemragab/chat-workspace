import "reflect-metadata";
import { NestFactory } from "@nestjs/core";
import { ValidationPipe } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { SwaggerModule } from "@nestjs/swagger";
import helmet from "helmet";
import type { Request, Response, NextFunction } from "express";
import { AppModule } from "./app.module";
import { ProblemFilter } from "./errors.filter";
import { openApiDocument } from "./openapi";
import { createHttpRequestLogger } from "./infrastructure/http-logging";
import { DebugTrafficLogger } from "./infrastructure/debug-traffic-logger";
export async function createApplication() {
  const app = await NestFactory.create(AppModule, {
    logger: ["error", "warn", "log"],
  });
  const config = app.get(ConfigService);
  app.use(
    createHttpRequestLogger({
      logger: app.get(DebugTrafficLogger),
    }),
  );
  app.use((_req: Request, res: Response, next: NextFunction) => {
    // Include authorization/not-found media responses; permissions can change
    // after attachment, deletion or account switching. Controllers may narrow
    // successful responses further to private, no-store.
    res.setHeader("Cache-Control", "no-store");
    next();
  });
  app.use(
    helmet({
      crossOriginResourcePolicy: { policy: "cross-origin" },
      contentSecurityPolicy: false,
    }),
  );
  const origins = config
    .get<string>("CORS_ORIGINS")
    ?.split(",")
    .map((x) => x.trim())
    .filter(Boolean);
  app.enableCors({
    origin: origins?.length
      ? origins
      : config.get("NODE_ENV") === "development",
    methods: ["GET", "HEAD", "POST", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: [
      "Content-Type",
      "Authorization",
      "x-device-id",
      "x-request-id",
    ],
    exposedHeaders: ["X-Request-ID", "Retry-After"],
  });
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
      transformOptions: { enableImplicitConversion: false },
    }),
  );
  app.useGlobalFilters(new ProblemFilter());
  SwaggerModule.setup("docs", app, openApiDocument);
  app.enableShutdownHooks();
  return app;
}
async function main() {
  const app = await createApplication();
  const config = app.get(ConfigService);
  await app.listen(
    config.get<number>("PORT", 3000),
    config.get<string>(
      "HOST",
      config.get("NODE_ENV") === "development" ? "0.0.0.0" : "127.0.0.1",
    ),
  );
}
if (require.main === module)
  void main().catch(() => {
    process.stderr.write(
      "Backend startup failed. Check required configuration and local service availability.\n",
    );
    process.exitCode = 1;
  });
