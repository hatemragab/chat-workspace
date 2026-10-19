import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseEnv } from "node:util";

const workspaceRoot = fileURLToPath(new URL("../", import.meta.url));

/** Explicit developer command; importing this module never starts the API. */
export function debugBackendLaunch(
  root = workspaceRoot,
  inherited = process.env,
) {
  const directory = join(root, "backend");
  let configured = {};
  try {
    configured = parseEnv(readFileSync(join(directory, ".env"), "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw new Error("Could not read the backend logging configuration.");
    }
  }
  const setting = (key, fallback) =>
    inherited[key] ?? configured[key] ?? fallback;
  return {
    command: process.execPath,
    args: [
      join(directory, "node_modules", "ts-node", "dist", "bin.js"),
      "src/main.ts",
    ],
    options: {
      cwd: directory,
      stdio: "inherit",
      env: {
        ...inherited,
        HTTP_LOGGING_ENABLED: setting("HTTP_LOGGING_ENABLED", "true"),
        DEBUG_TRAFFIC_LOGGING_ENABLED: setting(
          "DEBUG_TRAFFIC_LOGGING_ENABLED",
          "true",
        ),
        TRAFFIC_LOG_FORMAT: setting("TRAFFIC_LOG_FORMAT", "pretty"),
        TRAFFIC_LOG_FILE: setting(
          "TRAFFIC_LOG_FILE",
          join(root, ".runtime", "backend-logs", "traffic.jsonl"),
        ),
        LOCAL_SERVICE_LOG_FILE: setting(
          "LOCAL_SERVICE_LOG_FILE",
          join(root, ".runtime", "observability", "inputs", "services.jsonl"),
        ),
      },
    },
  };
}

export function startDebugBackend(root = workspaceRoot) {
  const launch = debugBackendLaunch(root);
  process.stdout.write(
    "Starting backend with your console and file logging settings.\n",
  );
  process.stdout.write(
    "Log viewer: http://127.0.0.1:8082/ (start it separately with npm run logs).\n",
  );
  const child = spawn(launch.command, launch.args, launch.options);
  const forwardInterrupt = () => child.kill("SIGINT");
  const forwardTerminate = () => child.kill("SIGTERM");
  process.once("SIGINT", forwardInterrupt);
  process.once("SIGTERM", forwardTerminate);
  const cleanup = () => {
    process.removeListener("SIGINT", forwardInterrupt);
    process.removeListener("SIGTERM", forwardTerminate);
  };
  child.once("error", () => {
    cleanup();
    process.stderr.write(
      "Could not start the backend. Run npm install in backend first.\n",
    );
    process.exitCode = 1;
  });
  child.once("exit", (code, signal) => {
    cleanup();
    process.exitCode = code ?? (signal === "SIGINT" ? 130 : 1);
  });
  return child;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  startDebugBackend();
}
