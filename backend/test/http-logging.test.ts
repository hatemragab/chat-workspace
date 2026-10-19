import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import {
  BadRequestException,
  HttpException,
  type ArgumentsHost,
} from "@nestjs/common";
import type { Request, Response } from "express";
import { ConfigService } from "@nestjs/config";
import {
  createHttpRequestLogger,
  HttpLogRecord,
  normalizeRequestId,
} from "../src/infrastructure/http-logging";
import { ProblemFilter } from "../src/errors.filter";
import { DebugTrafficLogger } from "../src/infrastructure/debug-traffic-logger";
function response() {
  const value = Object.assign(new EventEmitter(), {
    statusCode: 200,
    writableFinished: true,
    headers: new Map<string, string>(),
    sentBody: undefined as unknown,
    setHeader(name: string, data: string) {
      this.headers.set(name, data);
      return this;
    },
    getHeader(name: string) {
      const key = [...this.headers.keys()].find(
        (key) => key.toLowerCase() === name.toLowerCase(),
      );
      return key ? this.headers.get(key) : undefined;
    },
    getHeaders() {
      return Object.fromEntries(this.headers);
    },
    send(body: unknown) {
      this.sentBody = body;
      return this;
    },
    json(body: unknown) {
      this.setHeader("Content-Type", "application/json");
      return this.send(JSON.stringify(body));
    },
  });
  return value;
}
test("request IDs are bounded and reject header injection, arrays and invalid characters", () => {
  assert.equal(normalizeRequestId("trace-123_ABC.def"), "trace-123_ABC.def");
  for (const value of [
    undefined,
    [],
    ["a", "b"],
    "",
    "a".repeat(65),
    "Bearer secret",
    "good\n",
    "good\r\nX-Evil: injected",
  ]) {
    assert.match(normalizeRequestId(value), /^[a-f0-9-]{36}$/);
  }
});
test("structured HTTP logs use route templates and omit payloads, queries, identifiers and credentials", () => {
  const records: HttpLogRecord[] = [];
  const res = response();
  let nextCalled = false;
  const req = {
    method: "PATCH",
    headers: {
      "x-request-id": "trace-safe",
      authorization: "Bearer private-token",
    },
    route: { path: "/messages/:messageId" },
    path: "/messages/private-message-id",
    originalUrl: "/messages/private-message-id?token=private-query",
    body: { password: "private-password", text: "private-text" },
    ip: "private-ip",
  } as unknown as Request;
  createHttpRequestLogger({ write: (record) => records.push(record) })(
    req,
    res as unknown as Response,
    () => {
      nextCalled = true;
    },
  );
  res.statusCode = 403;
  res.emit("finish");
  res.emit("close");
  assert.equal(nextCalled, true);
  assert.equal(records.length, 1);
  assert.equal(records[0].route, "/messages/:messageId");
  assert.equal(records[0].requestId, "trace-safe");
  assert.equal(records[0].level, "warn");
  assert.equal(records[0].status, 403);
  assert.ok(records[0].durationMs >= 0);
  assert.equal(res.headers.get("X-Request-ID"), "trace-safe");
  const logged = JSON.stringify(records);
  for (const secret of [
    "private-token",
    "private-message-id",
    "private-query",
    "private-password",
    "private-text",
    "private-ip",
  ])
    assert.equal(logged.includes(secret), false);
  const unmatched = response();
  createHttpRequestLogger({ write: (record) => records.push(record) })(
    { ...req, route: undefined } as Request,
    unmatched as unknown as Response,
    () => {},
  );
  unmatched.emit("finish");
  assert.equal(records[1].route, "[unmatched]");
});
test("turning off request logs preserves response correlation", () => {
  const records: HttpLogRecord[] = [];
  const res = response();
  let nextCalled = false;
  createHttpRequestLogger({
    enabled: false,
    write: (record) => records.push(record),
  })(
    { method: "GET", headers: {} } as Request,
    res as unknown as Response,
    () => {
      nextCalled = true;
    },
  );
  res.emit("finish");
  assert.equal(nextCalled, true);
  assert.equal(records.length, 0);
  assert.match(res.headers.get("X-Request-ID")!, /^[a-f0-9-]{36}$/);
});
test("only completed successful GET and HEAD health probes are quiet", () => {
  const records: HttpLogRecord[] = [];
  for (const debugEnabled of [false, true]) {
    for (const method of ["GET", "HEAD"]) {
      const res = response();
      createHttpRequestLogger({
        debugEnabled,
        write: (record) => records.push(record),
      })(
        {
          method,
          path: "/health",
          headers: {},
          route: { path: "/health" },
        } as Request,
        res as unknown as Response,
        () => {},
      );
      res.json({ status: "ok" });
      res.emit("finish");
      res.emit("close");
      assert.match(res.headers.get("X-Request-ID")!, /^[a-f0-9-]{36}$/);
    }
  }
  assert.equal(records.length, 0);
  for (const [method, route, status, aborted] of [
    ["GET", "/health", 503, false],
    ["HEAD", "/health", 503, false],
    ["GET", "/health", 200, true],
    ["GET", "/rooms", 200, false],
    ["POST", "/health", 200, false],
  ] as const) {
    const res = response();
    res.statusCode = status;
    res.writableFinished = !aborted;
    createHttpRequestLogger({ write: (record) => records.push(record) })(
      { method, headers: {}, route: { path: route } } as Request,
      res as unknown as Response,
      () => {},
    );
    res.emit(aborted ? "close" : "finish");
    assert.equal(records.at(-1)!.status, status);
    assert.equal(records.at(-1)!.aborted, aborted);
  }
  assert.equal(records.length, 5);
});
test("metadata logging includes guard-populated user ID without reading or wrapping business payloads", () => {
  const records: HttpLogRecord[] = [];
  const res = response();
  const send = res.send;
  const json = res.json;
  const req = {
    method: "POST",
    path: "/messages",
    headers: {},
    route: { path: "/messages" },
    userId: undefined as string | undefined,
    get body() {
      throw new Error("Metadata mode must not inspect this body");
    },
    get params() {
      throw new Error("Metadata mode must not inspect params");
    },
    get query() {
      throw new Error("Metadata mode must not inspect query");
    },
  } as unknown as Request & { userId?: string };
  createHttpRequestLogger({ write: (record) => records.push(record) })(
    req,
    res as unknown as Response,
    () => {
      req.userId = "authenticated-user";
    },
  );
  assert.equal(res.send, send);
  assert.equal(res.json, json);
  res.emit("finish");
  assert.equal(records[0].userId, "authenticated-user");
  for (const field of [
    "path",
    "params",
    "query",
    "requestHeaders",
    "requestBody",
    "responseHeaders",
    "responseBody",
  ]) {
    assert.equal(Object.hasOwn(records[0], field), false);
  }
});
test("debug HTTP logging snapshots full JSON and headers while redacting credentials recursively", () => {
  const records: HttpLogRecord[] = [];
  const res = response();
  const req = {
    method: "POST",
    path: "/messages/example-id",
    headers: {
      "x-request-id": "debug-trace",
      authorization: "Bearer private-bearer",
      cookie: "session=private-cookie",
      "x-api-key": "private-api-key",
      origin: "http://localhost:5173",
      "content-type": "application/json",
    },
    route: { path: "/messages/:messageId" },
    params: { messageId: "example-id" },
    query: { page: "2", access_token: "private-query" },
    userId: "actor",
    body: {
      text: "Full message text",
      nested: [
        {
          Password_Hash: "private-password-hash",
          imageUrl: "/public/uploads/photo.png",
        },
      ],
      count: 3,
    },
  } as unknown as Request;
  createHttpRequestLogger({
    debugEnabled: true,
    write: (record) => records.push(record),
  })(req, res as unknown as Response, () => {});
  res.setHeader("Set-Cookie", "session=response-cookie");
  const body = {
    message: {
      id: "message-id",
      text: "Full response text",
      credential: "response-credential",
    },
    token: "response-token",
  };
  res.json(body);
  (req.body as { text: string }).text = "Changed after serialization";
  body.message.text = "Changed after serialization";
  res.emit("finish");
  const record = records[0];
  assert.equal(record.userId, "actor");
  assert.equal(record.path, "/messages/example-id");
  assert.deepEqual(record.params, { messageId: "example-id" });
  assert.deepEqual(record.query, { page: "2", access_token: "[REDACTED]" });
  assert.deepEqual(record.requestBody, {
    text: "Full message text",
    nested: [
      { Password_Hash: "[REDACTED]", imageUrl: "/public/uploads/photo.png" },
    ],
    count: 3,
  });
  assert.deepEqual(record.responseBody, {
    message: {
      id: "message-id",
      text: "Full response text",
      credential: "[REDACTED]",
    },
    token: "[REDACTED]",
  });
  assert.equal(
    (record.requestHeaders as Record<string, string>).origin,
    "http://localhost:5173",
  );
  assert.equal(
    (record.responseHeaders as Record<string, string>)["Set-Cookie"],
    "[REDACTED]",
  );
  const logged = JSON.stringify(record);
  for (const secret of [
    "private-bearer",
    "private-cookie",
    "private-api-key",
    "private-query",
    "private-password-hash",
    "response-cookie",
    "response-token",
    "response-credential",
  ])
    assert.equal(logged.includes(secret), false);
  assert.equal(JSON.parse(res.sentBody as string).token, "response-token");
  assert.equal(
    (req.body as { nested: { Password_Hash: string }[] }).nested[0]
      .Password_Hash,
    "private-password-hash",
  );
});
test("public auth identity is inferred from successful server responses even without debug capture", () => {
  const records: HttpLogRecord[] = [];
  for (const path of ["/auth/login", "/AUTH/LOGIN", "/auth/login/"]) {
    const req = {
      method: "POST",
      path,
      headers: {},
      route: { path: "/auth/login" },
    } as Request;
    for (const status of [200, 401]) {
      const res = response();
      res.statusCode = status;
      createHttpRequestLogger({ write: (record) => records.push(record) })(
        req,
        res as unknown as Response,
        () => {},
      );
      res.json({ user: { _id: "trusted-user" }, accessToken: "must-not-log" });
      res.emit("finish");
    }
  }
  for (const record of records) {
    assert.equal(record.userId, record.status === 200 ? "trusted-user" : null);
    assert.equal(Object.hasOwn(record, "responseBody"), false);
  }
});
test("OPTIONS is never logged or captured in metadata or debug mode", () => {
  for (const debugEnabled of [false, true]) {
    const records: HttpLogRecord[] = [];
    const res = response();
    const json = res.json;
    createHttpRequestLogger({
      debugEnabled,
      write: (record) => records.push(record),
    })(
      {
        method: "OPTIONS",
        headers: {},
        get body() {
          throw new Error("Do not capture preflight");
        },
      } as unknown as Request,
      res as unknown as Response,
      () => {},
    );
    res.emit("finish");
    assert.deepEqual(records, []);
    assert.equal(res.json, json);
    assert.ok(res.headers.get("X-Request-ID"));
  }
});
test("JSON sent directly, JSON null, binary bodies and multipart uploads preserve wire data safely", () => {
  const records: HttpLogRecord[] = [];
  const req = {
    method: "POST",
    path: "/uploads/image",
    headers: { "content-type": "multipart/form-data; boundary=example" },
    params: {},
    query: {},
    body: { caption: "Photo caption" },
    file: {
      fieldname: "file",
      originalname: "photo.png",
      mimetype: "image/png",
      size: 123,
      get buffer() {
        throw new Error("Never copy upload bytes");
      },
    },
  } as unknown as Request;
  const res = response();
  createHttpRequestLogger({
    debugEnabled: true,
    write: (record) => records.push(record),
  })(req, res as unknown as Response, () => {});
  res.send('{"imageUrl":"/public/uploads/photo.png","apiKey":"secret"}');
  res.emit("finish");
  assert.deepEqual(records[0].requestBody, {
    kind: "multipart",
    fields: { caption: "Photo caption" },
    files: [
      {
        fieldName: "file",
        filename: "photo.png",
        mimeType: "image/png",
        byteLength: 123,
      },
    ],
  });
  assert.deepEqual(records[0].responseBody, {
    imageUrl: "/public/uploads/photo.png",
    apiKey: "[REDACTED]",
  });
  for (const body of [null, Buffer.from("private-binary-content")]) {
    const binary = response();
    createHttpRequestLogger({
      debugEnabled: true,
      write: (record) => records.push(record),
    })(
      {
        method: "GET",
        headers: {},
        params: {},
        query: {},
      } as unknown as Request,
      binary as unknown as Response,
      () => {},
    );
    binary.send(body);
    binary.emit("finish");
  }
  assert.equal(records[1].responseBody, null);
  assert.deepEqual(records[2].responseBody, { kind: "binary", byteLength: 22 });
  assert.equal(
    JSON.stringify(records).includes("private-binary-content"),
    false,
  );
});
test("request contexts keep the late-authenticated actor and correlation isolated across asynchronous fanout", async () => {
  const logger = new DebugTrafficLogger(
    new ConfigService({ HTTP_LOGGING_ENABLED: "false" }),
  );
  const middleware = createHttpRequestLogger({ logger });
  const identities: { requestId: string | null; userId: string | null }[] = [];
  await Promise.all(
    ["first", "second"].map(
      (id) =>
        new Promise<void>((resolve) => {
          const req = {
            method: "POST",
            headers: { "x-request-id": id },
            userId: undefined as string | undefined,
          } as unknown as Request & { userId?: string };
          middleware(req, response() as unknown as Response, () => {
            req.userId = `actor-${id}`;
            setTimeout(
              () => {
                identities.push(logger.identity());
                resolve();
              },
              id === "first" ? 10 : 1,
            );
          });
        }),
    ),
  );
  assert.deepEqual(identities, [
    { requestId: "second", userId: "actor-second" },
    { requestId: "first", userId: "actor-first" },
  ]);
  assert.deepEqual(logger.identity(), { requestId: null, userId: null });
});
test("traffic writer failures cannot escape response completion", () => {
  const res = response();
  createHttpRequestLogger({
    write: () => {
      throw new Error("Logging sink unavailable");
    },
  })(
    { method: "GET", headers: {} } as Request,
    res as unknown as Response,
    () => {},
  );
  assert.doesNotThrow(() => res.emit("finish"));
});
test("unexpected failures expose and log the same request ID without raw exception data", () => {
  const filter = new ProblemFilter();
  const errors: string[] = [];
  (filter as unknown as { logger: { error: (value: string) => void } }).logger =
    { error: (value) => errors.push(value) };
  let problem: Record<string, unknown> = {};
  const base = response();
  const res = Object.assign(base, {
    status(value: number) {
      base.statusCode = value;
      return this;
    },
    type(_value: string) {
      return this;
    },
    json(value: Record<string, unknown>) {
      problem = value;
      return this;
    },
  });
  const req = {
    headers: { "x-request-id": "failure-trace" },
    path: "/messages",
  };
  const host = {
    switchToHttp: () => ({ getRequest: () => req, getResponse: () => res }),
  } as unknown as ArgumentsHost;
  filter.catch(new Error("database-password=never-log-this"), host);
  assert.equal(problem.status, 500);
  assert.equal(problem.requestId, "failure-trace");
  assert.equal(res.headers.get("X-Request-ID"), "failure-trace");
  assert.equal(JSON.parse(errors[0]).requestId, "failure-trace");
  assert.equal(JSON.stringify(problem).includes("never-log-this"), false);
  assert.equal(errors.join("").includes("never-log-this"), false);
});
test("problem responses expose stable retry policy and matching rate-limit cooldown", () => {
  const cases: [number, string, boolean][] = [
    [400, "BAD_REQUEST", false],
    [401, "AUTHENTICATION_REQUIRED", false],
    [403, "FORBIDDEN", false],
    [404, "NOT_FOUND", false],
    [408, "REQUEST_TIMEOUT", true],
    [409, "CONFLICT", false],
    [413, "PAYLOAD_TOO_LARGE", false],
    [415, "UNSUPPORTED_MEDIA_TYPE", false],
    [422, "VALIDATION_FAILED", false],
    [429, "RATE_LIMITED", true],
    [500, "INTERNAL_ERROR", true],
    [502, "BAD_GATEWAY", true],
    [503, "SERVICE_UNAVAILABLE", true],
    [504, "GATEWAY_TIMEOUT", true],
  ];
  for (const [status, code, retryable] of cases) {
    const filter = new ProblemFilter();
    (filter as unknown as { logger: { error: () => void } }).logger = {
      error: () => {},
    };
    const base = response();
    const res = Object.assign(base, {
      status(value: number) {
        base.statusCode = value;
        return this;
      },
      type(value: string) {
        base.setHeader("Content-Type", value);
        return this;
      },
      json(value: unknown) {
        base.sentBody = JSON.stringify(value);
        return this;
      },
    });
    filter.catch(new HttpException("Request rejected", status), {
      switchToHttp: () => ({
        getRequest: () => ({ headers: {}, path: "/messages" }),
        getResponse: () => res,
      }),
    } as unknown as ArgumentsHost);
    const problem = JSON.parse(res.sentBody as string);
    assert.equal(problem.code, code);
    assert.equal(problem.retryable, retryable);
    assert.equal(problem.status, status);
    assert.equal(problem.message, "Request rejected");
    assert.equal(res.getHeader("Content-Type"), "application/problem+json");
    assert.equal(problem.retryAfterSeconds, status === 429 ? 60 : undefined);
    assert.equal(
      res.getHeader("Retry-After"),
      status === 429 ? "60" : undefined,
    );
  }
});

