# Sleep Time

Sleep Time is a Flutter app that helps people enforce a bedtime boundary.

It combines:
- a scheduled wake / wind-down / lockdown flow
- a persistent negotiation history
- a "sleep guardian" chat that can decide whether extra time is justified
- platform-specific enforcement hooks for Windows and Android

## Project status

This is now set up as an open source project with:
- CI
- manual release workflow
- contributing docs
- security policy
- changelog
- release drafting support

## Core features

- configurable wake, wind-down, lockdown, and unlock times
- Windows lockdown helpers: fullscreen, always-on-top, prevent-close, skip-taskbar
- Android lockdown hooks: device-admin + lock-task channel scaffolding
- Gemini support
- Anthropic support
- BYOK support for end users
- optional Concierge Gemini default key via build-time environment
- local persistence with `sqflite`
- compliance tracking
- negotiation transcript storage

## AI provider setup

The app supports two modes:

### 1. Concierge Gemini default

The app build can provide a default Gemini key:

```bash
flutter run --dart-define=CONCIERGE_GEMINI_API_KEY=your_key_here
```

Users can then use that bundled key unless they enable BYOK in Settings.

### 2. Bring your own key

Users can switch providers and supply their own keys in Settings:
- Gemini API key
- Anthropic API key

Optional runtime defines:

```bash
flutter run \
  --dart-define=GEMINI_API_KEY=your_gemini_key \
  --dart-define=ANTHROPIC_API_KEY=your_anthropic_key \
  --dart-define=POKE_API_KEY=your_poke_key
```

## Development

```bash
flutter pub get
flutter analyze
flutter test
```

## Windows notes

Windows support is designed to be practical and scalable for desktop distribution, but it is still best-effort enforcement, not anti-tamper security.

Current Windows behavior includes:
- always-on-top window management
- fullscreen lockdown
- prevent-close integration
- taskbar hiding during lockdown
- release packaging through GitHub Actions

## Android notes

Android support depends on device-admin / lock-task support and OEM behavior.

## Releases

Releases are manual by design.

Use the GitHub Actions **Manual Release** workflow and provide a version like `0.1.0`.
That workflow will:
- run analyze + test
- optionally create the tag
- build the Windows release artifact
- publish the GitHub Release

## Security notes

- Do not commit real API keys.
- `.env` files are ignored.
- Windows enforcement can be bypassed by determined local administrators.
- See `SECURITY.md` for reporting guidance and threat-model limits.

## Repository docs

- `CONTRIBUTING.md`
- `CHANGELOG.md`
- `SECURITY.md`
- `CODE_OF_CONDUCT.md`
- `REVIEW.md`
