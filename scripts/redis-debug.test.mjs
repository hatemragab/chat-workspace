import assert from "node:assert/strict";
import {
  lstat,
  mkdtemp,
  mkdir,
  readFile,
  readlink,
  writeFile,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  COMMANDER_VERSION,
  childEnvironment,
  createInspectorConfig,
  ensureJsonViewerAssets,
  escapeRedisGlob,
  inspectorPaths,
  installPlan,
  main,
  parseBackendEnv,
  parseRedisUrl,
  startPlan,
} from "./redis-debug.mjs";

test("reads only Redis settings from private dotenv text", () => {
  assert.deepEqual(
    parseBackendEnv(`
    REDIS_URL='redis://local-user:p%40ss@localhost:6380/7'
    REDIS_KEY_PREFIX="chat:local:"
    JWT_SECRET=unrelated-private-secret
  `),
    {
      redisUrl: "redis://local-user:p%40ss@localhost:6380/7",
      prefix: "chat:local:",
    },
  );
  assert.equal(parseBackendEnv("REDIS_URL=redis://localhost").prefix, "");
  assert.throws(() => parseBackendEnv("JWT_SECRET=private"), /Set REDIS_URL/);
});

test("parses loopback Redis URLs, database selection and encoded credentials", () => {
  for (const hostname of ["localhost", "127.0.0.1", "[::1]"]) {
    const target = parseRedisUrl(
      `redis://user%40local:p%3Ass%40word@${hostname}:6380/7`,
    );
    assert.equal(target.host, hostname.replace(/^\[|\]$/g, ""));
    assert.equal(target.port, 6380);
    assert.equal(target.dbIndex, 7);
    assert.equal(target.username, "user@local");
    assert.equal(target.password, "p:ss@word");
    assert.equal(target.tls, undefined);
  }
  assert.equal(parseRedisUrl("redis://localhost").dbIndex, 0);
  assert.equal(parseRedisUrl("redis://localhost/?db=3").dbIndex, 3);
  assert.equal(parseRedisUrl("redis://localhost/7?db=3").dbIndex, 7);
  assert.deepEqual(parseRedisUrl("rediss://:secret@[::1]/2").tls, {
    rejectUnauthorized: true,
  });
});

test("refuses nonlocal, malformed and redirecting targets without leaking credentials", () => {
  const urls = [
    "redis://private-user:private-password@redis.example.test/0",
    "redis://private-password@0.0.0.0/0",
    "redis://private-password@127.1/0",
    "redis://private-password@localhost.example.test/0",
    "redis://private-password@localhost./0",
    "redis://private-password@[::]/0",
    "redis://private-password@[::ffff:127.0.0.1]/0",
    "http://private-password@localhost/0",
    "redis://private-password@localhost/-1",
    "redis://private-password@localhost/2.5",
    "redis://private-password@localhost/9007199254740992",
    "redis://private-password@localhost:0/0",
    "redis://private-password@localhost:65536/0",
    "redis://private-password@localhost/0?host=remote.test",
    "redis://private-password@localhost?db=1&db=2",
    "redis://private-password@localhost/0#private-password",
    "redis://private%ZZ-password@localhost/0",
    "private-password is not a URL",
  ];
  for (const value of urls) {
    assert.throws(
      () => parseRedisUrl(value),
      (error) => {
        assert.match(error.message, /REDIS_URL must use/);
        assert.doesNotMatch(
          error.message,
          /private-password|private-user|remote.test/,
        );
        return true;
      },
    );
  }
});

test("escapes Redis glob syntax in the prefix and sets complete read-only defaults", () => {
  assert.equal(escapeRedisGlob("chat:[dev]*?\\:"), "chat:\\[dev\\]\\*\\?\\\\:");
  const config = createInspectorConfig({
    redisUrl: "redis://:private-password@localhost/4",
    prefix: "chat:[dev]:",
  });
  assert.equal(config.noSave, true);
  assert.equal(config.noLogData, true);
  assert.equal(config.redis.readOnly, true);
  assert.equal(config.redis.useScan, true);
  assert.equal(config.redis.flushOnImport, false);
  assert.deepEqual(config.redis.extraAllowedReadOnlyCommands, [
    "select",
    "info",
  ]);
  assert.equal(config.redis.rootPattern, "chat:\\[dev\\]:*");
  assert.equal(config.ui.jsonViewAsDefault, "hash,string,zset");
  assert.equal(config.server.address, "127.0.0.1");
  assert.equal(config.server.port, 8081);
  assert.equal(config.server.trustProxy, false);
  assert.equal(config.sso.enabled, false);
  assert.equal(config.connections.length, 1);
  assert.equal(config.connections[0].dbIndex, 4);
});

