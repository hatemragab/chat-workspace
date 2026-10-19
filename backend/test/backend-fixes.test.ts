import "reflect-metadata";
import assert from "node:assert/strict";
import { test } from "node:test";
import { ConfigService } from "@nestjs/config";
import { ValidationPipe } from "@nestjs/common";
import { AuthGuard } from "../src/auth/auth.guard";
import {
  SendMessageDto,
  GroupDto,
  DeliveredBatchDto,
  PresenceQuery,
  RoomsQuery,
} from "../src/chat/dto";
import { BoundedWork } from "../src/infrastructure/bounded-work";

const id = "507f1f77bcf86cd799439011";
function guard(
  dependency: "mongo" | "redis" | "none",
  retired = false,
  invalid = false,
) {
  return new AuthGuard(
    { getAllAndOverride: () => false } as never,
    {
      verifyAsync: async () => {
        if (invalid) throw new Error("invalid");
        return { sub: id };
      },
    } as never,
    new ConfigService({ JWT_SECRET: "synthetic" }),
    {
      users: {
        exists: async () => {
          if (dependency === "mongo") throw new Error("unavailable");
          return true;
        },
      },
    } as never,
    {
      isSessionRetired: async () => {
        if (dependency === "redis") throw new Error("unavailable");
        return retired;
      },
    } as never,
  );
}
const context = () =>
  ({
    getHandler: () => null,
    getClass: () => null,
    switchToHttp: () => ({
      getRequest: () => ({
        headers: { authorization: "Bearer synthetic" },
        method: "GET",
        path: "/users",
      }),
    }),
  }) as never;
test("guard keeps dependency failures retryable while rejecting invalid and retired sessions", async () => {
  for (const dependency of ["mongo", "redis"] as const)
    await assert.rejects(guard(dependency).canActivate(context()), {
      status: 503,
    });
  await assert.rejects(guard("none", true).canActivate(context()), {
    status: 401,
  });
  await assert.rejects(guard("none", false, true).canActivate(context()), {
    status: 401,
  });
  assert.equal(await guard("none").canActivate(context()), true);
});
test("JSON and query ObjectIds are canonical before identity comparisons and duplicate validation", async () => {
  const pipe = new ValidationPipe({ transform: true, whitelist: true });
  const validate = (
    value: unknown,
    type:
      | typeof SendMessageDto
      | typeof GroupDto
      | typeof DeliveredBatchDto
      | typeof PresenceQuery
      | typeof RoomsQuery,
  ) => pipe.transform(value, { type: "body", metatype: type });
  const send = await validate(
    {
      peerUserId: id.toUpperCase(),
      idempotencyKey: "123e4567-e89b-42d3-a456-426614174000",
      type: "text",
      text: "test",
    },
    SendMessageDto,
  );
  assert.equal(send.peerUserId, id);
  assert.deepEqual(
    (await validate({ userIds: id.toUpperCase() }, PresenceQuery)).userIds,
    [id],
  );
  assert.deepEqual(
    (await validate({ userIds: [id.toUpperCase()] }, PresenceQuery)).userIds,
    [id],
  );
  await assert.rejects(
    validate(
      { title: "test", participantIds: [id, id.toUpperCase()] },
      GroupDto,
    ),
    { status: 400 },
  );
  await assert.rejects(
    validate({ roomIds: [id, id.toUpperCase()] }, DeliveredBatchDto),
    { status: 400 },
  );
  assert.equal(
    (
      await validate(
        { beforeRoomId: id.toUpperCase(), pinnedLimit: 2, pinnedOnly: "true" },
        RoomsQuery,
      )
    ).beforeRoomId,
    id,
  );
});
test("bounded work caps concurrency, rejects overload and never starts expired queued work", async () => {
  const work = new BoundedWork(1, 1);
  let release!: () => void;
  let started = 0;
  const first = work.run(async () => {
    started++;
    await new Promise<void>((r) => (release = r));
  });
  const expired = work.run(async () => {
    started++;
  }, Date.now() + 15);
  await assert.rejects(
    work.run(async () => {}),
    { status: 503 },
  );
  await assert.rejects(expired, { status: 503 });
  release();
  await first;
  await work.run(async () => {
    started++;
  });
  assert.equal(started, 2);
});

