import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { createHash, randomBytes } from "node:crypto";
import {
  chmod,
  lstat,
  open,
  readFile,
  readdir,
  rename,
} from "node:fs/promises";
import { constants } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createServer } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import { childEnvironment, ensureLogFile } from "./backend-logs.mjs";
import { createPrivateProcessLog } from "./private-process-log.mjs";
import {
  ALLOY_URL,
  GRAFANA_URL,
  LOKI_URL,
  DASHBOARD_PATH,
  comparisonConfiguration,
  comparisonPaths,
} from "./loki-grafana-config.mjs";

const exec = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const self = fileURLToPath(import.meta.url);
const paths = comparisonPaths(root);
export const LOKI_PLUGIN_VERSION = "13.2.2";

async function privatePluginTree(path) {
  const info = await lstat(path);
  if (info.isSymbolicLink() || (!info.isDirectory() && !info.isFile()))
    throw new Error("Unsafe plugin path.");
  await chmod(path, info.isDirectory() || info.mode & 0o111 ? 0o700 : 0o600);
  if (info.isDirectory())
    for (const name of await readdir(path))
      await privatePluginTree(join(path, name));
}

async function verifiedPlugin() {
  const manifest = join(paths.directory, "plugins/loki/plugin.json");
  const info = await lstat(manifest).catch(() => null);
  if (!info?.isFile() || info.isSymbolicLink())
    throw new Error(
      "Install the official Loki data source: node scripts/loki-grafana.mjs install",
    );
  const plugin = JSON.parse(await readFile(manifest, "utf8"));
  if (plugin.id !== "loki" || plugin.info?.version !== LOKI_PLUGIN_VERSION)
    throw new Error(
      "The Loki plugin version differs; existing plugin preserved.",
    );
}

export async function writePrivateConfiguration(file, content) {
  // Reuse the logging stack's ancestor/link checks without truncating anything.
  await ensureLogFile(file);
  const old = await readFile(file, "utf8");
  if (old === content) return;
  if (old)
    throw new Error("Existing comparison configuration differs; preserved.");
  const handle = await open(file, constants.O_RDWR | constants.O_NOFOLLOW);
  try {
    await handle.writeFile(content);
  } finally {
    await handle.close();
  }
}

async function secret(file) {
  await ensureLogFile(file);
  if (!(await lstat(file)).size)
    await writePrivateConfiguration(
      file,
      randomBytes(32).toString("hex") + "\n",
    );
}

async function tools() {
  const { stdout } = await exec("brew", ["--prefix"], {
    env: childEnvironment(),
  });
  const prefix = stdout.trim();
  const result = {
    loki: join(prefix, "opt/loki/bin/loki"),
    grafana: join(prefix, "opt/grafana/bin/grafana"),
    alloy: join(prefix, "opt/grafana-alloy/bin/alloy"),
    grafanaHome: join(prefix, "opt/grafana/share/grafana"),
  };
  for (const name of ["loki", "grafana", "alloy"])
    if (!(await lstat(result[name]).catch(() => null))?.isFile())
      throw new Error(
        "Install native tools: brew install grafana loki grafana-alloy",
      );
  return result;
}

async function configured() {
  const files = comparisonConfiguration(root);
  const digest = createHash("sha256")
    .update(JSON.stringify(files))
    .digest("hex")
    .slice(0, 16);
  const config = join(paths.directory, "config", digest);
  await secret(paths.password);
  await secret(paths.secret);
  for (const [name, text] of Object.entries(
    comparisonConfiguration(root, config),
  )) {
    await writePrivateConfiguration(join(config, name), text);
  }
  for (const name of ["plugins", "alerting"])
    await ensureLogFile(
      join(config, "provisioning", name, ".private-directory"),
    );
  for (const name of ["loki", "alloy", "grafana", "grafana-logs", "plugins"]) {
    const directory = join(paths.directory, name);
    await ensureLogFile(join(directory, ".private-directory"));
    await chmod(directory, 0o700);
  }
  return config;
}

