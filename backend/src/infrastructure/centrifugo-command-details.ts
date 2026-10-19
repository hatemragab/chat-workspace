import { sanitizeTrafficValue } from "./debug-traffic-logger";

export const centrifugoDetailLimit = 64 * 1024;

/** Detached private debug detail; an oversized value must not hide its operation. */
export function centrifugoLogSnapshot(value: unknown): unknown {
  try {
    const safe = sanitizeTrafficValue(value);
    const json = JSON.stringify(safe);
    if (json === undefined) return null;
    const bytes = Buffer.byteLength(json);
    return bytes <= centrifugoDetailLimit
      ? safe
      : {
          payloadOmitted: true,
          omissionReason: "detail_byte_limit",
          omittedBytes: bytes,
          limitBytes: centrifugoDetailLimit,
        };
  } catch {
    return { payloadOmitted: true, omissionReason: "unserializable" };
  }
}
