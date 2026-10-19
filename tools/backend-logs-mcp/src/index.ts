import {
  serveStdio,
  StdioServerTransport,
} from "@modelcontextprotocol/server/stdio";
import { lstatSync } from "node:fs";
import { dirname, join, parse, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createBackendLogsServer } from "./server.js";

// This entrypoint is built to tools/backend-logs-mcp/dist/src/index.js.
// Locate the capture from the workspace, independent of the AI host's cwd.
export const workspaceRoot = fileURLToPath(
  new URL("../../../../", import.meta.url),
);
/** Select once during host startup; never switch the backing capture mid-connection. */
export function selectDefaultCaptureFile(root = workspaceRoot): string {
  const unified = resolve(root, ".runtime/observability/events.jsonl");
  try {
    const parent = dirname(unified);
    let current = parse(parent).root;
    for (const part of relative(current, parent).split(sep).filter(Boolean)) {
      current = join(current, part);
      const info = lstatSync(current);
      if (!info.isDirectory() || info.isSymbolicLink())
        throw new Error("Unsafe capture.");
    }
    const info = lstatSync(unified);
    if (
      !info.isFile() ||
      info.isSymbolicLink() ||
      info.nlink !== 1 ||
      (info.mode & 0o444) === 0
    ) {
      throw new Error("Unsafe capture.");
    }
    return unified;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT")
      throw new Error("Local capture cannot be selected safely.");
    return resolve(root, ".runtime/backend-logs/traffic.jsonl");
  }
}

// Preserve the exported legacy fallback path. Selection happens inside main's
// error boundary, so --file and --help never inspect an unrelated default path.
export const defaultCaptureFile = resolve(
  workspaceRoot,
  ".runtime/backend-logs/traffic.jsonl",
);

export function parseArguments(
  args: readonly string[],
  root = workspaceRoot,
): { help: boolean; file: string } {
  if (args.length === 0) {
    return {
      help: false,
      file: selectDefaultCaptureFile(root),
    };
  }
  if (args.length === 1 && ["--help", "-h"].includes(args[0])) {
    return {
      help: true,
      file: resolve(root, ".runtime/backend-logs/traffic.jsonl"),
    };
  }
  if (
    args.length === 2 &&
    args[0] === "--file" &&
    args[1].trim() &&
    !args[1].startsWith("-") &&
    !args[1].includes("\0")
  ) {
    return { help: false, file: resolve(root, args[1]) };
  }
  throw new Error("Use backend-logs-mcp [--file PATH | --help].");
}

export function main(args = process.argv.slice(2)): void {
  const options = parseArguments(args);
  if (options.help) {
    process.stdout.write(
      "Usage: node tools/backend-logs-mcp/dist/src/index.js [--file PATH]\n" +
        "Read-only MCP over stdio: search_logs, trace_request, error_summary, trace_events, list_log_archives.\n" +
        "Uses an existing .runtime/observability/events.jsonl, otherwise .runtime/backend-logs/traffic.jsonl; selection is fixed at startup.\n" +
        "Relative --file paths resolve from the workspace root. Tools may select only fixed-name sibling archives.\n" +
        "The AI host starts this process; it never starts the API or viewer.\n",
    );
    return;
  }
  const handle = serveStdio(() => createBackendLogsServer(options.file), {
    transport: new StdioServerTransport(process.stdin, process.stdout, {
      maxBufferSize: 256 * 1024,
    }),
    onerror: () => {
      process.stderr.write("Backend log MCP transport error.\n");
    },
  });
  const stop = () => {
    void handle.close().catch(() => {
      process.stderr.write("Backend log MCP shutdown failed.\n");
      process.exitCode = 1;
    });
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  try {
    main();
  } catch {
    process.stderr.write(
      "Could not start backend log MCP. Check the command and local installation.\n",
    );
    process.exitCode = 1;
  }
}
