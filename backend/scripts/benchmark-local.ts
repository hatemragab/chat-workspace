import "reflect-metadata";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import { ConfigService } from "@nestjs/config";
import { Types } from "mongoose";
import type { DatabaseService } from "../src/infrastructure/database.service";
import type { CentrifugoService } from "../src/infrastructure/centrifugo.service";
import type { INestApplication } from "@nestjs/common";
const { createApplication } = require("../dist/main.js") as {
  createApplication: () => Promise<INestApplication>;
};
const BuiltDatabase =
  require("../dist/infrastructure/database.service.js").DatabaseService;
const BuiltProvider =
  require("../dist/infrastructure/centrifugo.service.js").CentrifugoService;

type ExplainResult = {
  queryPlanner: { winningPlan: unknown };
  executionStats: {
    executionTimeMillis: number;
    totalKeysExamined: number;
    totalDocsExamined: number;
    nReturned: number;
  };
};

async function main() {
  if (process.env.NODE_ENV === "production")
    throw new Error("Local synthetic benchmark only");
  for (const path of [".env", "../centrifugo/.env"])
    if (existsSync(path))
      Object.assign(process.env, parseEnv(readFileSync(path, "utf8")));
  const run = randomUUID().replaceAll("-", "");
  Object.assign(process.env, {
    NODE_ENV: "development",
    MONGODB_URI: `mongodb://127.0.0.1:27017/chat_benchmark_${run}?replicaSet=rs0`,
    REDIS_KEY_PREFIX: `chat-benchmark:${run}:`,
    HTTP_LOGGING_ENABLED: "false",
    DEBUG_TRAFFIC_LOGGING_ENABLED: "false",
    LOCAL_SERVICE_LOG_FILE: "off",
    TRAFFIC_LOG_FILE: "off",
  });
  const app = await createApplication();
  app.useLogger(false);
  await app.listen(0, "127.0.0.1");
  const base = await app.getUrl();
  const db = app.get<DatabaseService>(BuiltDatabase);
  const config = app.get(ConfigService);
  const provider = app.get<CentrifugoService>(BuiltProvider);
  const originalFetch = globalThis.fetch,
    originalPublish = provider.publish;
  let active = 0,
    peak = 0,
    publications = 0;
  provider.publish = async function (
    ...args: Parameters<typeof originalPublish>
  ) {
    active++;
    peak = Math.max(peak, active);
    publications++;
    try {
      return await originalPublish.apply(this, args);
    } finally {
      active--;
    }
  };
  const call = async (path: string, token?: string, body?: unknown) => {
    const start = performance.now();
    const response = await fetch(base + path, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const data = await response.json();
    if (response.status >= 400)
      throw new Error(`Benchmark request failed ${response.status}`);
    return { data, ms: performance.now() - start };
  };
  try {
    const { data: auth } = await call("/auth/debug-login", undefined, {
      debugUserNumber: 1,
    });
    const synthetic = await db.users.insertMany(
      Array.from({ length: 99 }, (_, i) => ({
        username: `bench_${run}_${i}`,
        email: `bench_${run}_${i}@example.test`,
        displayName: `Benchmark ${i}`,
        passwordHash: "unusable-synthetic-benchmark-password",
      })),
    );
    const group = await call("/rooms/group", auth.accessToken, {
      title: "Synthetic 100-member benchmark",
      participantIds: synthetic.map((user) => user._id.toString()),
    });
    const groupCreation = { ms: Math.round(group.ms), peak, publications };
    peak = 0;
    publications = 0;
    const target =
      config.getOrThrow<string>("CENTRIFUGO_API_URL").replace(/\/$/, "") +
      "/publish";
    globalThis.fetch = async (input, init) => {
      if (typeof input === "string" && input === target)
        await new Promise((r) => setTimeout(r, 50));
      return originalFetch(input, init);
    };
    const sends = await Promise.all(
      Array.from({ length: 3 }, async (_, i) => {
        const sent = await call("/messages", auth.accessToken, {
          roomId: group.data.room.roomId,
          idempotencyKey: randomUUID(),
          type: "text",
          text: `Synthetic measured concurrent send ${i}`,
        });
        return Math.round(sent.ms);
      }),
    );
    const slowdown = {
      injectedProviderLatencyMs: 50,
      concurrentSendRequests: 3,
      sendDurationsMs: sends,
      peak,
      publications,
      storedMessages: await db.messages.countDocuments({
        roomId: new Types.ObjectId(group.data.room.roomId),
      }),
    };
    peak = 0;
    publications = 0;
    config.set("INBOX_FANOUT_DEADLINE_MS", 100);
    config.set("REALTIME_PUBLISH_TIMEOUT_MS", 75);
    const bounded = await call("/messages", auth.accessToken, {
      roomId: group.data.room.roomId,
      idempotencyKey: randomUUID(),
      type: "text",
      text: "Synthetic committed send under fanout deadline",
    });
    const committed = await db.messages.exists({
      _id: new Types.ObjectId(bounded.data.message.id),
    });
    const deadline = {
      configuredDeadlineMs: 100,
      httpMs: Math.round(bounded.ms),
      peak,
      publications,
      committed: !!committed,
    };
    globalThis.fetch = originalFetch;
    // Representative receipt query shapes over 20,000 retained rows. No application fixture deletion.
    const roomId = new Types.ObjectId(),
      senderId = new Types.ObjectId(auth.user.id),
      otherId = synthetic[0]._id;
    const baseTime = Date.now() - 60000;
    await db.messages.insertMany(
      Array.from({ length: 20000 }, (_, i) => ({
        roomId,
        roomType: "direct",
        senderId: i % 2 ? otherId : senderId,
        senderName: "Benchmark",
        idempotencyKey: randomUUID(),
        type: "text",
        text: "Synthetic receipt plan row",
        createdAt: new Date(baseTime + i),
        deliveredAt: i < 18000 ? new Date(baseTime + 30000) : null,
        seenAt: i < 16000 ? new Date(baseTime + 40000) : null,
      })),
    );
    const queries: Record<string, unknown> = {};
    for (const field of ["deliveredAt", "seenAt"] as const) {
      const explain = (await db.messages
        .find({
          roomId,
          roomType: "direct",
          senderId,
          [field]: { $type: "date" },
        })
        .select({ createdAt: 1 })
        .sort({ createdAt: -1, _id: -1 })
        .limit(1)
        .explain("executionStats")) as unknown as ExplainResult;
      const gap = (await db.messages
        .find({
          roomId,
          roomType: "direct",
          senderId,
          [field]: null,
          createdAt: { $lte: new Date(baseTime + 15998) },
        })
        .limit(1)
        .explain("executionStats")) as unknown as ExplainResult;
      const summary = (plan: ExplainResult) => ({
        winningPlan: plan.queryPlanner.winningPlan,
        executionTimeMillis: plan.executionStats.executionTimeMillis,
        totalKeysExamined: plan.executionStats.totalKeysExamined,
        totalDocsExamined: plan.executionStats.totalDocsExamined,
        nReturned: plan.executionStats.nReturned,
      });
      queries[field] = { boundary: summary(explain), gap: summary(gap) };
    }
    const mediaPlan = (await db.messages
      .find({
        isDeletedForAll: false,
        deletedForUsers: { $nin: [senderId] },
        $or: [
          {
            imageUrl: {
              $eq: "/public/uploads/synthetic-explain.png",
              $type: "string",
            },
          },
          {
            "replyTo.imageUrl": {
              $eq: "/public/uploads/synthetic-explain.png",
              $type: "string",
            },
            "replyTo.isDeleted": false,
          },
        ],
      })
      .limit(1)
      .explain("executionStats")) as unknown as ExplainResult;
    const mediaQuery = {
      winningPlan: mediaPlan.queryPlanner.winningPlan,
      totalDocsExamined: mediaPlan.executionStats.totalDocsExamined,
      totalKeysExamined: mediaPlan.executionStats.totalKeysExamined,
      nReturned: mediaPlan.executionStats.nReturned,
    };
    process.stdout.write(
      JSON.stringify({
        runId: run,
        groupSize: 100,
        groupCreation,
        slowdown,
        deadline,
        receiptRows: 20000,
        queries,
        mediaQuery,
      }) + "\n",
    );
  } finally {
    globalThis.fetch = originalFetch;
    provider.publish = originalPublish;
    await app.close();
  }
}
void main().catch((error) => {
  process.stderr.write(
    `Local benchmark failed: ${error instanceof Error ? error.name : "Error"}\n`,
  );
  process.exitCode = 1;
});
