import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  defaultCaptureFile,
  selectDefaultCaptureFile,
  parseArguments,
  workspaceRoot,
} from "../src/index.js";

test("default capture is anchored to this workspace rather than the host working directory", () => {
  assert.equal(
    defaultCaptureFile,
    resolve(workspaceRoot, ".runtime/backend-logs/traffic.jsonl"),
  );
  assert.equal(
    parseArguments([]).file,
    selectDefaultCaptureFile(workspaceRoot),
  );
  assert.equal(
    parseArguments([], "/workspace").file,
    "/workspace/.runtime/backend-logs/traffic.jsonl",
  );
  assert.equal(
    parseArguments(["--file", "capture.jsonl"], "/workspace").file,
    "/workspace/capture.jsonl",
  );
  assert.equal(
    parseArguments(["--file", "/private/other.jsonl"], "/workspace").file,
    "/private/other.jsonl",
  );
});

test("CLI rejects ambiguous or unsupported arguments", () => {
  for (const args of [
    ["--file"],
    ["--file", ""],
    ["--file", "--help"],
    ["--port", "8083"],
    ["--file", "x", "y"],
    ["--file", "x\0y"],
  ]) {
    assert.throws(() => parseArguments(args));
  }
  assert.equal(parseArguments(["--help"]).help, true);
});

test("help and argument errors are separate from the stdio protocol", () => {
  const entrypoint = fileURLToPath(new URL("../src/index.js", import.meta.url));
  const help = spawnSync(process.execPath, [entrypoint, "--help"], {
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /search_logs, trace_request, error_summary/);
  assert.equal(help.stderr, "");
  const invalid = spawnSync(
    process.execPath,
    [entrypoint, "--unknown", "private-command-value"],
    { encoding: "utf8", timeout: 10_000 },
  );
  assert.equal(invalid.status, 1);
  assert.equal(invalid.stdout, "");
  assert.match(invalid.stderr, /Could not start backend log MCP/);
  assert.doesNotMatch(invalid.stderr, /private-command-value|\bat \w|stack/i);
});

test("an unused stdio server exits quietly when its host closes stdin", () => {
  const entrypoint = fileURLToPath(new URL("../src/index.js", import.meta.url));
  const result = spawnSync(process.execPath, [entrypoint], {
    input: "",
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(result.status, 0);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, "");
});

test("startup prefers a safe existing unified capture and fixes that file for the connection", async (t) => {
  const directory = await mkdtemp(
    join(await realpath(tmpdir()), "mcp-default-"),
  );
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fallback = parseArguments([], directory);
  assert.equal(
    fallback.file,
    join(directory, ".runtime/backend-logs/traffic.jsonl"),
  );
  const parent = join(directory, ".runtime/observability");
  await mkdir(parent, { recursive: true });
  const capture = join(parent, "events.jsonl");
  await writeFile(capture, "", { mode: 0o600 });
  assert.equal(parseArguments([], directory).file, capture);
  assert.equal(
    fallback.file,
    join(directory, ".runtime/backend-logs/traffic.jsonl"),
  );
  await rm(capture);
  await symlink(join(directory, "private-capture"), capture);
  assert.throws(
    () => selectDefaultCaptureFile(directory),
    /cannot be selected safely/,
  );
  assert.equal(parseArguments(["--help"], directory).help, true);
  assert.equal(
    parseArguments(["--file", "explicit.jsonl"], directory).file,
    join(directory, "explicit.jsonl"),
  );
});
