# Changelog

All notable changes to this project should be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

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
