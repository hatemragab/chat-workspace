import {
  HttpException,
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
} from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import Redis from "ioredis";
import { createHash, randomUUID } from "node:crypto";
import { HydratedRoomPayload } from "../models";

export const upsertUserRoomDeltaLua = `
local newPts = tonumber(ARGV[1])
local roomId = ARGV[2]
local ttl = tonumber(ARGV[5])
if redis.call('EXISTS', KEYS[1]) == 0 then
  redis.call('HSET', KEYS[1], 'epoch', ARGV[4], 'min_pts', newPts - 1, 'current_pts', newPts)
else
  local curPts = tonumber(redis.call('HGET', KEYS[1], 'current_pts') or '0')
  if newPts > curPts then redis.call('HSET', KEYS[1], 'current_pts', newPts) end
end
local prevScore = tonumber(redis.call('ZSCORE', KEYS[2], roomId) or '0')
if newPts >= prevScore then
  redis.call('ZADD', KEYS[2], newPts, roomId)
  redis.call('HSET', KEYS[3], roomId, ARGV[3])
end
redis.call('EXPIRE', KEYS[1], ttl)
redis.call('EXPIRE', KEYS[2], ttl)
redis.call('EXPIRE', KEYS[3], ttl)
return redis.call('HGET', KEYS[1], 'epoch')`;

const deltaLua = `
if redis.call('EXISTS',KEYS[1]) == 0 then return '' end
local epoch=redis.call('HGET',KEYS[1],'epoch')
local min=tonumber(redis.call('HGET',KEYS[1],'min_pts') or '0')
local cur=tonumber(redis.call('HGET',KEYS[1],'current_pts') or '0')
local since=tonumber(ARGV[1])
if epoch~=ARGV[2] or since<min or since>cur then return '' end
local rooms=redis.call('ZRANGEBYSCORE',KEYS[2],'('..ARGV[1],'+inf','LIMIT',0,101)
if #rooms>100 then return '' end
local data={}
for _,id in ipairs(rooms) do
 local payload=redis.call('HGET',KEYS[3],id)
 if not payload then return '' end
 table.insert(data,cjson.decode(payload))
end
return cjson.encode({requiresFullSync=false,pts=cur,epoch=epoch,rooms=data})`;

@Injectable()
export class RedisSyncService implements OnModuleInit, OnModuleDestroy {
  readonly client: Redis;
  private readonly prefix: string;
  private readonly logger = new Logger(RedisSyncService.name);
  constructor(config: ConfigService) {
    this.prefix = config.get<string>("REDIS_KEY_PREFIX", "");
    this.client = new Redis(config.getOrThrow<string>("REDIS_URL"), {
      maxRetriesPerRequest: 1,
      connectTimeout: 3000,
      retryStrategy: (n) => Math.min(n * 200, 3000),
    });
    this.client.on("error", () =>
      this.logger.warn(
        "Redis connection unavailable; clients will recover through a full sync",
      ),
    );
  }
  async onModuleInit() {
    await this.client.ping();
  }
  async onModuleDestroy() {
    await this.client.quit();
  }
  keys(userId: string) {
    return ["meta", "dirty_rooms", "rooms_data"].map(
      (suffix) => `${this.prefix}user:${userId}:${suffix}`,
    );
  }
  async upsert(userId: string, room: HydratedRoomPayload): Promise<string> {
    return String(
      await this.client.eval(
        upsertUserRoomDeltaLua,
        3,
        ...this.keys(userId),
        room.roomPts,
        room.roomId,
        JSON.stringify(room),
        randomUUID(),
        604800,
      ),
    );
  }
  async invalidate(userId: string) {
    await this.client.del(this.keys(userId)[0]).catch(() => undefined);
  }
  async ensureEpoch(userId: string, pts: number): Promise<string> {
    return String(
      await this.client.eval(
        `local current=tonumber(redis.call('HGET',KEYS[1],'current_pts') or '-1')
if current<tonumber(ARGV[2]) then
 redis.call('HSET',KEYS[1],'epoch',ARGV[1],'min_pts',ARGV[2],'current_pts',ARGV[2])
end
redis.call('EXPIRE',KEYS[1],604800)
return redis.call('HGET',KEYS[1],'epoch')`,
        1,
        this.keys(userId)[0],
        randomUUID(),
        pts,
      ),
    );
  }
  async delta(
    userId: string,
    sincePts: number,
    epoch: string,
  ): Promise<
    | { requiresFullSync: true }
    | {
        requiresFullSync: false;
        pts: number;
        epoch: string;
        rooms: HydratedRoomPayload[];
      }
  > {
    try {
      const result = await this.client.eval(
        deltaLua,
        3,
        ...this.keys(userId),
        sincePts,
        epoch,
      );
      if (!result) return { requiresFullSync: true };
      const parsed = JSON.parse(String(result)) as {
        requiresFullSync: false;
        pts: number;
        epoch: string;
        rooms: HydratedRoomPayload[] | object;
      };
      return {
        ...parsed,
        rooms: Array.isArray(parsed.rooms) ? parsed.rooms : [],
      };
    } catch {
      return { requiresFullSync: true };
    }
  }
  async limitAuth(ip: string) {
    const key = `${this.prefix}auth-rate:${createHash("sha256").update(ip).digest("hex")}`;
    const count = Number(
      await this.client.eval(
        `local n=redis.call('INCR',KEYS[1]) if n==1 then redis.call('EXPIRE',KEYS[1],60) end return n`,
        1,
        key,
      ),
    );
    if (count > 30)
      throw new HttpException(
        "Too many authentication attempts. Try again in a minute.",
        429,
      );
  }
  presenceKey(userId: string) {
    return `${this.prefix}presence:${userId}`;
  }
}
