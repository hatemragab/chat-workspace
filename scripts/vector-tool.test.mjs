import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  VECTOR_RELEASE,
  VectorToolError,
  installVector,
  isPinnedVectorVersion,
  main,
  vectorPaths,
  verifiedVector,
} from "./vector-tool.mjs";

async function rootFixture(t) {
  const root = await mkdtemp(
    join(await realpath(tmpdir()), "vector-tool-test-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

function controlled(error) {
  assert.ok(error instanceof VectorToolError);
  assert.doesNotMatch(
    error.message,
    /vector-tool-test-|\/Users\/|secret-token|\bat \w/,
  );
  return true;
}

test("Vector pins the exact official stable macOS ARM64 artifact in the workspace", () => {
  assert.equal(VECTOR_RELEASE.version, "0.59.0");
  assert.equal(VECTOR_RELEASE.size, 52687645);
  assert.equal(
    VECTOR_RELEASE.sha256,
    "6f0cd290c90ea2cfc7cb3c10eca32fc897f0b958b60d48ad2867a91d5585363c",
  );
  assert.equal(
    VECTOR_RELEASE.url,
    `https://github.com/vectordotdev/vector/releases/download/v0.59.0/${VECTOR_RELEASE.filename}`,
  );
  const paths = vectorPaths("/workspace");
  assert.equal(paths.installDir, "/workspace/.runtime/vector");
  assert.equal(
    paths.binary,
    "/workspace/.runtime/vector/vector-0.59.0/bin/vector",
  );
  assert.equal(paths.archive, join(paths.installDir, VECTOR_RELEASE.filename));
  assert.equal(paths.manifest, "/workspace/.runtime/vector/vector-0.59.0.json");
  assert.ok(Object.isFrozen(VECTOR_RELEASE));
});

test("version checks reject development, mismatched and prefixed command output", () => {
  assert.equal(
    isPinnedVectorVersion(
      "vector 0.59.0 (arm64-apple-darwin abc 2026-10-01)\n",
    ),
    true,
  );
  for (const output of [
    "vector 0.59.0-dev",
    "vector vdevrelease",
    "vector 0.59.01",
    "vector 0.58.0",
    "untrusted vector 0.59.0",
    "vector v0.59.0",
  ]) {
    assert.equal(isPinnedVectorVersion(output), false, output);
  }
});

test("missing readonly verification does not create directories or launch installation", async (t) => {
  const root = await rootFixture(t);
  await assert.rejects(verifiedVector(root), controlled);
  await assert.rejects(lstat(join(root, ".runtime")), { code: "ENOENT" });
});

test("verification rejects changed artifacts while preserving bytes, modes and timestamps", async (t) => {
  const root = await rootFixture(t);
  const paths = vectorPaths(root);
  await mkdir(dirname(paths.binary), { recursive: true, mode: 0o700 });
  await writeFile(paths.binary, "untrusted binary content", { mode: 0o700 });
  await writeFile(paths.archive, "untrusted archive content", { mode: 0o600 });
  await writeFile(
    paths.manifest,
    JSON.stringify({
      version: VECTOR_RELEASE.version,
      platform: VECTOR_RELEASE.platform,
      arch: VECTOR_RELEASE.arch,
      archiveSha256: VECTOR_RELEASE.sha256,
      binarySha256: createHash("sha256")
        .update("untrusted binary content")
        .digest("hex"),
    }),
    { mode: 0o600 },
  );
  const before = await Promise.all(
    [paths.binary, paths.archive, paths.manifest].map(async (path) => ({
      path,
      bytes: await readFile(path),
      stat: await lstat(path),
    })),
  );
  await assert.rejects(verifiedVector(root), controlled);
  for (const original of before) {
    assert.deepEqual(await readFile(original.path), original.bytes);
    const after = await lstat(original.path);
    assert.equal(after.mode, original.stat.mode);
    assert.equal(after.mtimeMs, original.stat.mtimeMs);
  }
  assert.equal(
    await lstat(paths.processLog).catch((error) => error.code),
    "ENOENT",
  );
});

test("unsafe manifest links, parent links and oversized metadata fail readonly verification", async (t) => {
  const root = await rootFixture(t);
  const paths = vectorPaths(root);
  await mkdir(paths.installDir, { recursive: true, mode: 0o700 });
  const target = join(root, "private-target");
  await writeFile(target, "secret-token", { mode: 0o600 });
  await symlink(target, paths.manifest);
  await assert.rejects(verifiedVector(root), controlled);
  assert.equal(await readFile(target, "utf8"), "secret-token");
  await rm(paths.manifest);
  await writeFile(paths.manifest, "x".repeat(8193), { mode: 0o600 });
  await assert.rejects(verifiedVector(root), controlled);
  await rm(paths.installDir, { recursive: true });
  await symlink(root, paths.installDir);
  await assert.rejects(verifiedVector(root), controlled);
});

test("installer preserves unexpected existing archives and incomplete version directories without downloading", async (t) => {
  const root = await rootFixture(t);
  const paths = vectorPaths(root);
  await mkdir(paths.installDir, { recursive: true, mode: 0o700 });
  await writeFile(paths.archive, "unexpected archive", { mode: 0o600 });
  await assert.rejects(installVector(root), controlled);
  assert.equal(await readFile(paths.archive, "utf8"), "unexpected archive");
  await mkdir(paths.versionDir, { mode: 0o700 });
  const unrelated = join(paths.versionDir, "unrelated.txt");
  await writeFile(unrelated, "preserve this", { mode: 0o600 });
  await assert.rejects(installVector(root), controlled);
  assert.equal(await readFile(unrelated, "utf8"), "preserve this");
});

test("installer refuses invalid existing manifests and active locks without altering their contents", async (t) => {
  const root = await rootFixture(t);
  const paths = vectorPaths(root);
  await mkdir(paths.installDir, { recursive: true, mode: 0o700 });
  await writeFile(paths.manifest, "invalid existing manifest", { mode: 0o600 });
  await assert.rejects(installVector(root), controlled);
  assert.equal(
    await readFile(paths.manifest, "utf8"),
    "invalid existing manifest",
  );
  await rm(paths.manifest);
  const lock = join(paths.installDir, ".install.lock");
  await writeFile(lock, "other invocation", { mode: 0o600 });
  await assert.rejects(installVector(root), controlled);
  assert.equal(await readFile(lock, "utf8"), "other invocation");
});

test("CLI accepts only explicit install or verify and contains command errors", async (t) => {
  const root = await rootFixture(t);
  for (const args of [
    [],
    ["start"],
    ["install", "extra"],
    ["--file", "private-path"],
  ])
    await assert.rejects(main(args, root), controlled);
  const entrypoint = fileURLToPath(
    new URL("./vector-tool.mjs", import.meta.url),
  );
  const result = spawnSync(
    process.execPath,
    [entrypoint, "private-command-value"],
    { encoding: "utf8", timeout: 5000 },
  );
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /install\|verify/);
  assert.doesNotMatch(result.stderr, /private-command-value|\bat \w|\/Users\//);
});
