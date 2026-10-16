# Implementation validation

Recorded 2026-10-16 against local MongoDB replica set `rs0`, Redis, Centrifugo 6.9.7 OSS and the implemented NestJS API. Flutter 3.47.6 / Dart 3.13.5 and Node.js 24.22.0 were used. These results establish local implementation and browser behavior; they do not claim deployment, production capacity or native-device acceptance.

## Commands actually run

| Scope                           | Command                                                                                                                                          | Result                                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Backend formatting              | `npm run format:check`                                                                                                                           | Pass                                                                      |
| Backend TypeScript              | `npm run typecheck`                                                                                                                              | Pass                                                                      |
| Backend production compilation  | `npm run build`                                                                                                                                  | Pass                                                                      |
| Backend unit checks             | `npm test`                                                                                                                                       | 10 pass                                                                   |
| Backend live integration        | `npm run test:integration`                                                                                                                       | 21 pass                                                                   |
| Independent REST/two-socket E2E | `node --check scripts/e2e.mjs` and `node --test scripts/e2e.mjs`                                                                                 | 14 pass against final running API                                         |
| Dart formatting                 | `dart format --output=none --set-exit-if-changed lib test`                                                                                       | 19 files checked, zero changes                                            |
| Flutter analysis                | `flutter analyze`                                                                                                                                | No issues                                                                 |
| Flutter unit/widget checks      | `flutter test`                                                                                                                                   | 55 pass: 41 core, 14 UI/widget                                            |
| Release Web                     | `flutter build web --dart-define=API_BASE_URL=http://localhost:3000 --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket`       | Pass, output `mobile_and_web/build/web/`                                  |
| Debug Android                   | `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket` | Pass, output `mobile_and_web/build/app/outputs/flutter-apk/app-debug.apk` |

Backend integration covers actual transactions and indexes, concurrent sender-scoped idempotency, membership/sender authorization, counter separation, preferences/order, receipt boundaries/direction, reply edits/deletes, compound pagination, explicit around targets, Lua ordering/expiry, cache-failure recovery, upload validation, presence, rate limits, protected WebSocket subscriptions, CORS and redacted correlation logs. The independent E2E script uses native Node HTTP/WebSocket APIs against the separately running final API; it additionally verifies `X-Request-ID` correlation and rejected image edits.

Flutter core tests cover queue ordering, cursor ownership, epoch/full-sync reset, overlap and old-history invalidation, recovery without another publication, pagination, optimistic failure/retry, receipt directions, presence batching, cached/remote reply jumps, and account-switch/logout fences. Four final regressions delay local writes or upload completion across session changes. UI/widget tests cover auth, draft/group entry, responsive navigation, message actions, reply/jump layout, live historical mutations, image validation/failure/retry, input retention and the SQLite inspector.

## Two-browser computer-use evidence

Two independent Flutter web-server processes ran at `http://localhost:5173` (User 1) and `http://localhost:5174` (User 2). Chrome UI interaction verified:

- Debug login, connected state, reload persistence, online presence and independent account storage.
- Reopening current cached rooms made zero additional message requests: the diagnostics counter remained 2 and the direct room's `msgPts` and `messagesSyncedPts` both remained 549.
- Lazy direct drafts, bidirectional text delivery, delivered/read receipts and live editing.
- Quoted replies, cached target jumping/highlighting, pin and mute controls, and group creation appearing in the peer inbox.
- Reopening User 1 after 525 missed synthetic messages. Recovery fetched the latest 30 messages, discarded the stale history window, and aligned `msgPts` with `messagesSyncedPts` (both 544 in the recorded recovery snapshot). Opening the distant quote loaded the explicit remote target and context; Return to Latest restored the live view.
- PNG selection through the native browser file dialog, authenticated upload, peer image rendering and receipts.
- Delete for me removed only User 2's local/server view of the synthetic quote while User 1 retained it. Delete for everyone replaced the synthetic image with tombstones in both browsers.
- Sync diagnostics and expansion of actual read-only SQLite metadata/room/message rows.

Centrifugo admin readback showed one OSS 6.9.7 node with **2 clients, 2 users, 2 subscriptions and 2 channels**. The independent live suite rejected a foreign user's subscription. Client insecure mode is disabled; existing local insecure admin mode remains enabled.

Local screenshots are ignored artifacts retained for review:

- `.runtime/chat-user1-image.jpg` and `.runtime/chat-user2-image.jpg`: both accounts after image delivery, before the deletion test.
- `.runtime/history-recovery-diagnostics.jpg`: counters and bounded recovery request.
- `.runtime/history-remote-jump.jpg`: older explicit target/context.
- `.runtime/sqlite-inspector.jpg`: actual SQLite row snapshot.
- `.runtime/centrifugo-final.jpg`: final service connection counts.

The initial generic file-chooser automation could not address the upstream picker's detached HTML input. Native Chrome/macOS file selection completed the same user workflow successfully. No product workaround or dependency patch was added. A Flutter disposed-engine warning appeared during development hot restart; the subsequent reloaded app completed the workflows above.

## Final requirements audit

| Approved phase               | Evidence                                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Foundation/auth/schemas   | Four exact Mongoose schemas and indexes, normal and debug auth, dev-only debug routes, integration index/token tests                                                |
| 2. Transactions/Redis/REST   | All specified room/message/upload/receipt/presence routes, transaction and Lua integration tests, independent live socket suite                                     |
| 3. Flutter/database/accounts | Android/Web manifests and builds, exact Drift tables/assets, interrupted-send recovery, session tests and account UI                                                |
| 4. Inbox/realtime/rooms      | Serialized queue, automatic token refresh and mandatory recovery triggers, protected channels, reactive inbox/presence/preferences/pagination, two-browser delivery |
| 5. Messages/history/jumps    | Required V chat widgets, optimistic sends/retry/actions/images, hole-free reconciliation, 525-message offline recovery and both reply-jump paths                    |
| Requested debugging support  | Redacted correlated HTTP logs, bounded client events, request/revision diagnostics, read-only SQLite inspector and runbooks                                         |

Independent source review found and then rechecked the final pre-HTTP send/session race; the generation/sender checks and deterministic regressions close it. No known required implementation work remains.

## Environment repairs and boundaries

- Repaired the existing broken `mongosh` native dependency linkage and restored the Node 24 link. `mongosh` 2.5.8 now connects to MongoDB 8.0.15, returns ping 1, and confirms writable replica-set `rs0`.
- Used the existing OSS Centrifugo binary to remove the PRO sandbox's local API quota, retained the existing credentials, and configured only required local origins and the approved user-limited namespace. No credentials are printed in maintained artifacts.
- Tests retain synthetic databases, users, messages and uploads. No existing data was dropped or flushed. Private `.env`, uploaded files, runtime backups, local SQLite, build outputs and dependency trees are ignored.
- No commit, push, publication, deployment, external message, new simulator, Android device/UI run, release signing or store submission was performed.
- Transitive media plugins warn about future Flutter built-in Kotlin compatibility. Current Android compilation passes; native runtime behavior remains unverified because no Android test device was authorized.
