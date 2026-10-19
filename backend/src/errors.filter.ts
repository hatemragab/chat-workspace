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
const problemCodes: Readonly<Record<number, string>> = {
  400: "BAD_REQUEST",
  401: "AUTHENTICATION_REQUIRED",
  403: "FORBIDDEN",
  404: "NOT_FOUND",
  408: "REQUEST_TIMEOUT",
  409: "CONFLICT",
  410: "GONE",
  413: "PAYLOAD_TOO_LARGE",
  415: "UNSUPPORTED_MEDIA_TYPE",
  422: "VALIDATION_FAILED",
  429: "RATE_LIMITED",
  500: "INTERNAL_ERROR",
  502: "BAD_GATEWAY",
  503: "SERVICE_UNAVAILABLE",
  504: "GATEWAY_TIMEOUT",
};
const retryableStatuses = new Set([408, 429, 500, 502, 503, 504]);
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
    const code =
      status === 400 && Array.isArray(message)
        ? "VALIDATION_FAILED"
        : (problemCodes[status] ?? `HTTP_${status}`);
    const retryable = retryableStatuses.has(status);
    // No raw exception message, query, uploaded filename, request body or headers enter logs.
    if (status >= 500)
      this.logger.error(
        JSON.stringify({
          event: "http_error",
          requestId,
          status,
          errorType: "InternalError",
          code,
          retryable,
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
        code,
        retryable,
        ...(status === 429 ? { retryAfterSeconds: 60 } : {}),
        detail: Array.isArray(message) ? message.join("; ") : String(message),
        message,
        instance: req.path,
        requestId,
      });
  }
}