test("validation failures are nonretryable and metadata logging excludes message contents", () => {
  const records: HttpLogRecord[] = [];
  const req = {
    method: "POST",
    headers: {},
    path: "/messages",
    route: { path: "/messages" },
    body: { text: "private-chat-message", secret: "private-credential" },
  } as unknown as Request;
  const base = response();
  const res = Object.assign(base, {
    status(value: number) {
      base.statusCode = value;
      return this;
    },
    type(value: string) {
      base.setHeader("Content-Type", value);
      return this;
    },
  });
  createHttpRequestLogger({
    debugEnabled: false,
    write: (record) => records.push(record),
  })(req, res as unknown as Response, () => {});
  new ProblemFilter().catch(
    new BadRequestException(["type must be a supported message type"]),
    {
      switchToHttp: () => ({ getRequest: () => req, getResponse: () => res }),
    } as unknown as ArgumentsHost,
  );
  res.emit("finish");
  const problem = JSON.parse(res.sentBody as string);
  assert.equal(problem.code, "VALIDATION_FAILED");
  assert.equal(problem.retryable, false);
  assert.equal(records.length, 1);
  assert.equal(records[0].status, 400);
  assert.equal(records[0].level, "warn");
  const logged = JSON.stringify(records);
  for (const privateValue of [
    "private-chat-message",
    "private-credential",
    "type must be a supported message type",
  ])
    assert.equal(logged.includes(privateValue), false);
});
