# KICKOFF — Sleep Time on a Fresh Machine

This is the first thing to read after cloning the repo on a new machine. Get the dev environment up, prove the build works, then start the diagnosis work in `docs/SESSION_NOTES_2026-05-17.md`.

## Required toolchain (install in this order)

1. **Flutter SDK 3.x stable** — https://docs.flutter.dev/get-started/install
   After install, run `flutter doctor` and resolve every red X before continuing.

2. **Android platform-tools (`adb`)** — needed to sideload the Android APK onto a real phone for the Device Admin / kiosk path that emulators can't fully exercise.
   - Windows: `winget install Google.PlatformTools` *or* `scoop install adb` *or* download zip from https://developer.android.com/tools/releases/platform-tools
   - Verify: `adb version`
   - Add to PATH if not already.

3. **gstack** (required for the browser-based UI QA workflow used in this repo) — install per its current docs. Verify with `gstack --version` (or whichever command exposes its CLI).
   *If you don't yet have gstack on this machine, do this before running any /design-review, /browse, /qa, or /ship skill.*

4. **Visual Studio 2022 with "Desktop development with C++" workload** — required by Flutter Windows builds. Community edition is fine.

5. **Android Studio** *(optional but recommended)* — easiest way to manage SDK platforms, emulators, and signing keys.

## Repo setup

```bash
git clone <repo-url>
cd sleep-time
cp .env.example .env
# Fill in .env with:
#   GEMINI_API_KEY=...
#   POKE_API_KEY=...
#   BLAXEL_API_KEY=...   # only if using Blaxel sandboxes (see SESSION_NOTES; not used for app)
flutter pub get
flutter analyze        # should pass clean
```

## Build smoke test (proves the toolchain works)

```bash
flutter build windows --release      # produces build/windows/x64/runner/Release/sleep_time.exe
flutter build apk --release          # produces build/app/outputs/flutter-apk/app-release.apk
```

Both must exit 0 before you move on.

## How to test the lockdown safely

Read [docs/SESSION_NOTES_2026-05-17.md](docs/SESSION_NOTES_2026-05-17.md) before attempting any of the sandbox/VM strategies — it documents which paths were tried, which ones failed, and what's worth retrying on a new machine. Highlights:

- **Windows lockdown tests need a sandbox** because if the lockdown wedges your session you can lose work. Options ranked by viability *on a Win 11 Pro or Enterprise host*:
  1. **Windows Sandbox** (built-in, fast, disposable). Needs Pro/Enterprise/Edu — not Home.
  2. **Hyper-V VM with checkpoints** (also needs Pro/Enterprise).
  3. **VirtualBox** — works on Home, but on the *previous* dev machine VBoxManage input injection was broken against the Win 11 25H2 guest (could not type or click into the guest from the host). **Avoid unless on a different host edition.**
- **Android lockdown tests** need a real phone with Device Admin enabled — emulators don't faithfully reproduce kiosk + admin behaviors. Wire an Android device via USB, `adb devices`, then `flutter run -d <deviceId>`.

## Linked context

- [CLAUDE.md](CLAUDE.md) — project overview, schedule, commands
- [CURRENT_STATE.md](CURRENT_STATE.md) — what's working and what isn't, app-wise
- [docs/SESSION_NOTES_2026-05-17.md](docs/SESSION_NOTES_2026-05-17.md) — full record of the VM-harness debugging session: what failed, what wasted hours, what to skip on the new machine
