import { Injectable, Logger } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { HydratedRoomPayload } from "../models";
@Injectable()
export class CentrifugoService {
  private readonly logger = new Logger(CentrifugoService.name);
  constructor(private readonly config: ConfigService) {}
  async publish(
    userId: string,
    epoch: string,
    room: HydratedRoomPayload,
  ): Promise<boolean> {
    for (const delay of [100, 300, 1000]) {
      await new Promise((resolve) => setTimeout(resolve, delay));
      try {
        const response = await fetch(
          `${this.config.getOrThrow<string>("CENTRIFUGO_API_URL").replace(/\/$/, "")}/publish`,
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "X-API-Key": this.config.getOrThrow<string>("CENTRIFUGO_API_KEY"),
            },
            body: JSON.stringify({
              channel: `inbox:user#${userId}`,
              data: { pts: room.roomPts, epoch, room },
            }),
            signal: AbortSignal.timeout(2500),
          },
        );
        const result = (await response.json()) as { error?: unknown };
        if (response.ok && !result.error) return true;
      } catch {
        /* Retry only safe advisory publications. Never log tokens or response bodies. */
      }
    }
    this.logger.warn(
      "Realtime publication exhausted its retry budget; REST inbox recovery remains available",
    );
    return false;
  }
}
