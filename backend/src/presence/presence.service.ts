import { Injectable, ServiceUnavailableException } from "@nestjs/common";
import { DatabaseService } from "../infrastructure/database.service";
import { CentrifugoService } from "../infrastructure/centrifugo.service";
import { iso } from "../models";

@Injectable()
export class PresenceService {
  constructor(
    private readonly db: DatabaseService,
    private readonly centrifugo: CentrifugoService,
  ) {}
  async statuses(viewerId: string, userIds: string[]) {
    viewerId = viewerId.toLowerCase();
    userIds = userIds.map((id) => id.toLowerCase());
    // No contacts table exists: self and co-members of existing rooms may see
    // presence. Requests and provider batches are capped at 100 users.
    const requested = new Set(userIds);
    const permitted = new Set(requested.has(viewerId) ? [viewerId] : []);
    if (requested.size) {
      const rooms = this.db.rooms
        .find({
          $and: [
            { participantIds: viewerId },
            { participantIds: { $in: userIds } },
          ],
        })
        .select({ participantIds: 1 })
        .lean()
        .cursor({ batchSize: 100 });
      for await (const room of rooms) {
        for (const participant of room.participantIds) {
          const id = participant.toString();
          if (requested.has(id)) permitted.add(id);
        }
        if (permitted.size === requested.size) break;
      }
    }
    try {
      const statuses = await this.centrifugo.presenceStatuses([...permitted]);
      const offline = [...permitted].filter((id) => statuses[id] === false);
      const users = offline.length
        ? await this.db.users
            .find({ _id: { $in: offline } })
            .select("_id lastSeenAt")
            .lean()
        : [];
      return {
        statuses,
        lastSeenAt: Object.fromEntries(
          users.map((user) => [user._id.toString(), iso(user.lastSeenAt)]),
        ),
      };
    } catch {
      throw new ServiceUnavailableException("Realtime presence unavailable");
    }
  }
}
