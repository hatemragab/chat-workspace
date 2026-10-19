import "reflect-metadata";
import assert from "node:assert/strict";
import { test } from "node:test";
import { ConfigService } from "@nestjs/config";
import { Reflector } from "@nestjs/core";
import type { Command } from "ioredis";
import { AuthGuard } from "../src/auth/auth.guard";
import { HealthController } from "../src/health.controller";
import { DatabaseService } from "../src/infrastructure/database.service";
import { RedisSyncService } from "../src/infrastructure/redis-sync.service";

test("Mongo readiness uses driver-wide primary command timeout without Mongoose buffering", async () => {
  let request: unknown;
  const service = Object.assign(Object.create(DatabaseService.prototype), {
    connection: {
      readyState: 1,
      db: {
        admin: () => ({
          command: async (...args: unknown[]) => {
            request = args;
            return { ok: 1 };
          },
        }),
      },
    },
  }) as DatabaseService;
  await service.ping();
  assert.deepEqual(request, [
    { ping: 1 },
    { timeoutMS: 1500, readPreference: "primary" },
  ]);
  const disconnected = Object.assign(Object.create(DatabaseService.prototype), {
    connection: {},
  }) as DatabaseService;
  await assert.rejects(disconnected.ping(), /not connected/);
});

test("Redis readiness does not enqueue disconnected probes and bounds an unresponsive command", async () => {
  let commands = 0;
  const client = {
    status: "reconnecting",
    sendCommand: (command: Command) => {
      commands++;
      assert.equal(command.name, "ping");
      assert.deepEqual(command.args, []);
    },
  };
  const service = Object.assign(Object.create(RedisSyncService.prototype), {
    client,
  }) as RedisSyncService;
  await assert.rejects(service.ping(), /not connected/);
  assert.equal(commands, 0);
  client.status = "ready";
  await assert.rejects(service.ping(15), /timed out/i);
  assert.equal(commands, 1);
  client.sendCommand = (command: Command) =>
    command.resolve(Buffer.from("PONG"));
  await service.ping(15);
  client.sendCommand = () => {
    throw new Error("transport unavailable");
  };
  await assert.rejects(service.ping(15), /transport unavailable/);
});

test("health probes both dependencies concurrently and keeps the compatible response", async () => {
  const calls: unknown[] = [];
  let release!: () => void;
  const pending = new Promise<void>((resolve) => (release = resolve));
  const controller = new HealthController(
    {
      ping: (timeout: number) => {
        calls.push(["mongo", timeout]);
        return pending;
      },
    } as never,
    {
      ping: (timeout: number) => {
        calls.push(["redis", timeout]);
        return pending;
      },
    } as never,
  );
  const response = controller.health();
  assert.deepEqual(calls, [
    ["mongo", 1500],
    ["redis", 1500],
  ]);
  release();
  assert.deepEqual(await response, { status: "ok", mongo: "ok", redis: "ok" });
});

test("health GET and HEAD are public and dependency failures are sanitized 503", async () => {
  const guard = new AuthGuard(
    new Reflector(),
    {} as never,
    new ConfigService(),
    {} as never,
    {} as never,
  );
  for (const handler of [
    HealthController.prototype.health,
    HealthController.prototype.head,
  ]) {
    assert.equal(
      await guard.canActivate({
        getHandler: () => handler,
        getClass: () => HealthController,
      } as never),
      true,
    );
  }
  for (const unavailable of ["mongo", "redis"]) {
    const dependency = (name: string) => ({
      ping: async () => {
        if (name === unavailable) throw new Error("private dependency details");
      },
    });
    const controller = new HealthController(
      dependency("mongo") as never,
      dependency("redis") as never,
    );
    for (const action of [() => controller.health(), () => controller.head()])
      await assert.rejects(action(), (error: unknown) => {
        const failure = error as {
          getStatus(): number;
          getResponse(): unknown;
        };
        assert.equal(failure.getStatus(), 503);
        assert.equal(
          JSON.stringify(failure.getResponse()).includes("private"),
          false,
        );
        return true;
      });
  }
});
