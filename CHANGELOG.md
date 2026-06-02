# Changelog

All notable changes to this project should be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added
- real Anthropic tool-calling guardian (Claude Sonnet): a minimal 4-tool set
  (`guardian_action`, `unlock_app`, `adjust_schedule`, `end_session`) so the
  guardian emits exactly one structured decision per turn in a single
  prompt-cached request — no more fragile "JSON on the last line" parsing
- AI-adjustable schedule: the guardian can move bedtime/wake via `adjust_schedule`,
  hard-clamped by anti-manipulation guardrails (bedtime envelope, ±60 min nudge,
  +90 min/night cap, max 3 edits/night, no edit to an active lockdown, "tonight"
  nudges auto-revert each morning) so it can't be talked out of bedtime
- reactive, persisted schedule store — Settings and AI changes propagate live and
  survive restarts; grant state now survives a crash (no instant re-lock)
- per-app selective unlock on Windows: the guardian can free specific apps for N
  minutes (corner countdown HUD) while everything else stays blocked
- sibling watchdog process (`sleep_time_watchdog.exe`) that relaunches the app if
  it is killed while locked (best-effort, never runs in safe/simulate mode)
- Capabilities seam for the future Play-compliant / sideload Android build flavors

### Changed
- Windows refocus is now event-driven (`SetWinEventHook`) instead of a 500 ms Dart
  timer + 150 ms PowerShell loop — markedly lower idle CPU/battery
- lockdown IPC moved to `%LOCALAPPDATA%\SleepTime\state\lock.json`
- default Anthropic model is now `claude-sonnet-4-5`
- Gemini is retained as a quarantined text-parsing fallback (no typed tool use)

## [1.0.0] - 2026-04-11

### Added
- guardian AI actions: minimize, close, unlock — the AI controls the app, not the user
- full unlock mode: guardian can lift lockdown for the rest of the night
- startup cleanup: restores system state if app crashed during lockdown
- AI provider selection between Gemini and Anthropic
- BYOK support for end users
- Concierge Gemini fallback key support via build-time environment
- manual Windows release workflow
- open source project docs: license, code of conduct, security policy

### Changed
- removed registry lockdown (DisableTaskMgr, NoWinKeys, etc.) — too dangerous on crash
- removed explorer kill — desktop stays intact even during lockdown
- lockdown now relies on fullscreen + always-on-top + refocus timer + PowerShell guardian
- scheduler and negotiation flow hardened for more edge cases
- settings expanded for provider and model management

### Fixed
- release build crash caused by duplicate setSkipTaskbar call in activate()
- home-screen overflow in tests and smaller windows
- unlock and schedule formatting issues
- missing graceful handling for absent AI keys
- platform lockdown wiring from scheduler state
- nightly logging duplicate protection

## [0.1.0] - 2026-04-10

### Added
- initial Flutter app structure for Windows and Android
- lockdown, negotiation, memory, and compliance foundations
