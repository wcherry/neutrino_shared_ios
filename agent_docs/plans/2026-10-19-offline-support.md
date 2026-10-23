# Plan: Better offline support in the mobile apps

## Summary
Every mobile app decides for itself what "offline" looks like: Docs, Notes and Calendar queue
edits and drain them with backoff, but only Notes' editor and Calendar say so on screen; Photos has
its own upload banners; Drive, Sheets and Slides say nothing until a request fails; no API client
retries a transient failure; and Android has a copy of the connectivity callback in each app. This
change puts the shared pieces in the two shared libraries — a connectivity/sync banner, a retry
policy for transient request failures, and (Android) one `NetworkMonitor` — and wires them into
every app. Offline *editing* for Sheets and Slides (an outbox like Docs') is out of scope and is the
follow-up.

## Affected Repos (branch `feature/offline-support` in each)
- neutrino_shared_ios — `NeutrinoCore`: `RetryPolicy` + `URLSession.data(for:retry:)`,
  `SyncActivity` and `ConnectivityBannerState` (pure, tested). `NeutrinoUI`: `ConnectivityBanner`
  view and `.connectivityBanner(...)` modifier.
- neutrino_shared_android — `neutrino-core`: `RetryPolicy`, retry inside `NeutrinoApi.send`,
  `SyncActivity`/`ConnectivityBannerState`. `neutrino-android`: `NetworkMonitor`,
  `ConnectivityBanner` composable.
- neutrino_docs_ios_mobile, neutrino_notes_ios_mobile, neutrino_calendar_ios_mobile — banner fed
  by the existing sync engine / pending writes (offline, syncing N, failed + Retry, back online);
  retries in the request funnels.
- neutrino_photos_ios_mobile, neutrino_drive_ios_mobile, neutrino_sheets_ios_mobile,
  neutrino_slides_ios_mobile — `NetworkMonitor` where missing, offline banner ("showing what's on
  this device"), retries in the request funnels.
- neutrino_docs_android_mobile (local only, no remote), neutrino_calendar_android_mobile,
  neutrino_drive_android_mobile — shared `NetworkMonitor` replaces the per-app callback; banner fed
  by the sync engine / pending writes / upload queue.

## Tasks
1. iOS `RetryPolicy`: which errors and statuses are transient, backoff with jitter, `Retry-After`,
   idempotent methods only by default (a retried PUT whose first response was lost would come back
   as a false content-version conflict).
2. iOS `ConnectivityBannerState.resolve(...)` — the copy and the Retry affordance as a pure function.
3. iOS `ConnectivityBanner` view, including the transient "Back online".
4. Android equivalents of 1–3, retry wired into `NeutrinoApi.send`.
5. Each app: mount the banner at the root, feed it, replace `session.data(for:)` in the funnels.

## Test Plan
- Unit: `RetryPolicyTests` / `RetryTest` (transient classification, attempts, Retry-After, methods),
  `ConnectivityBannerStateTests` (every state's copy and retry flag). Each app's existing suite.
- Build every dependent app (xcodegen + xcodebuild; `./gradlew :core:test :app:assembleDebug`).
- E2E: none — no server or web change.

## Open Questions
- Sheets/Slides offline editing (outbox + conflict-safe drain) — next change.
