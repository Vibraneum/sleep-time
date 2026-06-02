# Current State

## Summary

Sleep Time is currently a Windows-first Flutter bedtime-boundary app with:
- scheduled wake / wind-down / lockdown phases backed by a reactive, persisted
  schedule store (Settings and AI changes apply live and survive restarts)
- AI negotiation via a real Claude **tool-calling** guardian (Anthropic Sonnet,
  4-tool set, one decision per turn, prompt-cached) with Gemini as a quarantined
  text-parsing fallback
- an AI-adjustable schedule gated by anti-manipulation guardrails
- per-app selective unlock on Windows (free specific apps for N minutes while the
  rest of the desktop stays blocked)
- a sibling watchdog process that relaunches the app if killed while locked
- BYOK support and an optional Concierge Gemini fallback via build-time config
- local persistence for memories, negotiations, compliance, and a schedule-change
  audit log
- best-effort, event-driven Windows lockdown behavior (low idle CPU)
- scaffolded Android lockdown hooks (native background app is the next milestone)

## What is production-ready enough to use now

- Flutter app boot flow
- first-run setup flow
- settings management
- provider switching between Gemini and Anthropic
- local storage on Windows via `sqflite_common_ffi`
- manual GitHub release pipeline
- Windows portable build
- Windows installer generation via Inno Setup

## What Windows lockdown does today

The app currently attempts to:
- enter fullscreen
- stay always on top
- prevent normal close flow
- hide from the taskbar
- periodically refocus itself
- best-effort disable some shell shortcuts and policies through registry writes
- best-effort stop Explorer during active lockdown in release mode
- restore Explorer and related state on unlock
- restore system state on next startup if the prior session crashed mid-lockdown

## What Windows lockdown does not guarantee

This is not a kernel-level or enterprise-grade kiosk lockdown.

It does **not** guarantee prevention of:
- secure attention paths like `Ctrl+Alt+Del`
- local administrator bypass
- safe-mode or advanced-user escape paths
- determined process-kill / policy-reset scenarios

## Practical interpretation

Today, Sleep Time should be understood as a **best-effort friction app** on Windows:
- strong enough to stop casual bedtime drift
- not strong enough to claim anti-tamper security

## Safe mode

The app now ships with a **safe mode** flag (`AppConfig.simulateLockdown`).

When safe mode is on:
- the lockdown UI still flows end-to-end (locked → negotiate → granted → unlocked)
- no fullscreen takeover, no always-on-top, no `prevent close`, no refocus loop
- no Windows registry writes, no startup registration, no PowerShell guardian
- no Android Device Admin / lock-task method-channel calls
- a small "SAFE MODE — simulated lockdown" banner appears on the lockdown screen

Resolution order on app start:
1. `--dart-define=SIMULATE_LOCKDOWN=true|false` if provided
2. previously-saved user preference (`Settings → Platform + Notifications`)
3. debug builds default to ON, release builds default to OFF

`runAtStartup` is now off by default and is force-disabled while safe mode is on.

## Android status

Android has native method-channel scaffolding for:
- device admin requests
- lock-task / screen pinning
- unlock / relock flow

The manifest now also declares the runtime permissions a real mobile build needs:
- `WAKE_LOCK` (keep the screen on during lockdown)
- `POST_NOTIFICATIONS` (Android 13+ runtime notification gate)
- `USE_FULL_SCREEN_INTENT` (high-priority lockdown alert)
- `FOREGROUND_SERVICE_SPECIAL_USE` (Android 14+ typed FGS)
- `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` (future exact-alarm scheduler)

Still missing for production on Android:
- a persistent foreground service so the scheduler keeps firing after the app is backgrounded / evicted
- exact-alarm scheduling for wake / wind-down / lockdown / unlock transitions
- the in-app `POST_NOTIFICATIONS` runtime prompt

iOS is not yet supported (no `ios/` runner). A real iOS port would need to use the Screen Time API rather than try to emulate the Windows model.

## AI/provider status

Implemented:
- Gemini support
- Anthropic support
- BYOK
- Concierge Gemini build-time fallback
- model selection in settings

Still desirable later:
- richer retries / backoff
- clearer rate-limit UX
- provider-specific error normalization
- deeper tests around malformed model output

## Test status

Passing now:
- `flutter analyze`
- `flutter test`
- `flutter build windows --release`

Coverage is still modest. Most important future test expansions:
- scheduler edge cases around midnight
- negotiation parsing edge cases
- Windows-specific recovery / restore behavior

## Release/distribution status

The repo now includes:
- CI
- manual release workflow
- changelog
- contributing guide
- code of conduct
- security policy
- Windows installer script

## Near-term priorities

1. strengthen Windows recovery and optional watchdog support
2. deepen scheduler / parser test coverage
3. add code-signing guidance for Windows releases
4. validate Android behavior on real devices
5. document the Windows threat model clearly for contributors and users

