import { Global, Module } from "@nestjs/common";
import { DatabaseService } from "./database.service";
import { RedisSyncService } from "./redis-sync.service";
import { CentrifugoService } from "./centrifugo.service";
@Global()
@Module({
  providers: [DatabaseService, RedisSyncService, CentrifugoService],
  exports: [DatabaseService, RedisSyncService, CentrifugoService],
})
export class InfrastructureModule {}