async function owner() {
  try {
    const state = JSON.parse(await readFile(paths.state, "utf8"));
    if (!Number.isSafeInteger(state.pid) || !/^[a-f0-9]{32}$/.test(state.token))
      return null;
    const { stdout } = await exec("/bin/ps", [
      "-p",
      String(state.pid),
      "-o",
      "command=",
    ]);
    return stdout.trim() === `${process.execPath} ${self} run ${state.token}`
      ? state
      : null;
  } catch {
    return null;
  }
}

async function healthy(url) {
  try {
    return (
      await fetch(url, { redirect: "error", signal: AbortSignal.timeout(1500) })
    ).ok;
  } catch {
    return false;
  }
}

async function waitHealthy(url, child) {
  for (let attempt = 0; attempt < 120; attempt++) {
    if (child && (child.exitCode !== null || child.signalCode))
      throw new Error(
        "Comparison process exited; inspect its private process log.",
      );
    if (await healthy(url)) return;
    await delay(500);
  }
  throw new Error(
    "Comparison process did not become ready; inspect its private process log.",
  );
}

async function freePort(port) {
  await new Promise((ok, fail) => {
    const server = createServer();
    server.once("error", () =>
      fail(new Error(`Port ${port} is occupied; existing process preserved.`)),
    );
    server.listen(port, "127.0.0.1", () => server.close(ok));
  });
}

async function run(token) {
  process.umask(0o077);
  const binary = await tools();
  await verifiedPlugin();
  const capture = await lstat(paths.capture);
  if (!capture.isFile() || capture.isSymbolicLink() || capture.nlink !== 1)
    throw new Error(
      "The existing Vector capture must be a regular unlinked file.",
    );
  await ensureLogFile(join(paths.directory, ".private-directory"));
  if (await owner()) throw new Error("The comparison is already running.");
  // A stale owner record is preserved for diagnosis instead of overwritten.
  const old = await lstat(paths.state).catch(() => null);
  if (old) {
    await ensureLogFile(paths.state);
    await rename(paths.state, `${paths.state}.${Date.now()}.stale`);
  }
  const lock = await open(paths.state, "wx", 0o600);
  await lock.writeFile(JSON.stringify({ pid: process.pid, token }));
  await lock.close();
  const children = [],
    logs = [];
  let closing = false;
  let resolveDone;
  const done = new Promise((resolve) => {
    resolveDone = resolve;
  });
  const close = async (failed = false) => {
    if (closing) return;
    closing = true;
    // Drain the reader before stopping its destination.
    for (const child of [...children].reverse()) {
      if (!child.pid || child.exitCode !== null || child.signalCode) continue;
      child.kill("SIGTERM");
      const kill = setTimeout(() => child.kill("SIGKILL"), 15000);
      await new Promise((r) => child.once("exit", r));
      clearTimeout(kill);
    }
    await Promise.all(logs.map((log) => log.close()));
    process.exitCode = failed ? 1 : 0;
    resolveDone();
  };
  process.once("SIGTERM", () => void close());
  process.once("SIGINT", () => void close());
  try {
    for (const port of [3100, 9096, 3001, 12345]) await freePort(port);
    const config = await configured();
    await exec(
      binary.loki,
      [`-config.file=${join(config, "loki.json")}`, "-verify-config=true"],
      { env: childEnvironment() },
    );
    await exec(binary.alloy, ["validate", join(config, "config.alloy")], {
      env: childEnvironment(),
    });
    const start = async (name, command, args, url) => {
      if (closing) throw new Error("Comparison startup was interrupted.");
      const log = await createPrivateProcessLog(
        join(paths.directory, `${name}-process.log`),
      );
      logs.push(log);
      const child = spawn(command, args, {
        cwd: paths.directory,
        env: childEnvironment(),
        stdio: ["ignore", "pipe", "pipe"],
      });
      children.push(child);
      child.stdout.on("data", (chunk) => log.append(chunk));
      child.stderr.on("data", (chunk) => log.append(chunk));
      child.once("error", () => void close(true));
      child.once("exit", () => {
        if (!closing) void close(true);
      });
      await waitHealthy(url, child);
    };
    await start(
      "loki",
      binary.loki,
      [`-config.file=${join(config, "loki.json")}`],
      `${LOKI_URL}/ready`,
    );
    await start(
      "grafana",
      binary.grafana,
      [
        "server",
        "--homepath",
        binary.grafanaHome,
        "--config",
        join(config, "grafana.ini"),
      ],
      `${GRAFANA_URL}/api/health`,
    );
    await start(
      "alloy",
      binary.alloy,
      [
        "run",
        "--server.http.listen-addr=127.0.0.1:12345",
        `--storage.path=${join(paths.directory, "alloy")}`,
        "--disable-reporting",
        join(config, "config.alloy"),
      ],
      `${ALLOY_URL}/-/ready`,
    );
    await done;
  } catch (error) {
    const log = await createPrivateProcessLog(
      join(paths.directory, "startup-process.log"),
    );
    log.append(Buffer.from(`${error.message}\n`));
    await log.close();
    await close(true);
    throw new Error(
      "Comparison startup failed. Inspect .runtime/loki-grafana/startup-process.log.",
    );
  }
}

