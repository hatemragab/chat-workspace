import { randomUUID } from "node:crypto";
import type { NextFunction, Request, Response } from "express";
import { ConfigService } from "@nestjs/config";
import {
  DebugTrafficLogger,
  sanitizeTrafficValue,
  TrafficLogRecord,
} from "./debug-traffic-logger";

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
export type CorrelatedRequest = Request & {
  requestId?: string;
  userId?: string;
};
export interface HttpLogRecord extends TrafficLogRecord {
  event: "http_request";
  requestId: string;
  method: string;
  route: string;
  status: number;
  durationMs: number;
  aborted: boolean;
}
const authSessionRoutes = new Set([
  "/auth/login",
  "/auth/signup",
  "/auth/debug-login",
]);
function authSessionRoute(path: unknown): boolean {
  return (
    typeof path === "string" &&
    authSessionRoutes.has(path.replace(/\/+$/, "").toLowerCase())
  );
}

function uploadMetadata(req: Request) {
  const files = req.file
    ? [req.file]
    : Array.isArray(req.files)
      ? req.files
      : Object.values(req.files ?? {}).flat();
  return files.map((file) => ({
    fieldName: file.fieldname,
    filename: file.originalname,
    mimeType: file.mimetype,
    byteLength: file.size,
  }));
}

function requestPayload(req: Request): unknown {
  const contentType = req.headers["content-type"] ?? "";
  if (contentType.startsWith("multipart/")) {
    return {
      kind: "multipart",
      fields: req.body ?? {},
      files: uploadMetadata(req),
    };
  }
  if (contentType.startsWith("application/octet-stream")) {
    return {
      kind: "binary",
      contentType,
      byteLength: Number(req.headers["content-length"]) || null,
    };
  }
  return req.body ?? null;
}

function responsePayload(body: unknown): unknown {
  if (typeof body === "string") {
    try {
      return sanitizeTrafficValue(JSON.parse(body));
    } catch {
      return sanitizeTrafficValue(body);
    }
  }
  return sanitizeTrafficValue(body);
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
  options: {
    enabled?: boolean;
    debugEnabled?: boolean;
    logger?: DebugTrafficLogger;
    write?: (record: HttpLogRecord) => void;
  } = {},
) {
  const logger =
    options.logger ??
    new DebugTrafficLogger(
      new ConfigService({
        HTTP_LOGGING_ENABLED: "true",
        DEBUG_TRAFFIC_LOGGING_ENABLED: "false",
      }),
    );
  return (req: CorrelatedRequest, res: Response, next: NextFunction): void => {
    const requestId = ensureRequestId(req, res);
    const userId = () => req.userId ?? responseUserId;
    let responseUserId: string | null = null;
    const proceed = () =>
      logger.runWithRequest({ requestId, getUserId: userId }, next);
    if (req.method === "OPTIONS" || !(options.enabled ?? logger.httpEnabled))
      return proceed();
    const debug = options.debugEnabled ?? logger.debugEnabled;
    const start = performance.now();
    let logged = false;
    let requestSnapshot: Record<string, unknown> | undefined;
    let responseSnapshot: unknown;
    let responseCaptured = false;
    const captureRequest = () => {
      if (!debug || requestSnapshot !== undefined) return;
      // Nest's ValidationPipe transforms a separate DTO. req.body still holds
      // submitted parsed JSON, including fields rejected by validation.
      requestSnapshot = sanitizeTrafficValue({
        path: req.path,
        params: req.params ?? {},
        query: req.query ?? {},
        requestHeaders: req.headers,
        requestBody: requestPayload(req),
      }) as Record<string, unknown>;
    };
    const inferAuthUser = (body: unknown) => {
      if (
        req.userId ||
        res.statusCode >= 400 ||
        !authSessionRoute(req.route?.path)
      )
        return;
      if (body === null || typeof body !== "object" || !("user" in body))
        return;
      const user = body.user;
      if (user === null || typeof user !== "object") return;
      const id = "id" in user ? user.id : "_id" in user ? user._id : null;
      if (typeof id === "string") responseUserId = id;
    };
    if (debug || authSessionRoute(req.path)) {
      const json = res.json;
      res.json = function (body: unknown) {
        inferAuthUser(body);
        if (debug) {
          captureRequest();
          responseSnapshot = responsePayload(body);
          responseCaptured = true;
        }
        return json.call(this, body);
      };
    }
    if (debug) {
      const send = res.send;
      res.send = function (body: unknown) {
        captureRequest();
        // res.json delegates to send after Express serializes the actual JSON.
        responseSnapshot = responsePayload(body);
        responseCaptured = true;
        return send.call(this, body);
      };
    }
    const complete = (aborted: boolean) => {
      if (logged) return;
      logged = true;
      // Express supplies the matched route template after routing. Never fall back to req.path/originalUrl.
      const route = (req.route as { path?: unknown } | undefined)?.path;
      const status = res.statusCode;
      if (
        !aborted &&
        status === 200 &&
        (req.method === "GET" || req.method === "HEAD") &&
        route === "/health"
      )
        return;
      const record: HttpLogRecord = {
        timestamp: new Date().toISOString(),
        level:
          aborted || status >= 500 ? "error" : status >= 400 ? "warn" : "info",
        event: "http_request",
        source: "backend",
        requestId,
        userId: userId(),
        method: methods.has(req.method) ? req.method : "OTHER",
        route:
          typeof route === "string" && route.length <= 256
            ? route
            : "[unmatched]",
        status,
        durationMs: Math.round((performance.now() - start) * 100) / 100,
        aborted,
      };
      record.summary = `${record.method} ${record.route}: HTTP ${status}${aborted ? ", response aborted" : ""}.`;
      if (debug) {
        captureRequest();
        Object.assign(record, requestSnapshot, {
          responseHeaders: res.getHeaders(),
          responseBody: responseCaptured
            ? responseSnapshot
            : {
                kind: "unbuffered",
                contentType: res.getHeader("content-type") ?? null,
                byteLength: Number(res.getHeader("content-length")) || null,
              },
        });
      }
      logger.write(
        record,
        options.write
          ? (safe) => options.write!(safe as HttpLogRecord)
          : undefined,
      );
    };
    res.once("finish", () => complete(false));
    res.once("close", () => complete(!res.writableFinished));
    proceed();
  };
}
