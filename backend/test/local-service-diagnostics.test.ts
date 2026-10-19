import "reflect-metadata";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp, readFile, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { ConfigService } from "@nestjs/config";
import Redis, { Command } from "ioredis";
import type { MongoClient } from "mongodb";
import { DebugTrafficLogger } from "../src/infrastructure/debug-traffic-logger";
import { CentrifugoService } from "../src/infrastructure/centrifugo.service";
import {
  centrifugoDetailLimit,
  centrifugoLogSnapshot,
} from "../src/infrastructure/centrifugo-command-details";
import {
  LocalServiceDiagnostics,
  localServiceLoggingEnabled,
  type LocalServiceLogRecord,
} from "../src/infrastructure/local-service-diagnostics";
import type { HydratedRoomPayload } from "../src/models";

async function fixture() {
  const directory = await mkdtemp(
    join(await realpath(tmpdir()), "chat-service-logs-"),
  );
  const path = join(directory, "services.jsonl");
  const config = new ConfigService({
    LOCAL_SERVICE_LOG_FILE: path,
    DEBUG_TRAFFIC_LOGGING_ENABLED: "false",
  });
  const traffic = new DebugTrafficLogger(config);
  const diagnostics = new LocalServiceDiagnostics(config, traffic);
  return { directory, path, config, traffic, diagnostics };
}

