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

## Android status

Android has native method-channel scaffolding for:
- device admin requests
- lock-task / screen pinning
- unlock / relock flow

But Android still needs broader real-device validation before being called production-complete.

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
