# Current State

## Summary

Sleep Time is currently a Windows-first Flutter bedtime-boundary app with:
- scheduled wake / wind-down / lockdown phases
- AI negotiation using Gemini or Anthropic
- BYOK support
- optional Concierge Gemini fallback via build-time configuration
- local persistence for memories, negotiations, and compliance data
- best-effort Windows lockdown behavior
- scaffolded Android lockdown hooks

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
