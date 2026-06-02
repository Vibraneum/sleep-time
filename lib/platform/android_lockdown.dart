import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/config.dart';
import '../core/schedule_store.dart';

/// A single native guardian state update streamed over the
/// `lockdown_events` EventChannel.
///
/// `state` mirrors the native [SleepGuardianService] state strings
/// (`inactive` / `windDown` / `locked` / `unlocked`). `grantExpiresAt` is an
/// epoch-ms timestamp (0 when no grant is active). `degraded` is true when the
/// native alarm scheduler had to fall back to inexact alarms because the user
/// has not granted exact-alarm access.
@immutable
class AndroidGuardianEvent {
  final String state;
  final int grantExpiresAt;
  final bool degraded;

  const AndroidGuardianEvent({
    required this.state,
    this.grantExpiresAt = 0,
    this.degraded = false,
  });

  /// Parse a map sent from the native EventChannel. Tolerant of missing /
  /// mistyped fields so a malformed event never throws into the stream.
  factory AndroidGuardianEvent.fromMap(Map<dynamic, dynamic> map) {
    return AndroidGuardianEvent(
      state: (map['state'] as String?) ?? 'inactive',
      grantExpiresAt: (map['grantExpiresAt'] as num?)?.toInt() ?? 0,
      degraded: (map['degraded'] as bool?) ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AndroidGuardianEvent &&
      other.state == state &&
      other.grantExpiresAt == grantExpiresAt &&
      other.degraded == degraded;

  @override
  int get hashCode => Object.hash(state, grantExpiresAt, degraded);

  @override
  String toString() => 'AndroidGuardianEvent(state: $state, '
      'grantExpiresAt: $grantExpiresAt, degraded: $degraded)';
}

/// Native runtime permission snapshot for the Android guardian. Overlay /
/// accessibility / usage-access are M5 placeholders and report `false` here.
@immutable
class AndroidPermissionStatus {
  final bool notifications;
  final bool exactAlarm;
  final bool batteryExemption;
  final bool overlay;
  final bool accessibility;
  final bool usageAccess;

  const AndroidPermissionStatus({
    this.notifications = false,
    this.exactAlarm = false,
    this.batteryExemption = false,
    this.overlay = false,
    this.accessibility = false,
    this.usageAccess = false,
  });

  factory AndroidPermissionStatus.fromMap(Map<dynamic, dynamic> map) {
    bool b(String k) => (map[k] as bool?) ?? false;
    return AndroidPermissionStatus(
      notifications: b('notifications'),
      exactAlarm: b('exactAlarm'),
      batteryExemption: b('batteryExemption'),
      overlay: b('overlay'),
      accessibility: b('accessibility'),
      usageAccess: b('usageAccess'),
    );
  }
}

/// Drives the Play-compliant Android background guardian (M4).
///
/// The native [SleepGuardianService] is the background backstop: it owns the
/// alarm scheduling, the persistent notification, and background state
/// transitions. The Dart [LockdownScheduler] keeps driving the in-app UI. They
/// run in parallel; in safe (simulate) mode both short-circuit platform
/// effects, so they never double-escalate.
///
/// Everything degrades to a no-op (or `false`) off-Android and when the native
/// plugin is missing (`MissingPluginException`).
class AndroidLockdown {
  static const _channel = MethodChannel('com.vedastro.sleep_time/lockdown');
  static const _events =
      EventChannel('com.vedastro.sleep_time/lockdown_events');

  static bool _isLocked = false;

  static bool get isLocked => _isLocked;

  static bool get _simulating => AppConfig.simulateLockdown;

  /// Whether the native Android guardian channel is wired up. `ping` returns
  /// true once M4 native code is present; throws MissingPluginException before.
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

  /// Stream of native guardian state updates. Empty stream off-Android.
  static Stream<AndroidGuardianEvent> events() {
    if (!Platform.isAndroid) {
      return const Stream<AndroidGuardianEvent>.empty();
    }
    return _events.receiveBroadcastStream().map((event) {
      if (event is Map) return AndroidGuardianEvent.fromMap(event);
      return const AndroidGuardianEvent(state: 'inactive');
    }).handleError((_) {
      // Swallow stream errors so a transient platform hiccup doesn't tear down
      // the subscription.
    });
  }

  /// Start the background guardian foreground service and arm the alarms.
  static Future<void> startGuardian() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startGuardian');
    } on MissingPluginException {
      // ignore
    } catch (_) {}
  }

