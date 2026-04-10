# Changelog

All notable changes to this project should be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added
- AI provider selection between Gemini and Anthropic
- BYOK support for end users
- Concierge Gemini fallback key support via build-time environment
- manual Windows release workflow
- open source project docs: license, code of conduct, security policy

### Changed
- scheduler and negotiation flow hardened for more edge cases
- settings expanded for provider and model management
- README updated for open source distribution and manual releases

### Fixed
- home-screen overflow in tests and smaller windows
- unlock and schedule formatting issues
- missing graceful handling for absent AI keys
- platform lockdown wiring from scheduler state
- nightly logging duplicate protection

## [0.1.0] - 2026-04-10

### Added
- initial Flutter app structure for Windows and Android
- lockdown, negotiation, memory, and compliance foundations