test("child environment removes inherited authentication and configuration overrides", () => {
  const inherited = {
    PATH: "/safe/bin",
    HOME: "/safe/user",
    TMPDIR: "/safe/tmp",
    NODE_CONFIG: '{"redis":{"readOnly":false}}',
    NODE_CONFIG_DIR: "/foreign/config",
    NODE_OPTIONS: "--require=/foreign/code",
    NODE_ENV: "production",
    NODE_TLS_REJECT_UNAUTHORIZED: "0",
    REDIS_URL: "redis://:ambient-password@remote.test",
    REDIS_PASSWORD: "ambient-password",
    ADDRESS: "0.0.0.0",
    PORT: "9999",
    READ_ONLY: "false",
    NOSAVE: "false",
    NO_LOG_DATA: "false",
    USE_SCAN: "false",
    ROOT_PATTERN: "*",
    HTTP_USER: "ambient-user",
    HTTP_PASSWORD: "ambient-password",
    SSO_ENABLED: "true",
    VIEW_JSON_DEFAULT: "none",
    JWT_SECRET: "unrelated-private-secret",
  };
  assert.deepEqual(childEnvironment(inherited), {
    PATH: "/safe/bin",
    HOME: "/safe/user",
    TMPDIR: "/safe/tmp",
  });
  const plan = startPlan(
    "/project",
    { redisUrl: "rediss://:private-password@localhost/2" },
    inherited,
  );
  const config = JSON.parse(plan.env.NODE_CONFIG);
  assert.equal(config.connections[0].password, "private-password");
  assert.deepEqual(config.connections[0].tls, { rejectUnauthorized: true });
  assert.equal(config.redis.readOnly, true);
  assert.equal(
    plan.env.NODE_CONFIG_DIR,
    "/project/.runtime/redis-inspector/empty-config",
  );
  assert.equal(plan.env.NODE_OPTIONS, undefined);
  assert.doesNotMatch(
    JSON.stringify(plan.args),
    /private-password|ambient-password|redis:\/\//,
  );
  assert.ok(plan.args.includes("--read-only=true"));
  assert.ok(plan.args.includes("--nosave=true"));
  assert.ok(plan.args.includes("--no-log-data"));
  assert.ok(plan.args.includes("--address=127.0.0.1"));
  assert.ok(plan.args.includes("--port=8081"));
  assert.ok(plan.args.includes("--use-scan=true"));
});

test("installation is pinned and isolated from backend dependencies", () => {
  const paths = inspectorPaths("/project");
  const plan = installPlan("/project", {
    PATH: "/bin",
    REDIS_PASSWORD: "private-password",
  });
  assert.equal(COMMANDER_VERSION, "0.9.0");
  assert.equal(plan.cwd, "/project/.runtime/redis-inspector");
  assert.equal(
    paths.binary,
    "/project/.runtime/redis-inspector/node_modules/redis-commander/bin/redis-commander.js",
  );
  for (const argument of [
    "redis-commander@0.9.0",
    "--save-exact",
    "--omit=optional",
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
  ]) {
    assert.ok(plan.args.includes(argument));
  }
  assert.doesNotMatch(JSON.stringify(plan), /backend|private-password/);
});

test("missing package and unknown flags fail with safe, actionable messages", async () => {
  const root = await mkdtemp(join(tmpdir(), "chat-inspector-test-"));
  try {
    await assert.rejects(
      main(["start"], root),
      /Run node scripts\/redis-debug.mjs install first/,
    );
    await assert.rejects(
      main(["--redis-password=private-password"], root),
      (error) => {
        assert.doesNotMatch(error.message, /private-password/);
        return true;
      },
    );
    const paths = inspectorPaths(root);
    await mkdir(join(paths.packageDir, "bin"), { recursive: true });
    await writeFile(
      join(paths.packageDir, "package.json"),
      JSON.stringify({ name: "redis-commander", version: "0.8.1" }),
    );
    await writeFile(paths.binary, "");
    await assert.rejects(
      main(["start"], root),
      /0\.9\.0 is missing or incomplete/,
    );
  } finally {
    await rm(root, { recursive: true });
  }
});

