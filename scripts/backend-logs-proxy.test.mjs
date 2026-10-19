import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import http from "node:http";
import { join } from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import {
  createLogProxy,
  quotaSafeLogMap,
  rewriteViewerLogCache,
  rewriteViewerReconnect,
} from "./backend-logs-proxy.mjs";

const assetPath = "/assets/index-jVCiWEg8.js";
const before = 'new WebSocket(Ui+"?password="+e.getPassword())';

function request(url, { path = assetPath, method = "GET" } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      new URL(path, url),
      { method, agent: false },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("error", reject);
        res.on("end", () =>
          resolve({
            status: res.statusCode,
            headers: res.headers,
            body: Buffer.concat(chunks),
          }),
        );
      },
    );
    req.on("error", reject);
    req.end();
  });
}

async function fixture(t, handler) {
  const root = await mkdtemp("/tmp/chat-logdy-reconnect-");
  const socketPath = join(root, "viewer.sock");
  const sockets = new Set();
  const upstream = http.createServer(handler);
  upstream.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  await new Promise((resolve) => upstream.listen(socketPath, resolve));
  const proxy = await createLogProxy({
    upstreamSocketPath: socketPath,
    port: 0,
  });
  t.after(async () => {
    await proxy.close();
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => upstream.close(resolve));
    await rm(root, { recursive: true, force: true });
  });
  return { ...proxy, upstream };
}

test("reconnect handshake preserves initial and explicit pause and resumes both following modes", () => {
  const urls = [];
  const context = {
    Ui: "ws://127.0.0.1/ws",
    e: { receiveStatus: "paused", getPassword: () => "p&should_follow=true#" },
    WebSocket: function (url) {
      urls.push(new URL(url));
    },
  };
  const code = rewriteViewerReconnect(`function connect(){return ${before};}`);
  runInNewContext(`${code};connect();`, context);
  assert.equal(urls.at(-1).searchParams.get("should_follow"), "false");
  assert.equal(
    urls.at(-1).searchParams.get("password"),
    "p&should_follow=true#",
  );
  for (const mode of ["following", "following_cursor"]) {
    context.e.receiveStatus = mode;
    // The same connection setup runs on initial activation and socket reconnect.
    runInNewContext("connect();connect();", context);
    assert.equal(urls.at(-1).searchParams.get("should_follow"), "true");
    assert.equal(urls.at(-2).searchParams.get("should_follow"), "true");
  }
  context.e.receiveStatus = "paused";
  runInNewContext("connect();", context);
  assert.equal(urls.at(-1).searchParams.get("should_follow"), "false");
});

test("reconnect rewrite refuses absent, duplicate, or already transformed fragments", () => {
  for (const source of [null, "unrecognized bundle", before + before]) {
    assert.throws(() => rewriteViewerReconnect(source), /Unsupported/);
  }
  assert.throws(
    () => rewriteViewerReconnect(rewriteViewerReconnect(before)),
    /Unsupported/,
  );
});

