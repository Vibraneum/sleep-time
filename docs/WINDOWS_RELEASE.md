# Windows release guide

How to produce a distributable Windows build of Sleep Time.

## Prerequisites

- Flutter (stable) with Windows desktop enabled (`flutter config --enable-windows-desktop`).
- Visual Studio with the **Desktop development with C++** workload (MSVC + Windows SDK).
- [Inno Setup 6](https://jrsoftware.org/isdl.php) for the installer (`iscc` on PATH).

## 1. Build the release binaries

```powershell
flutter pub get
flutter analyze            # must be clean
flutter test               # must be green
flutter build windows --release
```

This produces, under `build\windows\x64\runner\Release\`:

- `sleep_time.exe` — the app.
- `sleep_time_watchdog.exe` — the sibling watchdog (relaunches the app if it is
  killed while locked). Built as part of the CMake `ALL` target, so a release
  build always includes it.
- the Flutter engine DLLs, ICU data, and `data\` assets.

> The watchdog is part of the build graph — if it ever fails to compile (it is
> built `/W4 /WX`, warnings-as-errors), the whole release build fails. That is
> intentional: we never ship the app without its recovery process.

## 2. Build the installer

The Inno Setup script reads the version from the `ST_VERSION` environment
variable and bundles the entire `Release\` directory (including the watchdog).

```powershell
$env:ST_VERSION = "1.1.0"
iscc installer\windows\sleep_time.iss
```

Output: `dist\sleep-time-windows-setup-v1.1.0.exe`.

The installer:
- installs to `{autopf}\Sleep Time` with `PrivilegesRequired=lowest` (no elevation),
- creates Start-menu (and optional desktop) shortcuts,
- on **uninstall**, kills both processes, removes the runtime auto-start registry
  keys (`SleepTime`, `SleepTimeWatchdog`), and deletes `%LOCALAPPDATA%\SleepTime`.

A portable build is simply the zipped `Release\` directory.

## 3. Code signing (recommended for distribution)

Unsigned binaries trigger SmartScreen "unknown publisher" warnings. To sign:

1. Obtain an **OV or EV code-signing certificate** (EV gets instant SmartScreen
   reputation; OV builds reputation over time).
2. Sign both executables **and** the installer with `signtool` (from the Windows SDK):

   ```powershell
   signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
     /a build\windows\x64\runner\Release\sleep_time.exe
   signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
     /a build\windows\x64\runner\Release\sleep_time_watchdog.exe
   # build the installer AFTER signing the exes, then sign the installer:
   signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
     /a dist\sleep-time-windows-setup-v1.1.0.exe
   ```

3. Verify: `signtool verify /pa /v <file>`.

CI signing is best done with the certificate in a secure store (Azure Key Vault
via `AzureSignTool`, or a hosted HSM) rather than a `.pfx` on disk.

## 4. Pre-release QA (do NOT use your primary account)

Sleep Time can lock you out. Test enforcement safely:

- All development runs default to **safe mode** (`simulateLockdown`, defaults to
  `kDebugMode`): the full lock → negotiate → grant → unlock UI flows with **no**
  platform side effects, no always-on-top, no watchdog. Exercise every flow here
  first.
- To test *real* enforcement, install on a **throwaway / secondary Windows user
  account** (or VM) and only there toggle safe mode off in Settings. Never flip it
  on your primary session.
- Manual matrix to run on the throwaway account before shipping: see the "Windows
  manual QA" section of the QA strategy and the honest threat model in
  [../KICKOFF.md](../KICKOFF.md).

## 5. Threat model honesty

Windows enforcement is **best-effort friction, not a kiosk**. It runs without
elevation, so a determined elevated user can still escape it. Never market it as
tamper-proof. The defeatable cases are documented in `lib/platform/windows_lockdown.dart`
and `KICKOFF.md`.
