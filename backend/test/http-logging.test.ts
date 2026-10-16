import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import type { ArgumentsHost } from "@nestjs/common";
import type { Request, Response } from "express";
import {
  createHttpRequestLogger,
  HttpLogRecord,
  normalizeRequestId,
} from "../src/infrastructure/http-logging";
import { ProblemFilter } from "../src/errors.filter";
function response() {
  const value = Object.assign(new EventEmitter(), {
    statusCode: 200,
    writableFinished: true,
    headers: new Map<string, string>(),
    setHeader(name: string, data: string) {
      this.headers.set(name, data);
      return this;
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
  assert.deepEqual(records, []);
  assert.match(res.headers.get("X-Request-ID")!, /^[a-f0-9-]{36}$/);
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
