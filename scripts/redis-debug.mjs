import { spawn } from "node:child_process";
import { constants } from "node:os";
import {
  access,
  lstat,
  mkdir,
  readFile,
  readdir,
  stat,
  symlink,
} from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseEnv } from "node:util";

export const COMMANDER_VERSION = "0.9.0";
export const INSPECTOR_URL = "http://127.0.0.1:8081/";
const defaultRoot = fileURLToPath(new URL("../", import.meta.url));
const installInstruction = "Run node scripts/redis-debug.mjs install first.";

class InspectorError extends Error {}

export function inspectorPaths(root = defaultRoot) {
  const installDir = resolve(root, ".runtime", "redis-inspector");
  const packageDir = join(installDir, "node_modules", "redis-commander");
  return {
    installDir,
    packageDir,
    binary: join(packageDir, "bin", "redis-commander.js"),
    // No package, working-directory, or user configuration files are loaded.
    configDir: join(installDir, "empty-config"),
  };
}

export function parseBackendEnv(source) {
  let values;
  try {
    values = parseEnv(source);
  } catch {
    throw new InspectorError("Could not parse the private backend/.env file.");
  }
  if (!values.REDIS_URL) {
    throw new InspectorError("Set REDIS_URL in the private backend/.env file.");
  }
  return {
    redisUrl: values.REDIS_URL,
    prefix: values.REDIS_KEY_PREFIX ?? "",
  };
}

export function parseRedisUrl(value) {
  try {
    const url = new URL(value);
    const hostname = url.hostname.toLowerCase();
    if (
      !["redis:", "rediss:"].includes(url.protocol) ||
      !["localhost", "127.0.0.1", "[::1]"].includes(hostname)
    ) {
      throw new Error();
    }
    // Do not silently ignore ioredis URL options or allow a second target.
    if (url.hash || [...url.searchParams.keys()].some((key) => key !== "db")) {
      throw new Error();
    }
    if (url.searchParams.getAll("db").length > 1) throw new Error();
    const database =
      url.pathname && url.pathname !== "/"
        ? url.pathname.slice(1)
        : (url.searchParams.get("db") ?? "0");
    const dbIndex = Number(database);
    const port = Number(url.port || 6379);
    if (
      !/^\d+$/.test(database) ||
      !Number.isSafeInteger(dbIndex) ||
      !Number.isInteger(port) ||
      port < 1 ||
      port > 65535
    ) {
      throw new Error();
    }
    return {
      label: "Chat workspace",
      host: hostname.replace(/^\[|\]$/g, ""),
      port,
      dbIndex,
      username: decodeURIComponent(url.username) || null,
      password: decodeURIComponent(url.password),
      ...(url.protocol === "rediss:"
        ? { tls: { rejectUnauthorized: true } }
        : {}),
    };
  } catch {
    // URL/decoder errors can contain the complete URL, including credentials.
    throw new InspectorError(
      "REDIS_URL must use redis:// or rediss:// with localhost, 127.0.0.1 or [::1], a numeric database, and no options except db.",
    );
  }
}

export function escapeRedisGlob(prefix) {
  return prefix.replace(/[\\*?\[\]]/g, "\\$&");
}

export function createInspectorConfig({ redisUrl, prefix = "" }) {
  // Complete defaults for the pinned release keep NODE_CONFIG_DIR isolated.
  // See redis-commander v0.9.0 config/default.json and bin/redis-commander.js.
  return {
    noSave: true,
    noLogData: true,
    ui: {
      sidebarWidth: 250,
      locked: false,
      cliHeight: 320,
      cliOpen: false,
      foldingChar: ":",
      jsonViewAsDefault: "hash,string,zset",
      binaryAsHex: true,
      maxHashFieldSize: 0,
    },
    redis: {
      readOnly: true,
      flushOnImport: false,
      useScan: true,
      scanCount: 100,
      rootPattern: `${escapeRedisGlob(prefix)}*`,
      connectionName: "chat-workspace-inspector",
      defaultLabel: "Chat workspace",
      defaultSentinelGroup: "mymaster",
      extraAllowedReadOnlyCommands: ["select", "info"],
    },
    server: {
      address: "127.0.0.1",
      port: 8081,
      urlPrefix: "",
      signinPath: "signin",
      httpAuthHeaderName: "Authorization",
      trustProxy: false,
      clientMaxBodySize: "100kb",
      httpAuth: { username: "", password: "", passwordHash: "", jwtSecret: "" },
    },
    sso: {
      enabled: false,
      jwtSharedSecret: "",
      jwtAlgorithms: ["HS256", "HS384", "HS512"],
      allowedIssuer: "",
      audience: "",
      subject: "",
    },
    connections: [parseRedisUrl(redisUrl)],
  };
}

