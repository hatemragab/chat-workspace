# Inspect the app's Redis data

[Redis Commander](https://github.com/joeferner/redis-commander) is the MIT-licensed, browser-based inspector used for this workspace. It runs locally without Docker. The workspace launcher pins version `0.9.0`, connects to the Redis URL/database in private `backend/.env`, and starts a read-only UI at [127.0.0.1:8081](http://127.0.0.1:8081/).

## Start and stop

From the workspace root, with Node.js 22 or newer:

```sh
node scripts/redis-debug.mjs install
node scripts/redis-debug.mjs start
```

Install is needed once, or to restore the pinned tool. Its package and dependencies live in ignored `.runtime/redis-inspector/`; backend and Flutter dependencies are unchanged. Stop the foreground inspector with **Ctrl+C**. Starting it does not start or restart the chat API, Redis, MongoDB or Centrifugo.

The launcher binds the HTTP inspector to `127.0.0.1`, validates the configured startup Redis URL as loopback and enables Redis Commander's server-side read-only checks for both forms and CLI commands. It disables connection saving and logging Redis values to the terminal. Connection credentials are passed privately to the process, without putting them in command arguments or a saved connection file. Treat the UI as private: it displays real room/message content from the local database.

## Find the app's keys

The initial key tree uses `<prefix>*`, where `<prefix>` is the API's optional `REDIS_KEY_PREFIX` (currently empty in the local app). Expand **user** for sync data and **auth-session** for login revocation. Centrifugo owns online presence under its separate engine prefix. **auth-rate** appears while a signup/login rate window exists. The local database is shared with other services and retained test namespaces such as `chat-test:<runId>:` and `chat-e2e:<runId>:`; those appear as separate folded branches. A prefix is a navigation aid, not an authorization boundary.

| Key / filter, after any configured prefix | Redis type | What to inspect                                                              | Expiry                 |
| ----------------------------------------- | ---------- | ---------------------------------------------------------------------------- | ---------------------- |
| `user:<userId>:meta`                      | Hash       | `epoch`, `min_pts`, `current_pts`                                            | 7 days                 |
| `user:<userId>:dirty_rooms`               | Sorted set | Room ID members; each score is that room's latest `roomPts` for this user    | 7 days                 |
| `user:<userId>:rooms_data`                | Hash       | Each field is a room ID; its value is the complete latest hydrated room JSON | 7 days                 |
| `auth-session:<userId>:retired:*`         | String     | Revoked authentication session; does not represent online status             | 24 hours               |
| `presence:<userId>:retired:*`             | String     | Legacy revocation marker honored until its existing TTL expires              | Original TTL only      |
| `auth-rate:*`                             | String     | Signup/login attempt count, keyed by an IP digest                            | Fixed 60-second window |

Copy the user ID from the app's Sync diagnostics or HTTP logs, then expand **user → that user ID**. A room ID identifies both a `dirty_rooms` member and a `rooms_data` hash field. JSON viewing expands nested room, last-message, updated-message and quote data. Use **Refresh** after normal app actions to read current values and TTLs. The browser also has a read-only command line; for filtered enumeration use `SCAN 0 MATCH user:*:rooms_data COUNT 100` and continue with its returned cursor, or use the terminal examples below. This release uses a key tree rather than a graphical search/filter box.

## Relate Redis to HTTP and realtime logs

1. Enable the existing full traffic logger when manually starting the API:

   ```sh
   HTTP_LOGGING_ENABLED=true DEBUG_TRAFFIC_LOGGING_ENABLED=true npm run start:dev
   ```

   Run this command from `backend/`. The API stays under your manual control.

2. In an HTTP completion or realtime publication record, find the actor/recipient `userId`, `recipientUserId`, room ID and `pts`/`roomPts`. HTTP `requestId` correlates server HTTP and publication records; it is not stored as a Redis key.
3. Inspect that recipient's `meta`, `dirty_rooms` and `rooms_data`. Compare the cached account `current_pts`, the room's sorted-set score and its JSON `roomPts`. Room `msgPts` and `lastHistoryEditPts` have separate meanings; preferences and receipts can advance `roomPts` without advancing message content.
4. For presence, query authorized snapshots from NestJS, which reads Centrifugo's inbox presence. Redis auth-session markers contain SHA-256 digests of validated bearers and prevent REST/token/reconnect access after logout. They are not online flags. The application no longer writes presence leases, state hashes or `presence:due`; existing expiring remnants may remain until their original TTL elapses.

Redis contains the latest projection, not every message or every past update. Durable messages and history are in MongoDB; client caches and pending sends are in Drift. The inspector refreshes current state and does not create an audit history. Use traffic logs alongside it to understand the sequence of requests and publications.

Cache expiry and invalidation are normal: an upsert refreshes all three user keys to seven days, while a full-sync epoch update refreshes only `meta`. Invalidation can remove `meta` and leave older room hashes or sorted-set entries. Those leftovers do not prove a usable delta cache; the API also compares Redis revisions with MongoDB before serving recovery.

## Read-only CLI examples

The following examples target the current local, unauthenticated Redis database 0. For other local credentials/database settings use the launcher and its UI rather than putting a password in shell history. Add the configured prefix to each pattern/key when applicable.

```sh
redis-cli --scan --pattern 'user:*:meta'
redis-cli HGETALL 'user:USER_ID:meta'
redis-cli ZREVRANGE 'user:USER_ID:dirty_rooms' 0 24 WITHSCORES
redis-cli HLEN 'user:USER_ID:rooms_data'
redis-cli HGET 'user:USER_ID:rooms_data' 'ROOM_ID'
redis-cli TTL 'user:USER_ID:meta'
redis-cli --scan --pattern 'auth-session:USER_ID:retired:*'
redis-cli TTL 'auth-session:USER_ID:retired:SESSION_DIGEST'
```

Key enumeration uses `SCAN`. No flush, key deletion, cache repair, server configuration change or always-on command monitor is part of this setup.
