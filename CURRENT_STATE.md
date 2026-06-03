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
- enter fullscreen, stay always on top, and prevent the normal close flow
- block a low-level keyboard hook (Win / Alt+Tab / Alt+F4 / Esc combos)
- reclaim focus **event-driven** via `SetWinEventHook` on the foreground event
  (no busy polling loop — near-zero idle CPU; replaced the old 500 ms Dart timer
  and 150 ms PowerShell guardian)
- run a sibling **watchdog process** that relaunches the app if it is killed while
  locked (never spawned in safe mode)
- **selectively** allow specific approved apps for a limited grant while blocking
  the rest of the desktop (corner countdown HUD)
- restore system state on next startup if the prior session crashed mid-lockdown

It no longer writes shell-policy registry keys or kills Explorer (both were removed
as too dangerous on crash).

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

> Superseded by the **Android (Play-compliant) architecture — M4** and
> **Android M5** sections below. The old Device Admin + lock-task / screen-pinning
> scaffolding has been **removed entirely** (guaranteed Play rejection). Android
> no longer uses any device-admin or kiosk APIs.

The Android background layer is now a `specialUse` foreground service driven by
exact alarms (M4), with a Play-compliant per-app lock overlay backed by
UsageStats as the primary foreground-app detector (M5). See those sections for
detail.

iOS is not yet supported (no `ios/` runner). A real iOS port would need to use the Screen Time API rather than try to emulate the Windows model.

## AI/provider status

Implemented:
- **Anthropic Claude tool-calling guardian** (default `claude-sonnet-4-5`): a 4-tool
  set (`guardian_action`, `unlock_app`, `adjust_schedule`, `end_session`), one
  decision per turn, prompt-cached, tool_result-first content-block history — no
  more JSON-on-the-last-line parsing
- Gemini retained as a quarantined text-parsing fallback (the pinned package can't
  do typed tool use)
- BYOK + Concierge Gemini build-time fallback + model selection in settings

Still desirable later:
- richer retries / backoff and clearer rate-limit UX
- deeper tests around malformed model output

## Test status

Passing now (all independently verified):
- `flutter analyze` (clean)
- `flutter test` (150 tests)
- `flutter build windows --release` (produces both `sleep_time.exe` and
  `sleep_time_watchdog.exe`)
- `flutter build apk --debug`

Coverage is meaningfully expanded (schedule validation + guardrails, tool-use
mapping + request/history shape, store/audit, selective-unlock gating, overlay/
onboarding logic). Most valuable next expansions:
- on-device Android QA (alarm firing, Doze, overlay, boot recovery, battery)
- on-device Windows enforcement QA on a throwaway account (kill-recovery, focus
  reclaim, selective allow)
- native (Kotlin/C++) unit/instrumentation tests

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

1. on-device QA: Android (alarms/Doze/overlay/boot/battery) and Windows enforcement
   on a throwaway account (kill-recovery, focus reclaim, selective allow)
2. obtain a code-signing certificate and sign the Windows binaries + installer
3. product sign-off on the schedule guardrail envelope/cap constants
   (`lib/core/schedule_guardrails.dart`)
4. Play Console submission (declarations + demo videos per `docs/PLAY_SUBMISSION.md`)
5. the `full` sideload Android flavor (broader permissions) behind the Capabilities seam
6. native (Kotlin/C++) unit + instrumentation tests

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
- MethodChannel methods (M4): `ping`, `startGuardian`, `stopGuardian`,
  `getPermissionStatus`, `setSchedule`, `requestExactAlarm`,
  `requestNotifications`, `requestBatteryExemption`. The former M5 stubs
  (`requestOverlay` / `requestUsageAccess` / `allowApp`) are now implemented;
  see the **Android M5** section for the full M5 channel surface.
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

### Deferred to M5 — now DONE
- The full-screen overlay, optional AccessibilityService, per-app blocking,
  usage-access reads, and the permission-onboarding UI all landed in M5 (see the
  **Android M5** section). The `full` sideload flavor (broader-permission build)
  is still a later milestone.

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

## Android M5 — per-app selective unlock + adjustable overlay + onboarding

M5 adds the Play-compliant enforcement layer on top of the M4 backstop: a lock
overlay over disallowed apps, a user-approved per-app unlock, and a permission
onboarding flow. **The whole design keeps UsageStats as the primary
foreground-app detector; the AccessibilityService is an optional, removable
latency enhancement.**

### Native (Kotlin)
- `ForegroundAppWatcher` — **PRIMARY** detector. Polls
  `UsageStatsManager.queryEvents` (~1s) for the current foreground package. Runs
  ONLY while the guardian is actively enforcing (locked / active grant), never as
  a standing loop. `hasUsageAccess()` gates it; degrades gracefully when not
  granted.
- `AllowListManager` — persisted, time-limited per-app allow-list
  (`package → expiry`). Persists into the SAME `FlutterSharedPreferences` blob
  (`flutter.app_allowlist`) and JSON shape as Dart's `AppAllowlist`. Own package
  and the default launcher are ALWAYS allowed. `isAllowed` / `allow` /
  `activeEntries` / `purgeExpired` / `nextExpiryMillis`.
- `OverlayController` + `res/layout/overlay_lockdown.xml` +
  `res/layout/overlay_banner.xml` — `TYPE_APPLICATION_OVERLAY` full-screen block
  (with an "Open Sleep Time" button that brings `MainActivity` forward) and a
  slim grant countdown banner. Holds a screen wake lock ONLY while an overlay is
  visible. **Fallback:** if adding/showing the overlay fails (e.g.
  `setHideOverlayWindows`, OEM refusal, or no permission) it brings
  `MainActivity` to front instead, so the lock is never silently bypassed.
