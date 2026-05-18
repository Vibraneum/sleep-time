# Sleep Time

A bedtime enforcer for Windows. Locks your screen at a set time. An AI guardian decides whether your reason for more time is good enough.

> **Best-effort enforcement, not anti-tamper security.** A determined local administrator can bypass it. The goal is friction, not a cage.

---

## Download and use (Windows)

1. Go to [Releases](https://github.com/Vibraneum/sleep-time/releases/latest)
2. Download `sleep-time-windows-setup-vX.X.X.exe` (installer) or the `.zip` (portable)
3. Run the installer — Windows may show a SmartScreen warning since the app is unsigned; click **More info → Run anyway**
4. On first launch, enter a [Gemini API key](https://aistudio.google.com/apikey) (free tier works)
5. Set your sleep schedule in Settings and leave the app running

That's it. The app sits in the background and locks the screen at your configured time.

---

## How it works

- **10:30 PM** — guardian wakes up, monitors activity
- **11:00 PM** — wind-down notice
- **11:30 PM** — screen locks
- **6:00 AM** — lockdown lifts automatically

All times are configurable in Settings.

When locked, you can tap **Negotiate** to chat with the AI guardian. It has full autonomy — it reads your request, checks your history, and decides whether to grant you extra time or not. It will get harder to convince the more you push.

---

## AI provider setup

The app supports two providers. Pick one:

### Gemini (default)

Get a free key at [aistudio.google.com](https://aistudio.google.com/apikey). Enter it in Settings → AI Provider.

### Anthropic Claude

Get a key at [console.anthropic.com](https://console.anthropic.com). Switch providers in Settings → AI Provider.

---

## Build from source (Windows)

### Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install/windows/desktop) — stable channel, 3.x
- [Visual Studio 2022](https://visualstudio.microsoft.com/) with the **Desktop development with C++** workload
- Windows 10 or 11

### Run in development

```bash
git clone https://github.com/Vibraneum/sleep-time.git
cd sleep-time
flutter pub get
flutter run -d windows
```

The app will open without any API key — visit Settings to add one.

> **Safe by default in dev.** Debug builds run with **safe mode** on, so
> launching the app on your laptop won't fullscreen the screen, register
> auto-startup, or spawn the focus-stealing PowerShell guardian. The lockdown
> UI still flows end to end — only the platform side effects are stubbed.
>
> To explicitly force one or the other:
>
> ```bash
> # Walk through the UI without any platform takeover
> flutter run -d windows --dart-define=SIMULATE_LOCKDOWN=true
>
> # Exercise the real lockdown path (will take over the screen)
> flutter run -d windows --dart-define=SIMULATE_LOCKDOWN=false
> ```
>
> You can also flip safe mode anytime from **Settings → Platform + Notifications**.

### Pass a key at build time (optional)

```bash
flutter run -d windows --dart-define=CONCIERGE_GEMINI_API_KEY=your_key_here
```

This bakes a default key into the build so users don't need to supply their own.

### Build release

```bash
flutter build windows --release
```

Output: `build/windows/x64/runner/Release/`

---

## Releasing

Releases are manual by design. Use the **Manual Release** GitHub Actions workflow:

1. Merge approved changes into `main`
2. Update `CHANGELOG.md`
3. Run the **Manual Release** workflow from the Actions tab
4. Enter a version like `1.0.0`

The workflow will analyze, test, build the Windows portable zip and installer, tag the commit, and publish the GitHub Release.

---

## Windows enforcement

What happens during lockdown:
- fullscreen, always-on-top window
- prevent-close enabled
- refocus timer reclaims focus every 500 ms
- companion PowerShell process uses Win32 APIs to steal focus every 150 ms
- on app startup, any leftover lockdown state from a previous crash is cleaned up automatically

The guardian AI can also **minimize**, **close**, or **fully unlock** the app — users must negotiate for these actions.

What it **cannot** stop:
- Ctrl+Alt+Del (Secure Attention Sequence — reserved by the OS)
- killing the process via Task Manager
- a user with local administrator access who knows what they're doing

See `docs/WINDOWS_THREAT_MODEL.md` for the full threat model.

---

## Project docs

| File | Purpose |
|------|---------|
| `CONTRIBUTING.md` | How to contribute and cut releases |
| `CHANGELOG.md` | Version history |
| `SECURITY.md` | Vulnerability reporting and threat model |
| `CODE_OF_CONDUCT.md` | Community standards |
| `docs/WINDOWS_THREAT_MODEL.md` | Windows enforcement limits |
| `docs/WINDOWS_PACKAGING_AND_SIGNING.md` | Signing and distribution notes |

---

## Mobile (Android)

Android is supported as a build target with **best-effort** kiosk-mode lockdown via Device Admin + lock-task. Real-world enforcement on Android is intrinsically more limited than Windows because the OS does not let user apps stop the user from killing them.

```bash
# Run on a connected Android device (USB debugging enabled)
flutter run -d android --dart-define=SIMULATE_LOCKDOWN=true

# Build a debug APK to side-load
flutter build apk --debug --dart-define=SIMULATE_LOCKDOWN=true
```

What works today on Android:

- Device Admin permission request (one-time setup)
- `lockNow()` to immediately lock the screen
- `startLockTask()` for screen-pinning kiosk mode
- Manual `deactivate` / `grantExtension` flows back through the same channel

Known gaps (tracked, not yet implemented):

- No persistent foreground service yet, so the scheduler stops firing if the OS evicts the app from memory. Lockdown only triggers while the app is in the foreground or recently backgrounded.
- No exact-alarm-based scheduler. The manifest now declares `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` so the future implementation can call `AlarmManager.setExactAndAllowWhileIdle` without a manifest churn.
- Notifications channel for Android 13+ runtime permission is requested via the manifest declaration (`POST_NOTIFICATIONS`); the in-app prompt and notification code is on the roadmap.

iOS is **not** currently supported — there is no `ios/` runner directory yet. Apple's app sandbox makes a true bedtime lock impossible without MDM / Screen Time API entitlements; a useful iOS port would expose Screen Time API integration rather than try to emulate the Windows lockdown model.

---

## Security notes

- Do not commit real API keys — `.env` files are git-ignored
- API keys are stored in local SharedPreferences, never transmitted except to the AI provider
- See `SECURITY.md` for vulnerability reporting