test("upload permits are acquired before parsing and released once on client close", async () => {
  const { EventEmitter } = await import("node:events");
  const { UploadBudgetGuard } = await import("../src/chat/uploads.controller");
  const responses = [new EventEmitter(), new EventEmitter()];
  let calls = 0;
  const guard = new UploadBudgetGuard(
    new ConfigService({
      UPLOAD_MAX_CONCURRENT: 1,
      UPLOAD_MAX_CONCURRENT_PER_USER: 1,
    }),
    {
      limitRealtime: async () => {
        calls++;
      },
    } as never,
  );
  const context = (index: number) =>
    ({
      switchToHttp: () => ({
        getRequest: () => ({ userId: id, ip: "127.0.0.1" }),
        getResponse: () => responses[index],
      }),
    }) as never;
  assert.equal(await guard.canActivate(context(0)), true);
  await assert.rejects(guard.canActivate(context(1)), { status: 429 });
  responses[0].emit("close");
  responses[0].emit("finish");
  assert.equal(await guard.canActivate(context(1)), true);
  responses[1].emit("finish");
  assert.equal(calls, 3);
});

test(
  "cancelled private media streams close actual file handles, including already disconnected responses",
  { timeout: 2000 },
  async () => {
    const { mkdtemp, writeFile, open } = await import("node:fs/promises");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const { Writable } = await import("node:stream");
    const { MediaController } = await import("../src/chat/uploads.controller");
    const directory = await mkdtemp(join(tmpdir(), "chat-media-stream-"));
    const path = join(directory, "synthetic.png");
    await writeFile(path, Buffer.alloc(65536));
    class Response extends Writable {
      set() {
        return this;
      }
      override _write(
        _chunk: Buffer,
        _encoding: BufferEncoding,
        callback: (error?: Error | null) => void,
      ) {
        setImmediate(callback);
      }
    }
    for (const preclosed of [false, true]) {
      const file = await open(path, "r");
      const response = new Response();
      if (preclosed) response.destroy();
      const controller = new MediaController({
        read: async () => ({ file, mime: "image/png", bytes: 65536 }),
      } as never);
      await controller.image(id, "synthetic.png", response as never);
      if (!preclosed) response.destroy();
      const until = Date.now() + 1500;
      while (file.fd >= 0 && Date.now() < until)
        await new Promise((r) => setTimeout(r, 5));
      assert.equal(file.fd, -1);
    }
  },
);

test("week-old retained pending uploads remain owner-readable and attachable until explicit cleanup", async () => {
  const { UploadsService } = await import("../src/chat/uploads.service");
  const { Types } = await import("mongoose");
  const { mkdir, writeFile } = await import("node:fs/promises");
  const { randomUUID } = await import("node:crypto");
  const { join } = await import("node:path");
  const filename = `pending_${randomUUID()}.png`;
  const path = `/public/uploads/${filename}`;
  await mkdir(join(process.cwd(), "public/uploads"), { recursive: true });
  await writeFile(
    join(process.cwd(), "public/uploads", filename),
    Buffer.from([137, 80, 78, 71]),
    { flag: "wx", mode: 0o600 },
  );
  let attachments = 0;
  const upload = {
    ownerId: new Types.ObjectId(id),
    state: "retained",
    attachedAt: null,
    orphanEligibleAt: new Date(Date.now() - 8 * 86400000),
  };
  const service = new UploadsService(
    {
      uploads: {
        findOne: () => ({ session: () => ({ lean: async () => upload }) }),
        updateOne: async () => {
          attachments++;
          return { matchedCount: 1 };
        },
      },
    } as never,
    new ConfigService(),
  );
  assert.equal(await service.canRead(id, path), true);
  const retained = await service.read(id, filename);
  assert.equal(retained.bytes, 4);
  await retained.file.close();
  await service.attach(id, path, {} as never);
  assert.equal(attachments, 1);
});
