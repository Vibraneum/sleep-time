import 'dart:io';
import 'package:flutter/services.dart';

/// Android-specific lockdown using platform channels.
/// The native Kotlin side handles Device Admin and kiosk mode.
class AndroidLockdown {
  static const _channel = MethodChannel('com.vedastro.sleep_time/lockdown');
  static bool _isLocked = false;

  static bool get isLocked => _isLocked;

  /// Request Device Admin permission (must be done once during setup).
  static Future<bool> requestDeviceAdmin() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod('requestDeviceAdmin') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Check if we have Device Admin permission.
  static Future<bool> hasDeviceAdmin() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod('hasDeviceAdmin') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Activate full lockdown: lock screen, start kiosk mode.
  static Future<void> activate() async {
    if (!Platform.isAndroid || _isLocked) return;
    _isLocked = true;

    try {
      await _channel.invokeMethod('activateLockdown');
    } catch (_) {
      // Fallback: at minimum start screen pinning
      await _channel.invokeMethod('startScreenPinning');
    }
  }

  /// Deactivate lockdown.
  static Future<void> deactivate() async {
    if (!Platform.isAndroid || !_isLocked) return;
    _isLocked = false;

    try {
      await _channel.invokeMethod('deactivateLockdown');
    } catch (_) {}
  }

  /// Grant temporary extension — exit kiosk but keep app running.
  static Future<void> grantExtension() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('grantExtension');
    } catch (_) {}
  }

  /// Re-lock after extension expires.
  static Future<void> relock() async {
    if (!Platform.isAndroid) return;
    _isLocked = false;
    await activate();
  }

  /// Open a specific app (guardian decides which apps are allowed).
  static Future<bool> openApp(String packageName) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod('openApp', {
            'packageName': packageName,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
