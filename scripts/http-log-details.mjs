import { debugPayloadSnapshot } from "./sqlite-log-details.mjs";

export const httpDetailLimit = 32 * 1024;

/** Optional full-debug data from an HTTP completion, never executable input. */
export function httpLogDetails(value) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    value.policy !== "full_debug"
  )
    return undefined;
  const result = { policy: "full_debug" };
  for (const key of [
    "params",
    "query",
    "requestBody",
    "requestHeaders",
    "responseHeaders",
    "responseBody",
  ]) {
    if (!Object.hasOwn(value, key)) continue;
    const safe = debugPayloadSnapshot(value[key]);
    const bytes = Buffer.byteLength(JSON.stringify({ ...result, [key]: safe }));
    result[key] =
      bytes <= httpDetailLimit - 1024
        ? safe
        : {
            payloadOmitted: true,
            omissionReason: "detail_byte_limit",
            limitBytes: httpDetailLimit,
          };
  }
  return result;
}
