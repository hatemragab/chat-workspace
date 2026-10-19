import assert from "node:assert/strict";
import {
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
import { join } from "node:path";
import { test } from "node:test";
import {
  VECTOR_SOURCE_BUILD,
  matchesVectorBuildProvenance,
  patchedVectorPaths,
  verifiedPatchedVector,
} from "./vector-source-build.mjs";

test("source build provenance pins upstream source, exact patch, toolchain and required components", () => {
  const manifest = {
    ...VECTOR_SOURCE_BUILD,
    platform: "darwin",
    arch: "arm64",
    binarySha256: "f".repeat(64),
  };
  assert.ok(matchesVectorBuildProvenance(manifest));
  for (const key of Object.keys(manifest))
    assert.equal(
      matchesVectorBuildProvenance({
        ...manifest,
        [key]: "changed-untrusted-value",
      }),
      false,
      key,
    );
  assert.ok(Object.isFrozen(VECTOR_SOURCE_BUILD));
  assert.equal(VECTOR_SOURCE_BUILD.jobs, 2);
  assert.equal(
    VECTOR_SOURCE_BUILD.features,
    "sources-file,sinks-file,transforms-remap",
  );
  assert.equal(
    patchedVectorPaths("/workspace").binary,
    "/workspace/.runtime/vector/source-build/chat-file-readiness-v1/bin/vector",
  );
});

test("missing, linked or altered source-build metadata fails read-only verification without executing files", async (t) => {
  const root = await mkdtemp(
    join(await realpath(tmpdir()), "vector-source-build-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(verifiedPatchedVector(root));
  await assert.rejects(lstat(join(root, ".runtime")), { code: "ENOENT" });
  const paths = patchedVectorPaths(root);
  await mkdir(paths.installed, { recursive: true, mode: 0o700 });
  const target = join(root, "preserved-private-file");
  await writeFile(target, "preserved-private-file");
  await symlink(target, paths.manifest);
  await assert.rejects(verifiedPatchedVector(root));
  assert.equal(await readFile(target, "utf8"), "preserved-private-file");
  await rm(paths.manifest);
  await writeFile(
    paths.manifest,
    JSON.stringify({ ...VECTOR_SOURCE_BUILD, upstreamCommit: "changed" }),
  );
  const before = await readFile(paths.manifest);
  await assert.rejects(verifiedPatchedVector(root));
  assert.deepEqual(await readFile(paths.manifest), before);
});
