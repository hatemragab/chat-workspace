export const upsertUserRoomDeltaLua = `
-- Expired commands may arrive after a lost response/reconnect; never apply them later.
if ARGV[6] then
 local now=redis.call('TIME')
 if tonumber(ARGV[6]) <= tonumber(now[1])*1000+math.floor(tonumber(now[2])/1000) then return redis.error_reply('Inbox deadline expired') end
end
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

export const deltaLua = `
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

export const invalidateLua = `local now=redis.call('TIME') if tonumber(ARGV[1])<=tonumber(now[1])*1000+math.floor(tonumber(now[2])/1000) then return 0 end return redis.call('DEL',KEYS[1])`;

export const ensureEpochLua = `local current=tonumber(redis.call('HGET',KEYS[1],'current_pts') or '-1')
if current<tonumber(ARGV[2]) then
 redis.call('HSET',KEYS[1],'epoch',ARGV[1],'min_pts',ARGV[2],'current_pts',ARGV[2])
end
redis.call('EXPIRE',KEYS[1],604800)
return redis.call('HGET',KEYS[1],'epoch')`;

export const limitAuthLua = `local n=redis.call('INCR',KEYS[1]) if n==1 then redis.call('EXPIRE',KEYS[1],60) end return n`;

export const limitRealtimeLua = `
local a=redis.call('INCR',KEYS[1])
if a==1 then redis.call('EXPIRE',KEYS[1],60) end
local b=redis.call('INCR',KEYS[2])
if b==1 then redis.call('EXPIRE',KEYS[2],60) end
return a<=tonumber(ARGV[1]) and b<=tonumber(ARGV[2]) and 1 or 0`;
