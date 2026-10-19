const redisNow = `
local time = redis.call('TIME')
local now = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)
`;

export const trackLastSeenLua = `${redisNow}
redis.call('HSET', KEYS[2], ARGV[1], cjson.encode({
  version = ARGV[2], lastOnlineAt = now
}))
-- Reconnecting must not indefinitely postpone an already scheduled observation.
redis.call('ZADD', KEYS[1], 'NX', now + tonumber(ARGV[3]), ARGV[1])
redis.call('ZADD', KEYS[1], 'LT', now + tonumber(ARGV[3]), ARGV[1])
return 1
`;

export const claimLastSeenLua = `${redisNow}
local users = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', now, 'LIMIT', 0, 100)
local claimed = {}
for _, user in ipairs(users) do
  local raw = redis.call('HGET', KEYS[2], user)
  if raw then
    local state = cjson.decode(raw)
    state.lease = ARGV[1]
    redis.call('HSET', KEYS[2], user, cjson.encode(state))
    redis.call('ZADD', KEYS[1], now + 60000, user)
    table.insert(claimed, {userId = user, version = state.version, lastOnlineAt = state.lastOnlineAt})
  else
    redis.call('ZREM', KEYS[1], user)
  end
end
return cjson.encode(claimed)
`;

export const finishLastSeenLua = `${redisNow}
local raw = redis.call('HGET', KEYS[2], ARGV[1])
if not raw then return 0 end
local state = cjson.decode(raw)
if state.version ~= ARGV[2] or state.lease ~= ARGV[3] then return 0 end
if ARGV[4] == 'offline' then
  redis.call('HDEL', KEYS[2], ARGV[1])
  redis.call('ZREM', KEYS[1], ARGV[1])
else
  if ARGV[4] == 'online' then state.lastOnlineAt = now end
  state.lease = nil
  redis.call('HSET', KEYS[2], ARGV[1], cjson.encode(state))
  redis.call('ZADD', KEYS[1], now + tonumber(ARGV[5]), ARGV[1])
end
return 1
`;

export const checkLastSeenSoonLua = `${redisNow}
local raw = redis.call('HGET', KEYS[2], ARGV[1])
if raw and not cjson.decode(raw).lease then
  redis.call('ZADD', KEYS[1], now, ARGV[1])
end
return 1
`;
