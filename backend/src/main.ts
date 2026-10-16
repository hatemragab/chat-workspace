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
export async function createApplication() {
  const app = await NestFactory.create(AppModule, {
    logger: ["error", "warn", "log"],
  });
  const config = app.get(ConfigService);
  app.use(
    createHttpRequestLogger({
      enabled: config.get<string>("HTTP_LOGGING_ENABLED", "true") !== "false",
    }),
  );
  app.use((req: Request, res: Response, next: NextFunction) => {
    if (!req.path.startsWith("/public/uploads/"))
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
    methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: [
      "Content-Type",
      "Authorization",
      "x-device-id",
      "x-request-id",
    ],
    exposedHeaders: ["X-Request-ID"],
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
  await app.listen(app.get(ConfigService).get<number>("PORT", 3000), "0.0.0.0");
}
if (require.main === module)
  void main().catch(() => {
    process.stderr.write(
      "Backend startup failed. Check required configuration and local service availability.\n",
    );
    process.exitCode = 1;
  });