export function childEnvironment(inherited = process.env) {
  // An allowlist excludes NODE_OPTIONS, node-config overrides, Redis/auth
  // settings, and unrelated application secrets without changing HOME.
  const allowed = [
    "PATH",
    "HOME",
    "USERPROFILE",
    "SystemRoot",
    "WINDIR",
    "COMSPEC",
    "PATHEXT",
    "TEMP",
    "TMP",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TZ",
    "TERM",
    "COLORTERM",
    "NO_COLOR",
    "FORCE_COLOR",
    "NODE_EXTRA_CA_CERTS",
  ];
  return Object.fromEntries(
    allowed
      .filter((key) => typeof inherited[key] === "string")
      .map((key) => [key, inherited[key]]),
  );
}

export function installPlan(root = defaultRoot, inherited = process.env) {
  const paths = inspectorPaths(root);
  return {
    command: process.platform === "win32" ? "npm.cmd" : "npm",
    args: [
      "install",
      "--prefix",
      paths.installDir,
      "--save-exact",
      "--omit=optional",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      `redis-commander@${COMMANDER_VERSION}`,
    ],
    cwd: paths.installDir,
    env: childEnvironment(inherited),
  };
}

export function startPlan(root, settings, inherited = process.env) {
  const paths = inspectorPaths(root);
  const config = createInspectorConfig(settings);
  return {
    command: process.execPath,
    // Force the safety flags at the CLI layer as well as NODE_CONFIG.
    args: [
      paths.binary,
      "--address=127.0.0.1",
      "--port=8081",
      "--read-only=true",
      "--nosave=true",
      "--no-log-data",
      "--use-scan=true",
      "--trust-proxy=false",
      `--root-pattern=${config.redis.rootPattern}`,
    ],
    cwd: paths.installDir,
    env: {
      ...childEnvironment(inherited),
      NODE_ENV: "development",
      NODE_CONFIG_DIR: paths.configDir,
      NODE_CONFIG: JSON.stringify(config),
    },
  };
}

async function hasJsonViewerAssets(dependencyDir) {
  try {
    const files = await Promise.all(
      ["jquery.json-viewer.js", "jquery.json-viewer.css"].map((name) =>
        stat(join(dependencyDir, "json-viewer", name)),
      ),
    );
    return files.every((file) => file.isFile() && file.size > 0);
  } catch {
    return false;
  }
}

export async function ensureJsonViewerAssets(root = defaultRoot) {
  const { installDir, packageDir } = inspectorPaths(root);
  const nested = join(packageDir, "node_modules", "jquery.json-viewer");
  const hoisted = join(installDir, "node_modules", "jquery.json-viewer");
  if (await hasJsonViewerAssets(nested)) return false;
  try {
    await lstat(nested);
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw new InspectorError(
        "Could not verify the inspector's nested JSON assets.",
      );
    }
    if (!(await hasJsonViewerAssets(hoisted))) {
      throw new InspectorError(
        `The inspector's JSON viewer JS/CSS assets are missing. ${installInstruction}`,
      );
    }
    // Upstream 0.9.0 serves these assets from a nested dependency path even
    // when npm hoists it. Link the existing dependency without editing vendors.
    try {
      await mkdir(dirname(nested), { recursive: true });
      await symlink(relative(dirname(nested), hoisted), nested, "dir");
      return true;
    } catch (linkError) {
      // Another launcher may have repaired the same missing link meanwhile.
      if (linkError.code === "EEXIST" && (await hasJsonViewerAssets(nested)))
        return false;
      throw new InspectorError(
        "Could not link the inspector's JSON assets. Inspect the isolated installation; existing files were not overwritten.",
      );
    }
  }
  throw new InspectorError(
    "Existing nested jquery.json-viewer assets are incomplete. Inspect the isolated installation; existing files were not overwritten.",
  );
}

