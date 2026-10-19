import { spawn } from "node:child_process";
import { captureHealth } from "./capture-health.mjs";
import { createPrivateProcessLog } from "./private-process-log.mjs";
import { randomUUID, createHash } from "node:crypto";
import { chmod, lstat, open, readFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { childEnvironment, ensureLogFile } from "./backend-logs.mjs";
import { startLocalLogIngress } from "./local-logs-ingress.mjs";
import { installVector, verifiedVector } from "./vector-tool.mjs";
import {
  archiveCapture,
  pruneArchives,
  retentionPolicy,
} from "./log-retention.mjs";
import { pruneConsumedInputArchives } from "./input-log-retention.mjs";

const workspaceRoot = fileURLToPath(new URL("../", import.meta.url));
// Only bounded operational fields cross the native diagnostic boundary.
const centrifugoNativeDetails = String.raw`
  if is_string(parsed.serverRunId) && match(string!(parsed.serverRunId), r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') {
    .serverRunId = parsed.serverRunId
    .instanceId = "centrifugo-server-" + string!(parsed.serverRunId)
  }
  for_each({"errorMessage": parsed.error, "reason": parsed.reason}) -> |key, value| {
    if is_string(value) {
      safe = replace(string!(value), r'(?i)(bearer|basic)\s+[^\s,;]+', "[REDACTED]")
      safe = replace(safe, r'\beyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\b', "[REDACTED]")
      safe = replace(safe, r'(?is)(password|passwd|token|secret|api[_-]?key|authorization|cookie)["\s]*[:=].*', "[REDACTED]")
      safe = replace(safe, r'://[^/\s?#]+@', "://[REDACTED]@")
      . = set!(., [key], truncate(safe, limit: 512))
    }
  }
  for_each({"clientId": parsed.client, "userId": parsed.user, "channel": parsed.channel}) -> |key, value| {
    if is_string(value) && match(string!(value), r'^[A-Za-z0-9_.:#-]{1,128}$') && !starts_with(string!(value), "eyJ") {
      . = set!(., [key], value)
    }
  }
  if is_integer(parsed.code) && int!(parsed.code) >= 0 && int!(parsed.code) <= 9999 { .protocolCode = parsed.code }
  if is_integer(parsed.limit) && int!(parsed.limit) >= 0 { .data.limit = parsed.limit }
  if text == "client command error" || match(severity, r'^(error|fatal|panic)$') { .result = "failure" }
  .summary = text
  if is_string(.errorMessage) { .summary = text + ": " + string!(.errorMessage) }
  if is_string(.reason) { .summary = text + ": " + string!(.reason) }
`;

export function localLogPaths(root = workspaceRoot) {
  const directory = resolve(root, ".runtime/observability");
  return {
    directory,
    inputs: join(directory, "inputs"),
    events: join(directory, "events.jsonl"),
    flutter: join(directory, "inputs/flutter.jsonl"),
    services: join(directory, "inputs/services.jsonl"),
    native_centrifugo: join(directory, "inputs/centrifugo-server.log"),
    backend: resolve(root, ".runtime/backend-logs/traffic.jsonl"),
    processLog: join(directory, "vector-process.log"),
    state: join(directory, "vector-state"),
  };
}

function fileSource(path, beginning = true) {
  return {
    type: "file",
    include: beginning
      ? [
          path,
          join(
            dirname(path),
            "archives",
            `${basename(path, ".jsonl")}.*.jsonl`,
          ),
        ]
      : [path],
    read_from: beginning ? "beginning" : "end",
    max_line_bytes: 1024 * 1024,
    max_read_bytes: 256 * 1024,
    // Discover new rotated inputs promptly. The verified Vector source patch
    // separately wakes already-known files when their open descriptor grows.
    glob_minimum_cooldown_ms: 250,
    ignore_checkpoints: false,
    fingerprint: { strategy: "checksum", lines: 1, ignored_header_bytes: 0 },
  };
}

/** Vector owns tailing, checkpoints, transformations, buffering and fan-in. */
export function vectorConfiguration(
  paths,
  { captureId, nativeFiles = {}, captureStart },
) {
  const sources = {
    backend: fileSource(paths.backend),
    services: fileSource(paths.services),
    flutter: fileSource(paths.flutter),
  };
  const transforms = {};
  for (const source of ["backend", "services", "flutter"]) {
    transforms[`normalize_${source}`] = {
      type: "remap",
      inputs: [source],
      drop_on_error: true,
      source: `record = parse_json!(string!(.message))\n. = object!(record)\n${source === "backend" ? '.source = "backend"\n.origin = "backend_traffic"\n' : ""}.collectedAt = now()\nif !exists(.receivedAt) { .receivedAt = .collectedAt }\n.captureId = ${JSON.stringify(captureId)}\n`,
    };
  }
  for (const [service, file] of Object.entries(nativeFiles)) {
    if (!["redis", "mongodb", "centrifugo"].includes(service))
      throw new Error("Invalid service source.");
    const owned =
      service === "centrifugo" &&
      file === join(paths.inputs, "centrifugo-server.log");
    sources[`native_${service}`] = fileSource(file, owned);
    // A server's structured level is authoritative; message keywords are a fallback.
    transforms[`normalize_native_${service}`] = {
      type: "remap",
      inputs: [`native_${service}`],
      drop_on_error: true,
      source: `text = string!(.message)
parsed, err = parse_json(text)
severity = ""
component = "server"
collected = now()
source_timestamp = null
source_event_code = null
name = "server_log"
if err == null && is_object(parsed) {
  text = "server_log"
  if is_string(parsed.msg) { text = string!(parsed.msg) } else if is_string(parsed.message) { text = string!(parsed.message) }
  if is_string(parsed.level) { severity = downcase(strip_whitespace(string!(parsed.level))) }
  if !match(severity, r'^(trace|debug|d[1-5]?|info|i|warn|warning|w|error|e|fatal|f|panic|none)$') && is_string(parsed.s) { severity = downcase(strip_whitespace(string!(parsed.s))) }
  if is_string(parsed.c) && match(string!(parsed.c), r'^[A-Za-z0-9_.-]{1,64}$') { component = string!(parsed.c) }
  native_time = null
  if is_string(parsed.t."$date") { native_time = parsed.t."$date" } else if is_string(parsed.time) { native_time = parsed.time } else if is_string(parsed.timestamp) { native_time = parsed.timestamp }
  if is_string(native_time) {
    candidate, time_error = parse_timestamp(string!(native_time), format: "%+")
    if time_error == null { source_timestamp = candidate }
  }
  ${
    service === "mongodb"
      ? `if is_integer(parsed.id) {
    code = int!(parsed.id)
    if code >= 0 && code <= 9007199254740991 {
      source_event_code = to_string!(code)
      name = "mongodb.event." + source_event_code
    }
  }`
      : ""
  }
}
if !match(severity, r'^(trace|debug|d[1-5]?|info|i|warn|warning|w|error|e|fatal|f|panic|none)$') {
  severity = "info"
  if match(text, r'(?i)\\b(warn|warning)\\b') { severity = "warn" }
  if match(text, r'(?i)\\b(error|fatal|panic)\\b') { severity = "error" }
}
if severity == "warning" || severity == "w" { severity = "warn" }
if severity == "e" { severity = "error" }
if severity == "f" { severity = "fatal" }
if severity == "i" { severity = "info" }
if match(severity, r'^d[1-5]?$') { severity = "debug" }
text = replace(text, r'(?i)(bearer|basic)\\s+[^\\s,;]+', "[REDACTED]")
text = replace(text, r'\\beyJ[a-zA-Z0-9_-]+\\.eyJ[a-zA-Z0-9_-]+\\.[a-zA-Z0-9_-]+\\b', "[REDACTED]")
text = replace(text, r'(?is)(password|passwd|token|secret|api[_-]?key|authorization|cookie)["\\s]*[:=].*', "[REDACTED]")
text = replace(text, r'://[^/\\s?#]+@', "://[REDACTED]@")
event_time = collected
timestamp_source = "collection"
if is_timestamp(source_timestamp) { event_time = source_timestamp; timestamp_source = "service" }
. = { "timestamp": event_time, "timestampSource": timestamp_source, "receivedAt": collected, "collectedAt": collected, "level": severity, "source": ${JSON.stringify(service)}, "event": "service_log", "origin": "server_log", "instanceId": ${JSON.stringify(`${service}-server`)}, "captureId": ${JSON.stringify(captureId)}, "requestId": null, "userId": null, "category": "server", "name": name, "component": component, "data": { "message": truncate(text, limit: 2048) } }
if is_timestamp(source_timestamp) { .sourceTimestamp = source_timestamp }
if is_string(source_event_code) { .sourceEventCode = source_event_code }
if err == null && is_object(parsed) {
  ${
    service === "centrifugo"
      ? `${centrifugoNativeDetails}
  if text == "http request" {
    .name = "http.request"
    if is_string(parsed.method) {
      method = upcase(strip_whitespace(string!(parsed.method)))
      if match(method, r'^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE)$') { .method = method }
    }
    if is_string(parsed.path) {
      path = replace(string!(parsed.path), r'[?#].*$', "")
      if length(path) <= 512 && match(path, r'^/[^\\s\\x00-\\x1f\\x7f\\\\]*$') && !starts_with(path, "//") {
        path = replace(path, r'\\beyJ[a-zA-Z0-9_-]+\\.eyJ[a-zA-Z0-9_-]+\\.[a-zA-Z0-9_-]+\\b', "[REDACTED]")
        .path = path
        .route = path
      }
    }
    if is_integer(parsed.status) {
      status = int!(parsed.status)
      if status >= 100 && status <= 599 {
        .status = status
        .result = if status >= 400 { "failure" } else { "success" }
      }
    }
    if is_string(parsed.duration) {
      elapsed = string!(parsed.duration)
      if length(elapsed) <= 128 && match(elapsed, r'^(?:[0-9]+(?:\\.[0-9]+)?(?:ns|us|µs|μs|ms|s|m|h))+$') {
        duration_ms, duration_error = parse_duration(replace(replace(elapsed, "µs", "us"), "μs", "us"), unit: "ms")
        if duration_error == null && duration_ms >= 0 {
          .duration = elapsed
          .durationMs = duration_ms
        }
      }
    }
    summary = "HTTP request"
    if is_string(.method) { summary = string!(.method) }
    if is_string(.path) { summary = summary + " " + string!(.path) }
    if is_integer(.status) { summary = summary + " HTTP " + to_string!(.status) }
    if is_string(.duration) { summary = summary + " in " + string!(.duration) }
    .summary = summary
  }`
      : ""
  }
  if is_string(parsed.logRecordId) && match(string!(parsed.logRecordId), r'^[a-f0-9]{32}$') { .logRecordId = parsed.logRecordId; .data.logRecordId = parsed.logRecordId }
  if is_integer(parsed.logDeliveryAttempt) && int!(parsed.logDeliveryAttempt) >= 1 && int!(parsed.logDeliveryAttempt) <= 32 { .logDeliveryAttempt = parsed.logDeliveryAttempt; .data.logDeliveryAttempt = parsed.logDeliveryAttempt }
  if is_string(parsed.logPreviousWriteOutcome) && match(string!(parsed.logPreviousWriteOutcome), r'^(not_attempted|not_written|uncertain)$') { .logPreviousWriteOutcome = parsed.logPreviousWriteOutcome; .data.logPreviousWriteOutcome = parsed.logPreviousWriteOutcome }
}
`,
    };
  }
  let captureInputs = Object.keys(transforms);
  if (captureStart !== undefined) {
    if (
      typeof captureStart !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T.*Z$/.test(captureStart) ||
      !Number.isFinite(Date.parse(captureStart))
    )
      throw new Error("Invalid clean capture boundary.");
    // Native logs have second precision. Retain the entire reset second.
    const boundary = new Date(
      Math.floor(Date.parse(captureStart) / 1000) * 1000,
    ).toISOString();
    transforms.capture_since_reset = {
      type: "remap",
      drop_on_abort: true,
      drop_on_error: true,
      inputs: captureInputs,
      source: `event_time = parse_timestamp(to_string(.timestamp) ?? "", format: "%+") ?? now()\nif event_time < parse_timestamp!(${JSON.stringify(boundary)}, format: "%+") { abort }`,
    };
    captureInputs = ["capture_since_reset"];
  }
  return {
    data_dir: paths.state,
    // The verified minimal source build omits the API feature entirely.
    sources,
    transforms,
    sinks: {
      capture: {
        type: "file",
        acknowledgements: { enabled: true },
        inputs: captureInputs,
        path: paths.events,
        encoding: { codec: "json", timestamp_format: "rfc3339" },
        framing: { method: "newline_delimited" },
        buffer: { type: "memory", max_events: 1000, when_full: "block" },
      },
    },
  };
}

export async function discoverNativeLogs(
  inherited = process.env,
  root = workspaceRoot,
) {
  const result = {};
  for (const [service, setting, fallback] of [
    ["redis", "LOCAL_REDIS_LOG_FILE", "/opt/homebrew/var/log/redis.log"],
    [
      "mongodb",
      "LOCAL_MONGODB_LOG_FILE",
      "/opt/homebrew/var/log/mongodb/mongod.log",
    ],
    [
      "centrifugo",
      "LOCAL_CENTRIFUGO_LOG_FILE",
      resolve(root, ".runtime/observability/inputs/centrifugo-server.log"),
    ],
  ]) {
    const configured = inherited[setting];
    if (configured === "off") continue;
    const path = configured ?? fallback;
    if (!path) continue;
    try {
      let parent = dirname(resolve(path));
      while (true) {
        const entry = await lstat(parent);
        if (!entry.isDirectory() || entry.isSymbolicLink())
          throw new Error("Invalid service log directory.");
        const next = dirname(parent);
        if (next === parent) break;
        parent = next;
      }
      const entry = await lstat(path);
      if (!entry.isFile() || entry.isSymbolicLink())
        throw new Error("Invalid service log.");
      result[service] = resolve(path);
    } catch (error) {
      if (configured || error.code !== "ENOENT")
        throw new Error("Could not read a configured local service log.");
    }
  }
  return result;
}

async function privateConfig(path, text) {
  try {
    const handle = await open(path, "wx", 0o600);
    try {
      await handle.writeFile(text);
    } finally {
      await handle.close();
    }
  } catch (error) {
    const entry = await lstat(path).catch(() => null);
    if (
      error.code !== "EEXIST" ||
      !entry?.isFile() ||
      entry.isSymbolicLink() ||
      entry.nlink !== 1 ||
      (await readFile(path, "utf8")) !== text
    )
      throw new Error(
        "Existing collector configuration differs; it was preserved.",
      );
  }
}

function waitForExit(child) {
  return new Promise((resolveExit, rejectExit) => {
    child.once("error", () =>
      rejectExit(new Error("Could not execute Vector.")),
    );
    child.once("exit", (code) =>
      code === 0
        ? resolveExit()
        : rejectExit(
            new Error(
              "Vector configuration failed; inspect the private process log.",
            ),
          ),
    );
  });
}

export async function startLocalLogs({
  root = workspaceRoot,
  port = 8083,
  nativeFiles,
  captureId = randomUUID(),
  retention = retentionPolicy(),
  retentionIntervalMs = 30000,
} = {}) {
  const tool = await verifiedVector(root);
  const paths = localLogPaths(root);
  // The child inherits this private mask, including its checkpoints and output.
  const previousMask = process.umask(0o077);
  let log;
  let ingress;
  let child;
  let retentionTimer;
  let healthTimer;
  let health = {};
  let healthWork;
  let closing = false;
  let rotating;
  let intentionallyStopping;
  const retentionStatus = {
    maxBytes: retention.maxBytes,
    maxArchives: retention.maxArchives,
    maxAgeDays: retention.maxAgeMs / 86400000,
    checkedAt: null,
    inputs: {},
  };
  let close;
  try {
    for (const file of [
      paths.flutter,
      paths.services,
      paths.events,
      paths.processLog,
    ])
      await ensureLogFile(file);
    await ensureLogFile(join(paths.state, ".private-directory"));
    await chmod(paths.state, 0o700);
    nativeFiles ??= await discoverNativeLogs(process.env, root);
    let captureStart;
    try {
      const resetFile = join(paths.directory, "last-unified-reset.json");
      const entry = await lstat(resetFile);
      if (
        !entry.isFile() ||
        entry.isSymbolicLink() ||
        entry.nlink !== 1 ||
        entry.size > 4096
      )
        throw new Error("Unsafe clean capture boundary.");
      captureStart = JSON.parse(await readFile(resetFile, "utf8")).resetAt;
      if (typeof captureStart !== "string")
        throw new Error("Invalid clean capture boundary.");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const configuration = vectorConfiguration(paths, {
      captureId,
      nativeFiles,
      captureStart,
    });
    const contents = JSON.stringify(configuration, null, 2) + "\n";
    const digest = createHash("sha256")
      .update(contents)
      .digest("hex")
      .slice(0, 16);
    const configPath = join(paths.directory, `vector-${digest}.json`);
    await privateConfig(configPath, contents);
    log = await createPrivateProcessLog(paths.processLog, {
      policy: retention,
    });
    const attachLog = (process) => {
      for (const stream of [process.stdout, process.stderr])
        stream?.on("data", (chunk) => log.append(chunk));
      return process;
    };
    const env = {
      ...childEnvironment(),
      VECTOR_LOG: "warn",
      VECTOR_THREADS: "2",
    };
    const validate = attachLog(
      spawn(
        tool.binary,
        ["validate", "--no-environment", "--skip-healthchecks", configPath],
        { env, stdio: ["ignore", "pipe", "pipe"] },
      ),
    );
    await waitForExit(validate);
    ingress = await startLocalLogIngress({
      file: paths.flutter,
      port,
      captureId,
      retention,
      healthDetails: () => ({
        captureStartAt: captureStart ?? null,
        retention: retentionStatus,
        captureHealth: health,
        vectorAlive:
          !!child && child.exitCode === null && child.signalCode === null,
      }),
    });
    const launchVector = async () => {
      const next = attachLog(
        spawn(tool.binary, ["--config", configPath], {
          env,
          stdio: ["ignore", "pipe", "pipe"],
        }),
      );
      await new Promise((ready, failed) => {
        const timer = setTimeout(ready, 600);
        next.once("error", () => {
          clearTimeout(timer);
          failed(new Error("Could not start Vector."));
        });
        next.once("exit", () => {
          clearTimeout(timer);
          failed(new Error("Vector stopped; inspect the private process log."));
        });
      });
      next.once("close", () => {
        if (!closing && next !== intentionallyStopping) void close?.();
      });
      return next;
    };
    child = await launchVector();
    const refreshHealth = () =>
      (healthWork ??= captureHealth(paths, health)
        .then((next) => {
          health = next;
        })
        .catch(() => {})
        .finally(() => {
          healthWork = undefined;
        }));
    await refreshHealth();
    healthTimer = setInterval(() => {
      void refreshHealth();
    }, 2000);
    healthTimer.unref();
    let openedAt = (await lstat(paths.events)).birthtimeMs || Date.now();
    const maintain = async () => {
      if (closing || rotating) return rotating;
      rotating = (async () => {
        const info = await lstat(paths.events);
        if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1)
          throw new Error("Unsafe active capture.");
        if (
          info.size &&
          (info.size >= retention.maxBytes ||
            Date.now() - openedAt >= retention.rotateAfterMs)
        ) {
          const previous = child;
          intentionallyStopping = previous;
          // Stop only Vector, allowing its normal shutdown to flush the sink.
          // Inputs keep buffering privately; the API and ingress stay available.
          await new Promise((done, failed) => {
            const timeout = setTimeout(
              () => failed(new Error("Vector did not flush before rotation.")),
              10000,
            );
            previous.once("close", (code) => {
              clearTimeout(timeout);
              code === 0
                ? done()
                : failed(
                    new Error("Vector shutdown failed; capture preserved."),
                  );
            });
            previous.kill("SIGTERM");
          });
          await archiveCapture(paths.events);
          openedAt = Date.now();
          child = await launchVector();
          intentionallyStopping = undefined;
        }
        await pruneArchives(paths.events, retention);
        for (const source of ["backend", "services", "flutter"]) {
          retentionStatus.inputs[source] = await pruneConsumedInputArchives(
            paths[source],
            join(paths.state, source, "checkpoints.json"),
            retention,
          );
        }
        const ownedNative = nativeFiles.centrifugo;
        if (ownedNative === join(paths.inputs, "centrifugo-server.log"))
          retentionStatus.inputs.native_centrifugo =
            await pruneConsumedInputArchives(
              ownedNative,
              join(paths.state, "native_centrifugo", "checkpoints.json"),
              retention,
            );
        retentionStatus.checkedAt = new Date().toISOString();
      })().finally(() => {
        rotating = undefined;
      });
      return rotating;
    };
    retentionTimer = setInterval(() => {
      void maintain().catch(() => {
        // Never continue silently if maintenance left Vector stopped.
        if (child.exitCode !== null || child.signalCode !== null) void close();
        else
          console.error(
            "Log retention could not complete; active capture preserved.",
          );
      });
    }, retentionIntervalMs);
    retentionTimer.unref();
    let closed;
    close = () =>
      (closed ??= (async () => {
        closing = true;
        clearInterval(retentionTimer);
        clearInterval(healthTimer);
        await healthWork;
        await rotating?.catch(() => {});
        await ingress.close();
        if (child.exitCode === null && child.signalCode === null)
          await new Promise((done, failed) => {
            const timeout = setTimeout(() => child.kill("SIGKILL"), 30000);
            timeout.unref();
            child.once("close", (code) => {
              clearTimeout(timeout);
              code === 0
                ? done()
                : failed(
                    new Error(
                      "Vector did not shut down cleanly; unacknowledged inputs remain for recovery.",
                    ),
                  );
            });
            child.kill("SIGTERM");
          });
        await log.close();
      })());
    return {
      paths,
      url: ingress.url,
      get child() {
        return child;
      },
      captureId,
      nativeSources: Object.keys(nativeFiles),
      close,
      maintain,
    };
  } catch (error) {
    clearInterval(retentionTimer);
    clearInterval(healthTimer);
    await healthWork;
    await ingress?.close();
    child?.kill("SIGTERM");
    await log?.close();
    throw error;
  } finally {
    process.umask(previousMask);
  }
}

export async function main(args = process.argv.slice(2)) {
  if (args.length !== 1 || !["install", "start"].includes(args[0]))
    throw new Error("Use node scripts/local-logs.mjs install|start.");
  if (args[0] === "install") {
    await installVector(workspaceRoot);
    console.log(
      "Pinned local Vector installed. Start with node scripts/local-logs.mjs start.",
    );
    return;
  }
  const runtime = await startLocalLogs();
  console.log(
    `Local Flutter ingestion: ${runtime.url}\nVector capture: ${runtime.paths.events}\nNative log sources: ${runtime.nativeSources.join(", ") || "none configured"}\nLogdy: npm run logs in backend/. API and existing services stay under your control.`,
  );
  await new Promise((resolveExit) => {
    const stop = async () => {
      await runtime.close();
      process.off("SIGINT", stop);
      process.off("SIGTERM", stop);
      resolveExit();
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    // Process shutdown is driven by the ingress; Vector may rotate normally.
    runtime.child.on("error", stop);
  });
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
)
  main().catch(() => {
    console.error(
      "Local logs could not start. Check the private Vector process log, installation and port availability; existing captures were preserved.",
    );
    process.exitCode = 1;
  });
