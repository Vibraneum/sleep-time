# Sleep Time

A cross-platform sleep enforcement app that locks your device at bedtime, with an AI guardian you must negotiate with to get screen time back.

## Architecture

- **Flutter** — cross-platform (Windows desktop + Android APK)
- **Gemini 2.5 Flash** — the guardian AI, called via `google_generative_ai` package
- **SQLite** (via `sqflite`) — local memory: negotiation history, conversation logs, sleep compliance
- **Poke API** — optional notification channel (Telegram)
- **Platform channels** — native lockdown (Windows: registry + window_manager, Android: Device Admin + kiosk mode)

## Project Structure

```
lib/
├── main.dart                    # Entry point, config loading, window setup
├── core/
│   ├── config.dart              # Schedule, API keys
│   ├── negotiation_engine.dart  # Gemini conversation + autonomous decision parsing
│   ├── memory_service.dart      # SQLite persistence
│   ├── lockdown_scheduler.dart  # State machine: inactive → wind_down → locked → granted → unlocked
│   └── poke_service.dart        # Poke notifications
├── ui/
│   ├── home_screen.dart         # Dashboard
│   ├── lockdown_screen.dart     # Full-screen lock overlay
│   ├── negotiation_chat.dart    # Chat UI
│   └── settings_screen.dart     # Configuration
├── platform/
│   ├── windows_lockdown.dart    # Windows native lockdown
│   └── android_lockdown.dart    # Android native lockdown
assets/prompts/
└── personality.md               # Guardian personality definition
```

## Schedule

- **10:30 PM** — guardian wakes up, monitors activity
- **11:00 PM** — tells user to wind down, start wrapping up
- **11:30 PM** — lockdown mode, screen locked
- **6:00 AM** — lockdown lifts
- All times configurable in settings

## Guardian Autonomy

The AI guardian has FULL agency over granting/denying time. No hard limits on minutes or number of grants. The agent evaluates each request based on:
- Urgency and legitimacy of the reason
- Past negotiation history and patterns
- Current compliance rate
- Time of night (harder to convince at 2 AM than 11:30 PM)

## Commands

```bash
flutter run -d windows          # Run on Windows
flutter build windows           # Build Windows exe
flutter build apk               # Build Android APK
flutter analyze                 # Static analysis
```

## Environment

Copy `.env.example` to `.env` and fill in your API keys. Keys can also be set in the app's settings screen.

## Design

UI follows Poke's design language: light backgrounds, rounded cards, clean sans-serif typography, subtle shadows, spacious layout.
