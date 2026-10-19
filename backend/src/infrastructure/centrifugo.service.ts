import { Injectable, Logger, Optional } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { randomUUID } from "node:crypto";
import { HydratedRoomPayload } from "../models";
import { DebugTrafficLogger } from "./debug-traffic-logger";
import { centrifugoLogSnapshot } from "./centrifugo-command-details";
import { LocalServiceDiagnostics } from "./local-service-diagnostics";
import { boundedSetting } from "./bounded-work";
@Injectable()
export class CentrifugoService {
  private readonly logger = new Logger(CentrifugoService.name);
  constructor(
    private readonly config: ConfigService,
    private readonly traffic: DebugTrafficLogger,
    @Optional() private readonly diagnostics?: LocalServiceDiagnostics,
  ) {}
  private async api<T>(
    method: string,
    body: object,
    channels: string[] = [],
    purpose = "server_api",
  ): Promise<T> {
    const wireBody = JSON.stringify(body);
    let status: number | null = null;
    const data = this.traffic.debugEnabled
      ? {
          method: "POST",
          providerMethod: method,
          requestBody: centrifugoLogSnapshot(JSON.parse(wireBody)),
          channels,
          status: null as number | null,
          timeoutMs: 1500,
        }
      : undefined;
    const done = this.diagnostics?.begin("centrifugo", method, undefined, {
      summary:
        method === "batch"
          ? `Read presence counts for ${channels.length} inbox channels from Centrifugo.`
          : method === "presence"
            ? "Read connected inbox clients before disconnecting a retired login."
            : "Disconnect the selected retired-login realtime client.",
      data,
      purpose,
      channelCount: channels.length,
      method: "POST",
      path: `/api/${method}`,
      channel: channels.length === 1 ? channels[0] : undefined,
      get status() {
        return status;
      },
      includeResponse: true,
      responseSnapshot: centrifugoLogSnapshot,
    });
    let value:
      | { result: T; error?: unknown; replies?: { error?: unknown }[] }
      | undefined;
    let failure: unknown;
    try {
      const response = await fetch(
        `${this.config.getOrThrow<string>("CENTRIFUGO_API_URL").replace(/\/$/, "")}/${method}`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "X-API-Key": this.config.getOrThrow<string>("CENTRIFUGO_API_KEY"),
          },
          body: wireBody,
          signal: AbortSignal.timeout(1500),
        },
      );
      status = response.status;
      if (data) data.status = status;
      value = (await response.json()) as typeof value;
      if (!response.ok || value?.error)
        throw new Error("Realtime server API unavailable");
      // Batch uses a top-level replies envelope; individual methods use result.
      return method === "batch" ? (value as unknown as T) : value!.result;
    } catch (error) {
      failure = error;
      throw error;
    } finally {
      // HTTP 200 may contain per-command errors. Preserve the raw envelope and
      // the caller's existing validation/return behavior while reporting failure.
      const replyError =
        Array.isArray(value?.replies) &&
        value.replies.some((reply) => reply?.error);
      const malformedBatch =
        method === "batch" &&
        (!Array.isArray(value?.replies) ||
          value.replies.length !== channels.length ||
          value.replies.some((reply) => {
            const stats = (
              reply as {
                presence_stats?: { num_clients: number; num_users: number };
              } | null
            )?.presence_stats;
            return (
              !stats ||
              !Number.isSafeInteger(stats.num_clients) ||
              stats.num_clients < 0 ||
              !Number.isSafeInteger(stats.num_users) ||
              stats.num_users < 0 ||
              stats.num_users > stats.num_clients
            );
          }));
      done?.(
        failure ??
          (replyError || malformedBatch
            ? new Error("Provider reply error")
            : undefined),
        value === undefined && data?.status != null
          ? { payloadOmitted: true, omissionReason: "unreadable_json_response" }
          : value,
      );
    }
  }
  async presenceStatuses(
    userIds: string[],
    purpose: "client_status" | "last_seen_observer" = "client_status",
  ): Promise<Record<string, boolean>> {
    const ids = [...new Set(userIds)];
    if (ids.length > 100)
      throw new Error("Presence batches must not exceed 100 users");
    if (!ids.length) return {};
    const result = await this.api<{
      replies: {
        error?: unknown;
        presence_stats?: { num_clients: number; num_users: number };
      }[];
    }>(
      "batch",
      {
        commands: ids.map((id) => ({
          presence_stats: { channel: `inbox:user#${id}` },
        })),
      },
      ids.map((id) => `inbox:user#${id}`),
      purpose,
    );
    if (!Array.isArray(result?.replies) || result.replies.length !== ids.length)
      throw new Error("Realtime presence unavailable");
    return Object.fromEntries(
      ids.map((id, index) => {
        const reply = result.replies[index];
        const stats = reply?.presence_stats;
        // Unavailable/malformed presence must never be reported as offline.
        if (
          reply?.error ||
          !stats ||
          !Number.isSafeInteger(stats.num_clients) ||
          stats.num_clients < 0 ||
          !Number.isSafeInteger(stats.num_users) ||
          stats.num_users < 0 ||
          stats.num_users > stats.num_clients
        )
          throw new Error("Realtime presence unavailable");
        return [id, stats.num_clients > 0];
      }),
    );
  }
  async disconnectSession(userId: string, sessionId: string) {
    try {
      let remaining = false;
      // Repeat once to catch a connect already in flight when logout retired
      // the session. A replay/new connect is rejected by the connect proxy.
      for (const delay of [0, 200]) {
        remaining = false;
        if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
        const result = await this.api<{
          presence: Record<
            string,
            { user: string; conn_info?: { sessionId?: string } }
          >;
        }>(
          "presence",
          { channel: `inbox:user#${userId}` },
          [`inbox:user#${userId}`],
          "logout_verification",
        );
        if (
          !result?.presence ||
          typeof result.presence !== "object" ||
          Array.isArray(result.presence)
        )
          throw new Error("Realtime presence unavailable");
        for (const [client, info] of Object.entries(result.presence)) {
          if (!info || typeof info.user !== "string")
            throw new Error("Realtime presence unavailable");
          if (info.user === userId && info.conn_info?.sessionId === sessionId) {
            remaining = true;
            await this.api(
              "disconnect",
              {
                user: userId,
                client,
                disconnect: { code: 4501, reason: "session ended" },
              },
              [`inbox:user#${userId}`],
              "logout_disconnect",
            );
          }
        }
      }
      // API acceptance alone does not prove that the sockets have closed.
      // Retain the job until a later presence read confirms their absence.
      return !remaining;
    } catch {
      this.logger.warn(
        "Session retired; realtime disconnection remains queued for retry",
      );
      return false;
    }
  }
  async publish(
    userId: string,
    epoch: string,
    room: HydratedRoomPayload,
    deadline?: number,
  ): Promise<boolean> {
    const mode = this.config.get<string>("RECEIPT_PUSH_MODE", "legacy");
    if (mode !== "legacy" && mode !== "compact")
      throw new Error("RECEIPT_PUSH_MODE must be legacy or compact");
    const compact =
      mode === "compact" &&
      room.sequenceReceipt === true &&
      (room.eventType === "room_delivered" ||
        room.eventType === "room_peer_seen");
    const compactUnread =
      mode === "compact" && room.eventType === "room_unread_cleared";
    return this.publishInbox(
      userId,
      compactUnread
        ? {
            pts: room.roomPts,
            epoch,
            unread: {
              eventType: room.eventType,
              roomId: room.roomId,
              unreadCount: room.unreadCount,
              ownDeliveredSeq: room.ownDeliveredSeq ?? 0,
              ownSeenSeq: room.ownSeenSeq ?? 0,
            },
          }
        : compact
          ? {
              pts: room.roomPts,
              epoch,
              receipt: {
                roomId: room.roomId,
                eventType: room.eventType,
                peerDeliveredSeq: room.peerDeliveredSeq ?? 0,
                peerSeenSeq: room.peerSeenSeq ?? 0,
                contentPts: room.contentPts ?? room.msgPts,
              },
            }
          : { pts: room.roomPts, epoch, room },
      room.eventType,
      room.roomPts,
      deadline,
    );
  }
  private async publishInbox(
    userId: string,
    payload: unknown,
    eventType: string,
    pts?: number,
    deadline = Date.now() + 10000,
  ): Promise<boolean> {
    const channel = `inbox:user#${userId}`;
    const envelope = payload as {
      epoch?: string;
      room?: { roomId?: string };
      receipt?: { roomId?: string };
      unread?: { roomId?: string };
    };
    const epoch = envelope.epoch;
    const roomId = (envelope.room ?? envelope.receipt ?? envelope.unread)
      ?.roomId;
    const correlationKey =
      epoch && pts !== undefined
        ? `inbox:${userId}:${epoch}:${pts}`
        : undefined;
    const publication = { channel, data: payload };
    const body = JSON.stringify(publication);
    const debug = this.traffic.debugEnabled;
    const metadata = this.diagnostics?.enabled === true;
    const identity = debug
      ? this.traffic.identity()
      : metadata
        ? this.diagnostics!.identity()
        : null;
    const publicationId = debug || metadata ? randomUUID() : null;
    // Snapshot only in opt-in mode, and use the exact data sent to Centrifugo.
    const data: unknown = debug
      ? centrifugoLogSnapshot(JSON.parse(body).data)
      : undefined;
    let attempt = 0;
    for (const delay of [0, 300, 1000]) {
      if (Date.now() + delay >= deadline) break;
      attempt++;
      await new Promise((resolve) => setTimeout(resolve, delay));
      const started = performance.now();
      let status: number | null = null;
      let responseBody: unknown = null;
      let success = false;
      let failure: unknown;
      try {
        const response = await fetch(
          `${this.config.getOrThrow<string>("CENTRIFUGO_API_URL").replace(/\/$/, "")}/publish`,
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "X-API-Key": this.config.getOrThrow<string>("CENTRIFUGO_API_KEY"),
            },
            body,
            signal: AbortSignal.timeout(
              Math.max(
                1,
                Math.min(
                  boundedSetting(
                    this.config,
                    "REALTIME_PUBLISH_TIMEOUT_MS",
                    2500,
                    10000,
                  ),
                  deadline - Date.now(),
                ),
              ),
            ),
          },
        );
        status = response.status;
        const result = (await response.json()) as { error?: unknown };
        responseBody = debug ? centrifugoLogSnapshot(result) : undefined;
        success = response.ok && !result.error;
      } catch (error) {
        failure = error;
        if (debug && status !== null && responseBody === null)
          responseBody = {
            payloadOmitted: true,
            omissionReason: "unreadable_json_response",
          };
        /* Retry only safe advisory publications; never serialize raw errors. */
      }
      const durationMs = Math.round((performance.now() - started) * 100) / 100;
      if (metadata) {
        this.diagnostics!.publication({
          ...identity!,
          publicationId: publicationId!,
          recipientUserId: userId,
          channel,
          eventType,
          pts,
          epoch,
          roomId,
          correlationKey,
          data,
          responseBody,
          attempt,
          status,
          durationMs,
          success,
          error: failure,
        });
      }
      if (debug) {
        this.traffic.write({
          timestamp: new Date().toISOString(),
          level: success ? "info" : "warn",
          event: "realtime_publication",
          summary: `Publish ${eventType} to ${channel}, attempt ${attempt}: ${success ? "provider accepted" : "failed"}.`,
          direction: "publish",
          method: "POST",
          path: "/api/publish",
          source: "backend",
          requestId: identity!.requestId,
          userId: identity!.userId,
          actorUserId: identity!.userId,
          recipientUserId: userId,
          channel,
          pts,
          epoch,
          roomId,
          correlationKey,
          stage: success ? "provider_accepted" : "provider_failed",
          purpose: "inbox_publish",
          eventType,
          publicationId,
          attempt,
          result: success ? "success" : "failure",
          status,
          responseBody,
          durationMs,
          data,
        });
      }
      if (success) return true;
    }
    this.logger.warn(
      "Realtime publication exhausted its retry budget; REST inbox recovery remains available",
    );
    return false;
  }
}
