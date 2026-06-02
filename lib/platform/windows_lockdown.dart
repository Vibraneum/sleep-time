import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size, Alignment;
import 'package:window_manager/window_manager.dart';

import '../core/config.dart';
import 'windows_lock_state.dart';

/// Windows-specific lockdown. This is **best-effort friction only** — never
/// tamper-proof. A determined local user (especially an administrator) can
/// still bypass it. The goal is reliable friction at bedtime, not kernel-level
/// security. See the "Windows threat model (honest)" section in `KICKOFF.md`.
///
/// ## Architecture (M2)
/// - IPC is a small JSON file at
///   `%LOCALAPPDATA%\SleepTime\state\lock.json` (schema in
///   [WindowsLockState]). The native runner (`flutter_window.cpp`) and the
///   sibling watchdog (`sleep_time_watchdog.exe`) both read it. Writes here are
///   best-effort and swallowed so a failure never wedges the machine
///   (fail-open).
/// - Foreground reclaim is **event-driven** in C++ via `SetWinEventHook`
///   (EVENT_SYSTEM_FOREGROUND). The old Dart 500 ms refocus `Timer` and the
///   detached PowerShell `SetForegroundWindow` guardian loop are GONE — they
///   were hot loops. A one-time best-effort kill of any *legacy* orphaned
///   PowerShell guardian still runs on [restoreSystemState] so upgrades from
///   older builds clean up.
/// - A sibling **watchdog exe** relaunches `sleep_time.exe` if it is killed
///   while locked. It is spawned detached from [activate] (real mode only) and
///   self-exits when `lock.json.locked` flips false.
///
/// ## Roadmap simplification — the "named-event push"
/// The roadmap wanted Dart to *signal* a named auto-reset kernel event
/// (`Local\\SleepTimeLockChanged`) so C++ could wake instantly on a lock
/// change. Dart has no no-FFI way to `SetEvent` on a named kernel object, and
/// this milestone forbids new pub deps (which rules out an FFI helper). So the
/// push is simplified to a **low-frequency (5 s) C++ `WM_TIMER` re-read** of
/// lock.json. The event-driven `SetWinEventHook` already handles the
/// latency-sensitive case (a foreign window stealing focus); the 5 s poll is
/// only a safety net for missed events / external edits to lock.json. The
/// watchdog single-instance mutex (`Global\\SleepTimeWatchdogPresent`) IS used.
///
/// ## Defeatable cases (documented, not fixed — best-effort by design)
/// - An **elevated process** can set itself above our always-on-top window and
///   ignore our foreground reclaim (we cannot win against higher integrity).
/// - The **UAC secure desktop** (Ctrl+Alt+Del, consent prompts) is a separate
///   desktop the low-level keyboard hook cannot see or block.
/// - lock.json is a **user-writable file**; a user can edit it to `locked:false`
///   to drop the overlay. This is intentional fail-open, not a hole to plug.
/// - Killing **both** the app and the watchdog within the watchdog's minimum
///   relaunch interval (~5 s) leaves a gap where nothing relaunches.
/// - **Multi-monitor**: the overlay only covers the window's monitor; a foreign
///   window on another monitor can stay visible (we reclaim foreground, not
///   every pixel of every display).
class WindowsLockdown {
  static bool _isLocked = false;
  static Process? _watchdogProcess;
  static Timer? _watchdogRespawnTimer;
  static DateTime? _lastWatchdogSpawn;

  /// Minimum gap between watchdog spawn attempts — mirrors the watchdog's own
  /// anti-fork-bomb relaunch interval so the reciprocal Dart respawn can't spin.
  static const Duration _watchdogMinSpawnInterval = Duration(seconds: 5);
  static const Duration _watchdogRespawnCheck = Duration(seconds: 30);

  /// True when the platform side effects are running (real lockdown).
  /// In simulate mode this stays false even while the UI is in locked state.
  static bool get isLocked => _isLocked;

