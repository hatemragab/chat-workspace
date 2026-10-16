# Agent Instructions

## Scope and authorization

This workspace contains the approved specifications and the NestJS backend (`backend/`) and Flutter Android/Web app (`mobile_and_web/`). Inspect their current manifests and source before relying on tooling or implementation claims.

The user has explicitly authorized the full backend and Flutter implementation, all five roadmap phases, fixes to required local tooling/services, automated tests, and verification in two independent Flutter Web sessions using computer use. This supersedes the earlier documentation-only boundary. Continue through the approved implementation and verification work without requesting phase-by-phase approval. For later tasks, work only within their requested scope; roadmap prompts alone are not permission to start new work.

The user has approved the current specifications and closed the earlier review suggestions. Follow the current files; do not reintroduce earlier architectural proposals or rewrite the approved design without a new user request. Documentation approval is not evidence of runtime correctness.

Do not commit, push, publish, deploy, delete data, or make destructive infrastructure changes without explicit user authorization. Preserve unrelated changes, private files, and generated artifacts. Never expose or commit secrets, credentials, environment files, uploaded media, local databases, or personal data.

## Read before working

Read these documents in order, then inspect any applicable nested `AGENTS.md`, README, manifests, configuration, and relevant source files that exist:

1. [CONTEXT.md](CONTEXT.md): workspace structure and synchronization contract.
2. [BACKEND_SPEC.md](BACKEND_SPEC.md): schemas, indexes, transactions, Redis Lua, APIs, authorization, and receipts.
3. [FLUTTER_SPEC.md](FLUTTER_SPEC.md): dependencies, local storage, synchronization, and UI behavior.
4. [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md): five implementation phases and their verification requirements.

The latest explicit user instruction takes precedence. This guide does not replace or amend the approved specifications. Use the roadmap for sequencing and the specifications for behavior. If a contradiction or missing requirement prevents a safe implementation, ask a focused question instead of silently changing the contract. Otherwise, make reasonable decisions within the approved design.

## Approved architecture

- Backend: NestJS, Mongoose, MongoDB replica-set transactions, ioredis with atomic Lua updates, Multer, and Centrifugo v6. Flutter targets Android and Web, with Riverpod and Drift.
- Use the existing local MongoDB, Redis, and Centrifugo services described in `CONTEXT.md`; do not introduce Docker. Verify availability when relevant to an authorized task rather than assuming the documented services are running.
- All client mutations use REST. Personal realtime channels use exactly `inbox:user#<userId>`.
- Redis retains the latest hydrated room state per user and room. The approved design does not store a per-message event log in MongoDB or Centrifugo. Follow the specified MongoDB transaction, post-commit Redis Lua update, and Centrifugo retry flow.
- Keep `pts`, `roomPts`, `msgPts`, and `lastHistoryEditPts` distinct. Follow the event-specific update rules. Preferences do not advance `msgPts`; only new messages advance an existing room's `sortTimestamp`.
- Keep `room_unread_cleared`, `room_peer_seen`, and `room_delivered` separate. Clearing the reader's unread badge must not mark their outgoing messages seen.
- Preserve lazy direct-room creation, sender-scoped send idempotency, the partial direct-pair index, membership checks, upload validation, and the documented compound pagination cursors.

## Flutter contract

- Follow the specified Flutter/Dart constraints, dependencies, and exported widget names. Search existing code before adding widgets or utilities; reuse dependencies and the established Riverpod structure.
- Keep the approved single `chat_app_db` database, logout/account-switch cleanup, and session-generation handling.
- Serialize inbox processing through `InboxSyncQueue`. REST mutation responses may reconcile resources but must never advance `SyncMetadata.localPts` directly. Apply inbox data and cursor changes atomically in Drift.
- Perform inbox synchronization on login/startup, subscription/reconnection, resume, and detected gaps. Finish inbox reconciliation before using `msgPts == messagesSyncedPts` to skip message requests.
- Follow the specified full-sync reset, message-window overlap/history-edit rules, draft room IDs, interrupted-send recovery, and two-tier reply jump. Keep the in-memory jump view responsive to live edits and deletions.

## Implementation and validation when authorized

Make the smallest complete change. Follow existing naming and architecture, use strongly typed TypeScript and null-safe Dart, preserve compatibility, and avoid unrelated refactors or unnecessary packages. Validate inputs, authorization, asynchronous failures, and relevant loading/error states. Add or update tests for meaningful behavior changes.

Verify each phase's acceptance criteria before advancing within the authorized scope. Derive backend formatter, lint, type-check, test, and build commands from the actual manifests once they exist; do not invent scripts. For Flutter changes, run `dart format`, `flutter analyze`, relevant Flutter tests, and applicable builds. Review the final diff and fix failures caused by the change.

For documentation-only work, check document consistency, relative links, and changed-file scope. Do not install tooling or scaffold code merely to run checks.

## Device/UI testing restriction

When the user asks to test an app, use only the existing **iPhone 17 Pro, iOS 26.0** simulator, explicitly selected with the UDID supplied privately by the user. Do not publish the local device identifier. Do not select another device/runtime or create/download a replacement without an explicit user change.

For the current implementation task, the user's newer explicit request authorizes two Flutter Web instances and browser UI testing. This is a task-specific exception; it does not authorize other simulators/devices or adding iOS support. For other app-testing requests, if the permitted simulator is unavailable or unsupported, report the blocker. Unit tests and static analysis may continue.

## Completion report

Report a concise summary, main files changed, actual validation commands and results, and remaining limitations or blockers. Distinguish document review, static/unit checks, live-service checks, and device/UI evidence. Never claim an unrun command passed or describe planned functionality as implemented.
