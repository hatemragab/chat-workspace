# Flutter chat client

Android and Web client using Riverpod, Drift, Dio, Centrifugo, `v_chat_bubbles`, and `v_chat_input_ui`. The source follows [FLUTTER_SPEC.md](../FLUTTER_SPEC.md); [the workspace README](../README.md) contains service setup and two-browser commands.

`lib/core/` contains typed API models, HTTP handling, SQLite storage, the inbox queue, reconciliation, session lifecycle, optimistic sends and presence. `lib/ui/` contains responsive authentication, inbox, direct/group entry, Telegram-style messages, image attachments, actions, reply jumps and diagnostics. `lib/main.dart` starts the provider scope and semantic accessibility support.

Run `flutter pub get` before development. Configure `API_BASE_URL` and `CENTRIFUGO_URL` using `--dart-define`. Defaults target localhost ports 3000 and 8000. Separate localhost ports 5173 and 5174 provide independent account storage for web verification. For an Android environment reaching the host through its loopback bridge, build with `http://10.0.2.2:3000` and `ws://10.0.2.2:8000/connection/websocket`; use the appropriate reachable host for a physical device. The Android project uses compile SDK 37 and AGP 9.1.1. Local cleartext connections are enabled only in debug/profile manifests.

The exact Drift tables are `SyncMetadata`, `LocalRooms` and `LocalMessages` in `chat_app_db`. Logout and account switching clear account data and fence stale asynchronous operations. Interrupted sends become failed rows on startup and retain their idempotency key when retried. `web/sqlite3.wasm` and `web/drift_worker.js` are required runtime assets. Regenerate database bindings only after an intentional schema change using `dart run build_runner build --delete-conflicting-outputs`.

Open **Sync diagnostics**, scroll to **SQLite database rows**, and expand it to inspect a read-only local snapshot. Authentication tokens are excluded. The panel also shows revision counters, connection status, request counts and recent operational events. Keep copied diagnostics private because local room/message content may be included in the row snapshot.

Validation commands:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build web --dart-define=API_BASE_URL=http://localhost:3000 \
  --dart-define=CENTRIFUGO_URL=ws://localhost:8000/connection/websocket
flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:3000 \
  --dart-define=CENTRIFUGO_URL=ws://10.0.2.2:8000/connection/websocket
```

Recorded on 2026-10-16: formatter and analyzer clean, all 55 tests pass (41 core and 14 UI/widget tests), release Web build and debug Android APK succeed. Web UI workflows were also exercised in two Chrome instances. No Android device or simulator was used. Existing transitive media plugins emit a warning about future Flutter built-in Kotlin compatibility; the current APK builds successfully.

The user permits device/UI testing only on their existing iPhone 17 Pro / iOS 26.0 simulator, selected explicitly using the UDID supplied privately by the user, except for this task's explicit two-Web-instance request. Do not publish the local device identifier or substitute an Android or other simulator without new authorization. This project currently targets Android and Web.