async function main(command, token) {
  if (command === "install") {
    process.umask(0o077);
    const binary = await tools();
    const config = await configured();
    const installed = await lstat(join(paths.directory, "plugins/loki")).catch(
      () => null,
    );
    if (installed) await verifiedPlugin();
    else
      await exec(
        binary.grafana,
        [
          "cli",
          "--homepath",
          binary.grafanaHome,
          "--config",
          join(config, "grafana.ini"),
          "--pluginsDir",
          join(paths.directory, "plugins"),
          "plugins",
          "install",
          "loki",
          LOKI_PLUGIN_VERSION,
        ],
        { env: childEnvironment(), timeout: 120000 },
      );
    await privatePluginTree(join(paths.directory, "plugins/loki"));
    await verifiedPlugin();
    return console.log(
      `Official Loki data source ${LOKI_PLUGIN_VERSION} installed. Native tools are managed by Homebrew.`,
    );
  }
  if (command === "run") {
    if (!/^[a-f0-9]{32}$/.test(token ?? ""))
      throw new Error("Invalid supervisor identity.");
    return run(token);
  }
  const active = await owner();
  if (command === "stop") {
    if (!active) return console.log("No owned comparison process is running.");
    process.kill(active.pid, "SIGTERM");
    for (let attempt = 0; attempt < 100 && (await owner()); attempt++)
      await delay(500);
    if (await owner())
      throw new Error("Graceful comparison shutdown is still pending.");
    return console.log(
      "Comparison stopped; stored logs, Vector and Logdy preserved.",
    );
  }
  if (command === "status") {
    const checks = await Promise.all(
      [
        `${LOKI_URL}/ready`,
        `${GRAFANA_URL}/api/health`,
        `${ALLOY_URL}/-/ready`,
        `${GRAFANA_URL}/api/datasources/uid/chat-loki/health`,
      ].map(healthy),
    );
    return console.log(
      JSON.stringify(
        {
          ownedSupervisor: Boolean(active),
          loki: checks[0],
          grafana: checks[1],
          alloy: checks[2],
          lokiDatasource: checks[3],
          dashboard: GRAFANA_URL + DASHBOARD_PATH,
        },
        null,
        2,
      ),
    );
  }
  if (command !== "start")
    throw new Error(
      "Use node scripts/loki-grafana.mjs install|start|status|stop.",
    );
  if (!active) {
    await tools();
    await verifiedPlugin();
    for (const port of [3100, 9096, 3001, 12345]) await freePort(port);
    const child = spawn(
      process.execPath,
      [self, "run", randomBytes(16).toString("hex")],
      { cwd: root, env: childEnvironment(), detached: true, stdio: "ignore" },
    );
    child.unref();
    await waitHealthy(`${GRAFANA_URL}/api/health`, child);
    await waitHealthy(`${ALLOY_URL}/-/ready`, child);
  }
  await waitHealthy(`${GRAFANA_URL}/api/datasources/uid/chat-loki/health`);
  console.log(
    `Grafana: ${GRAFANA_URL}${DASHBOARD_PATH}\nLogdy: http://127.0.0.1:8082/\nSame Vector capture; retained archives import in the background.`,
  );
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
)
  main(process.argv[2] ?? "status", process.argv[3]).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
