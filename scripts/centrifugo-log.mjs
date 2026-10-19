import { Transform } from "node:stream";

/** Native v6 debug messages can contain protobuf command strings with JWTs.
 * Keep operational metadata; omit commands and payloads before any sink. */
export function sanitizeCentrifugoLog(line, secrets = [], serverRunId) {
  let record;
  try {
    record = JSON.parse(line);
  } catch {
    return JSON.stringify({
      level: "warn",
      message: "Unstructured Centrifugo diagnostic omitted",
    });
  }
  if (!record || typeof record !== "object" || Array.isArray(record))
    return JSON.stringify({
      level: "warn",
      message: "Unstructured Centrifugo diagnostic omitted",
    });
  const scrub = (value, key = "") => {
    if (
      /password|secret|token|authorization|cookie|api.?key|^(command|reply|request|response|body|data|b64data|conn_info|chan_info)$/i.test(
        key,
      )
    )
      return "[REDACTED]";
    if (typeof value === "string") {
      let safe = value
        .replace(
          /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g,
          "[REDACTED]",
        )
        .replace(/(\b[a-z][a-z0-9+.-]*:\/\/)[^/\s?#]+@/gi, "$1[REDACTED]@");
      for (const secret of secrets)
        if (secret) safe = safe.replaceAll(secret, "[REDACTED]");
      return safe;
    }
    if (Array.isArray(value)) return value.map((v) => scrub(v));
    if (value && typeof value === "object")
      return Object.fromEntries(
        Object.entries(value).map(([k, v]) => [k, scrub(v, k)]),
      );
    return value;
  };
  const safe = scrub(record);
  if (typeof serverRunId === "string" && /^[a-f0-9-]{36}$/.test(serverRunId))
    safe.serverRunId = serverRunId;
  return JSON.stringify(safe);
}

export function centrifugoLogFilter(secrets = [], serverRunId) {
  let pending = "",
    oversized = false;
  return new Transform({
    transform(chunk, _encoding, done) {
      for (const part of chunk.toString().split(/(?<=\n)/)) {
        if (!oversized) pending += part;
        if (pending.length > 1024 * 1024) {
          pending = "";
          oversized = true;
        }
        if (part.endsWith("\n")) {
          this.push(
            sanitizeCentrifugoLog(
              oversized ? "" : pending,
              secrets,
              serverRunId,
            ) + "\n",
          );
          pending = "";
          oversized = false;
        }
      }
      done();
    },
    flush(done) {
      if (pending || oversized)
        this.push(
          sanitizeCentrifugoLog(
            oversized ? "" : pending,
            secrets,
            serverRunId,
          ) + "\n",
        );
      done();
    },
  });
}
