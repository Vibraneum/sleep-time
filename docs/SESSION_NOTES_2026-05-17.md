# Session Notes — 2026-05-17 — VM Test Harness Attempt

Honest record of what was tried, what worked, what didn't, and what *not to retry* on the new machine.

## Why this session existed

The Sleep Time app's Windows build wouldn't launch on the dev machine, and we lacked a safe place to test the lockdown (if it wedges your session, you lose work). Goal: stand up a disposable Win 11 VM, drop the build into it, capture the launch crash, fix the root cause.

**We never got to the diagnosis step.** The session burned ~3 hours setting up a VM that ultimately wasn't usable for our purpose. Lessons below.

## Host environment

- Windows 11 **Home** (10.0.26200) — *no Windows Sandbox, no Hyper-V Manager UI*.
- Intel Core Ultra 9 185H, 16 cores, 31.5 GB RAM — plenty of compute.
- C: drive was at **5.8 GB free** at session start (critical). D: had 228 GB free, E: 205 GB.
- WSL2 was already running on the host, meaning `HypervisorPresent = True` — so VirtualBox ran on top of Microsoft's Windows Hypervisor Platform (slower than VBox's native backend).

## What worked

- **Disk cleanup**: freed ~36 GB on C: by deleting safe caches (uv 26 GB, .dartServer 4 GB, npm-cache 4 GB, pip 1 GB), moving 16 GB of Downloads to D:, removing a 4 GB Antigravity backup, and cleaning old Playwright browser versions. Final C: free: 41.77 GB.
- **Defender exclusions** added for `D:\VirtualBox-VMs` and `D:\sleep-time-testing` plus VBox processes (VBoxHeadless.exe, VBoxManage.exe, VirtualBoxVM.exe). This roughly doubled VM disk-I/O speed during install.
- **VirtualBox 7.2.8** installed cleanly via silent installer.
- **Win 11 25H2 ISO** (~7.9 GB) downloaded via Fido (signed Microsoft URL, no MS sign-in).
- **VM created and configured** via `VBoxManage` (8 GB RAM, 4 vCPU, EFI, TPM 2.0, 64 GB VDI on D:, NAT with port-forward 2222→22, shared folder `D:\sleep-time-testing\drop` → `\\VBOXSVR\drop`).
- **Unattended Windows install** via `VBoxManage unattended install` auto-completed OOBE — Microsoft account skipped, local user `test` / `test1234`, accepted EULA, no clicking needed during the install itself.
- **flutter build windows --release** on the host succeeded; output staged in the shared-folder drop with `.env` alongside.
- Three helper scripts staged at `D:\sleep-time-testing\`: `create-vm.ps1`, `build-and-drop.ps1`, `install-and-launch.ps1` — the second is reusable on any machine.

## What didn't work (the costly lessons)

### 1. Win 11 install was very slow

Total wall-clock: **~2.5 hours** for the OS install, even with Defender exclusions and 4 vCPUs. The "Getting devices ready" phase sat at 42% for ~25 minutes. Multiple Cursor instances + Comet + python running on the host (~7000+ CPU-seconds consumed during the install) shared the CPU with the VM.

**Lesson**: Win 11 25H2 in VirtualBox 7.2 on a Hyper-V-backed host is roughly 3–4× slower than native install. If you must use VirtualBox, close every other CPU consumer first.

### 2. `VBoxManage unattended install --install-additions` didn't install Guest Additions

The `--install-additions` flag is supposed to mount the Guest Additions ISO and run `VBoxWindowsAdditions-amd64.exe` as part of the post-install script. It didn't fire. No `/VirtualBox/GuestAdd/Version` property was ever populated, and no VBox icon appeared in the guest taskbar tray.

**Lesson**: Don't rely on `--install-additions` in VBox 7.2.x on Win 11. Plan to install GA manually after first boot, or use a different injection mechanism.

### 3. `VBoxManage controlvm keyboardputscancode` and `keyboardputstring` did not reach the guest

This was the dealbreaker. After the Win 11 desktop came up, we tried to autonomously drive the Guest Additions install by sending keystrokes:
- `keyboardputscancode 02 82` (digit "1" press + release) — Search field stayed empty.
- `keyboardputstring "powershell"` — Search field stayed empty.
- Win+R, Win+E, Esc — none produced any visible effect.

Mouse injection (`controlvm mouse`, `mouseclickevent`) also did not produce reliable input. The user reported the host's own mouse/cursor connection to the VM window was failing too.

**Probable cause**: VirtualBox 7.2.x synthesized PS/2 input is not reliably accepted by Win 11 25H2's input stack, especially against WinUI/UWP surfaces like the Search panel. We never confirmed whether injection works against classic Win32 windows (Notepad, etc.) because we never got past Search.

**Lesson**: If you can't move past this on a fresh machine, *don't sink hours into scancode injection workarounds*. Either:
- Install Guest Additions with **4 physical clicks** in the VM window (then `VBoxManage guestcontrol` works fully and you don't need injection ever again), OR
- Use a host edition that supports **Windows Sandbox** (Win 11 Pro/Enterprise/Edu) — it integrates input natively and starts from scratch every time, OR
- Use a **Hyper-V Generation 2 VM** (Pro/Enterprise) — Enhanced Session Mode handles input cleanly.

### 4. We never confirmed Sleep Time's launch failure

The whole point of the session. **Status: still unknown.** Try this first on the new machine:

```powershell
# On the host where it failed:
Get-WinEvent -LogName Application -MaxEvents 50 | Where-Object { $_.ProviderName -match 'Application Error|.NET Runtime|sleep_time' } | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
```

…or open Event Viewer → Windows Logs → Application and look for entries near the failed launch time tagged with `sleep_time.exe`.

## Artifacts left on the previous machine

- VM `sleep-time-test` (powered off, registered, on D:). Disk: D:\VirtualBox-VMs\sleep-time-test\sleep-time-test.vdi (~30 GB).
- Win 11 ISO: `D:\sleep-time-testing\Win11_25H2_English_x64.iso` (7.9 GB).
- VirtualBox installer: `D:\sleep-time-testing\VirtualBox-7.2.8-173730-Win.exe` (170 MB).
- Build artifact dropped for the VM: `D:\sleep-time-testing\drop\sleep-time-20260517-165951\` (includes the .env file with API keys).
- API key now in `.env`: `BLAXEL_API_KEY=bl_aaabq0ouifpw2e70oubltunr0jw8vigw`. **This key was pasted in a chat transcript — rotate it in the Blaxel dashboard before anything else.**
- Defender exclusions added (per-user setting; stays on this machine only).

If you want to wipe the previous machine's leftovers later:
```powershell
& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' unregistervm sleep-time-test --delete
Remove-Item 'D:\sleep-time-testing' -Recurse -Force
```

## Recommended path on the new machine

See [../KICKOFF.md](../KICKOFF.md). Order of operations:

1. Install toolchain (Flutter, adb, gstack, VS 2022 + C++ workload).
2. Clone the repo, `cp .env.example .env`, fill keys, run `flutter pub get` + `flutter analyze`.
3. **Build both targets to prove the toolchain works**: `flutter build windows --release` + `flutter build apk --release`.
4. Run sleep-time directly on the new machine via `flutter run -d windows`. If it crashes on launch, capture Event Viewer + the stack trace *immediately* — that's the actual diagnosis work that this session never reached.
5. Only after step 4 reveals the root cause should you bother with a sandbox/VM. And if you do, prefer Windows Sandbox (Pro/Enterprise) over VirtualBox.
6. For Android: wire a real phone via USB, `adb devices`, `flutter run -d <id>` — the Device Admin / kiosk path doesn't work right on emulators.
