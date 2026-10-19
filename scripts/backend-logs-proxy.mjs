import http from "node:http";
import { createHash } from "node:crypto";

const bodyLimit = 256 * 1024;
const statusLimit = 1024 * 1024;
const assetLimit = 16 * 1024 * 1024;
// The embedded v0.17.1 UI omits should_follow when reconnecting. Its server
// therefore starts a stopped cursor while the UI can still display Following.
// Keep the compatibility change local to the verified, pinned browser bundle.
const reconnectAsset = "/assets/index-jVCiWEg8.js";
const reconnectAssetSha256 =
  "81d0928e68586f69df2992755ad4b81b1074a23fef408194082c8b8b06a4f3c4";
const reconnectBefore = 'new WebSocket(Ui+"?password="+e.getPassword())';
const reconnectAfter =
  'new WebSocket(Ui+"?password="+encodeURIComponent(e.getPassword())+"&should_follow="+e.receiveStatus.includes("following"))';
const logCacheBefore = 'YT=new y6e("logs")';
const apiRoutes = new Set([
  "/api/status",
  "/api/check-pass",
  "/api/client/set-status",
  "/api/client/load",
  "/api/client/peek-log",
]);
const blockedRoutes = new Set(["/api/log", "/api/config/save"]);
// Exact inline Monaco bootstrap in Logdy v0.17.1's embedded index.html.
// Other inline scripts remain blocked; recheck this hash on a version upgrade.
const monacoBootstrap = "'sha256-OJB5bpA48nJXaaPrxmAwYZyK8H4r0RU+Dvz4/3F5Xv4='";
const staticFiles = new Set([
  "/",
  "/wasm_exec.js",
  "/main.wasm",
  "/monacoeditorwork/ts.worker.bundle.js",
  "/fonts/roboto-mono-v23-latin-300.woff2",
  "/fonts/roboto-mono-v23-latin-700.woff2",
  "/fonts/roboto-mono-v23-latin-regular.woff2",
  "/logdy-transparent.png",
  "/icon.ico",
  "/favicon.ico",
  "/favicon.svg",
  "/vite.svg",
]);
const csp = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-eval' ${monacoBootstrap}`,
  "style-src 'self' 'unsafe-inline'",
  "connect-src 'self'",
  "img-src 'self' data:",
  "font-src 'self' data:",
  "worker-src 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "form-action 'self'",
  "base-uri 'self'",
].join("; ");

function securityHeaders(response) {
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Content-Security-Policy", csp);
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("Cross-Origin-Resource-Policy", "same-origin");
  response.setHeader("X-Frame-Options", "DENY");
}

function reject(response, status, message) {
  if (response.headersSent || response.destroyed) return;
  securityHeaders(response);
  response.writeHead(status, { "Content-Type": "text/plain; charset=utf-8" });
  response.end(message);
}

