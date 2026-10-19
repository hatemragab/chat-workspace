import { Module } from "@nestjs/common";
import { PresenceService } from "./presence.service";
import { PresenceController } from "./presence.controller";
@Module({ controllers: [PresenceController], providers: [PresenceService] })
export class PresenceModule {}