async function records(path: string): Promise<LocalServiceLogRecord[]> {
  return (await readFile(path, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
}

class RedisStub extends EventEmitter {
  calls: { command: Command; stream: unknown; receiver: unknown }[] = [];
  readonly returned = { original: "driver-result" };
  sendCommand(command: Command, stream?: unknown) {
    this.calls.push({ command, stream, receiver: this });
    return this.returned;
  }
  asClient(): Redis {
    return this as unknown as Redis;
  }
}

test("service diagnostics are off by default with no hooks, files or identity lookup", async () => {
  for (const path of [undefined, "", " ", "off", "OFF"]) {
    const config = new ConfigService({ LOCAL_SERVICE_LOG_FILE: path });
    const traffic = new DebugTrafficLogger(config);
    traffic.identity = () => {
      throw new Error("disabled lookup");
    };
    const diagnostics = new LocalServiceDiagnostics(config, traffic);
    const redis = new RedisStub();
    const original = redis.sendCommand;
    const mongo = new EventEmitter();
    diagnostics.observeRedis(redis.asClient());
    diagnostics.observeMongo(mongo as MongoClient);
    diagnostics.begin("redis", "ping")();
    assert.equal(diagnostics.enabled, false);
    assert.equal(diagnostics.fileStats(), null);
    assert.equal(redis.sendCommand, original);
    assert.equal(redis.eventNames().length, 0);
    assert.equal(mongo.eventNames().length, 0);
    assert.equal(localServiceLoggingEnabled(path), false);
    await diagnostics.onModuleDestroy();
  }
  assert.equal(localServiceLoggingEnabled("/local/services.jsonl"), true);
});

test("Redis captures original command completion once across resends and preserves receiver, promise, callback and pipeline stream", async () => {
  const { diagnostics, traffic, path } = await fixture();
  const redis = new RedisStub();
  const original = redis.sendCommand;
  const detach = diagnostics.observeRedis(redis.asClient());
  assert.equal(diagnostics.observeRedis(redis.asClient()), detach);
  const pipeline = { isPipeline: true };
  let callbackValue: unknown;
  const command = new Command("get", ["private-key"], {}, (error, value) => {
    assert.equal(error, null);
    callbackValue = value;
  });
  let actor = "actor-one";
  const initialPromise = command.promise;
  traffic.runWithRequest(
    { requestId: "request-one", getUserId: () => actor },
    () => {
      assert.equal(redis.sendCommand(command, pipeline), redis.returned);
      actor = "later-actor";
      redis.sendCommand(command, pipeline);
    },
  );
  assert.equal(command.promise, initialPromise);
  command.resolve("private-value");
  assert.equal(await command.promise, "private-value");
  await diagnostics.flush();
  assert.equal(callbackValue, "private-value");
  assert.equal(redis.calls.length, 2);
  assert.ok(
    redis.calls.every(
      (call) =>
        call.stream === pipeline &&
        call.receiver === redis &&
        call.command === command,
    ),
  );
  const values = await records(path);
  assert.equal(values.length, 1);
  assert.equal(values[0].source, "redis");
  assert.equal(values[0].operation, "get");
  assert.equal(values[0].name, "redis.get");
  assert.equal(values[0].category, "command");
  assert.equal(values[0].userId, "actor-one");
  assert.equal(values[0].requestId, "request-one");
  assert.equal(values[0].result, "success");
  assert.equal(values[0].origin, "backend_client");
  assert.doesNotMatch(
    JSON.stringify(values),
    /private-key|private-value|later-actor/,
  );
  detach();
  assert.equal(redis.sendCommand, original);
  assert.equal(redis.eventNames().length, 0);
  await diagnostics.onModuleDestroy();
});

test("Redis command failures preserve the same rejection and log only the error class", async () => {
  const { diagnostics, path } = await fixture();
  const redis = new RedisStub();
  diagnostics.observeRedis(redis.asClient());
  const command = new Command("eval", ["private-script", 1, "private-key"]);
  redis.sendCommand(command);
  class SyntheticRedisError extends Error {}
  const failure = new SyntheticRedisError("private error content");
  command.reject(failure);
  await assert.rejects(command.promise, (error) => error === failure);
  redis.emit("error", failure);
  redis.emit("ready");
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(values[0].result, "failure");
  assert.equal(values[0].errorType, "SyntheticRedisError");
  assert.equal(values[1].event, "service_connection");
  assert.equal(values[1].operation, "error");
  assert.equal(values[1].name, "redis.error");
  assert.equal(values[1].category, "connection");
  assert.equal(values[2].operation, "ready");
  assert.doesNotMatch(
    JSON.stringify(values),
    /private error content|private-script|private-key/,
  );
});

test("synchronous Redis driver throws and hostile error metadata preserve the original application error", async () => {
  const { diagnostics, path } = await fixture();
  const failure = new Error("private synchronous failure");
  Object.defineProperty(failure, "constructor", {
    get() {
      throw new Error("private error metadata getter");
    },
  });
  const redis = new RedisStub();
  redis.sendCommand = () => {
    throw failure;
  };
  diagnostics.observeRedis(redis.asClient());
  const command = new Command("ping");
  assert.throws(
    () => redis.sendCommand(command),
    (error) => error === failure,
  );
  command.resolve("PONG");
  await command.promise;
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(
    values.length,
    1,
    "Late promise completion does not double-count a synchronous failure",
  );
  assert.equal(values[0].result, "failure");
  assert.equal(values[0].errorType, "Error");
  assert.doesNotMatch(JSON.stringify(values), /private/);
});

test("Mongo commands capture initiating identities, completion and failure without reading queries, replies or database names", async () => {
  const { diagnostics, traffic, path } = await fixture();
  const mongo = new EventEmitter();
  const detach = diagnostics.observeMongo(mongo as MongoClient);
  assert.equal(diagnostics.observeMongo(mongo as MongoClient), detach);
  let actor = "mongo-actor";
  const event = (requestId: number, commandName: string) => ({
    requestId,
    commandName,
    get command() {
      throw new Error("must not inspect private queries");
    },
    get databaseName() {
      throw new Error("must not inspect private database names");
    },
    get reply() {
      throw new Error("must not inspect private replies");
    },
  });
  traffic.runWithRequest(
    { requestId: "mongo-request", getUserId: () => actor },
    () => {
      mongo.emit("commandStarted", event(1, "find"));
      actor = "later-mongo-actor";
      mongo.emit("commandStarted", event(2, "update"));
    },
  );
  mongo.emit("commandSucceeded", event(1, "find"));
  class SyntheticMongoError extends Error {}
  const failureEvent = event(2, "update");
  Object.defineProperty(failureEvent, "failure", {
    value: new SyntheticMongoError("private query/error"),
  });
  mongo.emit("commandFailed", failureEvent);
  mongo.emit("commandSucceeded", event(100, "unknown"));
  await diagnostics.flush();
  const values = await records(path);
  assert.equal(values.length, 3);
  assert.equal(values[0].operation, "monitor_attached");
  assert.equal(values[0].name, "mongodb.monitor_attached");
  assert.equal(values[0].category, "connection");
  assert.equal(values[1].userId, "mongo-actor");
  assert.equal(values[1].requestId, "mongo-request");
  assert.equal(values[1].operation, "find");
  assert.equal(values[1].name, "mongodb.find");
  assert.equal(values[1].category, "command");
  assert.equal(values[1].result, "success");
  assert.equal(values[2].userId, "later-mongo-actor");
  assert.equal(values[2].result, "failure");
  assert.equal(values[2].errorType, "SyntheticMongoError");
  assert.doesNotMatch(JSON.stringify(values), /private/);
  detach();
  assert.equal(mongo.eventNames().length, 0);
  await diagnostics.onModuleDestroy();
});

test("Mongo pending commands are bounded and cleared by pool closure and teardown", async () => {
  const { diagnostics, path } = await fixture();
  const mongo = new EventEmitter();
  diagnostics.observeMongo(mongo as MongoClient);
  for (let requestId = 0; requestId < 4100; requestId++)
    mongo.emit("commandStarted", { requestId, commandName: "find" });
  mongo.emit("commandSucceeded", { requestId: 0 }); // Evicted, cannot become a false success.
  mongo.emit("commandSucceeded", { requestId: 4099 });
  mongo.emit("connectionPoolClosed");
  mongo.emit("commandSucceeded", { requestId: 4098 });
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(
    values.filter((record) => record.event === "service_operation").length,
    1,
  );
  assert.ok(values.some((record) => record.operation === "pool_closed"));
  const omissions = values.filter(
    (record) => record.operation === "monitor_tracking_omitted",
  );
  assert.equal(
    omissions.find((record) => record.omissionReason === "capacity")
      ?.omittedOperations,
    4,
  );
  assert.equal(
    omissions.find((record) => record.omissionReason === "pool_closed")
      ?.omittedOperations,
    4095,
  );
  assert.ok(
    omissions.every(
      (record) => record.level === "warn" && record.result === "omitted",
    ),
  );
  assert.equal(mongo.eventNames().length, 0);
});

test("Mongo failures without retained correlation remain visible and never invent a request identity", async () => {
  const { diagnostics, path } = await fixture();
  const mongo = new EventEmitter();
  diagnostics.observeMongo(mongo as MongoClient);
  class ExpiredMongoError extends Error {}
  mongo.emit("commandFailed", {
    requestId: 99,
    commandName: "update",
    failure: new ExpiredMongoError("private unmatched command"),
    get command() {
      throw new Error("must not inspect private queries");
    },
  });
  await diagnostics.onModuleDestroy();
  const value = (await records(path)).find(
    (record) => record.correlationUnavailable,
  );
  assert.equal(value?.operation, "update");
  assert.equal(value?.result, "failure");
  assert.equal(value?.errorType, "ExpiredMongoError");
  assert.equal(value?.requestId, null);
  assert.equal(value?.userId, null);
  assert.doesNotMatch(
    JSON.stringify(value),
    /private unmatched|private queries/,
  );
});

test("Mongo tracking shutdown emits one bounded omission summary rather than losing outstanding observations silently", async () => {
  const { diagnostics, path } = await fixture();
  const mongo = new EventEmitter();
  diagnostics.observeMongo(mongo as MongoClient);
  for (let requestId = 0; requestId < 100; requestId++)
    mongo.emit("commandStarted", { requestId, commandName: "find" });
  await diagnostics.onModuleDestroy();
  const omissions = (await records(path)).filter(
    (record) => record.operation === "monitor_tracking_omitted",
  );
  assert.equal(omissions.length, 1);
  assert.equal(omissions[0].omittedOperations, 100);
  assert.equal(omissions[0].omissionReason, "shutdown");
  assert.equal(diagnostics.fileStats()?.importantWrittenRecords, 1);
  assert.equal(diagnostics.fileStats()?.importantDroppedRecords, 0);
});

test("expired Mongo correlation is counted and a later failure remains visible without the expired identity", async (context) => {
  let now = 0;
  context.mock.method(performance, "now", () => now);
  const { diagnostics, path } = await fixture();
  const mongo = new EventEmitter();
  diagnostics.observeMongo(mongo as MongoClient);
  mongo.emit("commandStarted", { requestId: 1, commandName: "find" });
  now = 60_001;
  mongo.emit("commandStarted", { requestId: 2, commandName: "update" });
  mongo.emit("commandFailed", {
    requestId: 1,
    commandName: "find",
    failure: new Error("private expired query"),
  });
  mongo.emit("commandSucceeded", { requestId: 2, commandName: "update" });
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(
    values.find((record) => record.omissionReason === "age")?.omittedOperations,
    1,
  );
  const failure = values.find((record) => record.correlationUnavailable);
  assert.equal(failure?.requestId, null);
  assert.equal(failure?.userId, null);
  assert.equal(failure?.operation, "find");
  assert.doesNotMatch(JSON.stringify(values), /private expired/);
});

test("diagnostic sink failure cannot change driver completion or expose private filesystem errors", async (context) => {
  const { directory, config, traffic } = await fixture();
  const blocker = join(directory, "private-blocker");
  await writeFile(blocker, "preserved");
  config.set("LOCAL_SERVICE_LOG_FILE", join(blocker, "services.jsonl"));
  const warnings: string[] = [];
  context.mock.method(process.stderr, "write", (value: unknown) => {
    warnings.push(String(value));
    return true;
  });
  const diagnostics = new LocalServiceDiagnostics(config, traffic);
  const redis = new RedisStub();
  diagnostics.observeRedis(redis.asClient());
  const first = new Command("ping");
  assert.equal(redis.sendCommand(first), redis.returned);
  first.resolve("PONG");
  assert.equal(await first.promise, "PONG");
  await diagnostics.flush();
  const second = new Command("ping");
  redis.sendCommand(second);
  second.resolve("PONG");
  assert.equal(await second.promise, "PONG");
  await diagnostics.onModuleDestroy();
  assert.equal(diagnostics.fileStats()?.failedRecords, 1);
  assert.equal(diagnostics.fileStats()?.droppedRecords, 1);
  assert.equal(warnings.length, 1);
  assert.doesNotMatch(warnings.join(""), /private-blocker|preserved/);
  assert.equal(await readFile(blocker, "utf8"), "preserved");
});

test("Centrifugo metadata is independent of full payload capture and keeps one logical publication across retries", async (context) => {
  const { diagnostics, traffic, config, path } = await fixture();
  config.set("CENTRIFUGO_API_URL", "http://synthetic-provider.test/api");
  config.set("CENTRIFUGO_API_KEY", "private-api-key");
  traffic.writer = () => {
    throw new Error("full debug traffic should remain disabled");
  };
  let calls = 0;
  context.mock.method(globalThis, "fetch", async () => {
    calls++;
    if (calls === 1) throw new TypeError("private network error");
    return Response.json({ result: { private: "provider-content" } });
  });
  const service = new CentrifugoService(config, traffic, diagnostics);
  const room = {
    roomPts: 1,
    eventType: "message_new",
    lastMessage: { text: "private-message" },
  } as unknown as HydratedRoomPayload;
  let actor = "publication-actor";
  const publishing = traffic.runWithRequest(
    { requestId: "publication-request", getUserId: () => actor },
    () => service.publish("recipient-one", "epoch-one", room),
  );
  actor = "changed-later";
  assert.equal(await publishing, true);
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(values.length, 2);
  assert.deepEqual(
    values.map((record) => record.result),
    ["failure", "success"],
  );
  assert.deepEqual(
    values.map((record) => record.attempt),
    [1, 2],
  );
  assert.equal(values[0].errorType, "TypeError");
  assert.equal(new Set(values.map((record) => record.publicationId)).size, 1);
  assert.ok(
    values.every(
      (record) =>
        record.userId === "publication-actor" &&
        record.actorUserId === "publication-actor" &&
        record.requestId === "publication-request" &&
        record.recipientUserId === "recipient-one" &&
        record.channel === "inbox:user#recipient-one" &&
        record.eventType === "message_new" &&
        record.pts === 1 &&
        !Object.hasOwn(record, "data") &&
        !Object.hasOwn(record, "responseBody"),
    ),
  );
  assert.ok(
    values.every(
      (record) =>
        record.source === "centrifugo" &&
        record.origin === "backend_client" &&
        record.name === "centrifugo.publish" &&
        record.category === "command",
    ),
  );
  assert.doesNotMatch(
    JSON.stringify(values),
    /private-|provider-content|changed-later/,
  );
});

test("Centrifugo debug diagnostics capture the sent snapshot, actor and inbox on every retry with credential redaction", async (context) => {
  const { diagnostics, traffic, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  config.set("CENTRIFUGO_API_URL", "http://synthetic-provider.test/api");
  config.set("CENTRIFUGO_API_KEY", "private-api-key");
  traffic.writer = () => undefined;
  const room = {
    roomPts: 7,
    eventType: "message_new",
    lastMessage: {
      senderId: "message-sender",
      text: "publication body",
      token: "private-message-token",
    },
  } as unknown as HydratedRoomPayload;
  const bodies: unknown[] = [];
  context.mock.method(
    globalThis,
    "fetch",
    async (_url: unknown, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)));
      // A later change must not change the logged snapshot or retry body.
      room.lastMessage!.text = "changed-later";
      return Response.json(
        bodies.length === 1
          ? { error: { code: 100, token: "private-error-token" } }
          : { result: {}, token: "private-result-token" },
      );
    },
  );
  assert.equal(
    await traffic.runWithRequest(
      { requestId: "debug-publish", getUserId: () => "initiating-actor" },
      () =>
        new CentrifugoService(config, traffic, diagnostics).publish(
          "recipient-one",
          "epoch-one",
          room,
        ),
    ),
    true,
  );
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(values.length, 2);
  assert.deepEqual(bodies[0], bodies[1]);
  assert.equal(new Set(values.map((record) => record.publicationId)).size, 1);
  for (const record of values) {
    assert.equal(record.actorUserId, "initiating-actor");
    assert.equal(record.userId, "initiating-actor");
    assert.equal(record.recipientUserId, "recipient-one");
    assert.equal(record.channel, "inbox:user#recipient-one");
    assert.equal(record.method, "POST");
    assert.equal(record.path, "/api/publish");
    assert.equal(record.eventType, "message_new");
    assert.equal(record.pts, 7);
    assert.deepEqual(record.data, {
      pts: 7,
      epoch: "epoch-one",
      room: {
        roomPts: 7,
        eventType: "message_new",
        lastMessage: {
          senderId: "message-sender",
          text: "publication body",
          token: "[REDACTED]",
        },
      },
    });
  }
  assert.deepEqual(values[0].responseBody, {
    error: { code: 100, token: "[REDACTED]" },
  });
  assert.deepEqual(values[1].responseBody, { result: {}, token: "[REDACTED]" });
  assert.doesNotMatch(JSON.stringify(values), /private-|changed-later/);
});