export function parseProxyPath(raw) {
  const path = typeof raw === "string" ? raw.split("?")[0] : "";
  // Reject ambiguities before URL parsing can normalize traversal segments.
  if (
    typeof raw !== "string" ||
    !raw.startsWith("/") ||
    raw.startsWith("//") ||
    /[\\\x00-\x20\x7f#]/.test(raw) ||
    /%(?:2f|5c|00|2e|25)/i.test(path) ||
    raw
      .split("?")[0]
      .split("/")
      .some((part) => part === "." || part === "..")
  ) {
    return null;
  }
  try {
    const parsed = new URL(raw, "http://127.0.0.1");
    parsed.pathname = decodeURIComponent(parsed.pathname);
    if (/[\\%\x00-\x20\x7f]/.test(parsed.pathname)) return null;
    return parsed;
  } catch {
    return null;
  }
}

function allowedRequest(request, host, origin, { upgrade = false } = {}) {
  if (request.headers.host !== host) return false;
  if (upgrade) return request.headers.origin === origin;
  if (request.headers.origin && request.headers.origin !== origin) return false;
  const site = request.headers["sec-fetch-site"];
  if (!site || site === "same-origin" || site === "none") return true;
  // Opening the local viewer from a link is harmless; its resources and APIs
  // must subsequently be requested from this origin.
  return (
    ["GET", "HEAD"].includes(request.method) &&
    request.url === "/" &&
    request.headers["sec-fetch-mode"] === "navigate" &&
    request.headers["sec-fetch-dest"] === "document"
  );
}

async function requestBody(request) {
  const length = request.headers["content-length"];
  if (length && (!/^\d+$/.test(length) || Number(length) > bodyLimit)) {
    throw new Error("body-limit");
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > bodyLimit) throw new Error("body-limit");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export function rewriteStatus(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid viewer status");
  }
  for (const key of ["AuthRequired", "auth_required", "authRequired"]) {
    if (Object.hasOwn(value, key)) value[key] = false;
  }
  for (const key of ["ApiPrefix", "api_prefix", "apiPrefix"]) {
    if (Object.hasOwn(value, key)) value[key] = "/";
  }
  return value;
}

export function rewriteViewerReconnect(source) {
  if (
    typeof source !== "string" ||
    source.split(reconnectBefore).length !== 2
  ) {
    throw new Error("Unsupported viewer reconnect code.");
  }
  return source.replace(reconnectBefore, reconnectAfter);
}

/** Runs inside the pinned browser bundle; keep this function self-contained. */
export function quotaSafeLogMap(Base) {
  return class extends Base {
    constructor(prefix) {
      super(prefix);
      this.cacheBudget = 2 * 1024 * 1024;
      this.cacheBytes = 0;
      this.cached = new Map();
      this.entries = new Map();
      this.cacheWarning = false;
      if (prefix !== "logs") throw new Error("Expected the viewer log cache.");
      try {
        const keys = [];
        for (let index = 0; index < localStorage.length; index++) {
          const key = localStorage.key(index);
          if (key && this.doesBelong(key)) keys.push(key);
        }
        for (const key of keys.sort()) {
          const value = localStorage.getItem(key);
          if (value === null) continue;
          const bytes = 2 * (key.length + value.length);
          this.cached.set(key, bytes);
          this.cacheBytes += bytes;
        }
        // This constructor runs before the layout map is initialized. Bound old
        // cache data now so loading/saving viewer settings has storage headroom.
        while (this.cacheBytes > this.cacheBudget && this.evictOldest()) {}
      } catch {
        this.warnCache();
      }
    }
    warnCache() {
      if (this.cacheWarning) return;
      this.cacheWarning = true;
      console.warn(
        "Logdy browser log cache unavailable; live view continues in memory.",
      );
    }
    removeCached(key) {
      try {
        localStorage.removeItem(key);
        this.cacheBytes -= this.cached.get(key) || 0;
        this.cached.delete(key);
        return true;
      } catch {
        this.warnCache();
        return false;
      }
    }
    evictOldest() {
      const key = Array.from(this.cached.keys()).sort()[0];
      return key !== undefined && this.removeCached(key);
    }
    saveCached(key, value) {
      let serialized;
      try {
        serialized = JSON.stringify(value);
      } catch {
        this.warnCache();
        return;
      }
      const bytes = 2 * (key.length + serialized.length);
      // Logical keys and current rows remain in memory even when a record is
      // too large for this optional cache. FIFO removal must still align with UI.
      if (!this.removeCached(key) || bytes > this.cacheBudget) return;
      while (this.cacheBytes + bytes > this.cacheBudget) {
        if (!this.evictOldest()) return;
      }
      let attempts = this.cached.size + 1;
      while (attempts-- > 0) {
        try {
          localStorage.setItem(key, serialized);
          this.cached.set(key, bytes);
          this.cacheBytes += bytes;
          return;
        } catch (error) {
          const quota =
            error &&
            (error.name === "QuotaExceededError" ||
              error.code === 22 ||
              error.code === 1014);
          if (!quota || !this.evictOldest()) {
            this.warnCache();
            return;
          }
        }
      }
    }
    clear() {
      super.clear();
      this.entries.clear();
    }
    clearUnknown() {
      for (const key of this.cached.keys()) {
        if (!this.keys.includes(key)) this.removeCached(key);
      }
    }
    load() {
      for (const key of this.cached.keys()) {
        if (this.entries.has(key)) continue;
        try {
          const value = localStorage.getItem(key);
          if (value !== null) this.entries.set(key, JSON.parse(value));
        } catch {
          this.warnCache();
          this.removeCached(key);
        }
      }
      this.keys = Array.from(this.entries.keys()).sort();
      return this.keys.map((key) => this.entries.get(key));
    }
    count() {
      return new Set([...this.cached.keys(), ...this.entries.keys()]).size;
    }
    getOne(id) {
      const key = this.id(id);
      if (this.entries.has(key)) return this.entries.get(key);
      try {
        const value = localStorage.getItem(key);
        if (value !== null) {
          const parsed = JSON.parse(value);
          this.entries.set(key, parsed);
          if (!this.keys.includes(key)) this.keys.push(key);
          return parsed;
        }
      } catch {
        this.warnCache();
      }
    }
    add(value, id) {
      let stamp = new Date().getTime().toString();
      if (stamp === this.lastInsertAt) stamp += "." + ++this.sameInserts;
      const key = this.id(id || stamp);
      value.id = key;
      this.entries.set(key, value);
      this.saveCached(key, value);
      this.lastInsertAt = stamp;
      if (!this.keys.includes(key)) this.keys.push(key);
      return { id: stamp.toString() };
    }
    update(id, value) {
      const key = this.id(id);
      this.entries.set(key, value);
      if (!this.keys.includes(key)) this.keys.push(key);
      this.saveCached(key, value);
    }
    remove(id) {
      const key = this.id(id);
      this.entries.delete(key);
      this.keys = this.keys.filter((candidate) => candidate !== key);
      this.removeCached(key);
    }
    removeAll() {
      for (const key of this.cached.keys()) this.removeCached(key);
      this.entries.clear();
      this.keys = [];
    }
    removeFirst() {
      const key = this.keys.shift();
      if (key === undefined) return;
      this.entries.delete(key);
      this.removeCached(key);
    }
  };
}

export function rewriteViewerLogCache(source) {
  if (typeof source !== "string" || source.split(logCacheBefore).length !== 2) {
    throw new Error("Unsupported viewer log cache code.");
  }
  return source.replace(
    logCacheBefore,
    `YT=new ((${quotaSafeLogMap.toString()})(y6e))("logs")`,
  );
}

function reconnectScript(upstreamResponse, response, { head = false } = {}) {
  const encoding = upstreamResponse.headers["content-encoding"];
  const type = upstreamResponse.headers["content-type"];
  const length = Number(upstreamResponse.headers["content-length"]);
  if (
    upstreamResponse.statusCode !== 200 ||
    (encoding && encoding !== "identity") ||
    !/^(?:text|application)\/(?:javascript|ecmascript)(?:;|$)/i.test(
      type ?? "",
    ) ||
    (Number.isFinite(length) && length > assetLimit)
  ) {
    upstreamResponse.destroy();
    reject(response, 502, "Unsupported viewer UI asset.");
    return;
  }
  const chunks = [];
  let size = 0;
  upstreamResponse.on("data", (chunk) => {
    size += chunk.length;
    if (size > assetLimit) {
      upstreamResponse.destroy();
      reject(response, 502, "Viewer UI asset is too large.");
      return;
    }
    chunks.push(chunk);
  });
  upstreamResponse.on("error", () =>
    reject(response, 502, "Viewer UI asset unavailable."),
  );
  upstreamResponse.on("end", () => {
    if (response.destroyed || response.writableEnded) return;
    try {
      const input = Buffer.concat(chunks);
      if (
        createHash("sha256").update(input).digest("hex") !==
        reconnectAssetSha256
      ) {
        throw new Error("Unsupported viewer UI asset.");
      }
      const output = Buffer.from(
        rewriteViewerLogCache(rewriteViewerReconnect(input.toString("utf8"))),
      );
      response.writeHead(200, {
        "Content-Type": type,
        "Content-Length": output.length,
      });
      response.end(head ? undefined : output);
    } catch {
      reject(response, 502, "Unsupported viewer UI asset.");
    }
  });
}

/** A localhost-only browser boundary around the isolated Logdy process. */
export async function createLogProxy({ upstreamSocketPath, port = 8082 }) {
  if (typeof upstreamSocketPath !== "string" || !upstreamSocketPath) {
    throw new Error("Invalid private viewer connection settings.");
  }
  const sockets = new Set();
  const requests = new Set();
  let host;
  let origin;
  let closing = false;
  const target = { socketPath: upstreamSocketPath };
  const makeUpstreamPath = (url) => {
    url.searchParams.delete("password");
    return `${url.pathname}${url.search}`;
  };
  const trackRequest = (request) => {
    requests.add(request);
    request.once("close", () => requests.delete(request));
    return request;
  };
  const server = http.createServer(async (request, response) => {
    securityHeaders(response);
    const url = parseProxyPath(request.url);
    if (!url) return reject(response, 400, "Invalid viewer path.");
    if (!allowedRequest(request, host, origin)) {
      return reject(response, 403, "Local same-origin requests only.");
    }
    if (blockedRoutes.has(url.pathname)) {
      return reject(response, 405, "This viewer endpoint is disabled.");
    }
    const staticPath =
      staticFiles.has(url.pathname) ||
      /^\/assets\/[A-Za-z0-9_.-]+$/.test(url.pathname);
    if (!staticPath && !apiRoutes.has(url.pathname)) {
      return reject(response, 404, "Viewer endpoint not found.");
    }
    if (!["GET", "HEAD", "POST"].includes(request.method)) {
      return reject(response, 405, "Viewer method not allowed.");
    }
    if (request.method === "POST" && !apiRoutes.has(url.pathname)) {
      return reject(response, 405, "Viewer method not allowed.");
    }
    if (
      /^\/assets\/index-[A-Za-z0-9_-]+\.js$/.test(url.pathname) &&
      url.pathname !== reconnectAsset
    ) {
      return reject(response, 502, "Unsupported viewer UI asset.");
    }
    let body;
    try {
      body = await requestBody(request);
    } catch {
      return reject(response, 413, "Viewer request body is too large.");
    }
    if (closing || response.destroyed) return;
    const headers = { host: "127.0.0.1" };
    for (const key of ["accept", "content-type", "logdy-client-id"]) {
      if (request.headers[key]) headers[key] = request.headers[key];
    }
    if (body.length) headers["content-length"] = String(body.length);
    const upstream = trackRequest(
      http.request(
        {
          ...target,
          path: makeUpstreamPath(url),
          // Buffer the same verified representation for HEAD, but omit its body.
          method:
            url.pathname === reconnectAsset && request.method === "HEAD"
              ? "GET"
              : request.method,
          headers,
        },
        (upstreamResponse) => {
          if (url.pathname === reconnectAsset) {
            reconnectScript(upstreamResponse, response, {
              head: request.method === "HEAD",
            });
            return;
          }
          if (url.pathname === "/api/status") {
            const chunks = [];
            let length = 0;
            upstreamResponse.on("data", (chunk) => {
              length += chunk.length;
              if (length > statusLimit) {
                upstreamResponse.destroy();
                reject(response, 502, "Invalid viewer status.");
                return;
              }
              chunks.push(chunk);
            });
            upstreamResponse.on("error", () =>
              reject(response, 502, "Viewer status unavailable."),
            );
            upstreamResponse.on("end", () => {
              if (response.destroyed || response.writableEnded) return;
              try {
                const status = rewriteStatus(
                  JSON.parse(Buffer.concat(chunks).toString("utf8")),
                );
                const output = JSON.stringify(status);
                response.writeHead(upstreamResponse.statusCode, {
                  // The pinned UI checks this header with exact equality.
                  "Content-Type": "application/json",
                });
                response.end(output);
              } catch {
                reject(response, 502, "Invalid viewer status.");
              }
            });
            return;
          }
          const responseHeaders = {};
          for (const key of [
            "content-type",
            "content-length",
            "content-encoding",
          ]) {
            if (upstreamResponse.headers[key]) {
              responseHeaders[key] = upstreamResponse.headers[key];
            }
          }
          if (upstreamResponse.headers.location) {
            const location = upstreamResponse.headers.location;
            if (!location.startsWith("/") || location.startsWith("//")) {
              upstreamResponse.destroy();
              return reject(response, 502, "Invalid viewer redirect.");
            }
            responseHeaders.location = location;
          }
          response.writeHead(upstreamResponse.statusCode, responseHeaders);
          upstreamResponse.on("error", () => response.destroy());
          upstreamResponse.pipe(response);
        },
      ),
    );
    upstream.setTimeout(15_000, () => upstream.destroy());
    upstream.on("error", () => reject(response, 502, "Viewer unavailable."));
    response.on("close", () => upstream.destroy());
    upstream.end(body);
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.maxHeadersCount = 64;
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  server.on("upgrade", (request, socket, head) => {
    const url = parseProxyPath(request.url);
    const deny = (status = 403) => {
      socket.end(`HTTP/1.1 ${status} Forbidden\r\nConnection: close\r\n\r\n`);
    };
    if (
      !url ||
      url.pathname !== "/ws" ||
      !allowedRequest(request, host, origin, { upgrade: true }) ||
      request.method !== "GET" ||
      request.headers.upgrade?.toLowerCase() !== "websocket"
    ) {
      return deny();
    }
    const headers = {
      host: "127.0.0.1",
      connection: "Upgrade",
      upgrade: "websocket",
    };
    for (const key of ["sec-websocket-key", "sec-websocket-version"]) {
      if (request.headers[key]) headers[key] = request.headers[key];
    }
    const upstream = trackRequest(
      http.request({ ...target, path: makeUpstreamPath(url), headers }),
    );
    upstream.setTimeout(10_000, () => upstream.destroy());
    upstream.once("upgrade", (response, peer, upstreamHead) => {
      if (closing || socket.destroyed) return peer.destroy();
      sockets.add(peer);
      peer.once("close", () => sockets.delete(peer));
      peer.setTimeout(0);
      const accept = response.headers["sec-websocket-accept"];
      if (response.statusCode !== 101 || !accept) {
        peer.destroy();
        return deny(502);
      }
      socket.write(
        "HTTP/1.1 101 Switching Protocols\r\n" +
          "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
          `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
      );
      if (upstreamHead.length) socket.write(upstreamHead);
      if (head.length) peer.write(head);
      socket.on("error", () => peer.destroy());
      socket.on("close", () => peer.destroy());
      socket.on("end", () => {
        peer.destroy();
        socket.destroy();
      });
      peer.on("error", () => socket.destroy());
      peer.on("close", () => socket.destroy());
      peer.on("end", () => socket.destroy());
      peer.pipe(socket).pipe(peer);
    });
    upstream.once("response", (response) => {
      response.resume();
      deny(502);
    });
    upstream.once("error", () => deny(502));
    socket.once("close", () => upstream.destroy());
    upstream.end();
  });
  try {
    await new Promise((resolve, rejectListen) => {
      server.once("error", rejectListen);
      server.listen(port, "127.0.0.1", resolve);
    });
    host = `127.0.0.1:${server.address().port}`;
    origin = `http://${host}`;
  } catch {
    throw new Error(
      "Could not bind the local log viewer; check port availability.",
    );
  }
  let closePromise;
  return {
    server,
    url: `${origin}/`,
    close() {
      if (!closePromise) {
        closing = true;
        for (const request of requests) request.destroy();
        for (const socket of sockets) socket.destroy();
        closePromise = new Promise((resolveClose) =>
          server.close(resolveClose),
        );
      }
      return closePromise;
    },
  };
}
