import { spawn, spawnSync } from "node:child_process";
import { centrifugoLogFilter } from "./centrifugo-log.mjs";
import { ensureLogFile } from "./backend-logs.mjs";
import { createPrivateProcessLog } from "./private-process-log.mjs";
import { randomBytes, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseEnv } from "node:util";

const root = fileURLToPath(new URL("../", import.meta.url));
const privateFile = join(root, "centrifugo/.env");
const readEnv = (path) =>
  existsSync(path) ? parseEnv(readFileSync(path, "utf8")) : {};

export function localEnvironment(inherited = process.env) {
  const env = {
    ...readEnv(join(root, "backend/.env")),
    ...readEnv(privateFile),
    ...inherited,
  };
  // NestJS validates connection-data JWTs. A Centrifugo verifier would
  // allow direct connect.token requests to bypass session revocation.
  for (const key of Object.keys(env)) {
    if (key.startsWith("CENTRIFUGO_CLIENT_TOKEN_")) delete env[key];
  }
  env.CENTRIFUGO_VAR_PROXY_SECRET = env.CENTRIFUGO_PROXY_SECRET;
  // Backend-driven revocation replaces periodic authorization callbacks.
  env.CENTRIFUGO_CLIENT_PROXY_REFRESH_ENABLED = "false";
  env.CENTRIFUGO_HTTP_API_KEY = env.CENTRIFUGO_API_KEY;
  env.CENTRIFUGO_ENGINE_REDIS_ADDRESS ??= env.REDIS_URL;
  // A LAN external listener must never move diagnostics off loopback.
  env.CENTRIFUGO_HTTP_SERVER_INTERNAL_ADDRESS = "127.0.0.1";
  env.CENTRIFUGO_HTTP_SERVER_INTERNAL_PORT = "9000";
  for (const suffix of [
    "CLIENT_INSECURE",
    "CLIENT_INSECURE_SKIP_TOKEN_SIGNATURE_VERIFY",
    "CLIENT_ALLOW_ANONYMOUS_CONNECT_WITHOUT_TOKEN",
    "CLIENT_SUBSCRIBE_TO_USER_PERSONAL_CHANNEL_ENABLED",
    "CLIENT_SUBSCRIBE_TO_USER_PERSONAL_CHANNEL_SINGLE_CONNECTION",
    "ADMIN_INSECURE",
    "ADMIN_EXTERNAL",
    "HTTP_API_INSECURE",
    "HTTP_API_EXTERNAL",
  ])
    env[`CENTRIFUGO_${suffix}`] = "false";
  env.CENTRIFUGO_CLIENT_DISALLOW_ANONYMOUS_CONNECTION_TOKENS = "true";
  env.CENTRIFUGO_ENGINE_TYPE = "redis";
  env.CENTRIFUGO_ENGINE_REDIS_PREFIX = "chat_centrifugo_local";
  for (const key of [
    "CENTRIFUGO_TOKEN_HMAC_SECRET_KEY",
    "CENTRIFUGO_PROXY_SECRET",
    "CENTRIFUGO_HTTP_API_KEY",
    "CENTRIFUGO_ADMIN_PASSWORD",
    "CENTRIFUGO_ADMIN_SECRET",
  ]) {
    if (!env[key] || env[key].length < 32 || env[key].startsWith("replace-"))
      throw new Error(
        `Set a strong ${key} in centrifugo/.env (run init once).`,
      );
  }
  return env;
}

export function nativeEnvironment(env) {
  const native = { ...env };
  // These shared settings are consumed by the launcher or NestJS. Centrifugo
  // uses the mapped HTTP_API_KEY/VAR_PROXY_SECRET keys and rejects the aliases.
  for (const key of [
    "CENTRIFUGO_API_KEY",
    "CENTRIFUGO_API_URL",
    "CENTRIFUGO_BIN",
    "CENTRIFUGO_PROXY_SECRET",
    "CENTRIFUGO_TOKEN_HMAC_SECRET_KEY",
  ])
    delete native[key];
  return native;
}

