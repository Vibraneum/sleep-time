import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// Windows-specific lockdown. This is best-effort only; a determined local
/// administrator can still bypass it. The goal is reliable friction, not
/// kernel-level security.
class WindowsLockdown {
  static bool _isLocked = false;
  static Timer? _refocusTimer;

  static bool get isLocked => _isLocked;

  /// Best-effort cleanup for cases where the app previously crashed while the
  /// machine was locked down.
  static Future<void> restoreSystemState() async {
    if (!Platform.isWindows) return;

    _isLocked = false;
    _refocusTimer?.cancel();
    _refocusTimer = null;

    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System',
      'DisableTaskMgr',
      0,
    );
    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer',
      'NoWinKeys',
      0,
    );
    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System',
      'DisableLockWorkstation',
      0,
    );
    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System',
      'DisableChangePassword',
      0,
    );
    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer',
      'NoLogoff',
      0,
    );

    if (!await _isExplorerRunning()) {
      await _startExplorer();
    }

    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setPreventClose(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setFullScreen(false);
    } catch (_) {
      // window manager may not be initialized yet on startup cleanup.
    }
  }

  /// Activate lockdown: full screen, always on top, prevent closing,
  /// disable hotkeys, remove shell affordances, and periodically refocus.
  static Future<void> activate() async {
    if (!Platform.isWindows || _isLocked) return;

    _isLocked = true;

    await windowManager.show();
    await windowManager.focus();
    await windowManager.setFullScreen(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setPreventClose(true);
    await windowManager.setSkipTaskbar(true);

    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System',
      'DisableTaskMgr',
      1,
    );
    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer',
      'NoWinKeys',
      1,
    );
    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System',
      'DisableLockWorkstation',
      1,
    );
    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System',
      'DisableChangePassword',
      1,
    );
    await _setRegistryDword(
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer',
      'NoLogoff',
      1,
    );

    await _killExplorer();

    _refocusTimer?.cancel();
    _refocusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_isLocked) {
        try {
          await windowManager.show();
          await windowManager.focus();
          await windowManager.setAlwaysOnTop(true);
        } catch (_) {
          // Ignore transient window-manager failures.
        }
      }
    });
  }

  /// Deactivate lockdown and restore a usable desktop.
  static Future<void> deactivate() async {
    if (!Platform.isWindows) return;

    _isLocked = false;
    _refocusTimer?.cancel();
    _refocusTimer = null;

    try {
      await windowManager.setFullScreen(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setPreventClose(false);
      await windowManager.setSkipTaskbar(false);
    } catch (_) {
      // Ignore window-manager errors during teardown.
    }

    await restoreSystemState();
  }

  /// Temporarily relax for a granted extension.
  static Future<void> grantExtension() async {
    if (!Platform.isWindows) return;

    _refocusTimer?.cancel();
    _refocusTimer = null;

    try {
      await windowManager.setFullScreen(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setPreventClose(false);
      await windowManager.setSkipTaskbar(false);
    } catch (_) {
      // Ignore transient window-manager failures.
    }

    await restoreSystemState();
  }

  /// Re-lock after extension expires.
  static Future<void> relock() async {
    if (!Platform.isWindows) return;
    _isLocked = false;
    await activate();
  }

  static Future<void> _setRegistryDword(
    String key,
    String valueName,
    int data,
  ) async {
    try {
      await Process.run('reg', [
        'add',
        key,
        '/v',
        valueName,
        '/t',
        'REG_DWORD',
        '/d',
        data.toString(),
        '/f',
      ]);
    } catch (_) {
      // Registry writes are best-effort and may fail on locked-down systems.
    }
  }

  static Future<void> _killExplorer() async {
    try {
      await Process.run('taskkill', ['/f', '/im', 'explorer.exe']);
    } catch (_) {}
  }

  static Future<bool> _isExplorerRunning() async {
    try {
      final result = await Process.run('tasklist', ['/fi', 'imagename eq explorer.exe']);
      final output = '${result.stdout} ${result.stderr}'.toLowerCase();
      return output.contains('explorer.exe');
    } catch (_) {
      return true;
    }
  }

  static Future<void> _startExplorer() async {
    try {
      await Process.start('explorer.exe', [], mode: ProcessStartMode.detached);
    } catch (_) {}
  }
}
