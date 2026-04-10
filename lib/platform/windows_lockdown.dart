import 'dart:io';
import 'package:window_manager/window_manager.dart';

/// Windows-specific lockdown: full-screen overlay, always-on-top,
/// prevent close, disable Task Manager.
class WindowsLockdown {
  static bool _isLocked = false;

  static bool get isLocked => _isLocked;

  /// Activate lockdown: full screen, always on top, prevent closing.
  static Future<void> activate() async {
    if (!Platform.isWindows || _isLocked) return;

    _isLocked = true;

    // Full screen, always on top
    await windowManager.setFullScreen(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setPreventClose(true);
    await windowManager.setSkipTaskbar(true);

    // Disable Task Manager via registry (medium security)
    await _setTaskManagerDisabled(true);
  }

  /// Deactivate lockdown: restore normal window.
  static Future<void> deactivate() async {
    if (!Platform.isWindows || !_isLocked) return;

    _isLocked = false;

    await windowManager.setFullScreen(false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setPreventClose(false);
    await windowManager.setSkipTaskbar(false);

    // Re-enable Task Manager
    await _setTaskManagerDisabled(false);
  }

  /// Temporarily deactivate for a granted extension.
  static Future<void> grantExtension() async {
    if (!Platform.isWindows) return;

    // Exit full screen but keep running
    await windowManager.setFullScreen(false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);

    // Re-enable Task Manager during extension
    await _setTaskManagerDisabled(false);
  }

  /// Re-lock after extension expires.
  static Future<void> relock() async {
    if (!Platform.isWindows) return;
    _isLocked = false; // Reset so activate() works
    await activate();
  }

  /// Disable/enable Task Manager via Windows registry.
  static Future<void> _setTaskManagerDisabled(bool disabled) async {
    try {
      final value = disabled ? '1' : '0';
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System',
        '/v',
        'DisableTaskMgr',
        '/t',
        'REG_DWORD',
        '/d',
        value,
        '/f',
      ]);
    } catch (_) {
      // Registry write may fail without admin — that's okay for medium security
    }
  }
}