test("help is available without installation, Redis or backend credentials", () => {
  const script = fileURLToPath(new URL("./redis-debug.mjs", import.meta.url));
  const result = spawnSync(process.execPath, [script, "--help"], {
    encoding: "utf8",
    env: childEnvironment(),
  });
  assert.equal(result.status, 0);
  assert.equal(result.stderr, "");
  assert.match(result.stdout, /Node\.js >=22/);
  assert.match(result.stdout, /127\.0\.0\.1:8081/);
  assert.match(result.stdout, /Ctrl\+C/);
});

async function createJsonAssets(dependencyDir) {
  await mkdir(join(dependencyDir, "json-viewer"), { recursive: true });
  for (const name of ["jquery.json-viewer.js", "jquery.json-viewer.css"]) {
    await writeFile(
      join(dependencyDir, "json-viewer", name),
      `existing ${name}`,
    );
  }
}

test("repairs hoisted JSON assets with an idempotent relative link", async () => {
  const root = await mkdtemp(join(tmpdir(), "chat-inspector-assets-"));
  try {
    const paths = inspectorPaths(root);
    const hoisted = join(
      paths.installDir,
      "node_modules",
      "jquery.json-viewer",
    );
    const nested = join(paths.packageDir, "node_modules", "jquery.json-viewer");
    await createJsonAssets(hoisted);
    assert.equal(await ensureJsonViewerAssets(root), true);
    assert.equal((await lstat(nested)).isSymbolicLink(), true);
    assert.equal(await readlink(nested), "../../jquery.json-viewer");
    assert.equal(
      await readFile(
        join(nested, "json-viewer", "jquery.json-viewer.js"),
        "utf8",
      ),
      "existing jquery.json-viewer.js",
    );
    assert.equal(await ensureJsonViewerAssets(root), false);
  } finally {
    await rm(root, { recursive: true });
  }
});

test("preserves an existing complete nested JSON dependency without requiring hoisted assets", async () => {
  const root = await mkdtemp(join(tmpdir(), "chat-inspector-assets-"));
  try {
    const nested = join(
      inspectorPaths(root).packageDir,
      "node_modules",
      "jquery.json-viewer",
    );
    await createJsonAssets(nested);
    assert.equal(await ensureJsonViewerAssets(root), false);
    assert.equal((await lstat(nested)).isDirectory(), true);
    assert.equal(
      await readFile(
        join(nested, "json-viewer", "jquery.json-viewer.css"),
        "utf8",
      ),
      "existing jquery.json-viewer.css",
    );
  } finally {
    await rm(root, { recursive: true });
  }
});

test("refuses to replace unexpected or partial nested JSON dependencies", async () => {
  for (const kind of ["file", "partial-directory"]) {
    const root = await mkdtemp(join(tmpdir(), "chat-inspector-assets-"));
    try {
      const paths = inspectorPaths(root);
      const nested = join(
        paths.packageDir,
        "node_modules",
        "jquery.json-viewer",
      );
      await createJsonAssets(
        join(paths.installDir, "node_modules", "jquery.json-viewer"),
      );
      await mkdir(join(paths.packageDir, "node_modules"), { recursive: true });
      const sentinel =
        kind === "file"
          ? nested
          : join(nested, "json-viewer", "jquery.json-viewer.js");
      if (kind === "partial-directory")
        await mkdir(join(nested, "json-viewer"), { recursive: true });
      await writeFile(sentinel, "preserve these existing files");
      await assert.rejects(
        ensureJsonViewerAssets(root),
        /Existing nested.*incomplete/,
      );
      assert.equal(
        await readFile(sentinel, "utf8"),
        "preserve these existing files",
      );
      assert.equal((await lstat(nested)).isSymbolicLink(), false);
    } finally {
      await rm(root, { recursive: true });
    }
  }
});

test("missing hoisted JSON assets produce an actionable failure without creating a nested dependency", async () => {
  const root = await mkdtemp(join(tmpdir(), "chat-inspector-assets-"));
  try {
    const nested = join(
      inspectorPaths(root).packageDir,
      "node_modules",
      "jquery.json-viewer",
    );
    await assert.rejects(
      ensureJsonViewerAssets(root),
      /JSON viewer JS\/CSS assets are missing.*install first/,
    );
    await assert.rejects(lstat(nested), { code: "ENOENT" });
  } finally {
    await rm(root, { recursive: true });
  }
});
