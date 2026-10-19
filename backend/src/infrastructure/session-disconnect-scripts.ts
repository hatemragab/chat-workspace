// Redis time keeps scheduling and visibility leases consistent across API processes.
const redisNow = `
local time = redis.call('TIME')
local now = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)
`;

// Revocation and its retry obligation must never be separated by a process crash.
// Keep the job/tombstone slightly longer than the maximum 24-hour access session.
export const retireSessionLua = `${redisNow}
redis.call('SET', KEYS[1], '1', 'EX', 86400, 'NX')
if redis.call('EXISTS', KEYS[2]) == 0 then
  redis.call('HSET', KEYS[2], 'state', 'pending', 'attempts', 0,
    'settleAt', now + 15000)
  redis.call('EXPIRE', KEYS[2], 86460)
  redis.call('ZADD', KEYS[3], now, ARGV[1])
end
return 1
`;

export const dueSessionDisconnectsLua = `${redisNow}
return redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', now, 'LIMIT', 0, ARGV[1])
`;

// The score doubles as a visibility timeout. A crashed worker cannot lose a job.
export const claimSessionDisconnectLua = `${redisNow}
local due = tonumber(redis.call('ZSCORE', KEYS[1], ARGV[1]))
if not due or due > now then return nil end
if redis.call('HGET', KEYS[2], 'state') ~= 'pending' then
  redis.call('ZREM', KEYS[1], ARGV[1])
  return nil
end
redis.call('HSET', KEYS[2], 'lease', ARGV[2])
local attempts = redis.call('HINCRBY', KEYS[2], 'attempts', 1)
redis.call('ZADD', KEYS[1], now + 60000, ARGV[1])
return attempts
`;

// A delayed reply from an expired lease cannot complete another worker's job.
// Successful early passes stay queued until any in-flight connect has settled
// (local connect proxy timeout 2s and stale connection timeout 10s).
export const finishSessionDisconnectLua = `${redisNow}
if redis.call('HGET', KEYS[2], 'lease') ~= ARGV[2] then return 0 end
local settleAt = tonumber(redis.call('HGET', KEYS[2], 'settleAt'))
redis.call('HDEL', KEYS[2], 'lease')
if ARGV[3] == '1' and now >= settleAt then
  redis.call('HSET', KEYS[2], 'state', 'done')
  redis.call('ZREM', KEYS[1], ARGV[1])
else
  local nextAt = now + tonumber(ARGV[4])
  if ARGV[3] == '1' then nextAt = settleAt end
  redis.call('ZADD', KEYS[1], nextAt, ARGV[1])
end
return 1
`;
