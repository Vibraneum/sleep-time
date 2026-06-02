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

/// A single installed app the user can choose to put on the allow-list.
@immutable
class AndroidInstalledApp {
  final String package;
  final String label;

  const AndroidInstalledApp({required this.package, required this.label});

  factory AndroidInstalledApp.fromMap(Map<dynamic, dynamic> map) =>
      AndroidInstalledApp(
        package: (map['package'] as String?) ?? '',
        label: (map['label'] as String?) ?? (map['package'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is AndroidInstalledApp &&
      other.package == package &&
      other.label == label;

  @override
  int get hashCode => Object.hash(package, label);
}

/// Native runtime permission snapshot for the Android guardian. Overlay /
/// accessibility / usage-access are real signals as of M5.
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

  /// Open the system "draw over other apps" (overlay) settings.
  static Future<void> requestOverlay() async => _invokeVoid('requestOverlay');

  /// Open the system Usage-Access settings (PRIMARY foreground-app detector).
  static Future<void> requestUsageAccess() async =>
      _invokeVoid('requestUsageAccess');

  /// Open the system Accessibility settings (OPTIONAL latency enhancement).
  /// Callers MUST show the prominent-disclosure dialog before invoking this.
  static Future<void> requestAccessibility() async =>
      _invokeVoid('requestAccessibility');

  /// Add [package] to the native time-limited allow-list for [minutes].
  /// Returns true when the native side accepted it.
  static Future<bool> allowApp({
    required String package,
    required int minutes,
    String label = '',
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod('allowApp', {
        'package': package,
        'label': label,
        'minutes': minutes,
      });
      return ok == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// The device manufacturer (`Build.MANUFACTURER`), lowercased, for best-effort
  /// OEM battery deep-link hints. Empty off-Android / when unavailable.
  static Future<String> deviceManufacturer() async {
    if (!Platform.isAndroid) return '';
    try {
      final m = await _channel.invokeMethod('deviceManufacturer');
      return (m as String?)?.toLowerCase() ?? '';
    } on MissingPluginException {
      return '';
    } catch (_) {
      return '';
    }
  }

  /// The launchable installed-app catalog (no QUERY_ALL_PACKAGES). Empty
  /// off-Android or when the plugin is missing.
  static Future<List<AndroidInstalledApp>> listInstalledApps() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod('listInstalledApps');
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map(AndroidInstalledApp.fromMap)
            .where((a) => a.package.isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    } on MissingPluginException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// Register a callback fired when native pushes a fresh permission snapshot
  /// (e.g. after the user returns from a system settings screen via onResume).
  static void setPermissionStatusListener(
    void Function(AndroidPermissionStatus status)? listener,
  ) {
    if (!Platform.isAndroid) return;
    if (listener == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPermissionStatusChanged') {
        final args = call.arguments;
        if (args is Map) listener(AndroidPermissionStatus.fromMap(args));
      }
      return null;
    });
  }

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
    // Clear any full-grant enforcement pause so a later re-lock starts clean.
    await resumeEnforcement();
    await stopGuardian();
  }

  /// Grant a FULL timed extension: the guardian keeps running (it owns the
  /// schedule) but native overlay enforcement is SUSPENDED until [untilEpochMs]
  /// so the whole device is usable for the grant. The pause auto-expires by wall
  /// clock; [deactivate]/[relock] also clear it. Safe-mode is a no-op.
  static Future<void> grantExtension({int? untilEpochMs}) async {
    if (!Platform.isAndroid) return;
    if (_simulating) {
      if (kDebugMode) debugPrint('[sleep-time] simulate: android grant');
      return;
    }
    if (untilEpochMs == null || untilEpochMs <= 0) {
      // No duration to honor — leave the guardian fully armed.
      return;
    }
    try {
      await _channel
          .invokeMethod('pauseEnforcement', {'untilEpochMs': untilEpochMs});
    } on MissingPluginException {
      // ignore
    } catch (_) {}
  }

  /// Resume native enforcement after a full grant ends/expires.
  static Future<void> resumeEnforcement() async {
    if (!Platform.isAndroid) return;
    if (_simulating) return;
    try {
      await _channel.invokeMethod('resumeEnforcement');
    } on MissingPluginException {
      // ignore
    } catch (_) {}
  }

  /// Re-lock after an extension expires — clear any full-grant pause and
  /// re-activate so the overlay re-arms.
  static Future<void> relock() async {
    if (!Platform.isAndroid) return;
    await resumeEnforcement();
    _isLocked = false;
    await activate();
  }

  /// Reset the cached lock flag (test-only).
  @visibleForTesting
  static void resetForTest() {
    _isLocked = false;
  }
}
