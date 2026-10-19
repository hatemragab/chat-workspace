import { Global, Module } from "@nestjs/common";
import { DatabaseService } from "./database.service";
import { RedisSyncService } from "./redis-sync.service";
import { CentrifugoService } from "./centrifugo.service";
import { DebugTrafficLogger } from "./debug-traffic-logger";
import { LocalServiceDiagnostics } from "./local-service-diagnostics";
import { SessionDisconnectService } from "./session-disconnect.service";
import { LastSeenService } from "./last-seen.service";
@Global()
@Module({
  providers: [
    DatabaseService,
    RedisSyncService,
    CentrifugoService,
    DebugTrafficLogger,
    LocalServiceDiagnostics,
    SessionDisconnectService,
    LastSeenService,
  ],
  exports: [
    DatabaseService,
    RedisSyncService,
    CentrifugoService,
    DebugTrafficLogger,
    LocalServiceDiagnostics,
    SessionDisconnectService,
    LastSeenService,
  ],
})
export class InfrastructureModule {}
