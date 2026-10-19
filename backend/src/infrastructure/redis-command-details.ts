import { createHash } from "node:crypto";
import type { Command } from "ioredis";
import { sanitizeTrafficValue } from "./debug-traffic-logger";
import * as scripts from "./redis-scripts";
import * as sessionScripts from "./session-disconnect-scripts";
import * as lastSeenScripts from "./last-seen-scripts";

const sessionDescriptions = [
  [
    lastSeenScripts.trackLastSeenLua,
    "last_seen.track",
    "Track this user's connection for bounded last-seen observation.",
  ],
  [
    lastSeenScripts.claimLastSeenLua,
    "last_seen.claim",
    "Claim up to 100 users for a Centrifugo last-seen snapshot.",
  ],
  [
    lastSeenScripts.finishLastSeenLua,
    "last_seen.finish",
    "Complete a fenced last-seen observation or retain it for retry.",
  ],
  [
    lastSeenScripts.checkLastSeenSoonLua,
    "last_seen.check_soon",
    "Schedule a last-seen observation after logout disconnection.",
  ],
  [
    sessionScripts.retireSessionLua,
    "auth_session.retire_and_queue",
    "Revoke the login and retain its disconnect retry atomically.",
  ],
  [
    sessionScripts.dueSessionDisconnectsLua,
    "auth_session.pending_disconnects",
    "Read due logout disconnect work; idle sockets create no work.",
  ],
  [
    sessionScripts.claimSessionDisconnectLua,
    "auth_session.claim_disconnect",
    "Lease one pending logout disconnect for a bounded worker.",
  ],
  [
    sessionScripts.finishSessionDisconnectLua,
    "auth_session.finish_disconnect",
    "Complete a settled logout disconnect or retain its next retry.",
  ],
] as const;

const descriptions = [
  [
    scripts.upsertUserRoomDeltaLua,
    "inbox.upsert_room",
    "Update the latest room projection and revision, then refresh the seven-day cache TTL.",
    ["newPts", "roomId", "room", "epoch", "ttlSeconds", "deadlineMs"],
  ],
  [
    scripts.deltaLua,
    "inbox.read_delta",
    "Validate the epoch and revision window, then read up to 100 changed room projections; an empty reply requires full sync.",
    ["sincePts", "epoch"],
  ],
  [
    scripts.invalidateLua,
    "inbox.invalidate",
    "Delete inbox metadata before the deadline so the next sync rebuilds the cache.",
    ["deadlineMs"],
  ],
  [
    scripts.ensureEpochLua,
    "inbox.ensure_epoch",
    "Initialize or advance inbox metadata when behind MongoDB, refresh its TTL, and return the epoch.",
    ["epoch", "pts"],
  ],
  [
    scripts.limitAuthLua,
    "rate_limit.authentication",
    "Increment the authentication attempt count with a 60-second expiry; the caller checks the returned count against its limit.",
    [],
  ],
  [
    scripts.limitRealtimeLua,
    "rate_limit.realtime",
    "Increment user and IP counters with 60-second expiry and return 1 if both limits permit the request, otherwise 0.",
    ["userLimit", "ipLimit"],
  ],
] as const;

export interface RedisCommandDetails {
  summary: string;
  data: unknown;
  includeResponse: boolean;
}

function decoded(value: unknown): unknown {
  if (typeof value !== "string") return value;
  if (/^\s*[\[{]/.test(value)) {
    try {
      return JSON.parse(value);
    } catch {
      /* Ordinary Redis text. */
    }
  }
  return value;
}

export function redisResponseDetails(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redisResponseDetails);
  return sanitizeTrafficValue(decoded(value));
}

/** Only known application scripts/commands expose positional values. AUTH,
 * CONFIG, ACL, unknown scripts and binary arguments cannot leak credentials. */
export function redisCommandDetails(command: Command): RedisCommandDetails {
  const name = command.name.toLowerCase();
  const args = command.args;
  if (name === "eval" || name === "evalsha") {
    const source = args[0];
    const session = sessionDescriptions.find(([script]) =>
      name === "eval"
        ? source === script
        : source === createHash("sha1").update(script).digest("hex"),
    );
    if (session) {
      const [script, scriptName, summary] = session;
      return {
        summary,
        data: {
          command: name,
          script: {
            name: scriptName,
            sha1: createHash("sha1").update(script).digest("hex"),
          },
          detailsOmitted:
            "Authentication session keys, lease tokens and queue members are private.",
        },
        includeResponse: false,
      };
    }
    const known =
      typeof source === "string"
        ? descriptions.find(([script]) =>
            name === "eval"
              ? script === source
              : createHash("sha1").update(script).digest("hex") === source,
          )
        : undefined;
    if (known) {
      const [sourceCode, scriptName, summary, labels] = known;
      const keyCount = Number(args[1]);
      if (
        Number.isSafeInteger(keyCount) &&
        keyCount >= 0 &&
        keyCount <= args.length - 2
      ) {
        return {
          summary,
          includeResponse: true,
          data: sanitizeTrafficValue({
            command: name,
            script: {
              name: scriptName,
              sha1: createHash("sha1").update(sourceCode).digest("hex"),
              source: sourceCode,
              // Static commands in the source, NOT a trace of executed branches.
              possibleCommands: [
                ...new Set(
                  [
                    ...sourceCode.matchAll(/redis\.call\(['"]([A-Z]+)['"]/g),
                  ].map((match) => match[1]),
                ),
              ],
              observation:
                "Client command and final reply; internal branch execution and intermediate values are not observed.",
            },
            keys: args
              .slice(2, 2 + keyCount)
              .map((key, index) => ({ position: `KEYS[${index + 1}]`, key })),
            arguments: args.slice(2 + keyCount).map((value, index) => ({
              position: `ARGV[${index + 1}]`,
              name: labels[index] ?? `argument${index + 1}`,
              value: decoded(value),
            })),
          }),
        };
      }
    }
    return {
      summary: "Run an unrecognized Lua script (positional values omitted).",
      data: {
        command: name,
        argumentCount: args.length,
        detailsOmitted: "Unknown script may contain credentials.",
      },
      includeResponse: false,
    };
  }
  const supported = [
    "get",
    "set",
    "exists",
    "del",
    "unlink",
    "expire",
    "ttl",
    "pttl",
    "zscore",
    "zrangebyscore",
    "ping",
    "quit",
    "info",
  ];
  const keys = supported.includes(name) ? command.getKeys() : [];
  const sensitiveKey = keys.some((key) =>
    /password|passwd|token|secret|credential|api.?key|authorization|cookie|private.?key/i.test(
      String(key),
    ),
  );
  if (!supported.includes(name) || sensitiveKey) {
    return {
      summary: `Run ${name.toUpperCase()} (values omitted).`,
      data: {
        command: name,
        argumentCount: args.length,
        detailsOmitted: "Sensitive or unsupported positional command.",
      },
      includeResponse: false,
    };
  }
  return {
    summary: `${name.toUpperCase()}${keys.length ? ` ${keys.join(", ")}` : ""}`,
    data: sanitizeTrafficValue({
      command: name,
      keys,
      arguments: args.map(decoded),
    }),
    includeResponse: true,
  };
}