test("Centrifugo diagnostics enforce the production payload policy independently", async () => {
  const { diagnostics, config, path } = await fixture();
  config.set("NODE_ENV", "production");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  diagnostics.publication({
    requestId: null,
    userId: null,
    recipientUserId: "recipient-one",
    channel: "inbox:user#recipient-one",
    eventType: "message_new",
    pts: 1,
    publicationId: "production-publication",
    attempt: 1,
    status: 200,
    durationMs: 1,
    success: true,
    data: { text: "private-body" },
    responseBody: { token: "private-token" },
  });
  await diagnostics.onModuleDestroy();
  const [value] = await records(path);
  assert.equal(value.actorUserId, null);
  assert.equal(value.channel, "inbox:user#recipient-one");
  assert.equal(Object.hasOwn(value, "data"), false);
  assert.equal(Object.hasOwn(value, "responseBody"), false);
  assert.doesNotMatch(JSON.stringify(value), /private-/);
});

test("service names are filterable metadata and never copy unsafe operation values", async () => {
  const { diagnostics, path } = await fixture();
  const identity = { requestId: "named-request", userId: "named-user" };
  diagnostics.begin("redis", "eval", identity)();
  for (const operation of [
    "eval private-message",
    "eval\nforged-label",
    "x".repeat(65),
  ])
    diagnostics.begin("redis", operation, identity)();
  const redis = new RedisStub();
  diagnostics.observeRedis(redis.asClient());
  redis.emit("ready");
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.deepEqual(
    values
      .filter((record) => record.category === "command")
      .map((record) => record.name),
    ["redis.eval", "redis.unknown", "redis.unknown", "redis.unknown"],
  );
  const ready = values.find((record) => record.name === "redis.ready");
  assert.equal(ready?.category, "connection");
  assert.equal(ready?.event, "service_connection");
  assert.ok(
    values
      .filter((record) => record.category === "command")
      .every(
        (record) =>
          record.event === "service_operation" &&
          record.requestId === identity.requestId &&
          record.userId === identity.userId,
      ),
  );
  assert.doesNotMatch(JSON.stringify(values), /private-message|forged-label/);
});

