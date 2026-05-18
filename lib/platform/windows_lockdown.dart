import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../core/config.dart';

/// Windows-specific lockdown. This is best-effort only; a determined local
/// administrator can still bypass it. The goal is reliable friction, not
/// kernel-level security.
class WindowsLockdown {
  static bool _isLocked = false;
  static Timer? _refocusTimer;
  static Process? _guardianProcess;

  /// True when the platform side effects are running (real lockdown).
  /// In simulate mode this stays false even while the UI is in locked state.
  static bool get isLocked => _isLocked;

  static bool get _simulating => AppConfig.simulateLockdown;

  static File get _lockFlagFile => File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}sleep_time.locked',
      );

  /// Register the app to run at Windows login.
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
        exePath,
        '/f',
      ]);
    } catch (_) {}
  }

  /// Remove the app from Windows startup.
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
    _refocusTimer?.cancel();
    _refocusTimer = null;
    await _stopGuardianProcess();
    await _killOrphanedGuardians();
    await _writeLockFlag(false);

    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setPreventClose(false);
      await windowManager.setFullScreen(false);
    } catch (_) {
      // window manager may not be initialized yet on startup cleanup.
    }
  }

  /// Activate lockdown: full screen, always on top, prevent closing,
  /// and periodically refocus. No registry or explorer changes — those are
  /// too dangerous on crash (leave Windows in a broken state).
  static Future<void> activate() async {
    if (!Platform.isWindows || _isLocked) return;
    if (_simulating) {
      if (kDebugMode) {
        debugPrint('[sleep-time] simulate: lockdown ACTIVE (no platform fx)');
      }
      // Still write the recovery flag so a real subsequent run can clean up
      // if simulate gets toggled off mid-cycle.
      return;
    }
    _isLocked = true;
    await _writeLockFlag(true);

    await windowManager.show();
    await windowManager.focus();
    await windowManager.setFullScreen(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setPreventClose(true);

    _refocusTimer?.cancel();
    _refocusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (_isLocked) {
        try {
          await windowManager.show();
          await windowManager.focus();
          await windowManager.setAlwaysOnTop(true);
        } catch (_) {}
      }
    });

    await _startGuardianProcess();
  }

  static Future<void> _startGuardianProcess() async {
    await _stopGuardianProcess();
    final script = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
"@
while ($true) {
  try {
    $p = Get-Process -Name "sleep_time" -ErrorAction SilentlyContinue
    if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
      [W]::ShowWindow($p.MainWindowHandle, 9)
      [W]::BringWindowToTop($p.MainWindowHandle)
      [W]::SetForegroundWindow($p.MainWindowHandle)
    }
  } catch {}
  Start-Sleep -Milliseconds 150
}
''';

    try {
      _guardianProcess = await Process.start(
        'powershell.exe',
        ['-WindowStyle', 'Hidden', '-NonInteractive', '-NoProfile', '-Command', script],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      // Guardian process is best-effort — app still locks without it
    }
  }

  static Future<void> _stopGuardianProcess() async {
    try {
      _guardianProcess?.kill();
    } catch (_) {}
    _guardianProcess = null;
  }

  /// Kill any guardian PowerShell processes orphaned by a previous crash.
  static Future<void> _killOrphanedGuardians() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile', '-Command',
        r"Get-WmiObject Win32_Process -Filter ""Name='powershell.exe'"" | "
        r"Where-Object { $_.CommandLine -match 'sleep_time.*SetForegroundWindow' } | "
        r"ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }",
      ]);
      // Best-effort — ignore failures.
      if (result.exitCode != 0) return;
    } catch (_) {}
  }

  /// Deactivate lockdown and restore a usable desktop.
  static Future<void> deactivate() async {
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: lockdown released');
      return;
    }
    return restoreSystemState();
  }

  /// Temporarily relax for a granted extension.
  static Future<void> grantExtension() async {
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: grant');
      return;
    }
    return restoreSystemState();
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

  static Future<void> _writeLockFlag(bool locked) async {
    try {
      if (locked) {
        await _lockFlagFile.writeAsString('locked');
      } else if (await _lockFlagFile.exists()) {
        await _lockFlagFile.delete();
      }
    } catch (_) {
      // Fail open rather than risking a machine that stays stuck.
    }
  }

}