## Android (Play-compliant) architecture — M4

The Android background layer was rebuilt to be Google Play–compliant. The old
Device Admin + kiosk (lockTask / screen-pinning) approach was removed entirely
(guaranteed Play rejection). The new backstop is a foreground service driven by
exact alarms, with WorkManager-based boot recovery.

### Components (Kotlin, `android/app/src/main/kotlin/com/vedastro/sleep_time/`)
- `SleepGuardianService` — a `specialUse` foreground service. Posts a persistent
  low-importance notification ("Sleep Time is watching your bedtime") and
  re-derives state on each alarm. Alarm-driven, never a busy loop. Carries a
  "Turn off" notification action (FGS dismissability). Honors safe mode: when
  `flutter.simulate_lockdown` is true it only notifies, never escalates. The M5
  escalation seam (overlay / per-app blocking) is marked but empty.
- `SleepScheduleStore` — reads the 8 schedule ints + the simulate flag from the
  `FlutterSharedPreferences` prefs file. `shared_preferences` prefixes every key
  with `flutter.` and stores Dart ints as `Long`, so values are read via
  `getLong(...).toInt()` with a defensive `getInt` fallback. Also holds the
  wrap-aware window logic mirroring Dart's `AppConfig`.
- `SleepAlarmScheduler` — schedules WIND_DOWN / LOCK / UNLOCK alarms. Guards
  exact alarms with `canScheduleExactAlarms()` (API 31+): uses
  `setExactAndAllowWhileIdle()` when allowed, else the idle-resilient inexact
  `setAndAllowWhileIdle()` and persists a `degraded` flag for Dart to surface.
  `rescheduleAll()` recomputes from the live schedule.
- `AlarmReceiver` — on each alarm, re-arms the next day's occurrence (+24h) and
  asks the service to re-evaluate.
- `BootReceiver` — on BOOT_COMPLETED / LOCKED_BOOT_COMPLETED enqueues an
  expedited WorkManager job (does NOT start a specialUse FGS directly — banned
  on Android 15).
- `GuardianBootWorker` — re-arms alarms and starts the service only if currently
  inside the lockdown window.
- `MainActivity` — MethodChannel `com.vedastro.sleep_time/lockdown` +
  EventChannel `com.vedastro.sleep_time/lockdown_events`. All Device Admin /
  lockTask code removed.

### Channel surface
- MethodChannel methods: `ping`, `startGuardian`, `stopGuardian`,
  `getPermissionStatus`, `setSchedule`, `requestExactAlarm`,
  `requestNotifications`, `requestBatteryExemption`, plus M5 stubs
  `requestOverlay` / `requestUsageAccess` / `allowApp` (return false).
- EventChannel payload: `{state, grantExpiresAt, degraded}` broadcast from the
  service via LocalBroadcastManager.

### Dual-run model
The native service is the **background** authority (alarms + notification +
background transitions). The Dart `LockdownScheduler` keeps driving the **in-app
UI**. They run in parallel; safe mode short-circuits platform effects on both
sides, so they never double-escalate.

### Manifest / Gradle
- Removed: `USE_EXACT_ALARM`, `USE_FULL_SCREEN_INTENT`, the
  `SleepDeviceAdminReceiver`, `device_admin.xml`, and `android:lockTaskMode`.
- Kept: `SCHEDULE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`, `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_SPECIAL_USE`, `POST_NOTIFICATIONS`, `WAKE_LOCK`,
  `INTERNET`, `SYSTEM_ALERT_WINDOW` (for M5). Added
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
- `build.gradle.kts`: `minSdk = 26`, `targetSdk = 35`; release signing reads
  `android/key.properties` when present, else falls back to debug signing so
  `flutter build apk` always works. `key.properties` / keystores are gitignored.

### Deferred to M5
- The full-screen overlay, AccessibilityService, per-app blocking, usage-access
  reads, and the permission-onboarding UI. The seams (SYSTEM_ALERT_WINDOW perm,
  the escalation no-op in the service, the `requestOverlay` / `requestUsageAccess`
  / `allowApp` stubs) are left clean.
- The `full` sideload flavor (broader-permission build) is a later milestone.

### Play declarations required (at submission time)
- A specialUse FGS justification (the manifest `<property>` subtype string is
  already in place: "Enforces a user-configured bedtime lock schedule while the
  app is backgrounded.").
- Data Safety form entries for any data collected.
- An exact-alarm justification (alarm-driven bedtime schedule) since
  `SCHEDULE_EXACT_ALARM` is declared.

### Unverified — pending device QA
Runtime behavior cannot be tested in this environment. Deferred to on-device QA:
alarm firing accuracy, boot recovery, Doze survival of `setAndAllowWhileIdle`,
the FGS 10s `startForeground` window, notification "Turn off" action, and the
EventChannel state mirroring.