test("late driver completion after diagnostic shutdown never appends to a closed sink", async () => {
  const { diagnostics } = await fixture();
  const redis = new RedisStub();
  diagnostics.observeRedis(redis.asClient());
  const command = new Command("quit");
  redis.sendCommand(command);
  await diagnostics.onModuleDestroy();
  command.resolve("OK");
  await command.promise;
  await Promise.resolve();
  assert.equal(diagnostics.fileStats()?.droppedRecords, 0);
  assert.equal(diagnostics.fileStats()?.failedRecords, 0);
  assert.equal(redis.eventNames().length, 0);
});

test("full-debug Redis Lua captures named inputs, immutable redacted data and decoded reply once", async () => {
  const { upsertUserRoomDeltaLua } =
    await import("../src/infrastructure/redis-scripts");
  const { diagnostics, traffic, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  const redis = new RedisStub();
  diagnostics.observeRedis(redis.asClient());
  const room = {
    roomId: "room-one",
    roomPts: 7,
    text: "hello",
    token: "private-room-token",
  };
  const command = new Command("eval", [
    upsertUserRoomDeltaLua,
    3,
    "user:one:meta",
    "user:one:dirty_rooms",
    "user:one:rooms_data",
    7,
    "room-one",
    JSON.stringify(room),
    "epoch-one",
    604800,
    123456789,
  ]);
  traffic.runWithRequest(
    { requestId: "detailed-request", getUserId: () => "actor-one" },
    () => {
      redis.sendCommand(command);
      redis.sendCommand(command);
    },
  );
  command.args[4] = "changed-after-send";
  const reply = JSON.stringify({
    pts: 7,
    rooms: [room],
    password: "private-reply-password",
  });
  command.resolve(reply);
  assert.equal(await command.promise, reply);
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(values.length, 1);
  assert.equal(values[0].requestId, "detailed-request");
  assert.match(values[0].summary!, /room projection/);
  const data = values[0].data as {
    script: {
      name: string;
      source: string;
      possibleCommands: string[];
      observation: string;
    };
    keys: unknown[];
    arguments: { name: string; value: unknown }[];
  };
  assert.equal(data.script.name, "inbox.upsert_room");
  assert.equal(data.script.source, upsertUserRoomDeltaLua);
  assert.ok(data.script.possibleCommands.includes("HSET"));
  assert.match(data.script.observation, /not observed/);
  assert.deepEqual(data.keys[2], {
    position: "KEYS[3]",
    key: "user:one:rooms_data",
  });
  assert.deepEqual(data.arguments[2], {
    position: "ARGV[3]",
    name: "room",
    value: { ...room, token: "[REDACTED]" },
  });
  assert.deepEqual(values[0].responseBody, {
    pts: 7,
    rooms: [{ ...room, token: "[REDACTED]" }],
    password: "[REDACTED]",
  });
  assert.doesNotMatch(
    JSON.stringify(values),
    /private-room-token|private-reply-password|changed-after-send/,
  );
});

test("Redis full-debug policy excludes credentials, unknown scripts and binary values", async () => {
  const { diagnostics, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  const redis = new RedisStub();
  diagnostics.observeRedis(redis.asClient());
  for (const command of [
    new Command("auth", ["private-auth-password"]),
    new Command("hello", [3, "AUTH", "default", "private-hello-password"]),
    new Command("config", ["get", "requirepass"]),
    new Command("get", ["secret:private-key"]),
    new Command("eval", [
      "return 'private-script-secret'",
      1,
      "private-key",
      "private-arg",
    ]),
    new Command("evalsha", ["unknown-sha", 1, "private-key"]),
  ]) {
    redis.sendCommand(command);
    command.resolve("private-reply");
    await command.promise;
  }
  const binary = new Command("set", [
    "room:binary",
    Buffer.from("private-binary"),
  ]);
  redis.sendCommand(binary);
  binary.resolve("OK");
  await binary.promise;
  const failure = new Command("get", ["room:normal"]);
  redis.sendCommand(failure);
  const error = new Error("private-error-message");
  failure.reject(error);
  await assert.rejects(failure.promise, (value) => value === error);
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(values.length, 8);
  for (const value of values.slice(0, 6))
    assert.equal(value.responseBody, undefined);
  assert.equal(values[6].responseBody, "OK");
  assert.match(JSON.stringify(values[6].data), /binary/);
  assert.equal(values[7].result, "failure");
  assert.equal(values[7].responseBody, undefined);
  assert.doesNotMatch(JSON.stringify(values), /private-/);
});

test("Redis details follow production override and never inspect arguments in metadata mode", async () => {
  for (const override of [false, true]) {
    const { diagnostics, config, path } = await fixture();
    config.set("NODE_ENV", "production");
    config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
    config.set("ALLOW_PRODUCTION_DEBUG_TRAFFIC_LOGGING", String(override));
    const redis = new RedisStub();
    diagnostics.observeRedis(redis.asClient());
    const command = new Command("get", ["room:one"]);
    if (!override)
      Object.defineProperty(command, "args", {
        get() {
          throw new Error("must not inspect");
        },
      });
    redis.sendCommand(command);
    command.resolve("room-value");
    await command.promise;
    await diagnostics.onModuleDestroy();
    const [value] = await records(path);
    assert.equal(Object.hasOwn(value, "data"), override);
    assert.equal(Object.hasOwn(value, "summary"), override);
    assert.equal(Object.hasOwn(value, "responseBody"), override);
  }
});

test("Mongo full debug snapshots real BSON filters, pipeline, writes, transaction options and returned batches without changing events", async () => {
  const { BSON } = await import("mongodb");
  const { diagnostics, traffic, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  const mongo = new EventEmitter();
  diagnostics.observeMongo(mongo as MongoClient);
  const id = new BSON.ObjectId();
  const date = new Date("2026-10-17T18:00:00.000Z");
  const command = {
    find: "messages",
    filter: {
      roomId: id,
      createdAt: { $gt: date },
      passwordHash: "private-filter",
      "account.sessionId": "private-session",
    },
    projection: { text: 1 },
    sort: { createdAt: -1 },
    limit: 30,
    lsid: { id: new BSON.Binary(Buffer.from("private-binary")) },
    txnNumber: BSON.Long.fromNumber(7),
    autocommit: false,
  };
  traffic.runWithRequest(
    { requestId: "query-request", getUserId: () => "query-actor" },
    () => {
      mongo.emit("commandStarted", {
        requestId: 801,
        commandName: "find",
        databaseName: "synthetic_chat",
        command,
      });
    },
  );
  command.limit = 99;
  const reply = {
    ok: 1,
    cursor: {
      id: BSON.Long.fromString("9223372036854775800"),
      ns: "synthetic_chat.messages",
      firstBatch: [
        { _id: id, text: "visible message", passwordHash: "private-result" },
      ],
    },
  };
  mongo.emit("commandSucceeded", { requestId: 801, reply });
  assert.equal(reply.cursor.firstBatch[0].passwordHash, "private-result");
  let requestId = 802;
  for (const [commandName, command] of Object.entries({
    insert: {
      insert: "messages",
      documents: [{ text: "new message", token: "private-insert" }],
    },
    update: {
      update: "messages",
      updates: [
        {
          q: { _id: id },
          u: { $set: { text: "edited", password: "private-update" } },
          multi: false,
        },
      ],
    },
    aggregate: {
      aggregate: "messages",
      pipeline: [
        { $match: { roomId: id } },
        { $group: { _id: "$roomId", count: { $sum: 1 } } },
      ],
      cursor: {},
    },
    getMore: {
      getMore: BSON.Long.fromNumber(123),
      collection: "messages",
      batchSize: 30,
    },
    commitTransaction: {
      commitTransaction: 1,
      txnNumber: BSON.Long.fromNumber(7),
      autocommit: false,
    },
  })) {
    mongo.emit("commandStarted", {
      requestId,
      commandName,
      databaseName: "synthetic_chat",
      command,
    });
    mongo.emit("commandSucceeded", {
      requestId,
      reply: { ok: 1, n: 1, nModified: 1 },
    });
    requestId++;
  }
  await diagnostics.onModuleDestroy();
  const values = (await records(path)).filter(
    (value) => value.category === "command",
  );
  assert.equal(values.length, 6);
  assert.equal(values[0].databaseName, "synthetic_chat");
  assert.equal(values[0].collection, "messages");
  assert.equal(values[0].requestId, "query-request");
  assert.equal(values[0].userId, "query-actor");
  assert.equal(values[0].driverRequestId, 801);
  const data = values[0].data as { command: typeof command };
  assert.deepEqual(data.command.filter.roomId, { $oid: id.toHexString() });
  assert.deepEqual(data.command.filter.createdAt, { $gt: date.toISOString() });
  assert.equal(data.command.limit, 30);
  assert.equal(data.command.filter.passwordHash, "[REDACTED]");
  assert.deepEqual(data.command.txnNumber, { $numberLong: "7" });
  assert.match(
    JSON.stringify(values[0].responseBody),
    /9223372036854775800|visible message/,
  );
  assert.ok(
    values.some(
      (value) =>
        value.operation === "getMore" && value.collection === "messages",
    ),
  );
  assert.match(JSON.stringify(values), /pipeline|nModified|autocommit/);
  assert.doesNotMatch(JSON.stringify(values), /private-/);
});

test("Mongo failures keep error codes and labels while credential expressions, raw messages and unsupported commands stay private", async () => {
  const { diagnostics, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  const mongo = new EventEmitter();
  diagnostics.observeMongo(mongo as MongoClient);
  mongo.emit("commandStarted", {
    requestId: 1,
    commandName: "find",
    databaseName: "test",
    command: {
      find: "users",
      filter: { $expr: { $eq: ["$passwordHash", "private-expression"] } },
    },
  });
  const failure = Object.assign(new Error("private-error"), {
    code: 11000,
    codeName: "DuplicateKey",
    errorLabels: ["RetryableWriteError", "private-label content"],
  });
  mongo.emit("commandFailed", { requestId: 1, failure });
  mongo.emit("commandStarted", {
    requestId: 2,
    commandName: "update",
    databaseName: "test",
    command: { update: "users" },
  });
  mongo.emit("commandSucceeded", {
    requestId: 2,
    reply: {
      ok: 1,
      writeErrors: [
        {
          code: 11000,
          errmsg: "private-duplicate-secret",
          keyValue: { passwordHash: "private-key-value" },
        },
      ],
    },
  });
  mongo.emit("commandStarted", {
    requestId: 3,
    commandName: "saslStart",
    get command() {
      throw Error("private-auth");
    },
    get databaseName() {
      throw Error("private-db");
    },
  });
  mongo.emit("commandSucceeded", {
    requestId: 3,
    get reply() {
      throw Error("private-reply");
    },
  });
  await diagnostics.onModuleDestroy();
  const values = (await records(path)).filter(
    (value) => value.category === "command",
  );
  assert.deepEqual(values[0].responseBody, {
    errorType: "Error",
    details: {
      code: 11000,
      codeName: "DuplicateKey",
      errorLabels: ["RetryableWriteError"],
    },
  });
  assert.equal(values[0].result, "failure");
  assert.equal(values[2].responseBody, undefined);
  assert.match(JSON.stringify(values[2].data), /unsupported_command/);
  assert.doesNotMatch(JSON.stringify(values), /private-/);
});

test("Mongo payloads obey production policy, configuration changes and hostile inspection never interrupts driver events", async () => {
  const { diagnostics, config, path } = await fixture();
  config.set("NODE_ENV", "production");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  const mongo = new EventEmitter();
  diagnostics.observeMongo(mongo as MongoClient);
  const inaccessible = {
    requestId: 1,
    commandName: "find",
    get command() {
      throw Error("private-getter");
    },
    get databaseName() {
      throw Error("private-getter");
    },
  };
  assert.doesNotThrow(() => mongo.emit("commandStarted", inaccessible));
  assert.doesNotThrow(() =>
    mongo.emit("commandSucceeded", {
      requestId: 1,
      get reply() {
        throw Error("private-getter");
      },
    }),
  );
  config.set("ALLOW_PRODUCTION_DEBUG_TRAFFIC_LOGGING", "true");
  assert.doesNotThrow(() =>
    mongo.emit(
      "commandStarted",
      Object.create(inaccessible, { requestId: { value: 2 } }),
    ),
  );
  mongo.emit("commandSucceeded", { requestId: 2, reply: {} });
  mongo.emit("commandStarted", {
    requestId: 3,
    commandName: "find",
    databaseName: "test",
    command: { find: "users" },
  });
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "false");
  mongo.emit("commandSucceeded", {
    requestId: 3,
    get reply() {
      throw Error("must not inspect");
    },
  });
  await diagnostics.onModuleDestroy();
  const values = (await records(path)).filter(
    (value) => value.category === "command",
  );
  assert.equal(values.length, 3);
  assert.ok(
    values.every(
      (value) => value.data === undefined && value.responseBody === undefined,
    ),
  );
});

test("Mongo detail and pending-byte limits are explicit and do not lose command completion", async () => {
  const { diagnostics, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  const mongo = new EventEmitter();
  diagnostics.observeMongo(mongo as MongoClient);
  for (let requestId = 1; requestId <= 45; requestId++) {
    mongo.emit("commandStarted", {
      requestId,
      commandName: "insert",
      databaseName: "test",
      command: {
        insert: "messages",
        documents: [{ text: "x".repeat(requestId === 45 ? 300000 : 120000) }],
      },
    });
  }
  for (let requestId = 1; requestId <= 45; requestId++)
    mongo.emit("commandSucceeded", {
      requestId,
      reply: requestId === 45 ? { text: "x".repeat(300000) } : { ok: 1, n: 1 },
    });
  await diagnostics.onModuleDestroy();
  const values = (await records(path)).filter(
    (value) => value.category === "command",
  );
  assert.equal(values.length, 45);
  assert.ok(values.every((value) => value.result === "success"));
  assert.match(
    JSON.stringify(values),
    /pending_detail_byte_limit|detail_byte_limit/,
  );
  assert.match(JSON.stringify(values[44].responseBody), /detail_byte_limit/);
});

test("Centrifugo presence and disconnect diagnostics capture requests, replies and provider failures with credentials redacted", async (context) => {
  const { diagnostics, traffic, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  config.set("CENTRIFUGO_API_URL", "http://synthetic-provider.test/api");
  config.set("CENTRIFUGO_API_KEY", "private-api-key");
  let failing = false;
  let presenceReads = 0;
  context.mock.method(globalThis, "fetch", async (url: unknown) => {
    if (failing)
      return Response.json(
        { error: { code: 100, token: "private-error-token" } },
        { status: 503 },
      );
    if (String(url).endsWith("/batch"))
      return Response.json({
        replies: [{ presence_stats: { num_clients: 2, num_users: 1 } }],
      });
    if (String(url).endsWith("/presence"))
      return Response.json({
        result: {
          presence:
            ++presenceReads === 1
              ? {
                  "client-one": {
                    user: "alice",
                    conn_info: { sessionId: "private-session" },
                  },
                }
              : {},
        },
      });
    return Response.json({ result: {} });
  });
  const provider = new CentrifugoService(config, traffic, diagnostics);
  await traffic.runWithRequest(
    { requestId: "provider-request", getUserId: () => "alice" },
    async () => {
      assert.deepEqual(await provider.presenceStatuses(["alice"]), {
        alice: true,
      });
      assert.equal(
        await provider.disconnectSession("alice", "private-session"),
        true,
      );
      failing = true;
      await assert.rejects(provider.presenceStatuses(["alice"]));
    },
  );
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(values.length, 5);
  assert.ok(
    values.every(
      (value) =>
        value.requestId === "provider-request" && value.userId === "alice",
    ),
  );
  assert.ok(values.some((value) => value.operation === "disconnect"));
  assert.match(JSON.stringify(values[0].responseBody), /num_clients/);
  assert.equal(values[0].channel, "inbox:user#alice");
  assert.equal(values[0].method, "POST");
  assert.equal(values[0].path, "/api/batch");
  assert.equal(values[0].status, 200);
  assert.deepEqual((values[0].data as { channels: string[] }).channels, [
    "inbox:user#alice",
  ]);
  assert.equal(values[4].result, "failure");
  assert.match(JSON.stringify(values[4].responseBody), /100/);
  assert.doesNotMatch(JSON.stringify(values), /private-/);
});

test("Centrifugo detail bounds keep detached redacted data and explicit oversized omissions", () => {
  const original = {
    text: "publication",
    token: "private-token",
    bytes: Buffer.from([1, 2]),
  };
  const safe = centrifugoLogSnapshot(original);
  original.text = "changed";
  assert.deepEqual(safe, {
    text: "publication",
    token: "[REDACTED]",
    bytes: { kind: "binary", byteLength: 2 },
  });
  assert.deepEqual(
    centrifugoLogSnapshot({ text: "x".repeat(centrifugoDetailLimit) }),
    {
      payloadOmitted: true,
      omissionReason: "detail_byte_limit",
      omittedBytes: centrifugoDetailLimit + 11,
      limitBytes: centrifugoDetailLimit,
    },
  );
});

test("Centrifugo HTTP 200 batch errors are failures and malformed replies preserve caller validation", async (context) => {
  const { diagnostics, traffic, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  config.set("CENTRIFUGO_API_URL", "http://synthetic-provider.test/api");
  config.set("CENTRIFUGO_API_KEY", "private-api-key");
  let response: unknown = {
    replies: [{ error: { code: 102, token: "private-token" } }],
  };
  context.mock.method(globalThis, "fetch", async () => Response.json(response));
  const provider = new CentrifugoService(config, traffic, diagnostics);
  await assert.rejects(
    provider.presenceStatuses(["alice"]),
    /Realtime presence unavailable/,
  );
  response = { replies: {} };
  await assert.rejects(
    provider.presenceStatuses(["alice"]),
    /Realtime presence unavailable/,
  );
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(values[0].result, "failure");
  assert.equal((values[0].data as { status: number }).status, 200);
  assert.deepEqual(values[0].responseBody, {
    replies: [{ error: { code: 102, token: "[REDACTED]" } }],
  });
  assert.doesNotMatch(JSON.stringify(values), /private-/);
});

test("Centrifugo unreadable publish replies retain HTTP status and omission reason across retries", async (context) => {
  const { diagnostics, traffic, config, path } = await fixture();
  config.set("NODE_ENV", "development");
  config.set("DEBUG_TRAFFIC_LOGGING_ENABLED", "true");
  config.set("CENTRIFUGO_API_URL", "http://synthetic-provider.test/api");
  config.set("CENTRIFUGO_API_KEY", "private-api-key");
  traffic.writer = () => undefined;
  context.mock.method(
    globalThis,
    "fetch",
    async () => new Response("private-invalid-response", { status: 502 }),
  );
  assert.equal(
    await new CentrifugoService(config, traffic, diagnostics).publish(
      "alice",
      "epoch",
      { roomPts: 1, eventType: "room_preferences" } as HydratedRoomPayload,
    ),
    false,
  );
  await diagnostics.onModuleDestroy();
  const values = await records(path);
  assert.equal(values.length, 3);
  for (const value of values) {
    assert.equal(value.status, 502);
    assert.equal(value.result, "failure");
    assert.deepEqual(value.responseBody, {
      payloadOmitted: true,
      omissionReason: "unreadable_json_response",
    });
  }
  assert.doesNotMatch(JSON.stringify(values), /private-/);
});

test("presence purpose, channel count, status and summary survive metadata-only capture", async (context) => {
  const { path, config, traffic, diagnostics } = await fixture();
  config.set("CENTRIFUGO_API_URL", "http://synthetic.invalid/api");
  config.set("CENTRIFUGO_API_KEY", "private-fixture-key");
  context.mock.method(globalThis, "fetch", async () =>
    Response.json({
      replies: [{ presence_stats: { num_clients: 1, num_users: 1 } }],
    }),
  );
  const service = new CentrifugoService(config, traffic, diagnostics);
  assert.deepEqual(
    await service.presenceStatuses(["one"], "last_seen_observer"),
    { one: true },
  );
  await diagnostics.onModuleDestroy();
  const [record] = await records(path);
  assert.equal(record.purpose, "last_seen_observer");
  assert.equal(record.channelCount, 1);
  assert.equal(record.status, 200);
  assert.equal(record.method, "POST");
  assert.equal(record.path, "/api/batch");
  assert.equal(record.channel, "inbox:user#one");
  assert.match(record.summary!, /presence counts/);
  assert.equal(record.data, undefined);
  assert.equal(record.responseBody, undefined);
  assert.equal(JSON.stringify(record).includes("private-fixture-key"), false);
});

test("metadata-only HTTP 200 batch provider errors remain failed operations", async (context) => {
  const { path, config, traffic, diagnostics } = await fixture();
  config.set("CENTRIFUGO_API_URL", "http://synthetic.invalid/api");
  config.set("CENTRIFUGO_API_KEY", "private-fixture-key");
  context.mock.method(globalThis, "fetch", async () =>
    Response.json({ replies: [{ error: { code: 100 } }] }),
  );
  await assert.rejects(
    new CentrifugoService(config, traffic, diagnostics).presenceStatuses([
      "one",
    ]),
  );
  await diagnostics.onModuleDestroy();
  const [record] = await records(path);
  assert.equal(record.status, 200);
  assert.equal(record.result, "failure");
  assert.equal(record.purpose, "client_status");
});

test("malformed HTTP 200 presence snapshots are recorded as failures without changing caller validation", async (context) => {
  for (const reply of [
    null,
    { presence_stats: { num_clients: -1, num_users: 0 } },
    { presence_stats: { num_clients: 1, num_users: 2 } },
  ]) {
    const { path, config, traffic, diagnostics } = await fixture();
    config.set("CENTRIFUGO_API_URL", "http://synthetic.invalid/api");
    config.set("CENTRIFUGO_API_KEY", "private-fixture-key");
    const mocked = context.mock.method(globalThis, "fetch", async () =>
      Response.json({ replies: [reply] }),
    );
    await assert.rejects(
      new CentrifugoService(config, traffic, diagnostics).presenceStatuses([
        "one",
      ]),
    );
    await diagnostics.onModuleDestroy();
    const [record] = await records(path);
    assert.equal(record.status, 200);
    assert.equal(record.result, "failure");
    mocked.mock.restore();
  }
});
