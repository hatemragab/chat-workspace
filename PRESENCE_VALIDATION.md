# Centrifugo connection presence verification

Verified locally on 2026-10-17, following the user's explicit request to replace application Redis presence tracking with Centrifugo.

## Result and behavior

- Centrifugo inbox presence is now the authority: at least one connection on `inbox:user#<userId>` means online. Authorized NestJS snapshots use one bounded `batch` of provider `presence_stats` commands for up to 100 unique IDs. Empty/unauthorized-only snapshots avoid provider calls.
- Removed application heartbeat/expiry/reconciliation Lua, the due-user index code, 500ms worker, and presence-transition publisher. Room projection Lua, epochs/delta recovery, rate limits and login retirement remain active.
- `/presence/heartbeat` is a deprecated authenticated no-op retained for compatibility; it cannot fabricate online status or write presence keys. New Flutter clients never call it.
- Logout preserves the existing session-only disconnect/revocation flow. New Redis revocations use `auth-session:<userId>:retired:<sessionHash>`; legacy revoked-session keys are honored until their original TTL expires. Existing expiring presence remnants are not refreshed. The obsolete local `presence:due` key was checked by a narrowly scoped removal operation and was already absent (0 keys removed); no other application keys were deleted.
- Provider failures, malformed counters and incomplete batch replies produce 503 instead of a false offline snapshot. Contact authorization, 100-ID limits, no-body validation, problem responses and no-store HTTP behavior remain.
- Flutter refreshes peer snapshots on startup/reconnect/resume/manual sync and every 30 foreground seconds (`PRESENCE_REFRESH_SECONDS`); hidden polling pauses. Existing lifecycle/account-generation fences and single-flight status batching remain. Legacy `presence_changed` hints are still accepted as invalidations, but are no longer emitted by this backend.

## Checks run

| Command                                                                                                                                    | Result            |
| ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- |
| `npm run format:check` in `backend`                                                                                                        | Passed            |
| `npm run typecheck` in `backend`                                                                                                           | Passed            |
| `npm run build` in `backend`                                                                                                               | Passed            |
| `npm test` in `backend`                                                                                                                    | 55 passed         |
| `npm run test:integration` in `backend`                                                                                                    | 45 passed         |
| `dart format --output=none --set-exit-if-changed` on the changed Flutter controller and four test files                                    | Passed; 0 changes |
| `flutter analyze` in `mobile_and_web`                                                                                                      | Passed; no issues |
| `flutter test test/core/presence_session_test.dart`                                                                                        | 12 passed         |
| `flutter test` in `mobile_and_web`                                                                                                         | 246 passed        |
| `flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket` | Passed            |
| `node --test scripts/e2e.mjs` against the restarted local API                                                                              | 17 passed         |
| `git diff --check`                                                                                                                         | Passed            |

The native Centrifugo v6.9.7 OSS integration fixture uses temporary loopback ports, synthetic MongoDB databases, and isolated application/provider Redis prefixes. It verifies multi-login presence, no heartbeat-derived presence, privacy, bounded queries, unchanged room revisions, disconnect without REST offline, session logout and reconnect denial, and a real subprocess WebSocket client killed abruptly without sending offline. The provider detects the client loss and snapshots become offline. A provider-outage test returns 503; empty snapshots still succeed. Test-only 2s/1s ping/pong settings do not change the running Centrifugo configuration.

Other integration checks continue to cover durable messages, idempotency, receipt semantics, room synchronization, post-commit cache failures, Redis Lua ordering/TTL, upload safety, authentication/rate limits and realtime protocol security. The live two-client script exercises chat mutations and media, Redis delta recovery, and an additional independent login socket: logging out one preserves the other, while logging out the final login produces offline snapshots.

## Running service and logs MCP evidence

The local API was restarted from the current source with `DEBUG_TRAFFIC_LOGGING_ENABLED=false` and existing metadata/file diagnostics. `/health` returned HTTP 200 with MongoDB/Redis healthy. Centrifugo configuration and its own Redis engine were not changed.

The logs MCP, reading the same unified capture as Logdy, reported **0 Redis records from the new backend instance during 00:47:33–00:47:51 UTC** (03:47:33–03:47:51 Cairo). The subsequent health check produced a successful `redis.ping` at 00:47:51.297 UTC, correlated with that HTTP request, confirming that command capture remained active. Both queries reported complete scan coverage, no malformed/invalid records, no result limit and no warnings. This is an 18-second local idle observation, supported by an automated integration check that also asserts no Redis operations while the backend is idle.

## Limits

This implements connection status, not foreground activity. A background socket still counts as online. Peer badge updates depend on the foreground refresh interval and Centrifugo's network-failure detection; the application's previous 90-second lease/five-second grace no longer applies. No custom last-seen activity tracker was added.

No device/browser UI test was run for this change. The repository's supported targets remain Android/Web; no iOS support was added and no substitute simulator was selected. Flutter unit/widget tests and real local backend/WebSocket checks are separate evidence from device/UI testing. No production or multi-node capacity claim, commit, push, publication or deployment was performed. Retained synthetic test data was not dropped/flushed.

## API guideline review

Reviewed the current [official Zalando RESTful API and Event Guidelines](https://opensource.zalando.com/restful-api-guidelines/) on 2026-10-17. Applied endpoint security (104), OpenAPI consistency (101), compatibility (106), rate-limit responses (153), and deprecation documentation (187). Existing camelCase fields and action URLs were preserved for compatibility; Centrifugo's batch envelope follows its own protocol. Provider presence/API details were checked against the [official server API](https://centrifugal.dev/docs/server/server_api) and the installed live v6.9.7 OSS service.
