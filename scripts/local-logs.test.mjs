import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import {
  appendFile,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { childEnvironment } from "./backend-logs.mjs";
import { patchedVectorPaths } from "./vector-source-build.mjs";
import {
  discoverNativeLogs,
  localLogPaths,
  vectorConfiguration,
} from "./local-logs.mjs";

async function temporaryRoot(t) {
  const root = await mkdtemp(
    join(await realpath(tmpdir()), "chat-local-logs-test-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}
const disabledNative = {
  LOCAL_REDIS_LOG_FILE: "off",
  LOCAL_MONGODB_LOG_FILE: "off",
  LOCAL_CENTRIFUGO_LOG_FILE: "off",
};

test("collector runtime paths remain local and distinguish raw inputs, retained output and Vector state", () => {
  const paths = localLogPaths("/synthetic/project");
  assert.equal(paths.directory, "/synthetic/project/.runtime/observability");
  assert.equal(
    paths.backend,
    "/synthetic/project/.runtime/backend-logs/traffic.jsonl",
  );
  assert.equal(paths.flutter, join(paths.inputs, "flutter.jsonl"));
  assert.equal(paths.services, join(paths.inputs, "services.jsonl"));
  assert.equal(paths.events, join(paths.directory, "events.jsonl"));
  assert.equal(paths.state, join(paths.directory, "vector-state"));
  assert.equal(
    new Set([paths.flutter, paths.services, paths.backend, paths.events]).size,
    4,
  );
});

test("Vector fan-in uses bounded checkpointed file inputs and one local JSONL sink with no network source, metrics or telemetry output", () => {
  const paths = localLogPaths("/synthetic/project");
  const config = vectorConfiguration(paths, { captureId: "capture-one" });
  assert.equal(config.api, undefined);
  assert.equal(config.data_dir, paths.state);
  assert.deepEqual(Object.keys(config.sources).sort(), [
    "backend",
    "flutter",
    "services",
  ]);
  assert.equal(Object.keys(config.sinks).length, 1);
  for (const [name, source] of Object.entries(config.sources)) {
    assert.equal(source.type, "file");
    assert.equal(source.include[0], paths[name]);
    assert.equal(source.include.length, 2);
    assert.match(source.include[1], /\/archives\/[a-z]+\.\*\.jsonl$/);
    assert.equal(source.read_from, "beginning");
    assert.equal(source.ignore_checkpoints, false);
    assert.equal(source.glob_minimum_cooldown_ms, 250);
    assert.ok(
      source.max_line_bytes > 0 && source.max_line_bytes <= 1024 * 1024,
    );
    assert.ok(source.max_read_bytes > 0 && source.max_read_bytes <= 256 * 1024);
  }
  const sink = config.sinks.capture;
  assert.equal(sink.type, "file");
  assert.equal(sink.path, paths.events);
  assert.deepEqual(sink.encoding, {
    codec: "json",
    timestamp_format: "rfc3339",
  });
  assert.deepEqual(sink.framing, { method: "newline_delimited" });
  assert.ok(sink.buffer.max_events <= 1000 && sink.buffer.max_events > 0);
  assert.equal(sink.buffer.when_full, "block");
  assert.deepEqual(
    new Set(sink.inputs),
    new Set(Object.keys(config.transforms)),
  );
  assert.ok(
    Object.values(config.transforms).every(
      (transform) =>
        transform.type === "remap" && transform.drop_on_error === true,
    ),
  );
});

test("native server sources begin at the current tail and form a valid transform graph without name collisions", () => {
  const paths = localLogPaths("/synthetic/project");
  const nativeFiles = {
    redis: "/synthetic/redis.log",
    mongodb: "/synthetic/mongodb.log",
    centrifugo: "/synthetic/centrifugo.log",
  };
  const config = vectorConfiguration(paths, {
    captureId: "capture-two",
    nativeFiles,
  });
  const sourceNames = new Set(Object.keys(config.sources));
  const transformNames = new Set(Object.keys(config.transforms));
  for (const transformName of transformNames)
    assert.equal(
      sourceNames.has(transformName),
      false,
      `Vector component IDs must be globally unique: ${transformName}`,
    );
  for (const service of Object.keys(nativeFiles)) {
    const source = config.sources[`native_${service}`];
    assert.deepEqual(source.include, [nativeFiles[service]]);
    assert.equal(
      source.read_from,
      "end",
      "Startup does not import historical native server secrets/data",
    );
    assert.equal(source.ignore_checkpoints, false);
    assert.equal(source.glob_minimum_cooldown_ms, 250);
    const transform = Object.values(config.transforms).find((value) =>
      value.inputs.includes(`native_${service}`),
    );
    assert.ok(transform, `Native ${service} is connected to a normalizer`);
    assert.equal(transform.drop_on_error, true);
  }
  for (const transform of Object.values(config.transforms))
    for (const input of transform.inputs)
      assert.ok(
        sourceNames.has(input),
        `Normalizer references an existing file source: ${input}`,
      );
  for (const input of config.sinks.capture.inputs)
    assert.ok(transformNames.has(input));
});

test("native source selection rejects unrecognized services and capture labels remain quoted as data in VRL", () => {
  const paths = localLogPaths("/synthetic/project");
  assert.throws(
    () =>
      vectorConfiguration(paths, {
        captureId: "capture",
        nativeFiles: { arbitrary: "/synthetic/input" },
      }),
    /Invalid service source/,
  );
  const captureId = 'capture"\n.source = "forged"';
  const config = vectorConfiguration(paths, { captureId });
  for (const transform of Object.values(config.transforms)) {
    assert.ok(
      transform.source.includes(`.captureId = ${JSON.stringify(captureId)}`),
    );
    assert.equal(
      transform.source.split("\n").includes('.source = "forged"'),
      false,
    );
  }
});

test("native log discovery honors explicit off and explicit regular files without reading their contents", async (t) => {
  const root = await temporaryRoot(t);
  const files = {
    redis: join(root, "redis.log"),
    mongodb: join(root, "mongodb.log"),
    centrifugo: join(root, "centrifugo.log"),
  };
  for (const file of Object.values(files))
    await writeFile(
      file,
      "Synthetic private server content that discovery must not parse\n",
    );
  assert.deepEqual(await discoverNativeLogs(disabledNative), {});
  const selected = await discoverNativeLogs({
    LOCAL_REDIS_LOG_FILE: files.redis,
    LOCAL_MONGODB_LOG_FILE: files.mongodb,
    LOCAL_CENTRIFUGO_LOG_FILE: files.centrifugo,
  });
  assert.deepEqual(selected, files);
  assert.deepEqual(
    await discoverNativeLogs({
      ...disabledNative,
      LOCAL_REDIS_LOG_FILE: files.redis,
    }),
    { redis: files.redis },
  );
  assert.equal(
    await readFile(files.redis, "utf8"),
    "Synthetic private server content that discovery must not parse\n",
  );
});

test("native Centrifugo discovery follows the workspace file when present and honors overrides and off", async (t) => {
  const root = await temporaryRoot(t);
  const inherited = {
    LOCAL_REDIS_LOG_FILE: "off",
    LOCAL_MONGODB_LOG_FILE: "off",
  };
  assert.deepEqual(await discoverNativeLogs(inherited, root), {});
  const file = join(
    root,
    ".runtime/observability/inputs/centrifugo-server.log",
  );
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  await writeFile(file, "Synthetic native Centrifugo fixture\n", {
    mode: 0o600,
  });
  assert.deepEqual(await discoverNativeLogs(inherited, root), {
    centrifugo: file,
  });
  assert.deepEqual(
    await discoverNativeLogs(
      { ...inherited, LOCAL_CENTRIFUGO_LOG_FILE: "off" },
      root,
    ),
    {},
  );
  const alternate = join(root, "alternate.log");
  await writeFile(alternate, "Synthetic alternate Centrifugo fixture\n");
  assert.deepEqual(
    await discoverNativeLogs(
      { ...inherited, LOCAL_CENTRIFUGO_LOG_FILE: alternate },
      root,
    ),
    { centrifugo: alternate },
  );
});

test("native log discovery fails closed for explicit missing paths, directories and symbolic links without exposing paths", async (t) => {
  const root = await temporaryRoot(t);
  const target = join(root, "private-native.log");
  await writeFile(target, "preserve this private native fixture");
  const alias = join(root, "alias-native.log");
  await symlink(target, alias);
  for (const file of [join(root, "missing.log"), root, alias])
    await assert.rejects(
      discoverNativeLogs({ ...disabledNative, LOCAL_REDIS_LOG_FILE: file }),
      (error) => {
        assert.equal(error.message.includes(root), false);
        return /Could not read a configured local service log/.test(
          error.message,
        );
      },
    );
  assert.equal(
    await readFile(target, "utf8"),
    "preserve this private native fixture",
  );
});

test("native log discovery rejects a symlinked parent for every explicitly configured service", async (t) => {
  const root = await temporaryRoot(t);
  const directory = join(root, "canonical-native-directory");
  await mkdir(directory, { mode: 0o700 });
  const target = join(directory, "server.log");
  await writeFile(target, "preserved synthetic native data\n", { mode: 0o600 });
  const alias = join(root, "linked-native-directory");
  await symlink(directory, alias);
  const linkedFile = join(alias, "server.log");
  for (const setting of [
    "LOCAL_REDIS_LOG_FILE",
    "LOCAL_MONGODB_LOG_FILE",
    "LOCAL_CENTRIFUGO_LOG_FILE",
  ]) {
    await assert.rejects(
      discoverNativeLogs({ ...disabledNative, [setting]: linkedFile }),
      (error) => {
        assert.equal(
          error.message,
          "Could not read a configured local service log.",
        );
        assert.equal(error.message.includes(root), false);
        return true;
      },
    );
  }
  assert.deepEqual(
    await discoverNativeLogs({
      ...disabledNative,
      LOCAL_REDIS_LOG_FILE: target,
    }),
    { redis: target },
  );
  assert.equal(
    await readFile(target, "utf8"),
    "preserved synthetic native data\n",
  );
  assert.equal((await stat(target)).mode & 0o777, 0o600);
});

const installedVector = patchedVectorPaths(
  fileURLToPath(new URL("../", import.meta.url)),
).binary;
test(
  "installed Vector preserves context, structured severity and native credential redaction without Mongo attributes",
  { skip: !existsSync(installedVector), timeout: 20_000 },
  async (t) => {
    const root = await temporaryRoot(t);
    const paths = localLogPaths(root);
    for (const directory of [paths.inputs, dirname(paths.backend), paths.state])
      await mkdir(directory, { recursive: true, mode: 0o700 });
    await writeFile(paths.events, "", { mode: 0o600 });
    const timestamp = "2026-10-17T10:00:00.000Z";
    const startup = {
      timestamp,
      event: "fixture_startup",
      source: "backend",
      requestId: "startup-request",
      padding: "synthetic-padding-".repeat(12),
    };
    for (const file of [paths.backend, paths.services, paths.flutter])
      await writeFile(file, JSON.stringify(startup) + "\n", { mode: 0o600 });
    const nativeFiles = {
      redis: join(root, "synthetic-redis.log"),
      mongodb: join(root, "synthetic-mongodb.log"),
      centrifugo: join(root, "synthetic-centrifugo.log"),
    };
    for (const file of Object.values(nativeFiles))
      await writeFile(
        file,
        "baseline-only-should-not-replay ".repeat(12) + "\n",
        { mode: 0o600 },
      );
    const configuration = vectorConfiguration(paths, {
      captureId: "synthetic-vector-capture",
      nativeFiles,
      captureStart: "2026-10-17T09:59:59.999Z",
    });
    const configPath = join(paths.directory, "synthetic-vector-config.json");
    await writeFile(configPath, JSON.stringify(configuration), { mode: 0o600 });
    let child;
    const previousMask = process.umask(0o077);
    try {
      child = spawn(installedVector, ["--config", configPath], {
        env: {
          ...childEnvironment(),
          VECTOR_LOG: "error",
          VECTOR_THREADS: "2",
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
    } finally {
      process.umask(previousMask);
    }
    let exited = false;
    let childError;
    let diagnostics = "";
    const closed = new Promise((resolve) => {
      child.once("error", (error) => {
        childError = error;
      });
      child.once("close", () => {
        exited = true;
        resolve();
      });
    });
    for (const stream of [child.stdout, child.stderr])
      stream.on("data", (chunk) => {
        if (diagnostics.length < 65536) diagnostics += chunk.toString("utf8");
      });
    t.after(async () => {
      if (!exited) {
        child.kill("SIGTERM");
        const force = setTimeout(() => child.kill("SIGKILL"), 3000);
        force.unref();
        await closed;
        clearTimeout(force);
      }
    });
    async function captured() {
      const text = await readFile(paths.events, "utf8");
      return text
        .split("\n")
        .filter(Boolean)
        .flatMap((line) => {
          try {
            return [JSON.parse(line)];
          } catch {
            return [];
          }
        });
    }
    async function until(predicate) {
      const deadline = Date.now() + 8000;
      while (Date.now() < deadline) {
        if (childError || exited)
          assert.fail(
            `Synthetic Vector fixture stopped: ${childError?.message ?? diagnostics}`,
          );
        const values = await captured();
        if (predicate(values)) return values;
        await delay(40);
      }
      assert.fail(
        `Synthetic Vector fixture did not produce expected records: ${diagnostics}`,
      );
    }
    await until((values) =>
      values.some((value) => value.event === "fixture_startup"),
    );
    await delay(150);
    const core = [
      [
        paths.backend,
        {
          timestamp,
          level: "info",
          source: "backend",
          event: "http_request",
          requestId: "synthetic-flow",
          userId: "synthetic-user",
          method: "POST",
          route: "/messages",
          status: 200,
        },
      ],
      [
        paths.services,
        {
          timestamp,
          level: "info",
          source: "redis",
          event: "service_operation",
          origin: "backend_client",
          requestId: "synthetic-flow",
          userId: "synthetic-user",
          operation: "eval",
          durationMs: 8.2,
        },
      ],
      [
        paths.flutter,
        {
          timestamp,
          level: "info",
          source: "flutter",
          event: "flutter_inspector",
          origin: "inspector",
          requestId: "synthetic-flow",
          userId: "synthetic-user",
          instanceId: "synthetic-tab-two",
          category: "realtime",
          name: "inbox.publication",
          receivedAt: "2026-10-17T10:00:01.000Z",
          phase: "end",
          seq: 21,
          traceId: "synthetic-t19",
          spanId: "synthetic-s21",
          parentSpanId: "synthetic-s20",
          sessionGeneration: 3,
          durationMicros: 265300,
        },
      ],
    ];
    for (const [file, value] of core)
      await appendFile(file, JSON.stringify(value) + "\n");
    const redisLines = [
      'SyntheticRedis quoted password="two words"',
      "SyntheticRedis cookies cookie: a=one; b=two",
      "SyntheticRedis bearer rejected Bearer syntheticbearersecret",
      "SyntheticRedis JWT rejected eyJheader.eyJpayload.signature",
      "SyntheticRedis URI failed redis://syntheticlogin:syntheticpass@127.0.0.1:6379",
      'SyntheticRedis plain error password="plain credential fixture"',
      'SyntheticRedis plain warning password="plain warning fixture"',
      "SyntheticRedis plain warn token=plain-warning-token",
      "SyntheticRedis warning error secret=plain-warning-error",
    ];
    await appendFile(nativeFiles.redis, redisLines.join("\n") + "\n");
    await appendFile(
      nativeFiles.mongodb,
      [
        JSON.stringify({
          t: { $date: "2026-10-17T12:00:00.123+02:00" },
          s: "E",
          c: "COMMAND",
          id: 22430,
          msg: "SyntheticMongo operation",
          attr: {
            query: {
              text: "synthetic-private-query-content",
              password: "synthetic-private-attribute-password",
            },
          },
        }),
        JSON.stringify({
          t: { $date: "private-invalid-timestamp" },
          s: "I",
          c: "password=private-component",
          id: "private-event-code",
          msg: "SyntheticMongo invalid metadata",
        }),
        JSON.stringify({
          t: { $date: "2026-99-99T99:99:99Z" },
          id: -1,
          msg: "SyntheticMongo impossible date",
        }),
        JSON.stringify({
          id: 9007199254740992,
          msg: "SyntheticMongo unsafe integer",
        }),
      ].join("\n") + "\n",
    );
    await appendFile(
      paths.backend,
      JSON.stringify({
        timestamp: "2026-10-16T00:00:00.000Z",
        source: "backend",
        event: "synthetic_pre_reset",
        level: "error",
        requestId: null,
        userId: null,
      }) + "\n",
    );
    const centrifugoCases = [
      {
        record: {
          level: "warn",
          time: "2026-10-17T10:00:00.456Z",
          message: 'SyntheticCentrifugo password="two more words"',
          fields: { data: "synthetic-private-provider-content" },
          logRecordId: "a".repeat(32),
          logDeliveryAttempt: 2,
          logPreviousWriteOutcome: "uncertain",
        },
        expected: "warn",
      },
      {
        record: {
          level: "debug",
          time: timestamp,
          message: "client command error",
          code: 106,
          client: "11111111-2222-4333-8444-555555555555",
          user: "synthetic-user",
          channel: "inbox:user#synthetic-user",
          reason: "no pong",
          error:
            "dial tcp redis://name:password@localhost:6379: connection refused",
          serverRunId: "11111111-2222-4333-8444-555555555555",
          command: "private-native-command",
        },
        expected: "debug",
      },
      {
        record: {
          level: "info",
          s: "E",
          message: "SyntheticCentrifugo explicit info error response",
          logRecordId: "private-invalid-id",
          logDeliveryAttempt: 33,
          logPreviousWriteOutcome: "private-invalid-outcome",
        },
        expected: "info",
      },
      {
        record: {
          level: "info",
          message: "SyntheticCentrifugo explicit info warning response",
        },
        expected: "info",
      },
      {
        record: {
          level: "warn",
          message: "SyntheticCentrifugo explicit warn error response",
        },
        expected: "warn",
      },
      {
        record: {
          level: " ERROR ",
          message: "SyntheticCentrifugo explicit failure response",
        },
        expected: "error",
      },
      {
        record: {
          level: "debug",
          message: "SyntheticCentrifugo debug error detail",
        },
        expected: "debug",
      },
      {
        record: {
          level: "",
          s: "W",
          message: "SyntheticCentrifugo alternative warning error response",
        },
        expected: "warn",
      },
      {
        record: {
          level: "unknown",
          message: "SyntheticCentrifugo unusable severity error response",
        },
        expected: "error",
      },
      {
        record: {
          message: "SyntheticCentrifugo absent severity fatal response",
        },
        expected: "error",
      },
    ];
    for (const level of ["trace", "fatal", "panic", "none"]) {
      centrifugoCases.push({
        record: { level, message: `SyntheticCentrifugo ${level} detail` },
        expected: level,
      });
    }
    const httpCases = [
      ...[
        ["158.792µs", 0.158792],
        ["158.792μs", 0.158792],
        ["125.875us", 0.125875],
        ["12ns", 0.000012],
        ["3.5ms", 3.5],
        ["1.25s", 1250],
        ["1h2m3.004005006s", 3723004.005006],
        ["0s", 0],
      ].map(([duration, durationMs]) => ({
        fields: { duration },
        expected: {
          method: "POST",
          path: "/api/publish",
          status: 200,
          duration,
          durationMs,
        },
      })),
      {
        fields: {
          method: " get ",
          path: "/connection/websocket?token=private-http-query#private-http-fragment",
          status: 101,
          duration: "1ms",
        },
        expected: {
          method: "GET",
          path: "/connection/websocket",
          status: 101,
          duration: "1ms",
          durationMs: 1,
        },
      },
      ...[
        {
          method: "private-http-method",
          path: "https://private-http-user:private-http-password@localhost/api",
          status: 600,
          duration: "private-http-duration",
        },
        { method: {}, path: {}, status: "200", duration: 1 },
        {
          method: null,
          path: "/" + "x".repeat(513),
          status: 200.5,
          duration: "-1ms",
        },
        {
          path: "//private-http-host/api",
          status: 99,
          duration: "9".repeat(129) + "s",
        },
        { path: "/private-http-path\n", duration: "1ms private-http-duration" },
        { path: "/private-http-path\\secret", duration: "NaN" },
      ].map((fields) => ({ fields, invalid: true })),
      {
        fields: { path: "/api/eyJheader.eyJpayload.signature" },
        expected: {
          method: "POST",
          path: "/api/[REDACTED]",
          status: 200,
          duration: "1ms",
          durationMs: 1,
        },
      },
    ].map((value, index) => ({
      ...value,
      record: {
        level: "debug",
        time: timestamp,
        message: "http request",
        method: "POST",
        path: "/api/publish",
        status: 200,
        duration: "1ms",
        ...value.fields,
        logRecordId: (index + 1).toString(16).padStart(32, "0"),
        request: { token: "private-http-body" },
      },
    }));
    await appendFile(
      nativeFiles.centrifugo,
      [...centrifugoCases, ...httpCases]
        .map((value) => JSON.stringify(value.record))
        .join("\n") + "\n",
    );
    const values = await until(
      (values) =>
        values.filter((value) => value.requestId === "synthetic-flow")
          .length === 3 &&
        values.filter((value) => value.event === "service_log").length >=
          redisLines.length + 4 + centrifugoCases.length + httpCases.length,
    );
    const flow = values.filter((value) => value.requestId === "synthetic-flow");
    assert.deepEqual(
      new Set(flow.map((value) => value.source)),
      new Set(["backend", "redis", "flutter"]),
    );
    assert.ok(
      flow.every(
        (value) =>
          value.userId === "synthetic-user" &&
          value.captureId === "synthetic-vector-capture",
      ),
    );
    const flutter = flow.find((value) => value.source === "flutter");
    assert.equal(flutter.receivedAt, core[2][1].receivedAt);
    assert.ok(Number.isFinite(Date.parse(flutter.collectedAt)));
    for (const key of [
      "instanceId",
      "phase",
      "seq",
      "traceId",
      "spanId",
      "parentSpanId",
      "sessionGeneration",
      "durationMicros",
    ])
      assert.equal(flutter[key], core[2][1][key]);
    assert.equal(
      values.some((value) => value.event === "synthetic_pre_reset"),
      false,
      "Pre-reset backlog must advance checkpoints without reentering the clean capture",
    );
    const native = values.filter((value) => value.event === "service_log");
    assert.ok(
      native.every(
        (value) =>
          value.origin === "server_log" &&
          ["service", "collection"].includes(value.timestampSource) &&
          Number.isFinite(Date.parse(value.receivedAt)) &&
          value.collectedAt === value.receivedAt &&
          value.requestId === null,
      ),
    );
    assert.equal(
      native.find((value) => value.source === "mongodb").level,
      "error",
    );
    assert.equal(
      native.find((value) => value.source === "mongodb").component,
      "COMMAND",
    );
    const mongo = native.find((value) => value.source === "mongodb");
    assert.equal(mongo.name, "mongodb.event.22430");
    assert.equal(mongo.sourceEventCode, "22430");
    assert.equal(mongo.timestampSource, "service");
    assert.equal(
      Date.parse(mongo.timestamp),
      Date.parse("2026-10-17T10:00:00.123Z"),
    );
    assert.equal(mongo.sourceTimestamp, mongo.timestamp);
    assert.notEqual(mongo.receivedAt, mongo.timestamp);
    for (const invalid of native.filter(
      (value) => value.source === "mongodb" && value !== mongo,
    )) {
      assert.equal(invalid.name, "server_log");
      assert.equal(invalid.timestampSource, "collection");
      assert.equal(invalid.timestamp, invalid.receivedAt);
      assert.equal(invalid.sourceTimestamp, undefined);
      assert.equal(invalid.sourceEventCode, undefined);
      assert.equal(invalid.component, "server");
    }
    const centrifugo = native.find((value) => value.source === "centrifugo");
    assert.equal(centrifugo.timestampSource, "service");
    assert.equal(
      Date.parse(centrifugo.sourceTimestamp),
      Date.parse("2026-10-17T10:00:00.456Z"),
    );
    assert.equal(centrifugo.level, "warn");
    assert.equal(centrifugo.logRecordId, "a".repeat(32));
    assert.equal(centrifugo.logDeliveryAttempt, 2);
    assert.equal(centrifugo.logPreviousWriteOutcome, "uncertain");
    assert.equal(centrifugo.data.logRecordId, "a".repeat(32));
    assert.equal(centrifugo.data.logDeliveryAttempt, 2);
    assert.equal(centrifugo.data.logPreviousWriteOutcome, "uncertain");
    assert.match(centrifugo.data.message, /SyntheticCentrifugo/);
    assert.match(centrifugo.data.message, /\[REDACTED\]/);
    for (const { record, expected } of centrifugoCases.slice(1)) {
      const normalized = native.find(
        (value) =>
          value.source === "centrifugo" &&
          value.data.message === record.message,
      );
      assert.ok(
        normalized,
        "Every synthetic structured severity case reaches the native sink",
      );
      assert.equal(
        normalized.level,
        expected,
        `Structured severity takes precedence: ${record.message}`,
      );
    }
    const rejection = native.find(
      (value) => value.source === "centrifugo" && value.protocolCode === 106,
    );
    assert.equal(rejection.result, "failure");
    assert.equal(rejection.reason, "no pong");
    assert.equal(rejection.userId, "synthetic-user");
    assert.equal(rejection.serverRunId, "11111111-2222-4333-8444-555555555555");
    assert.match(rejection.instanceId, /^centrifugo-server-/);
    assert.match(rejection.errorMessage, /connection refused/);
    assert.equal(rejection.errorMessage.includes("name:password"), false);
    assert.equal(rejection.command, undefined);
    for (const { record, expected, invalid, fields } of httpCases) {
      const normalized = native.find(
        (value) => value.logRecordId === record.logRecordId,
      );
      assert.ok(
        normalized,
        "Every HTTP record survives invalid optional metadata",
      );
      assert.equal(normalized.level, "debug");
      assert.equal(normalized.name, "http.request");
      assert.equal(normalized.data.message, "http request");
      if (invalid) {
        for (const key of Object.keys(fields)) {
          assert.equal(
            normalized[key],
            undefined,
            `Invalid HTTP ${key} is omitted`,
          );
          if (key === "path") assert.equal(normalized.route, undefined);
          if (key === "duration")
            assert.equal(normalized.durationMs, undefined);
        }
      } else {
        for (const key of ["method", "path", "status", "duration"])
          assert.equal(normalized[key], expected[key]);
        assert.equal(normalized.route, expected.path);
        assert.ok(
          Math.abs(normalized.durationMs - expected.durationMs) < 0.00000001,
        );
        assert.equal(
          normalized.summary,
          `${expected.method} ${expected.path} HTTP ${expected.status} in ${expected.duration}`,
        );
      }
      assert.equal(normalized.request, undefined);
    }
    const redis = native.filter((value) => value.source === "redis");
    assert.equal(redis.length, redisLines.length);
    assert.equal(
      redis.find((value) =>
        value.data.message.startsWith("SyntheticRedis plain error"),
      ).level,
      "error",
    );
    for (const [prefix, expected] of [
      ["SyntheticRedis plain warning", "warn"],
      ["SyntheticRedis plain warn ", "warn"],
      ["SyntheticRedis warning error", "error"],
    ]) {
      assert.equal(
        redis.find((value) => value.data.message.startsWith(prefix)).level,
        expected,
      );
    }
    assert.ok(
      redis.every((value) => value.data.message.includes("[REDACTED]")),
    );
    const json = JSON.stringify(values);
    for (const excluded of [
      "two words",
      "two more words",
      "a=one",
      "b=two",
      "syntheticbearersecret",
      "eyJheader",
      "syntheticlogin",
      "syntheticpass",
      "synthetic-private-query-content",
      "synthetic-private-attribute-password",
      "synthetic-private-provider-content",
      "private-invalid-timestamp",
      "private-component",
      "private-event-code",
      "plain credential fixture",
      "plain warning fixture",
      "plain-warning-token",
      "plain-warning-error",
      "private-invalid-id",
      "private-invalid-outcome",
      "private-http-",
      "baseline-only-should-not-replay",
    ])
      assert.equal(
        json.includes(excluded),
        false,
        `Synthetic secret/old native content excluded: ${excluded}`,
      );
    const invalidDelivery = native.find(
      (value) =>
        value.data.message ===
        "SyntheticCentrifugo explicit info error response",
    );
    assert.equal(invalidDelivery.logDeliveryAttempt, undefined);
    assert.equal(invalidDelivery.data.logRecordId, undefined);
    assert.equal(invalidDelivery.data.logDeliveryAttempt, undefined);
    assert.equal(invalidDelivery.data.logPreviousWriteOutcome, undefined);
    assert.equal((await stat(paths.events)).mode & 0o777, 0o600);
    assert.equal((await stat(paths.state)).mode & 0o777, 0o700);
  },
);

test("only the workspace-owned Centrifugo input includes checkpointed archives; shared native logs remain tail-only", () => {
  const paths = localLogPaths("/synthetic/project");
  const owned = join(paths.inputs, "centrifugo-server.log");
  const config = vectorConfiguration(paths, {
    captureId: "owned-capture",
    nativeFiles: {
      centrifugo: owned,
      redis: "/shared/redis.log",
      mongodb: "/shared/mongod.log",
    },
  });
  assert.equal(config.sources.native_centrifugo.read_from, "beginning");
  assert.deepEqual(config.sources.native_centrifugo.include, [
    owned,
    join(paths.inputs, "archives", "centrifugo-server.log.*.jsonl"),
  ]);
  for (const service of ["redis", "mongodb"]) {
    assert.equal(config.sources[`native_${service}`].read_from, "end");
    assert.equal(config.sources[`native_${service}`].include.length, 1);
  }
});
