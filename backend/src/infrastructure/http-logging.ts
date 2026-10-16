import { randomUUID } from "node:crypto";
import type { NextFunction, Request, Response } from "express";

const safeRequestId = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const methods = new Set([
  "GET",
  "POST",
  "PUT",
  "PATCH",
  "DELETE",
  "HEAD",
  "OPTIONS",
  "CONNECT",
  "TRACE",
]);
export type CorrelatedRequest = Request & { requestId?: string };
export interface HttpLogRecord {
  timestamp: string;
  level: "info" | "warn" | "error";
  event: "http_request";
  requestId: string;
  method: string;
  route: string;
  status: number;
  durationMs: number;
  aborted: boolean;
}
export function normalizeRequestId(value: unknown): string {
  return typeof value === "string" &&
    !/[\r\n]/.test(value) &&
    safeRequestId.test(value)
    ? value
    : randomUUID();
}
export function ensureRequestId(req: CorrelatedRequest, res: Response): string {
  const requestId = normalizeRequestId(
    req.requestId ?? req.headers["x-request-id"],
  );
  req.requestId = requestId;
  res.setHeader("X-Request-ID", requestId);
  return requestId;
}
export function createHttpRequestLogger(
  options: { enabled?: boolean; write?: (record: HttpLogRecord) => void } = {},
) {
  const write =
    options.write ??
    ((record: HttpLogRecord) => {
      process.stdout.write(`${JSON.stringify(record)}\n`);
    });
  return (req: CorrelatedRequest, res: Response, next: NextFunction): void => {
    const requestId = ensureRequestId(req, res);
    if (options.enabled === false) {
      next();
      return;
    }
    const start = performance.now();
    let logged = false;
    const complete = (aborted: boolean) => {
      if (logged) return;
      logged = true;
      // Express supplies the matched route template after routing. Never fall back to req.path/originalUrl.
      const route = (req.route as { path?: unknown } | undefined)?.path;
      const status = res.statusCode;
      const record: HttpLogRecord = {
        timestamp: new Date().toISOString(),
        level:
          aborted || status >= 500 ? "error" : status >= 400 ? "warn" : "info",
        event: "http_request",
        requestId,
        method: methods.has(req.method) ? req.method : "OTHER",
        route:
          typeof route === "string" && route.length <= 256
            ? route
            : "[unmatched]",
        status,
        durationMs: Math.round((performance.now() - start) * 100) / 100,
        aborted,
      };
      write(record);
    };
    res.once("finish", () => complete(false));
    res.once("close", () => complete(!res.writableFinished));
    next();
  };
}