- `SleepAccessibilityService` + `res/xml/accessibility_service_config.xml` —
  OPTIONAL. `typeWindowStateChanged` only, 500ms debounce, observe-only,
  `canRetrieveWindowContent=false`, **NOT `isAccessibilityTool`**. It only feeds
  the observed package into the same (UsageStats-primary) evaluation path faster.
  The evaluation logic does not depend on it; it works disabled or revoked.
- `SleepGuardianService` — the M4 escalation seam is now filled. While locked and
  NOT in safe mode it arms the watcher; for each foreground app it shows the full
  block (disallowed) or the countdown banner (allowed app during an active
  grant), re-blocking on expiry. Safe mode still escalates nothing.

### Channel surface (M5 additions in `MainActivity`)
- `requestOverlay` (`ACTION_MANAGE_OVERLAY_PERMISSION`),
  `requestUsageAccess` (`ACTION_USAGE_ACCESS_SETTINGS`),
  `requestAccessibility` (`ACTION_ACCESSIBILITY_SETTINGS`),
  `allowApp({package,label,minutes})`,
  `listInstalledApps` (`getInstalledApplications(0)`, launchable user apps,
  **no `QUERY_ALL_PACKAGES`**), `deviceManufacturer`.
- `getPermissionStatus` now reports real `overlay` / `usageAccess` /
  `accessibility` booleans. `onResume` pushes a fresh status to Dart via
  `onPermissionStatusChanged`.

### Dart
- `lib/ui/overlay/overlay_size.dart` — `OverlaySize {full, banner, mini}` +
  pure `OverlaySizing.select(...)`.
- `lib/ui/overlay/overlay_shell.dart` — reusable shell rendering lockdown content
  at the chosen size; `lockdown_screen.dart` uses it for the granted view
  (full-grant fold-to-corner mini + per-app grant view with the app name,
  remaining time, and a "back to sleep early" action). Red is reserved for the
  final 2-minute countdown only.
- `lib/ui/overlay/guardian_copy.dart` — time-of-night warm copy table
  (gentler near bedtime, firmer in the small hours).
- `lib/ui/permissions_onboarding_screen.dart` — stepped flow: notifications →
  overlay → usage-access (REQUIRED) → exact-alarm → battery (warn only) →
  Accessibility (OPTIONAL, with the MANDATORY prominent-disclosure dialog before
  the redirect). Hard gates (`PermissionGating.hardGates`): overlay + usage-access
  + exact-alarm. Re-checks on resume. Best-effort OEM battery hints by
  `Build.MANUFACTURER` (Samsung / Xiaomi / OnePlus), falling back to the generic
  battery dialog. Reachable from Settings and shown as a first-run gate.
- `lib/core/permission_gating.dart` — pure gating logic (hard gates, `canFinish`).
- `lib/core/negotiable_apps.dart` — `NegotiableAppStore`: the user-approved set
  of apps the guardian MAY unlock. `unlock_app` on Android is constrained to this
  set (resolve by package or friendly label; unapproved → degrade to a normal
  timed grant, never silently allow).
- `lib/ui/allowlist_editor_screen.dart` — Settings editor for the approved set,
  populated from `listInstalledApps`. Entry point added in `settings_screen.dart`;
  the stale "device-admin and lock-task" copy was rewritten to the
  overlay/usage-access framing.

### How `unlock_app` is constrained
The guardian tool can name any app, but on Android the unlock path
(`_onUnlockAppAndroid` in `lockdown_screen.dart`) only proceeds if
`NegotiableAppStore.resolve(identifier)` matches a user-approved app. Otherwise it
degrades to a plain timed grant. The native `AllowListManager` is only ever told
to allow a resolved, approved package.

### Tests (no device)
`test/overlay_size_test.dart`, `test/guardian_copy_test.dart`,
`test/permission_gating_test.dart`, `test/negotiable_apps_test.dart` cover
overlay-size selection, time-bucketing, onboarding hard-gate logic
(incl. the "works with accessibility disabled" invariant), and approved-app
persistence + label→package resolution. All existing tests stay green.

### Play declarations (see docs/PLAY_SUBMISSION.md)
specialUse FGS + demo; the Accessibility declaration (category Digital
Wellbeing) + demo + that it is optional; the prominent-disclosure requirement;
Data Safety (local app-usage data + chat messages sent to Anthropic/Gemini); the
sensitive-permission table with justifications; explicitly NO `QUERY_ALL_PACKAGES`
and `isAccessibilityTool` NOT set.

### Unverified — pending device QA (M5)
- Overlay actually drawing over a third-party app; the `setHideOverlayWindows`
  fallback path; wake-lock acquire/release timing.
- UsageStats foreground detection accuracy and the ~1s poll latency vs. the
  accessibility fast-path.
- The system permission redirects (overlay / usage-access / accessibility) and
  the `onResume` status refresh round-trip.
- OEM battery deep-link behavior on Samsung/Xiaomi/OnePlus.
- AllowList expiry → re-block transition and the banner countdown.

### Follow-ups for M6
- A `full` sideload flavor with broader enforcement (the M4-noted broader-perms
  build).
- Native unit/instrumentation tests for `AllowListManager` ISO round-trip and the
  `ForegroundAppWatcher` event parsing.
- Tighten the overlay UX (animations, accessibility of the overlay itself) and
  consider a per-grant "extend" affordance from the banner.
