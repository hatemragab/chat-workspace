import { debugPayloadSnapshot } from "./sqlite-log-details.mjs";

export const realtimeDetailLimit = 32 * 1024;

// Defend against producers that submit protobuf JSON with base64 still present.
// Already-decoded application objects stop protocol traversal at the byte field.
function protocolData(value) {
  if (typeof value !== "string") return value;
  if (Buffer.byteLength(value) > 8192)
    return { payloadOmitted: true, omissionReason: "value_byte_limit" };
  if (!value || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return value;
  const bytes = Buffer.from(value, "base64");
  if (bytes.toString("base64").replace(/=+$/, "") !== value.replace(/=+$/, ""))
    return value;
  try {
    return JSON.parse(bytes.toString("utf8"));
  } catch {
    return { type: "binary", length: bytes.length };
  }
}

function protocolPayload(value, depth = 0) {
  if (depth > 16)
    return { payloadOmitted: true, omissionReason: "protocol_depth_limit" };
  if (Array.isArray(value))
    return [
      ...value.slice(0, 512).map((item) => protocolPayload(item, depth + 1)),
      ...(value.length > 512
        ? [
            {
              payloadOmitted: true,
              omissionReason: "array_entry_limit",
              omittedEntries: value.length - 512,
            },
          ]
        : []),
    ];
  if (!value || typeof value !== "object") return value;
  const entries = Object.entries(value);
  return Object.fromEntries([
    ...entries
      .slice(0, 256)
      .map(([key, item]) => [
        key,
        ["data", "connInfo", "chanInfo"].includes(key)
          ? protocolData(item)
          : protocolPayload(item, depth + 1),
      ]),
    ...(entries.length > 256
      ? [
          [
            "__omitted__",
            {
              payloadOmitted: true,
              omissionReason: "object_entry_limit",
              omittedEntries: entries.length - 256,
            },
          ],
        ]
      : []),
  ]);
}

export function realtimeLogDetails(value, direction, operation) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    value.policy !== "full_debug" ||
    value.direction !== direction ||
    value.operation !== operation ||
    !Object.hasOwn(value, "payload")
  )
    return undefined;
  const common = { policy: "full_debug", direction, operation };
  const payload = debugPayloadSnapshot(protocolPayload(value.payload));
  return {
    ...common,
    payload:
      Buffer.byteLength(JSON.stringify({ ...common, payload })) <=
      realtimeDetailLimit
        ? payload
        : {
            payloadOmitted: true,
            omissionReason: "detail_byte_limit",
            limitBytes: realtimeDetailLimit,
          },
  };
}
