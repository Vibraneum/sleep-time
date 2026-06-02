# Sleep Time

A bedtime enforcer for Windows. Locks your screen at a set time. An AI guardian decides whether your reason for more time is good enough.

> **Best-effort enforcement, not anti-tamper security.** A determined local administrator can bypass it. The goal is friction, not a cage.

---

## Download and use (Windows)

1. Go to [Releases](https://github.com/Vibraneum/sleep-time/releases/latest)
2. Download `sleep-time-windows-setup-vX.X.X.exe` (installer) or the `.zip` (portable)
3. Run the installer — Windows may show a SmartScreen warning since the app is unsigned; click **More info → Run anyway**
4. On first launch, open **Settings → AI Provider** and enter an API key for your chosen provider ([Anthropic](https://console.anthropic.com) recommended; [Gemini](https://aistudio.google.com/apikey) also supported)
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

### Anthropic Claude (recommended)

The guardian is built around real **tool-calling** — Claude (Sonnet by default)
makes exactly one structured decision per turn (grant / deny / unlock a specific
app / adjust the schedule / end the session), so it's decisive and cheap. Get a
key at [console.anthropic.com](https://console.anthropic.com) and select Anthropic
in Settings → AI Provider.

### Gemini (fallback)

Get a free key at [aistudio.google.com](https://aistudio.google.com/apikey). Gemini
runs as a text-parsing fallback (no typed tool use), so the guardian is a little
less reliable than on Claude. Enter the key in Settings → AI Provider.

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
> auto-startup, or spawn the recovery watchdog. The lockdown UI still flows end
> to end — only the platform side effects are stubbed.
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
- fullscreen, always-on-top window with prevent-close
- **event-driven** focus reclaim — a `SetWinEventHook` on the foreground event
  snaps focus back when another window tries to take over (no busy polling loop,
  so idle CPU/battery cost is near zero)
- a sibling **watchdog process** (`sleep_time_watchdog.exe`) relaunches the app if
  it is killed while locked
- **per-app selective unlock** — the guardian can free a specific app (e.g. your
  browser) for N minutes, shrinking to a corner countdown HUD while everything
  else stays blocked
- on app startup, any leftover lockdown state from a previous crash is cleaned up automatically

The guardian AI can also **minimize**, **close**, **adjust your schedule** (within
anti-manipulation guardrails), or **fully unlock** the app — all via negotiation.

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
| `docs/WINDOWS_RELEASE.md` | Windows build → installer → signing → QA pipeline |
| `docs/QA_STRATEGY.md` | Test pyramid, device matrices, safe-test discipline |
| `docs/PLAY_SUBMISSION.md` | Google Play declarations and Data Safety notes |

---

## Mobile (Android)

Android is built to be **Google Play–distributable** — the old Device Admin +
kiosk (lock-task) approach was removed (it requires Device Owner provisioning and
is a guaranteed Play rejection). Instead, enforcement is a policy-compliant stack:

```bash
# Run on a connected Android device (USB debugging enabled)
flutter run -d android --dart-define=SIMULATE_LOCKDOWN=true

# Build a debug APK to side-load
flutter build apk --debug
```

How it works on Android:

- a **specialUse foreground service** keeps the guardian alive in the background,
  driven by **exact alarms** (`AlarmManager`, guarded by `canScheduleExactAlarms()`
  with a graceful inexact fallback) — it survives backgrounding and eviction
- **WorkManager boot recovery** re-arms the schedule after a reboot (it does not
  illegally start a specialUse FGS from `BOOT_COMPLETED`)
- foreground-app detection via **UsageStats** (primary) with an **optional**
  AccessibilityService as a latency boost — the app is fully functional without
  accessibility (important for Android 17 Advanced Protection users)
- a `SYSTEM_ALERT_WINDOW` **overlay** blocks non-allowed apps during lockdown, with
  a corner countdown banner during a grant and a fallback to bringing the app
  forward when the overlay is refused
- **per-app selective unlock**: the guardian frees only apps you pre-approved in
  the allow-list editor, for a limited time
- a gated **permission onboarding** flow (notifications, overlay, usage-access,
  exact-alarm, battery) with a **prominent disclosure** shown before any
  Accessibility redirect

See [`docs/PLAY_SUBMISSION.md`](docs/PLAY_SUBMISSION.md) for the Play Console
declarations (specialUse FGS justification, optional-Accessibility disclosure,
Data Safety). Real-device enforcement QA is still pending.

> A broader-permission **sideload (`full`) build** — for users who want stronger
> grip than Play policy allows — is planned as a later flavor behind the existing
> `Capabilities` seam.

iOS is **not** currently supported — there is no `ios/` runner directory yet. Apple's app sandbox makes a true bedtime lock impossible without MDM / Screen Time API entitlements; a useful iOS port would expose Screen Time API integration rather than try to emulate the Windows lockdown model.

---

## Security notes

- Do not commit real API keys — `.env` files are git-ignored
- API keys are stored in local SharedPreferences, never transmitted except to the AI provider
- See `SECURITY.md` for vulnerability reporting
