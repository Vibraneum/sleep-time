import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/platform/android_lockdown.dart';

void main() {
  group('AndroidGuardianEvent.fromMap', () {
    test('parses a fully-populated map', () {
      final event = AndroidGuardianEvent.fromMap(<dynamic, dynamic>{
        'state': 'locked',
        'grantExpiresAt': 1735689600000,
        'degraded': true,
      });
      expect(event.state, 'locked');
      expect(event.grantExpiresAt, 1735689600000);
      expect(event.degraded, isTrue);
    });

    test('falls back to defaults on a missing/empty map', () {
      final event = AndroidGuardianEvent.fromMap(const <dynamic, dynamic>{});
      expect(event.state, 'inactive');
      expect(event.grantExpiresAt, 0);
      expect(event.degraded, isFalse);
    });

    test('tolerates mistyped numeric fields', () {
      // Platform channels can deliver ints as num; ensure toInt() coercion.
      final event = AndroidGuardianEvent.fromMap(<dynamic, dynamic>{
        'state': 'windDown',
        'grantExpiresAt': 42.0,
        'degraded': false,
      });
      expect(event.state, 'windDown');
      expect(event.grantExpiresAt, 42);
      expect(event.degraded, isFalse);
    });

    test('equality and hashCode are value-based', () {
      const a = AndroidGuardianEvent(state: 'locked', degraded: true);
      const b = AndroidGuardianEvent(state: 'locked', degraded: true);
      const c = AndroidGuardianEvent(state: 'unlocked');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('AndroidPermissionStatus.fromMap', () {
    test('parses booleans and defaults missing keys to false', () {
      final status = AndroidPermissionStatus.fromMap(<dynamic, dynamic>{
        'notifications': true,
        'exactAlarm': false,
        'batteryExemption': true,
      });
      expect(status.notifications, isTrue);
      expect(status.exactAlarm, isFalse);
      expect(status.batteryExemption, isTrue);
      // M5 placeholders default false when absent.
      expect(status.overlay, isFalse);
      expect(status.accessibility, isFalse);
      expect(status.usageAccess, isFalse);
    });
  });

  // These exercise the off-Android guards. On the test host (not Android) every
  // method must be a safe no-op / benign default without touching a platform
  // channel.
  group('AndroidLockdown off-Android guards', () {
    setUp(AndroidLockdown.resetForTest);

    test('isNativeReady returns false off-Android', () async {
      if (Platform.isAndroid) return;
      expect(await AndroidLockdown.isNativeReady(), isFalse);
    });

    test('events() yields an empty stream off-Android', () async {
      if (Platform.isAndroid) return;
      expect(await AndroidLockdown.events().isEmpty, isTrue);
    });

    test('lifecycle methods are no-ops off-Android', () async {
      if (Platform.isAndroid) return;
      await AndroidLockdown.startGuardian();
      await AndroidLockdown.stopGuardian();
      await AndroidLockdown.setSchedule();
      await AndroidLockdown.requestExactAlarm();
      await AndroidLockdown.requestNotifications();
      await AndroidLockdown.requestBatteryExemption();
      await AndroidLockdown.activate();
      await AndroidLockdown.deactivate();
      await AndroidLockdown.grantExtension();
      await AndroidLockdown.relock();
      expect(AndroidLockdown.isLocked, isFalse);
    });

    test('getPermissionStatus returns all-false default off-Android', () async {
      if (Platform.isAndroid) return;
      final status = await AndroidLockdown.getPermissionStatus();
      expect(status.notifications, isFalse);
      expect(status.exactAlarm, isFalse);
      expect(status.batteryExemption, isFalse);
    });
  });
}