  static bool get _simulating => AppConfig.simulateLockdown;

  /// Resolve `%LOCALAPPDATA%\SleepTime\state`, creating it if needed. Falls
  /// back to the system temp dir if the env var is missing.
  static Directory get _stateDir {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = (localAppData != null && localAppData.trim().isNotEmpty)
        ? localAppData
        : Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}SleepTime${sep}state');
  }

  static File get _lockStateFile =>
      File('${_stateDir.path}${Platform.pathSeparator}lock.json');

  /// Legacy lock flag from pre-M2 builds. Cleaned up on restore so an older
  /// build's leftover flag can't confuse a freshly upgraded runner.
  static File get _legacyLockFlagFile => File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}sleep_time.locked',
      );

  /// Register the app + watchdog to run at Windows login.
  static Future<void> registerStartup() async {
    if (!Platform.isWindows) return;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: skip registerStartup');
      return;
    }
    try {
      final exePath = Platform.resolvedExecutable;
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'SleepTime',
        '/t',
        'REG_SZ',
        '/d',
        '"$exePath"',
        '/f',
      ]);
      final watchdog = _watchdogPath();
      if (watchdog != null) {
        await Process.run('reg', [
          'add',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'SleepTimeWatchdog',
          '/t',
          'REG_SZ',
          '/d',
          '"$watchdog"',
          '/f',
        ]);
      }
    } catch (_) {}
  }

  /// Remove the app + watchdog from Windows startup.
  static Future<void> unregisterStartup() async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('reg', [
        'delete',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'SleepTime',
        '/f',
      ]);
    } catch (_) {}
    try {
      await Process.run('reg', [
        'delete',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'SleepTimeWatchdog',
        '/f',
      ]);
    } catch (_) {}
  }

  /// Best-effort cleanup for cases where the app previously crashed while the
  /// machine was locked down.
  static Future<void> restoreSystemState() async {
    if (!Platform.isWindows) return;
    if (_simulating) {
      _isLocked = false;
      return;
    }

    _isLocked = false;
    _watchdogRespawnTimer?.cancel();
    _watchdogRespawnTimer = null;
    // Write locked:false FIRST so the watchdog and native runner stand down.
    await _writeLockState(const WindowsLockState(locked: false));
    _stopWatchdog();
    await _killLegacyGuardians();
    await _deleteLegacyFlag();

    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setPreventClose(false);
      await windowManager.setFullScreen(false);
    } catch (_) {
      // window manager may not be initialized yet on startup cleanup.
    }
  }

  /// Activate lockdown: full screen, always on top, prevent closing. Refocus is
  /// now handled natively (event-driven) — no Dart timer / PowerShell loop. The
  /// watchdog is spawned to relaunch us if killed. No registry or explorer
  /// changes (too dangerous on crash).
  static Future<void> activate() async {
    if (!Platform.isWindows || _isLocked) return;
    if (_simulating) {
      if (kDebugMode) {
        debugPrint('[sleep-time] simulate: lockdown ACTIVE (no platform fx)');
      }
      return;
    }
    _isLocked = true;
    await _writeLockState(const WindowsLockState(locked: true, mode: 'full'));

    await windowManager.show();
    await windowManager.focus();
    await windowManager.setFullScreen(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setPreventClose(true);

    _spawnWatchdog();
    _startWatchdogRespawnLoop();
  }

  /// Deactivate lockdown and restore a usable desktop.
  static Future<void> deactivate() async {
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: lockdown released');
      return;
    }
    return restoreSystemState();
  }

  /// Full grant — same end state as a release; the scheduler re-locks on
  /// expiry by calling [activate] again. Kept distinct from [grantSelective].
  static Future<void> grantExtension() async {
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: grant');
      return;
    }
    return restoreSystemState();
  }

  /// Selective grant: keep the overlay ARMED (keyboard hook + preventClose stay
  /// on) but shrink the Flutter window to a small top-right countdown HUD and
  /// switch lock.json to grant mode with an allow-list. The native side then
  /// only reclaims foreground from apps NOT on the allow-list, letting the
  /// granted apps stay usable.
  static Future<void> grantSelective({
    required List<String> allowImageNames,
    required int durationMinutes,
  }) async {
    if (!Platform.isWindows) return;
    if (_simulating) {
      if (kDebugMode) {
        debugPrint('[sleep-time] simulate: grantSelective '
            '$allowImageNames for ${durationMinutes}m');
      }
      return;
    }
    final expiry = DateTime.now()
        .add(Duration(minutes: durationMinutes))
        .millisecondsSinceEpoch;
    _isLocked = true;
    await _writeLockState(WindowsLockState(
      locked: true,
      mode: 'grant',
      allow: allowImageNames,
      grantExpiryEpochMs: expiry,
    ));

    try {
      await windowManager.setFullScreen(false);
      await windowManager.setSize(const Size(320, 100));
      await windowManager.setAlignment(Alignment.topRight);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setPreventClose(true);
    } catch (_) {}

    // Keep the watchdog running through a selective grant — the app must still
    // relaunch if killed mid-grant.
    _spawnWatchdog();
    _startWatchdogRespawnLoop();
  }

  /// Critical processes the guardian may NEVER minimize/control. These keep the
  /// desktop, session, and our own enforcement alive — minimizing them would
  /// either be pointless or destabilize the machine. Lower-cased image names.
  static const Set<String> criticalProcessSafelist = {
    'explorer.exe',
    'winlogon.exe',
    'lsass.exe',
    'csrss.exe',
    'dwm.exe',
    'sleep_time.exe',
    'sleep_time_watchdog.exe',
  };

  /// True when [imageName] (friendly or image name) resolves to a critical
  /// process we must refuse to control. Pure so it is unit-testable.
  static bool isCriticalProcess(String imageName) {
    final resolved = WindowsAppResolver.resolve(imageName);
    if (resolved == null) return false;
    return criticalProcessSafelist.contains(resolved.toLowerCase());
  }

  /// Block + MINIMIZE a distracting app's windows — NEVER kill/terminate (the
  /// owner must not lose unsaved work). Resolves the friendly/image name, then
  /// minimizes every top-level visible window owned by a matching process via a
  /// no-window PowerShell helper (no FFI / no new pub deps). Refuses any process
  /// on [criticalProcessSafelist]. Returns false when refused or off-Windows.
  ///
  /// This is the Dart-initiated counterpart to the native foreground reclaim in
  /// flutter_window.cpp (which minimizes whatever foreign window grabs focus).
  static Future<bool> minimizeApp(String imageName) async {
    if (!Platform.isWindows) return false;
    if (isCriticalProcess(imageName)) return false;
    final resolved = WindowsAppResolver.resolve(imageName);
    if (resolved == null) return false;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: minimizeApp $resolved');
      return true;
    }
    // Strip the .exe for Get-Process (which wants the base name).
    final procName = resolved.toLowerCase().endsWith('.exe')
        ? resolved.substring(0, resolved.length - 4)
        : resolved;
    try {
      // SW_MINIMIZE = 6. ShowWindowAsync is non-blocking and never terminates
      // the target — it only minimizes the window, preserving unsaved work.
      // Build the script line-by-line so the embedded here-string (@'...'@) and
      // the procName interpolation stay readable.
      final lines = <String>[
        r"$sig = @'",
        '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);',
        "'@",
        r'$t = Add-Type -MemberDefinition $sig -Name Win32Min -Namespace SleepTime -PassThru;',
        'Get-Process -Name "$procName" -ErrorAction SilentlyContinue | '
            r'ForEach-Object { if ($_.MainWindowHandle -ne 0) '
            r'{ [void]$t::ShowWindowAsync($_.MainWindowHandle, 6) } }',
      ];
      await Process.run(
        'powershell',
        ['-NoProfile', '-Command', lines.join('\n')],
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Snap back to the full overlay (e.g. on selective-grant expiry).
  static Future<void> restoreFull() async {
    if (!Platform.isWindows) return;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: restoreFull');
      return;
    }
    _isLocked = true;
    await _writeLockState(const WindowsLockState(locked: true, mode: 'full'));
    try {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setFullScreen(true);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setPreventClose(true);
    } catch (_) {}
    _spawnWatchdog();
    _startWatchdogRespawnLoop();
  }

  /// Re-lock after extension expires.
  static Future<void> relock() async {
    if (!Platform.isWindows) return;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: relock');
      return;
    }
    _isLocked = false;
    await activate();
  }

  // --- Watchdog wiring ------------------------------------------------------

  /// Resolve the watchdog exe path next to the running app exe.
  static String? _watchdogPath() {
    try {
      final exe = File(Platform.resolvedExecutable);
      final dir = exe.parent.path;
      return '$dir${Platform.pathSeparator}sleep_time_watchdog.exe';
    } catch (_) {
      return null;
    }
  }

  /// Spawn the watchdog detached, guarded by [_watchdogMinSpawnInterval] so the
  /// reciprocal respawn loop can't fork-bomb. The watchdog itself is
  /// single-instance via a named mutex, so a redundant spawn just exits.
  static void _spawnWatchdog() {
    if (_simulating) return; // SAFETY: never spawn while simulating.
    final now = DateTime.now();
    if (_lastWatchdogSpawn != null &&
        now.difference(_lastWatchdogSpawn!) < _watchdogMinSpawnInterval) {
      return;
    }
    final path = _watchdogPath();
    if (path == null) return;
    final exe = File(path);
    if (!exe.existsSync()) return;
    _lastWatchdogSpawn = now;
    () async {
      try {
        _watchdogProcess = await Process.start(
          path,
          [pid.toString(), Platform.resolvedExecutable],
          mode: ProcessStartMode.detached,
        );
      } catch (_) {
        // Best-effort — the app still locks without the watchdog.
      }
    }();
  }

  /// Low-frequency reciprocal respawn: while locked, periodically re-spawn the
  /// watchdog if it appears to be gone. Guarded by the same min interval and by
  /// the watchdog's own single-instance mutex.
  static void _startWatchdogRespawnLoop() {
    if (_simulating) return;
    _watchdogRespawnTimer?.cancel();
    _watchdogRespawnTimer = Timer.periodic(_watchdogRespawnCheck, (_) {
      if (!_isLocked || _simulating) return;
      _spawnWatchdog();
    });
  }

  static void _stopWatchdog() {
    // The watchdog self-exits once lock.json.locked is false (already written
    // by the caller). We also best-effort kill our tracked handle.
    try {
      _watchdogProcess?.kill();
    } catch (_) {}
    _watchdogProcess = null;
    _lastWatchdogSpawn = null;
  }

  // --- lock.json IPC --------------------------------------------------------

  static Future<void> _writeLockState(WindowsLockState state) async {
    try {
      final dir = _stateDir;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _lockStateFile.writeAsString(state.encode(), flush: true);
    } catch (_) {
      // Fail open rather than risking a machine that stays stuck.
    }
  }

  // --- Legacy cleanup (pre-M2 upgrades) -------------------------------------

  static Future<void> _deleteLegacyFlag() async {
    try {
      if (await _legacyLockFlagFile.exists()) {
        await _legacyLockFlagFile.delete();
      }
    } catch (_) {}
  }

  /// One-time best-effort kill of any PowerShell `SetForegroundWindow` guardian
  /// left running by a pre-M2 build, so upgrades clean up the old hot loop.
  static Future<void> _killLegacyGuardians() async {
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        r"Get-WmiObject Win32_Process -Filter ""Name='powershell.exe'"" | "
            r"Where-Object { $_.CommandLine -match 'sleep_time.*SetForegroundWindow' } | "
            r"ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }",
      ]);
    } catch (_) {}
  }
}