export function initialize() {
  if (existsSync(privateFile))
    throw new Error("centrifugo/.env already exists; preserving it.");
  const backend = readEnv(join(root, "backend/.env"));
  const secret = () => randomBytes(32).toString("hex");
  const settings = {
    CENTRIFUGO_BIN:
      process.env.CENTRIFUGO_BIN ??
      join(process.env.HOME, "centrifugo-local/centrifugo"),
    CENTRIFUGO_TOKEN_HMAC_SECRET_KEY: secret(),
    CENTRIFUGO_API_KEY: secret(),
    CENTRIFUGO_PROXY_SECRET: secret(),
    CENTRIFUGO_API_URL: "http://127.0.0.1:9000/api",
    CENTRIFUGO_ADMIN_PASSWORD: secret(),
    CENTRIFUGO_ADMIN_SECRET: secret(),
    CENTRIFUGO_ENGINE_REDIS_ADDRESS:
      backend.REDIS_URL ?? "redis://127.0.0.1:6379",
  };
  mkdirSync(dirname(privateFile), { recursive: true });
  writeFileSync(
    privateFile,
    Object.entries(settings)
      .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
      .join("\n") + "\n",
    { mode: 0o600, flag: "wx" },
  );
  process.stdout.write(
    "Created private centrifugo/.env. NestJS and Centrifugo share these dedicated credentials.\n",
  );
}

export async function launch(mode) {
  const env = localEnvironment();
  const binary = env.CENTRIFUGO_BIN ?? "centrifugo";
  const nativeEnv = nativeEnvironment(env);
  const version = spawnSync(binary, ["version"], { encoding: "utf8" });
  if (version.status !== 0 || !version.stdout.includes("Centrifugo v6.9.7 "))
    throw new Error(
      "This configuration targets installed Centrifugo v6.9.7; verify compatibility before changing the binary.",
    );
  const config = join(root, "centrifugo/config.json");
  const checked = spawnSync(binary, ["checkconfig", `--config=${config}`], {
    env: nativeEnv,
    stdio: "inherit",
  });
  if (checked.status !== 0)
    throw new Error("Centrifugo configuration validation failed.");
  if (mode === "check") return;
  const log = join(root, ".runtime/observability/inputs/centrifugo-server.log");
  mkdirSync(dirname(log), { recursive: true, mode: 0o700 });
  await ensureLogFile(log);
  // Never let the native process write unfiltered debug commands to a file.
  delete nativeEnv.CENTRIFUGO_LOG_FILE;
  const child = spawn(
    binary,
    [`--config=${config}`, "--http_server.internal_address=127.0.0.1"],
    { env: nativeEnv, stdio: ["ignore", "pipe", "pipe"] },
  );
  const sink = await createPrivateProcessLog(log, { input: true });
  const secrets = Object.entries(env)
    .filter(([key]) => /secret|password|token|api.?key/i.test(key))
    .map(([, value]) => value);
  const serverRunId = randomUUID();
  const filters = [child.stdout, child.stderr].map((stream) => {
    const filter = centrifugoLogFilter(secrets, serverRunId);
    stream.pipe(filter);
    filter.pipe(process.stdout, { end: false });
    filter.on("data", (chunk) => sink.append(chunk));
    return filter;
  });
  child.once("close", () => {
    void sink.close();
  });
  for (const signal of ["SIGINT", "SIGTERM"])
    process.once(signal, () => child.kill(signal));
  child.once("error", () => {
    process.stderr.write("Centrifugo could not start.\n");
    process.exitCode = 1;
  });
  child.once("exit", (code) => {
    process.exitCode = code ?? 1;
  });
  return child;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    const mode = process.argv[2] ?? "start";
    if (mode === "init") initialize();
    else if (["start", "check"].includes(mode)) await launch(mode);
    else
      throw new Error(
        "Usage: node scripts/centrifugo-local.mjs init|check|start",
      );
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