async function assertIsolated(paths, env) {
  try {
    if ((await readdir(paths.configDir)).length > 0) {
      throw new InspectorError(
        "The inspector's empty-config directory must remain empty.",
      );
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const legacyBase = env[process.platform === "win32" ? "USERPROFILE" : "HOME"];
  try {
    await access(join(legacyBase || paths.packageDir, ".redis-commander"));
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw new InspectorError(
      "Could not verify legacy Redis Commander configuration isolation.",
    );
  }
  // In 0.9.0 --noload is unused; a legacy file is imported unconditionally.
  throw new InspectorError(
    "A legacy .redis-commander configuration exists; this isolated launcher refuses to load saved connections.",
  );
}

function runChild(plan) {
  return new Promise((resolveChild, reject) => {
    // Upstream Redis error objects may contain AUTH command arguments. Keep
    // child output private and report only controlled, credential-free status.
    const child = spawn(plan.command, plan.args, {
      cwd: plan.cwd,
      env: plan.env,
      stdio: ["inherit", "ignore", "ignore"],
    });
    const onInterrupt = () => child.kill("SIGINT");
    const onTerminate = () => child.kill("SIGTERM");
    process.on("SIGINT", onInterrupt);
    process.on("SIGTERM", onTerminate);
    const cleanup = () => {
      process.off("SIGINT", onInterrupt);
      process.off("SIGTERM", onTerminate);
    };
    child.once("error", () => {
      cleanup();
      reject(
        new InspectorError(
          "Could not launch the inspector command. Check Node.js/npm and retry.",
        ),
      );
    });
    child.once("close", (code, signal) => {
      cleanup();
      resolveChild(code ?? 128 + (constants.signals[signal] ?? 1));
    });
  });
}

export async function main(args = process.argv.slice(2), root = defaultRoot) {
  const command = args[0] ?? "start";
  if (
    args.length > 1 ||
    !["install", "start", "--help", "-h"].includes(command)
  ) {
    throw new InspectorError(
      "Use node scripts/redis-debug.mjs [install|start|--help].",
    );
  }
  if (["--help", "-h"].includes(command)) {
    console.log(`Usage: node scripts/redis-debug.mjs [install|start|--help]
Requires Node.js >=22. Install downloads redis-commander@${COMMANDER_VERSION} into ignored .runtime/redis-inspector.
Start (the default) reads backend/.env and runs the read-only inspector at ${INSPECTOR_URL}
The initial tree includes all REDIS_KEY_PREFIX keys, including user, presence and auth families.
Connections and passwords stay in memory. Ctrl+C stops the foreground process.`);
    return 0;
  }
  if (Number(process.versions.node.split(".")[0]) < 22) {
    throw new InspectorError(
      "The Redis inspector wrapper requires Node.js >=22.",
    );
  }
  const paths = inspectorPaths(root);
  if (command === "install") {
    await mkdir(paths.installDir, { recursive: true, mode: 0o700 });
    console.log(
      `Installing redis-commander@${COMMANDER_VERSION} in .runtime/redis-inspector.`,
    );
    const code = await runChild(installPlan(root));
    if (code !== 0)
      throw new InspectorError(
        "Inspector installation failed. Check npm access and retry the install command.",
      );
    await ensureJsonViewerAssets(root);
    console.log("Inspector installed. Run node scripts/redis-debug.mjs start.");
    return 0;
  }
  try {
    const metadata = JSON.parse(
      await readFile(join(paths.packageDir, "package.json"), "utf8"),
    );
    if (
      metadata.name !== "redis-commander" ||
      metadata.version !== COMMANDER_VERSION
    )
      throw new Error();
    await access(paths.binary);
  } catch {
    throw new InspectorError(
      `redis-commander@${COMMANDER_VERSION} is missing or incomplete. ${installInstruction}`,
    );
  }
  let settings;
  try {
    settings = parseBackendEnv(
      await readFile(resolve(root, "backend", ".env"), "utf8"),
    );
  } catch (error) {
    if (error instanceof InspectorError) throw error;
    throw new InspectorError("Could not read the private backend/.env file.");
  }
  const plan = startPlan(root, settings);
  await assertIsolated(paths, plan.env);
  await ensureJsonViewerAssets(root);
  console.log(`Read-only Redis inspector: ${INSPECTOR_URL} (Ctrl+C to stop).`);
  const code = await runChild(plan);
  if (code !== 0 && code !== 130 && code !== 143) {
    throw new InspectorError(
      "Redis inspector exited unsuccessfully. Check local Redis availability and the inspector installation.",
    );
  }
  return code;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  main()
    .then((code) => {
      process.exitCode = code;
    })
    .catch((error) => {
      console.error(
        error instanceof InspectorError
          ? error.message
          : "Redis inspector setup failed. No credentials were logged.",
      );
      process.exitCode = 1;
    });
}