  /// Stop the background guardian and cancel its alarms.
  static Future<void> stopGuardian() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopGuardian');
    } on MissingPluginException {
      // ignore
    } catch (_) {}
  }

  /// Push the current [ScheduleStore] values to native (which re-reads the
  /// already-persisted SharedPreferences) and re-arm the alarms. Call whenever
  /// the schedule changes.
  static Future<void> setSchedule() async {
    if (!Platform.isAndroid) return;
    try {
      // The native side reads FlutterSharedPreferences directly; we only need
      // to signal a recompute. ScheduleStore has already persisted the values.
      await _channel.invokeMethod('setSchedule');
    } on MissingPluginException {
      // ignore
    } catch (_) {}
  }

  /// Current native permission snapshot (notifications / exact-alarm / battery
  /// exemption + M5 placeholders).
  static Future<AndroidPermissionStatus> getPermissionStatus() async {
    if (!Platform.isAndroid) return const AndroidPermissionStatus();
    try {
      final map = await _channel.invokeMethod('getPermissionStatus');
      if (map is Map) return AndroidPermissionStatus.fromMap(map);
      return const AndroidPermissionStatus();
    } on MissingPluginException {
      return const AndroidPermissionStatus();
    } catch (_) {
      return const AndroidPermissionStatus();
    }
  }

  /// Open the system "allow exact alarms" screen.
  static Future<void> requestExactAlarm() async => _invokeVoid('requestExactAlarm');

  /// Trigger the Android 13+ runtime notification permission prompt.
  static Future<void> requestNotifications() async =>
      _invokeVoid('requestNotifications');

  /// Open the system "ignore battery optimizations" dialog.
  static Future<void> requestBatteryExemption() async =>
      _invokeVoid('requestBatteryExemption');

  static Future<void> _invokeVoid(String method) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod(method);
    } on MissingPluginException {
      // ignore
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Compatibility shims for the existing LockdownScheduler → home_screen path.
  // These map the old activate/deactivate/grant verbs onto the new guardian so
  // `_syncPlatformLockdown` keeps compiling and behaving. The native service is
  // the real background authority; these calls keep the in-app intent in sync.
  // ---------------------------------------------------------------------------

  /// Activate lockdown — start the guardian. Safe mode short-circuits.
  static Future<void> activate() async {
    if (!Platform.isAndroid || _isLocked) return;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: android lockdown ON');
      _isLocked = true;
      return;
    }
    _isLocked = true;
    await startGuardian();
  }

  /// Deactivate lockdown — stop the guardian. Safe mode short-circuits effects.
  static Future<void> deactivate() async {
    if (!Platform.isAndroid || !_isLocked) return;
    _isLocked = false;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: android lockdown OFF');
      return;
    }
    await stopGuardian();
  }

  /// Grant temporary extension. With the M4 backstop the guardian keeps
  /// running (it owns the schedule); the in-app UI handles the actual grant.
  /// In M5 this will relax native blocking; for now it is a no-op beyond the
  /// safe-mode log so the existing call site keeps working.
  static Future<void> grantExtension() async {
    if (!Platform.isAndroid) return;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: android grant');
      return;
    }
    // Guardian stays armed; alarms will re-lock at the next transition.
  }

  /// Re-lock after an extension expires — re-activate.
  static Future<void> relock() async {
    if (!Platform.isAndroid) return;
    _isLocked = false;
    await activate();
  }

  /// Reset the cached lock flag (test-only).
  @visibleForTesting
  static void resetForTest() {
    _isLocked = false;
  }
}
