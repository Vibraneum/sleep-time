import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/config.dart';

/// Android-specific lockdown using platform channels.
/// The native Kotlin side handles Device Admin and kiosk mode.
class AndroidLockdown {
  static const _channel = MethodChannel('com.vedastro.sleep_time/lockdown');
  static bool _isLocked = false;

  static bool get isLocked => _isLocked;

  static bool get _simulating => AppConfig.simulateLockdown;

  /// Whether the native Android lockdown side is wired up. Callers that would
  /// dispatch minimize/close/unlock_app on Android should degrade to
  /// message-only when this returns false. The actual native implementation
  /// lands in M4/M5; until then a `ping` will throw MissingPluginException.
  static Future<bool> isNativeReady() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod('ping') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

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
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: android lockdown ON');
      _isLocked = true;
      return;
    }
    _isLocked = true;

    try {
      await _channel.invokeMethod('activateLockdown');
    } catch (_) {
      // Fallback: at minimum start screen pinning
      try {
        await _channel.invokeMethod('startScreenPinning');
      } catch (_) {}
    }
  }

  /// Deactivate lockdown.
  static Future<void> deactivate() async {
    if (!Platform.isAndroid || !_isLocked) return;
    _isLocked = false;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: android lockdown OFF');
      return;
    }

    try {
      await _channel.invokeMethod('deactivateLockdown');
    } catch (_) {}
  }

  /// Grant temporary extension — exit kiosk but keep app running.
  static Future<void> grantExtension() async {
    if (!Platform.isAndroid) return;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: android grant');
      return;
    }
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