test("pinned browser bundle is verified, rewritten across chunks, and served with correct GET/HEAD headers", async (t) => {
  let bundle;
  try {
    bundle = await readFile(
      new URL(
        "../.runtime/backend-log-viewer/module-cache/github.com/logdyhq/logdy-core@v0.17.1/http/assets/assets/index-jVCiWEg8.js",
        import.meta.url,
      ),
    );
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    t.skip("Pinned Logdy bundle is checked after the local viewer install.");
    return;
  }
  const methods = [];
  const cut = bundle.indexOf(before) + 15;
  assert.ok(cut > 15);
  const proxy = await fixture(t, (req, res) => {
    methods.push(req.method);
    res.writeHead(200, {
      "Content-Type": "text/javascript; charset=utf-8",
      "Content-Length": bundle.length,
      ETag: "stale-upstream-hash",
      "Cache-Control": "public, max-age=86400",
    });
    res.write(bundle.subarray(0, cut));
    setImmediate(() => res.end(bundle.subarray(cut)));
  });
  const get = await request(proxy.url);
  assert.equal(get.status, 200);
  assert.equal(
    get.body.toString(),
    rewriteViewerLogCache(rewriteViewerReconnect(bundle.toString())),
  );
  assert.equal(Number(get.headers["content-length"]), get.body.length);
  assert.equal(get.headers["content-encoding"], undefined);
  assert.equal(get.headers.etag, undefined);
  assert.equal(get.headers["cache-control"], "no-store");
  assert.match(
    get.headers["content-security-policy"],
    /frame-ancestors 'none'/,
  );
  const head = await request(proxy.url, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(head.body.length, 0);
  assert.equal(head.headers["content-length"], get.headers["content-length"]);
  assert.deepEqual(methods, ["GET", "GET"]);
});

test("changed main bundle names are rejected before reaching the private viewer", async (t) => {
  let calls = 0;
  const proxy = await fixture(t, (_req, res) => {
    calls++;
    res.end("unexpected");
  });
  const result = await request(proxy.url, {
    path: "/assets/index-newversion.js",
  });
  assert.equal(result.status, 502);
  assert.equal(calls, 0);
  assert.equal(result.headers["cache-control"], "no-store");
});

for (const [name, headers, body] of [
  ["modified source", { "Content-Type": "application/javascript" }, before],
  [
    "encoded source",
    { "Content-Type": "application/javascript", "Content-Encoding": "gzip" },
    before,
  ],
  ["unexpected MIME", { "Content-Type": "text/html" }, before],
  [
    "oversized declared source",
    {
      "Content-Type": "application/javascript",
      "Content-Length": 16 * 1024 * 1024 + 1,
    },
    before,
  ],
]) {
  test(`asset rewrite fails closed for ${name}`, async (t) => {
    const proxy = await fixture(t, (_req, res) => {
      res.writeHead(200, headers);
      res.end(body);
    });
    const result = await request(proxy.url);
    assert.equal(result.status, 502);
    assert.match(result.body.toString(), /Unsupported viewer UI asset/);
    assert.equal(result.headers["cache-control"], "no-store");
  });
}

test("chunked oversized source is bounded before rewrite", async (t) => {
  const proxy = await fixture(t, (_req, res) => {
    res.writeHead(200, { "Content-Type": "application/javascript" });
    res.end(Buffer.alloc(16 * 1024 * 1024 + 1));
  });
  const result = await request(proxy.url);
  assert.equal(result.status, 502);
  assert.match(result.body.toString(), /too large/);
});

test("WebSocket upgrade forwards following intent and strips passwords without changing origin restrictions", async (t) => {
  const seen = [];
  const proxy = await fixture(t, (_req, res) => res.end());
  proxy.upstream.on("upgrade", (req, socket) => {
    seen.push(new URL(req.url, "http://private"));
    const accept = createHash("sha1")
      .update(
        `${req.headers["sec-websocket-key"]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`,
      )
      .digest("base64");
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
  });
  for (const shouldFollow of ["false", "true"]) {
    await new Promise((resolve, reject) => {
      const req = http.request(
        new URL(
          `/ws?password=private&should_follow=${shouldFollow}`,
          proxy.url,
        ),
        {
          headers: {
            Origin: new URL(proxy.url).origin,
            Connection: "Upgrade",
            Upgrade: "websocket",
            "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version": "13",
          },
          agent: false,
        },
      );
      req.on("error", reject);
      req.on("upgrade", (res, socket) => {
        assert.equal(res.statusCode, 101);
        socket.destroy();
        resolve();
      });
      req.end();
    });
    assert.equal(seen.at(-1).searchParams.get("should_follow"), shouldFollow);
    assert.equal(seen.at(-1).searchParams.has("password"), false);
  }
  const denied = await new Promise((resolve, reject) => {
    const req = http.request(new URL("/ws?should_follow=true", proxy.url), {
      headers: {
        Origin: "http://untrusted.invalid",
        Connection: "Upgrade",
        Upgrade: "websocket",
      },
      agent: false,
    });
    req.on("error", reject);
    req.on("response", (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    req.end();
  });
  assert.equal(denied, 403);
  assert.equal(seen.length, 2);
});

function browserCache({ limit = 5 * 1024 * 1024, values = [] } = {}) {
  const stored = new Map(values);
  const warnings = [];
  const removed = [];
  let writes = 0;
  let writeError;
  const bytes = () =>
    Array.from(
      stored,
      ([key, value]) => 2 * (key.length + value.length),
    ).reduce((sum, size) => sum + size, 0);
  const storage = {
    get length() {
      return stored.size;
    },
    key: (index) => Array.from(stored.keys())[index] ?? null,
    getItem: (key) => stored.get(key) ?? null,
    setItem(key, value) {
      writes++;
      if (writeError) throw writeError;
      const old = stored.get(key);
      const oldBytes = old === undefined ? 0 : 2 * (key.length + old.length);
      if (bytes() - oldBytes + 2 * (key.length + value.length) > limit) {
        const error = new Error("storage quota");
        error.name = "QuotaExceededError";
        throw error;
      }
      stored.set(key, value);
    },
    removeItem(key) {
      removed.push(key);
      stored.delete(key);
    },
  };
  const context = {
    localStorage: storage,
    console: { warn: (message) => warnings.push(message) },
  };
  // This is the original map's inherited API used by the log-map specialization.
  const Base = `class Base {
    constructor(prefix){this.prefix=prefix;this.lastInsertAt="";this.sameInserts=0;this.keys=[];}
    clear(){this.lastInsertAt="";this.sameInserts=0;this.keys=[];}
    doesBelong(key){return key.startsWith("logdy_"+this.prefix+"_");}
    id(key){return "logdy_"+this.prefix+"_"+key;}
    upsert(id,value){const old=this.getOne(id);old?this.update(id,{...old,...value}):this.add(value,id);}
  }`;
  const Cache = runInNewContext(`${Base};(${quotaSafeLogMap})(Base)`, context);
  const cache = new Cache("logs");
  return {
    cache,
    storage,
    stored,
    removed,
    warnings,
    bytes,
    get writes() {
      return writes;
    },
    failWrites(error) {
      writeError = error;
    },
    reload() {
      return new Cache("logs");
    },
  };
}

const cacheValue = (text, fields = {}) =>
  JSON.stringify({ message: { id: text, text }, ...fields });

test("log cache rewrite applies exactly once and leaves app/layout constructors alone", () => {
  const input =
    'const ngt=new y6e("app"),YT=new y6e("logs"),CI=new y6e("layout");';
  const output = rewriteViewerLogCache(input);
  assert.ok(output.includes('ngt=new y6e("app")'));
  assert.ok(output.includes('CI=new y6e("layout")'));
  for (const value of [null, "changed", input + input, output]) {
    assert.throws(() => rewriteViewerLogCache(value), /Unsupported/);
  }
  // Execute the injected initializer too: a valid helper alone does not prove
  // that its constructor expression is valid in the pinned minified bundle.
  const cache = runInNewContext(`${output};YT`, {
    y6e: class {
      constructor(prefix) {
        this.prefix = prefix;
      }
    },
    localStorage: { length: 0 },
  });
  assert.equal(cache.prefix, "logs");
  assert.equal(cache.cacheBudget, 2 * 1024 * 1024);
});

test("old browser log cache is byte bounded before layout initialization without touching settings", () => {
  const values = [
    ["logdy_app_main", '{"password":"unchanged"}'],
    ["logdy_layout_main", '{"settings":{"maxMessages":500}}'],
    ["other-app", "preserved"],
  ];
  for (let index = 0; index < 8; index++) {
    values.push([`logdy_logs_00${index}`, cacheValue("x".repeat(220_000))]);
  }
  const browser = browserCache({ values });
  assert.ok(browser.cache.cacheBytes <= 2 * 1024 * 1024);
  assert.ok(!browser.stored.has("logdy_logs_000"));
  assert.ok(browser.stored.has("logdy_logs_007"));
  assert.equal(browser.stored.get("logdy_app_main"), values[0][1]);
  assert.equal(browser.stored.get("logdy_layout_main"), values[1][1]);
  assert.equal(browser.stored.get("other-app"), "preserved");
  assert.ok(browser.removed.every((key) => key.startsWith("logdy_logs_")));
  // The bounded cache now leaves room for future viewer settings writes.
  browser.storage.setItem("logdy_layout_next", "z".repeat(500_000));
  assert.ok(browser.stored.has("logdy_layout_next"));
  browser.cache.load();
  assert.equal(browser.cache.keys.length, browser.cache.entries.size);
  assert.equal(browser.cache.count(), browser.cache.keys.length);
});

test("quota evicts oldest persisted logs and preserves current logical row order and metadata", () => {
  const browser = browserCache({
    limit: 1_000,
    values: [["logdy_layout_main", "config"]],
  });
  browser.cache.add(
    { message: "x".repeat(200), opened: true, starred: true },
    "001",
  );
  browser.cache.add({ message: "y".repeat(200) }, "002");
  browser.cache.add({ message: "z".repeat(200) }, "003");
  assert.equal(browser.stored.has("logdy_logs_001"), false);
  assert.equal(browser.stored.has("logdy_logs_003"), true);
  assert.deepEqual(Array.from(browser.cache.keys), [
    "logdy_logs_001",
    "logdy_logs_002",
    "logdy_logs_003",
  ]);
  assert.equal(browser.cache.getOne("001").starred, true);
  assert.equal(browser.cache.getOne("001").opened, true);
  browser.cache.removeFirst();
  assert.equal(browser.cache.entries.has("logdy_logs_001"), false);
  assert.equal(browser.stored.has("logdy_logs_003"), true);
  assert.deepEqual(Array.from(browser.cache.keys), [
    "logdy_logs_002",
    "logdy_logs_003",
  ]);
  assert.equal(browser.stored.get("logdy_layout_main"), "config");
  assert.ok(browser.writes <= 6);
});

test("oversized single log remains in the live memory view and does not clear other cache rows", () => {
  const browser = browserCache({
    values: [["logdy_logs_001", cacheValue("small")]],
  });
  browser.cache.load();
  browser.cache.add({ message: "x".repeat(2 * 1024 * 1024) }, "002");
  assert.equal(browser.cache.getOne("002").message.length, 2 * 1024 * 1024);
  assert.equal(browser.stored.has("logdy_logs_001"), true);
  assert.equal(browser.stored.has("logdy_logs_002"), false);
  assert.equal(browser.writes, 0);
  assert.equal(browser.cache.load().length, 2);
  browser.cache.removeFirst();
  assert.equal(browser.cache.getOne("002").message.length, 2 * 1024 * 1024);
  assert.deepEqual(Array.from(browser.cache.keys), ["logdy_logs_002"]);
});

test("non-quota storage errors fall back to memory once without evicting existing records", () => {
  const browser = browserCache({
    values: [["logdy_logs_001", cacheValue("old")]],
  });
  browser.cache.load();
  const error = new Error("disabled storage");
  error.name = "SecurityError";
  browser.failWrites(error);
  browser.cache.add({ message: "new" }, "002");
  browser.cache.add({ message: "newer" }, "003");
  assert.equal(browser.stored.has("logdy_logs_001"), true);
  assert.equal(browser.cache.getOne("002").message, "new");
  assert.equal(browser.cache.getOne("003").message, "newer");
  assert.equal(browser.warnings.length, 1);
  assert.equal(browser.writes, 2);
  assert.ok(!browser.removed.includes("logdy_logs_001"));
});

test("an impossible quota has a finite retry budget and continues accepting in-memory records", () => {
  const browser = browserCache({
    limit: 10,
    values: [
      ["logdy_logs_001", cacheValue("old")],
      ["other-app", "big"],
    ],
  });
  browser.cache.load();
  browser.cache.add({ message: "never fits" }, "002");
  assert.equal(browser.writes, 2);
  assert.equal(browser.cache.getOne("001").message.text, "old");
  assert.equal(browser.cache.getOne("002").message, "never fits");
  assert.equal(browser.stored.get("other-app"), "big");
  assert.equal(browser.warnings.length, 1);
});

test("updates, duplicate deliveries, cleanup and reload keep cache identities consistent", () => {
  const browser = browserCache();
  browser.cache.add({ message: { id: "001", text: "one" } }, "001");
  browser.cache.add({ message: { id: "001", text: "one" } }, "001");
  browser.cache.upsert("001", { starred: true, opened: true });
  assert.equal(browser.cache.keys.length, 1);
  assert.equal(browser.cache.entries.size, 1);
  const reloaded = browser.reload();
  assert.equal(reloaded.load().length, 1);
  assert.equal(reloaded.getOne("001").starred, true);
  assert.equal(reloaded.getOne("001").opened, true);
  reloaded.remove("not-present");
  assert.equal(reloaded.keys.length, 1);
  reloaded.clearUnknown();
  assert.equal(browser.stored.has("logdy_logs_001"), true);
  reloaded.removeFirst();
  assert.equal(reloaded.keys.length, 0);
  assert.equal(reloaded.entries.size, 0);
  assert.equal(reloaded.cacheBytes, 0);
  reloaded.removeFirst();
  assert.equal(reloaded.cacheBytes, 0);
});

test("index-only clear reloads retained cache; stale cleanup and replay removeAll do not resurrect rows", () => {
  const browser = browserCache({
    values: [["logdy_layout_main", "preserved"]],
  });
  browser.cache.add({ message: "old" }, "001");
  browser.cache.clear();
  assert.equal(browser.cache.keys.length, 0);
  assert.equal(browser.cache.entries.size, 0);
  // Upstream clear is index-only and count reads storage; load rebuilds it.
  assert.equal(browser.cache.count(), 1);
  assert.equal(browser.cache.load().length, 1);
  assert.equal(browser.cache.count(), 1);
  assert.deepEqual(Array.from(browser.cache.keys), ["logdy_logs_001"]);
  browser.cache.clear();
  browser.cache.add({ message: "new" }, "002");
  browser.cache.clearUnknown();
  assert.equal(browser.stored.has("logdy_logs_001"), false);
  assert.equal(browser.stored.has("logdy_logs_002"), true);
  assert.equal(browser.cache.load().length, 1);
  assert.equal(browser.cache.getOne("002").message, "new");
  // The actual UI's clearAllRows/replay path invokes removeAll, not clear.
  browser.cache.removeAll();
  assert.equal(browser.cache.count(), 0);
  assert.equal(browser.cache.cacheBytes, 0);
  assert.equal(browser.cache.load().length, 0);
  assert.equal(browser.reload().load().length, 0);
  assert.equal(browser.stored.get("logdy_layout_main"), "preserved");
});
