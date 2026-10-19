import { BSON, type CommandStartedEvent } from "mongodb";
import { credentialField, sanitizeTrafficValue } from "./debug-traffic-logger";
import type { ServiceOperationDetails } from "./service-operation-details";

export const MAX_MONGO_DETAIL_BYTES = 256 * 1024;
const commands = new Set([
  "find",
  "getMore",
  "aggregate",
  "count",
  "distinct",
  "insert",
  "update",
  "delete",
  "findAndModify",
  "bulkWrite",
  "commitTransaction",
  "abortTransaction",
  "killCursors",
  "createIndexes",
  "listIndexes",
  "listCollections",
  "ping",
  "endSessions",
]);

/** BSON values retain readable types without serializing binary bytes or code.
 * Expression predicates referencing credentials are redacted as a whole so a
 * positional literal beside "$passwordHash" cannot bypass key redaction. */
export function mongoValueSnapshot(value: unknown): unknown {
  const ancestors = new WeakSet<object>();
  const credentialReference = (value: unknown, depth = 0): boolean => {
    if (typeof value === "string")
      return (
        value.startsWith("$") && credentialField(value.replace(/^\$+/, ""))
      );
    if (depth > 64) return true;
    if (Array.isArray(value))
      return value.some((item) => credentialReference(item, depth + 1));
    return false;
  };
  const visit = (current: unknown, depth: number): unknown => {
    if (depth > 64)
      return { payloadOmitted: true, omissionReason: "detail_depth_limit" };
    if (current === null || typeof current !== "object") return current;
    if (ArrayBuffer.isView(current) || current instanceof ArrayBuffer)
      return { kind: "binary", byteLength: current.byteLength };
    if (current instanceof Date) return current.toISOString();
    if (current instanceof RegExp)
      return {
        $regularExpression: { pattern: current.source, options: current.flags },
      };
    if (ancestors.has(current)) return "[Circular]";
    ancestors.add(current);
    try {
      const bsonType = (current as { _bsontype?: string })._bsontype;
      if (bsonType === "Binary")
        return {
          kind: "binary",
          byteLength: (current as BSON.Binary).length(),
        };
      if (bsonType === "Code")
        return { payloadOmitted: true, omissionReason: "javascript_code" };
      if (bsonType)
        return visit(
          BSON.EJSON.serialize(current, { relaxed: false }),
          depth + 1,
        );
      if (Array.isArray(current))
        return current.map((item) => visit(item, depth + 1));
      return Object.fromEntries(
        Object.entries(current).map(([key, item]) => [
          key,
          ["errmsg", "$err", "stack"].includes(key)
            ? "[Omitted diagnostic text]"
            : credentialField(key) || credentialReference(item)
              ? "[REDACTED]"
              : visit(item, depth + 1),
        ]),
      );
    } finally {
      ancestors.delete(current);
    }
  };
  try {
    const snapshot = sanitizeTrafficValue(visit(value, 0));
    const bytes = Buffer.byteLength(JSON.stringify(snapshot) ?? "null");
    return bytes > MAX_MONGO_DETAIL_BYTES
      ? {
          payloadOmitted: true,
          omissionReason: "detail_byte_limit",
          omittedBytes: bytes,
          limitBytes: MAX_MONGO_DETAIL_BYTES,
        }
      : snapshot;
  } catch {
    return "[Unserializable]";
  }
}

export function mongoFailureSnapshot(value: unknown): unknown {
  try {
    const error = value as {
      code?: unknown;
      codeName?: unknown;
      errorLabels?: unknown;
    };
    return {
      ...(typeof error?.code === "number" && Number.isSafeInteger(error.code)
        ? { code: error.code }
        : {}),
      ...(typeof error?.codeName === "string" &&
      /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(error.codeName)
        ? { codeName: error.codeName }
        : {}),
      ...(Array.isArray(error?.errorLabels)
        ? {
            errorLabels: error.errorLabels
              .filter(
                (label): label is string =>
                  typeof label === "string" &&
                  /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(label),
              )
              .slice(0, 16),
          }
        : {}),
    };
  } catch {
    return {};
  }
}

export function mongoCommandDetails(
  event: CommandStartedEvent,
): ServiceOperationDetails {
  const operation = event.commandName;
  if (!commands.has(operation))
    return {
      summary:
        "MongoDB command values omitted for an unsupported or authentication command.",
      data: { detailsOmitted: "unsupported_command" },
      includeResponse: false,
    };
  const command = event.command;
  const collectionValue =
    operation === "getMore" ? command.collection : command[operation];
  const collection =
    typeof collectionValue === "string" ? collectionValue : undefined;
  return {
    summary: `${operation} ${event.databaseName}${collection ? `.${collection}` : ""}`,
    databaseName: event.databaseName,
    collection,
    driverRequestId: event.requestId,
    data: {
      command: mongoValueSnapshot(command),
      observation:
        "Actual driver command and this reply batch; cursor batches use separate getMore records. Write counts are the server reply, not a reread of changed documents.",
    },
    includeResponse: true,
    responseSnapshot: mongoValueSnapshot,
    errorSnapshot: mongoFailureSnapshot,
  };
}
