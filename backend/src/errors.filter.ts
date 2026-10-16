import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  Logger,
} from "@nestjs/common";
import { Response } from "express";
import {
  CorrelatedRequest,
  ensureRequestId,
} from "./infrastructure/http-logging";
@Catch()
export class ProblemFilter implements ExceptionFilter {
  private readonly logger = new Logger(ProblemFilter.name);
  catch(error: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const req = ctx.getRequest<CorrelatedRequest>();
    const res = ctx.getResponse<Response>();
    const requestId = ensureRequestId(req, res);
    const status = error instanceof HttpException ? error.getStatus() : 500;
    const body = error instanceof HttpException ? error.getResponse() : null;
    const message =
      typeof body === "string"
        ? body
        : body && typeof body === "object" && "message" in body
          ? body.message
          : "Internal server error";
    // No raw exception message, query, uploaded filename, request body or headers enter logs.
    if (status >= 500)
      this.logger.error(
        JSON.stringify({
          event: "http_error",
          requestId,
          status,
          errorType: "InternalError",
        }),
      );
    if (status === 429) res.setHeader("Retry-After", "60");
    res
      .status(status)
      .type("application/problem+json")
      .json({
        type: "about:blank",
        title:
          status >= 500
            ? "Internal server error"
            : Array.isArray(message)
              ? "Validation failed"
              : String(message),
        status,
        detail: Array.isArray(message) ? message.join("; ") : String(message),
        message,
        instance: req.path,
        requestId,
      });
  }
}
